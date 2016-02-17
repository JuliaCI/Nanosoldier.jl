module Nanosoldier

################
# import/using #
################

import GitHub, BenchmarkTrackers, JSON, HttpCommon

using Compat

################
# ServerConfig #
################

immutable ServerConfig
    auth::GitHub.Authorization # the GitHub authorization used to post statuses/reports
    trigger::UTF8String        # the trigger phrase used in job-submitting comments
    buildrepo::UTF8String      # the main Julia repo tracked by the server
    reportrepo::UTF8String     # the repo to which result reports are posted
    workdir::UTF8String        # the server's work directory
    resultdir::UTF8String      # the directory where benchmark results are stored
    logdir::UTF8String         # the directory where build logs are stored
    makejobs::Int              # the value passed to `make -j` on child node builds
    function ServerConfig(workdir = pwd();
                          auth = GitHub.AnonymousAuth(),
                          trigger = "runbenchmarks",
                          buildrepo = "JuliaLang/julia",
                          reportrepo = "JuliaCI/BaseBenchmarkReports",
                          makejobs = 1)
        resultdir = joinpath(workdir, "benchmark_results")
        logdir = joinpath(workdir, "benchmark_logs")
        persistdir!(workdir)
        persistdir!(resultdir)
        persistdir!(logdir)
        return new(auth, trigger, buildrepo, reportrepo, workdir, resultdir, logdir, makejobs)
    end
end

###########################
# Build/Job Configuration #
###########################

const SHA_SEP = '@'
const BRANCH_SEP = ':'

type BuildRef
    repo::UTF8String  # the build repo
    sha::UTF8String   # the build + status SHA
    vinfo::UTF8String # versioninfo() taken during the build
end

BuildRef(repo, sha) = BuildRef(repo, sha, "?")

type BenchmarkJob
    primary::BuildRef           # the primary build
    against::Nullable{BuildRef} # the comparison build (if available)
    tagpredstr::UTF8String      # the tag predicate in string form
    status_sha::UTF8String      # report statuses to this SHA for this job
    trigger_url::UTF8String     # the URL linking to the triggering comment
    from_kind::Symbol           # :pr, :review, or :commit?
    pr_number::Nullable{Int}    # the job's PR number, if relevant
end

function BenchmarkJob(config::ServerConfig, event::GitHub.WebhookEvent, argstr::AbstractString)
    tagpredstr, against_ref = parsetrigger(argstr)

    if event.kind == "commit_comment"
        # A commit was commented on, and the comment contained a trigger phrase.
        # The primary repo is the location of the comment, and the primary SHA
        # is that of the commit that was commented on.
        primary_repo = get(event.repository.full_name)
        primary_sha = event.payload["comment"]["commit_id"]
        trigger_url = event.payload["comment"]["html_url"]
        from_kind = :commit
        pr_number = Nullable{Int}()
    elseif event.kind == "pull_request_review_comment"
        # A diff was commented on, and the comment contained a trigger phrase.
        # The primary repo is the location of the head branch, and the primary
        # SHA is that of the commit associated with the diff.
        primary_repo = event.payload["pull_request"]["head"]["repo"]["full_name"]
        primary_sha = event.payload["comment"]["commit_id"]
        trigger_url = event.payload["comment"]["html_url"]
        from_kind = :review
        pr_number = Nullable(Int(event.payload["pull_request"]["number"]))
    elseif event.kind == "pull_request"
        # A PR was opened, and the description body contained a trigger phrase.
        # The primary repo is the location of the head branch, and the primary
        # SHA is that of the head commit. The PR number is provided, so that the
        # build can execute on the relevant merge commit.
        primary_repo = event.payload["pull_request"]["head"]["repo"]["full_name"]
        primary_sha = event.payload["pull_request"]["head"]["sha"]
        trigger_url = event.payload["pull_request"]["html_url"]
        from_kind = :pr
        pr_number = Nullable(Int(event.payload["pull_request"]["number"]))
    elseif event.kind == "issue_comment"
        # A comment was made in a PR, and it contained a trigger phrase. The
        # primary repo is the location of the PR's head branch, and the primary
        # SHA is that of the head commit. The PR number is provided, so that the
        # build can execute on the relevant merge commit.
        pr = GitHub.pull_request(event.repository, event.payload["issue"]["number"], auth = config.auth)
        primary_repo = get(get(get(pr.head).repo).full_name)
        primary_sha = get(get(pr.head).sha)
        trigger_url = event.payload["comment"]["html_url"]
        from_kind = :pr
        pr_number = Nullable(Int(get(pr.number)))
    end

    primary = BuildRef(primary_repo, primary_sha)

    if isnull(against_ref)
        against = Nullable{BuildRef}()
    else
        against_ref = get(against_ref)
        if in(SHA_SEP, against_ref) # e.g. against_ref == jrevels/julia@e83b7559df94b3050603847dbd6f3674058027e6
            against = Nullable(BuildRef(split(against_ref, SHA_SEP)...))
        elseif in(BRANCH_SEP, against_ref)
            against_repo, against_branch = split(against_ref, BRANCH_SEP)
            against_sha = get(get(GitHub.branch(against_repo, against_branch; auth = config.auth).commit).sha)
            against = Nullable(BuildRef(against_repo, against_sha))
        else
            against = Nullable(BuildRef(primary_repo, against_ref))
        end
    end

    return BenchmarkJob(primary, against, tagpredstr, primary_sha, trigger_url, from_kind, pr_number)
end

function parsetrigger(argstr::AbstractString)
    parsed = parse(argstr)

    # if provided, extract a comparison ref from the trigger arguments
    against_ref = Nullable{UTF8String}()
    if (isa(parsed, Expr) && length(parsed.args) == 2 &&
        isa(parsed.args[2], Expr) && parsed.args[2].head == :(=))
        vskv = parsed.args[2].args
        tagpred = parsed.args[1]
        if length(vskv) == 2 && vskv[1] == :vs
            against_ref = Nullable(UTF8String(vskv[2]))
        else
            error("malformed comparison argument: $vskv")
        end
    else
        tagpred = parsed
    end

    # If `tagpred` is just a single tag, it'll just be a string, in which case
    # we'll need to wrap it in escaped quotes so that it can be interpolated.
    if isa(tagpred, AbstractString)
        tagpredstr = string('"', tagpred, '"')
    else
        tagpredstr = string(tagpred)
    end

    return tagpredstr, against_ref
end

function Base.summary(job::BenchmarkJob)
    result = summary(job.primary)
    if !(isnull(job.against))
        result = "$(result) vs $(summary(get(job.against)))"
    end
    return result
end

Base.summary(build::BuildRef) = string(build.repo, SHA_SEP, snipsha(build.sha))

##################################
# Running a server from a config #
##################################

function Base.run(config::ServerConfig, args...; workers = setdiff(procs(), 1), secret = nothing, kwargs...)
    @assert !(isempty(workers)) "ServerConfig server needs at least one worker node besides the master node"
    @assert myid() == 1 "ServerConfig server must be run from the master node"

    jobs = Vector{BenchmarkJob}()

    # This closure is the CommentListener's handle function, which validates the
    # trigger arguments and converts the event payload into a BenchmarkJob. This
    # job then gets added to the `jobs` queue, which is monitored and resoved by
    # the job-feeding tasks scheduled below.
    handle = (event, argstr) -> begin
        if event.kind == "issue_comment" && !(haskey(event.payload["issue"], "pull_request"))
            return HttpCommon.Response(400, "non-commit comments can only trigger jobs from pull resquests, not issues")
        end
        job = BenchmarkJob(config, event, argstr)
        if !(is_valid_tagpred(job.tagpredstr))
            descr = "invalid tag predicate: $(job.tagpredstr)"
            create_job_status(config, job, "error", descr)
            return HttpCommon.Response(400, descr)
        end
        push!(jobs, job)
        descr = "job added to queue: $(summary(job))"
        create_job_status(config, job, "pending", descr)
        return HttpCommon.Response(202, descr)
    end

    listener = GitHub.CommentListener(handle, config.trigger;
                                      auth = config.auth,
                                      secret = secret,
                                      repos = [config.buildrepo])

    # Schedule a task for each worker that feeds the worker a job from the
    # queque once the worker has completed its primary job. If the queue is
    # empty, then the task will call `yield` in order to avoid a deadlock.
    for worker in workers
        @schedule begin
            try
                while true
                    if isempty(jobs)
                        yield()
                    else
                        job = shift!(jobs)
                        # wait for a second so that we don't end up posting the
                        # "running" status before the "added to queue" status
                        sleep(1)
                        message = "running job on worker $(worker)"
                        create_job_status(config, job, "pending", message)
                        workerlog(worker, config, message)
                        try
                            workerlog(worker, config, "running primary build: $(summary(job.primary))")
                            job, primary_record = remotecall_fetch(execute_base_benchmarks!, worker, config, job, :primary)
                            workerlog(worker, config, "finished primary build: $(summary(job.primary))")
                            if !(isnull(job.against))
                                workerlog(worker, config, "running comparison build: $(summary(get(job.against)))")
                                job, against_record = remotecall_fetch(execute_base_benchmarks!, worker, config, job, :against)
                                workerlog(worker, config, "finished comparison build: $(summary(get(job.against)))")
                                report_results(config, job, worker, primary_record, against_record)
                            else
                                report_results(config, job, worker, primary_record)
                            end
                        catch err
                            message = "encountered error: $(err)"
                            create_job_status(config, job, "error", message)
                            workerlog(worker, config, message)
                        end
                    end
                end
            catch err
                workerlog(worker, config, "encountered task error: $(err)")
                throw(err)
            end
        end
    end

    return run(listener, args...; kwargs...)
end

# Tag Predicate Validation #
#--------------------------#
# The tag predicate is valid if it is simply a single tag, "ALL", or an
# expression joining multiple tags with the allowed symbols. This validation is
# only to prevent server-side evaluation of arbitrary code. No check is
# performed to ensure that the tag predicate is grammatically correct.

const VALID_TAG_PRED_SYMS = (:!, :&&, :||, :call)

function is_valid_tagpred(tagpredstr::AbstractString)
    parsed = parse(tagpredstr)
    if isa(parsed, Expr)
        return is_valid_tagpred(parsed)
    elseif parsed == :ALL
        return true
    else
        return isa(parsed, AbstractString)
    end
end

function is_valid_tagpred(tagpred::Expr)
    if !(in(tagpred.head, VALID_TAG_PRED_SYMS))
        return false
    else
        for item in tagpred.args
            if isa(item, Expr)
                if !(is_valid_tagpred(item))
                    return false
                end
            elseif isa(item, Symbol)
                if !(in(item, VALID_TAG_PRED_SYMS))
                    return false
                end
            elseif !(isa(item, AbstractString))
                return false
            end
        end
    end
    return true
end

#################
# Job Execution #
#################

function execute_base_benchmarks!(config::ServerConfig, job::BenchmarkJob, buildsym::Symbol)
    build = buildsym == :against ? get(job.against) : job.primary

    # Make a temporary workdir for Julia building and benchmark execution.
    # Don't use the deterministically destructing version of this method - for
    # debugging purposes, we want the build to remain on nanosoldier in case of
    # an error.
    buildpath = mktempdir(config.workdir)

    cd(buildpath)

    # clone/fetch the appropriate Julia version
    juliapath = joinpath(buildpath, "julia_$(build.sha)")

    if buildsym == :primary && job.from_kind == :pr
        pr = get(job.pr_number)
        run(`git clone --quiet https://github.com/$(config.buildrepo) $(juliapath)`)
        cd(juliapath)
        try
            run(`git fetch --quiet origin +refs/pull/$(pr)/merge:`)
        catch
            # if there's not a merge commit on the remote (likely due to
            # merge conflicts) then fetch the head commit instead.
            run(`git fetch --quiet origin +refs/pull/$(pr)/head:`)
        end
        run(`git checkout --quiet --force FETCH_HEAD`)
        build.sha = readchomp(`git rev-parse HEAD`)
    else
        run(`git clone --quiet https://github.com/$(build.repo) $(juliapath)`)
        cd(juliapath)
        run(`git checkout --quiet $(build.sha)`)
    end

    ENV["JULIA_THREADS"] = 1 # enable threading, if possible

    run(`make --silent -j $(config.makejobs)`)

    # Call `BaseBenchmarks.execute` in a new julia process using the fresh
    # build, splicing the tagpredicate string into the command. The resulting
    # record is serialized to the buildspace so that we can retrieve it from
    # outside of the new process.
    #
    # This command assumes that all packages are available in the working
    # process's Pkg directory.
    benchname = string(snipsha(build.sha), "_", buildsym)
    benchout = joinpath(config.logdir,  string(benchname, ".out"))
    bencherr = joinpath(config.logdir,  string(benchname, ".err"))
    benchresult = joinpath(config.resultdir, string(benchname, ".jls"))
    cmd = """
          using BaseBenchmarks;
          benchout = open(\"$(benchout)\", "w"); redirect_stdout(benchout);
          bencherr = open(\"$(bencherr)\", "w"); redirect_stderr(bencherr);
          benchresult = open(\"$(benchresult)\", "w");
          record = BaseBenchmarks.@execute $(job.tagpredstr);
          serialize(benchresult, record)
          close(benchresult); close(benchout); close(bencherr);
          """
    cd(juliapath)
    run(`./julia -e $(cmd)`)

    # deserialize the resulting BenchmarkRecord
    record = open(benchresult, "r") do file
        return deserialize(file)
    end

    # Get the verbose output of versioninfo for the build, throwing away
    # environment information that is useless/potentially risky to expose.
    try
        build.vinfo = first(split(readstring(`./julia -e 'versioninfo(true)'`), "Environment"))
    end

    cd(config.workdir)

    # delete the buildpath now that we're done with it
    rm(buildpath, recursive = true)

    return job, record
end

#############################
# Summary Report Generation #
#############################

# Generate a more detailed markdown report in the JuliaCI/BenchmarkReports repo,
# and link to this report in the final status on the relevant commit.
function report_results(config::ServerConfig, job::BenchmarkJob, worker,
                        records::BenchmarkTrackers.BenchmarkRecord...)
    workerlog(worker, config, "generating report for job: $(summary(job))")
    summary_dict = create_summary_dict(records...)
    job_summary = summary(job)
    url = ""
    report_path = report_file_path(job)
    file_name = report_file_name(job)

    if isempty(summary_dict["primary"])
        state = "error"
        status_message = "no benchmarks were executed"
        comment_message = "[Your benchmark job]($(job.trigger_url)) has completed, but no benchmarks were actually executed. Perhaps your tag predicate contains mispelled tags? cc @jrevels"
        create_job_status(config, job, state, status_message, url)
        create_report_comment(config, job, comment_message)
        workerlog(worker, config, "job complete: $(status_message)")
    else
        # It's okay if one (or all three) of the below try blocks fail. If all is successful, the status
        # URL goes from an empty string, to a link to the result data, to a
        # link to the markdown summary. Thus, even if there are failures, the status
        # URL will always point to the most "preferred" information available
        # (no link < link to data < link to markdown summary).

        # This is currently commented out because we're using this infrastructure to collect
        # large sample sizes that we don't want to upload to GitHub (which will just reject
        # such large binaries)
        # try
        #     # upload summary_dict to the report repository
        #     record_path = joinpath(report_path, "$(file_name).json")
        #     record_data = base64encode(JSON.json(summary_dict))
        #     message = "add result data for job: $(job_summary)"
        #     url = upload_report_file(config, record_path, record_data, message)
        #     workerlog(worker, config, "committed result data to $(config.reportrepo) at $(record_path)")
        # catch err
        #     workerlog(worker, config, "error when committing result data: $(err)")
        # end

        try
            # upload markdown summary to the report repository
            report_path = joinpath(report_path, "$(file_name).md")
            report_markdown = base64encode(io2string(io -> print_report(io, job, summary_dict)))
            message = "add markdown report for job: $(job_summary)"
            url = upload_report_file(config, report_path, report_markdown, message)
            workerlog(worker, config, "committed markdown report to $(config.reportrepo) at $(report_path)")
        catch err
            workerlog(worker, config, "error when committing markdown report: $(err)")
        end

        if isnull(job.against)
            state = "success"
            status_message = "successfully executed benchmarks"
        else
            wassuccess = summary_dict["success?"]
            state = wassuccess ? "success" : "failure"
            status_message = wassuccess ? "no performance regressions were detected" : "possible performance regressions were detected"
        end

        create_job_status(config, job, state, status_message, url)

        if isempty(url)
            comment_message = "[Your benchmark job]($(job.trigger_url)) has completed, but something went wrong when trying to upload the result data. cc @jrevels"
        else
            comment_message = "[Your benchmark job]($(job.trigger_url)) has completed - $(status_message). A full report can be found [here]($(url)). cc @jrevels"
        end
        create_report_comment(config, job, comment_message)

        workerlog(worker, config, "job complete: $(status_message)")
    end
end

# summary dict creation #
#-----------------------#

function create_summary_dict(primary_record::BenchmarkTrackers.BenchmarkRecord)
    return Dict("primary" => primary_record)
end

function create_summary_dict(primary_record::BenchmarkTrackers.BenchmarkRecord,
                             against_record::BenchmarkTrackers.BenchmarkRecord)
    compare_record = compare(primary_record, against_record)
    judge_record, detected_regression = judge(compare_record)
    return Dict("primary" => primary_record,
                "against" => against_record,
                "judged" => judge_record,
                "success?" => !(detected_regression))
end

# Comment Report #
#----------------#

function create_report_comment(config::ServerConfig, job::BenchmarkJob, message::AbstractString)
    comment_place = isnull(job.pr_number) ? job.status_sha : get(job.pr_number)
    comment_kind = job.from_kind == :review ? :pr : job.from_kind
    return GitHub.create_comment(config.buildrepo, comment_place, comment_kind;
                                 auth = config.auth, params = Dict("body" => message))
end

# Markdown Report #
#-----------------#

const REGRESS_MARK = ":x:"
const IMPROVE_MARK = ":white_check_mark:"

report_file_path(job::BenchmarkJob) = snipsha(job.primary.sha)

function report_file_name(job::BenchmarkJob)
    report_path = report_file_path(job)
    file_name = isnull(job.against) ? report_path : "$(report_path)_vs_$(snipsha(get(job.against).sha))"
    return file_name
end

function upload_report_file(config, path, content, message)
    params = Dict("content" => content, "message" => message)
    priorfile = GitHub.file(config.reportrepo, path; auth = config.auth, handle_error = false)
    if isnull(priorfile.sha)
        results = GitHub.create_file(config.reportrepo, path; auth = config.auth, params = params)
    else
        params["sha"] = get(priorfile.sha)
        results = GitHub.update_file(config.reportrepo, path; auth = config.auth, params = params)
    end
    return string(GitHub.permalink(results["content"], results["commit"]))
end

function print_report(io, job, summary_dict)
    primary_ref = string(job.primary.repo, SHA_SEP, snipsha(job.primary.sha))
    primary_link = "https://github.com/$(job.primary.repo)/commit/$(job.primary.sha)"
    job_summary = "[$(primary_ref)]($(primary_link))"
    is_comparison_job = !(isnull(job.against))

    if is_comparison_job
        against_build = get(job.against)
        against_ref = string(against_build.repo, SHA_SEP, snipsha(against_build.sha))
        against_link = "https://github.com/$(against_build.repo)/commit/$(against_build.sha)"
        job_summary = "$(job_summary) vs [$(against_ref)]($(against_link))"
        table_dict = summary_dict["judged"]
    else
        table_dict = summary_dict["primary"]
    end

    # print report preface + job properties

    println(io, """
                # Benchmark Report

                ## Job Properties

                *Commit(s):* $(job_summary)

                *Tag Predicate:* `$(job.tagpredstr)`

                *Triggered By:* [link]($(job.trigger_url))

                ## Results

                Below is a table of this job's results. If available, the data used to generate this
                table can be found in the JSON file in this directory.

                Benchmark definitions can be found in [JuliaCI/BaseBenchmarks.jl](https://github.com/JuliaCI/BaseBenchmarks.jl).
                """)

    # print benchmark results

    if is_comparison_job
        println(io, """
                    The ratio values in the below table equal `primary_result / comparison_result` for each corresponding
                    metric. Thus, `x < 1.0` would denote an improvement, while `x > 1.0` would denote a regression.
                    Note that a default tolerance of `0.2` is applied to account for the variance of our test
                    hardware.

                    Regressions are marked with $(REGRESS_MARK), while improvements are marked with $(IMPROVE_MARK). GC
                    measurements are [not considered when determining regression status](https://github.com/JuliaCI/BenchmarkTrackers.jl/issues/5).

                    Only benchmarks with significant results - results that indicate regressions or improvements - are
                    shown below (an empty table means that all benchmark results remained invariant between builds).
                    """)
    end

    print(io, """
              | Group ID | Benchmark ID | time | time spent in GC | bytes allocated | number of allocations |
              |----------|--------------|------|------------------|-----------------|-----------------------|
              """)

    group_ids = collect(keys(table_dict))

    try
        sort!(group_ids)
    end

    for group_id in group_ids
        group_results = table_dict[group_id].results
        bench_ids = collect(keys(group_results))
        try
            sort!(bench_ids)
        end
        for bench_id in bench_ids
            metrics = group_results[bench_id]
            if !(is_comparison_job) || is_significant(metrics)
                println(io, result_row(group_id, bench_id, metrics))
            end
        end
    end

    println(io)

    # print version info for Julia builds

    println(io, """
                ## Version Info

                #### Primary Build

                ```
                $(job.primary.vinfo)
                ```
                """)

    if is_comparison_job
        println(io, """
                    #### Comparison Build

                    ```
                    $(get(job.against).vinfo)
                    ```
                    """)
    end

    # print list of executed benchmarks

    println(io, """
                ## Benchmark Group List

                Here's a list of all the benchmark groups executed by this job:
                """)

    for group_id in group_ids
        println(io, "- `", group_id, "`")
    end
end

function result_row(group_id, bench_id, metrics::BenchmarkTrackers.Metrics)
    timestr = result_string(metrics, :time)
    gcstr = result_string(metrics, :gctime)
    bytestr = result_string(metrics, :bytes)
    allocstr = result_string(metrics, :allocs)
    return "| `$(group_id)` | `$(bench_id)` | $(timestr) | $(gcstr) | $(bytestr) | $(allocstr) |"
end

function result_string{T<:Number}(metrics::BenchmarkTrackers.Metrics{Tuple{Symbol,T}}, sym::Symbol)
    state, x = getfield(metrics, sym)
    result = result_string(x)
    if sym == :gctime # markers aren't added to GC results, see #5
        return result
    elseif state == :regression
        result = "**$(result)** $(REGRESS_MARK)"
    elseif state == :improvement
        result = "**$(result)** $(IMPROVE_MARK)"
    end
    return result
end

function result_string{T<:Number}(metrics::BenchmarkTrackers.Metrics{T}, sym::Symbol)
    return result_string(getfield(metrics, sym))
end

result_string(x::Number) = string(round(x, 2))

function is_significant{T<:Number}(metrics::BenchmarkTrackers.Metrics{Tuple{Symbol,T}})
    return (first(metrics.time) != :invariant ||
            first(metrics.bytes) != :invariant ||
            first(metrics.allocs) != :invariant)
end

#############
# Utilities #
#############

function io2string(f)
    tmpio = IOBuffer()
    f(tmpio)
    str = takebuf_string(tmpio)
    close(tmpio)
    return str
end

snip(str, len) = length(str) > len ? str[1:len] : str

# abbreviate a SHA to the first 7 characters
snipsha(sha::AbstractString) = snip(sha, 7)

function create_job_status(config::ServerConfig, job::BenchmarkJob, state, description, url=nothing)
    params = Dict("state" => state,
                  "context" => "NanosoldierBenchmark",
                  "description" => snip(description, 140))
    url != nothing && (params["target_url"] = url)
    return GitHub.create_status(config.buildrepo, job.status_sha; auth = config.auth, params = params)
end

function workerlog(worker, config, message)
    persistdir!(config.workdir)
    path = joinpath(config.workdir, "benchmark_worker_$(worker).log")
    open(path, "a") do file
        println(file, now(), " | ", worker, " | ", message)
    end
end

function persistdir!(path)
    !(isdir(path)) && mkdir(path)
    return path
end

end # module
