module Nanosoldier

################
# import/using #
################

import GitHub, BenchmarkTools, JLD, JSON, HttpCommon

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

const SHA_SEPARATOR = '@'
const BRANCH_SEPARATOR = ':'

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
    statussha::UTF8String      # report statuses to this SHA for this job
    triggerurl::UTF8String     # the URL linking to the triggering comment
    fromkind::Symbol           # :pr, :review, or :commit?
    prnumber::Nullable{Int}    # the job's PR number, if relevant
end

function BenchmarkJob(config::ServerConfig, event::GitHub.WebhookEvent, argstr::AbstractString)
    tagpredstr, againstref = parsetrigger(argstr)

    if event.kind == "commit_comment"
        # A commit was commented on, and the comment contained a trigger phrase.
        # The primary repo is the location of the comment, and the primary SHA
        # is that of the commit that was commented on.
        primaryrepo = get(event.repository.full_name)
        primarysha = event.payload["comment"]["commit_id"]
        triggerurl = event.payload["comment"]["html_url"]
        fromkind = :commit
        prnumber = Nullable{Int}()
    elseif event.kind == "pull_request_review_comment"
        # A diff was commented on, and the comment contained a trigger phrase.
        # The primary repo is the location of the head branch, and the primary
        # SHA is that of the commit associated with the diff.
        primaryrepo = event.payload["pull_request"]["head"]["repo"]["full_name"]
        primarysha = event.payload["comment"]["commit_id"]
        triggerurl = event.payload["comment"]["html_url"]
        fromkind = :review
        prnumber = Nullable(Int(event.payload["pull_request"]["number"]))
    elseif event.kind == "pull_request"
        # A PR was opened, and the description body contained a trigger phrase.
        # The primary repo is the location of the head branch, and the primary
        # SHA is that of the head commit. The PR number is provided, so that the
        # build can execute on the relevant merge commit.
        primaryrepo = event.payload["pull_request"]["head"]["repo"]["full_name"]
        primarysha = event.payload["pull_request"]["head"]["sha"]
        triggerurl = event.payload["pull_request"]["html_url"]
        fromkind = :pr
        prnumber = Nullable(Int(event.payload["pull_request"]["number"]))
    elseif event.kind == "issue_comment"
        # A comment was made in a PR, and it contained a trigger phrase. The
        # primary repo is the location of the PR's head branch, and the primary
        # SHA is that of the head commit. The PR number is provided, so that the
        # build can execute on the relevant merge commit.
        pr = GitHub.pull_request(event.repository, event.payload["issue"]["number"], auth = config.auth)
        primaryrepo = get(get(get(pr.head).repo).full_name)
        primarysha = get(get(pr.head).sha)
        triggerurl = event.payload["comment"]["html_url"]
        fromkind = :pr
        prnumber = Nullable(Int(get(pr.number)))
    end

    primary = BuildRef(primaryrepo, primarysha)

    if isnull(againstref)
        against = Nullable{BuildRef}()
    else
        againstref = get(againstref)
        if in(SHA_SEPARATOR, againstref) # e.g. againstref == jrevels/julia@e83b7559df94b3050603847dbd6f3674058027e6
            against = Nullable(BuildRef(split(againstref, SHA_SEPARATOR)...))
        elseif in(BRANCH_SEPARATOR, againstref)
            againstrepo, againstbranch = split(againstref, BRANCH_SEPARATOR)
            against = branchref(config, againstrepo, againstbranch)
        elseif in('/', againstref) # e.g. againstref == jrevels/julia
            against = branchref(config, againstref, "master")
        else # e.g. againstref == e83b7559df94b3050603847dbd6f3674058027e6
            against = Nullable(BuildRef(primaryrepo, againstref))
        end
    end

    return BenchmarkJob(primary, against, tagpredstr, primarysha, triggerurl, fromkind, prnumber)
end

function branchref(config::ServerConfig, reponame::AbstractString, branchname::AbstractString)
    shastr = get(get(GitHub.branch(reponame, branchname; auth = config.auth).commit).sha)
    return Nullable(BuildRef(reponame, shastr))
end

function parsetrigger(argstr::AbstractString)
    parsed = parse(argstr)

    # if provided, extract a comparison ref from the trigger arguments
    againstref = Nullable{UTF8String}()
    if (isa(parsed, Expr) && length(parsed.args) == 2 &&
        isa(parsed.args[2], Expr) && parsed.args[2].head == :(=))
        vskv = parsed.args[2].args
        tagpred = parsed.args[1]
        if length(vskv) == 2 && vskv[1] == :vs
            againstref = Nullable(UTF8String(vskv[2]))
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

    return tagpredstr, againstref
end

function Base.summary(job::BenchmarkJob)
    result = summary(job.primary)
    if !(isnull(job.against))
        result = "$(result) vs $(summary(get(job.against)))"
    end
    return result
end

Base.summary(build::BuildRef) = string(build.repo, SHA_SEPARATOR, build.sha)

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
                            job, primary_result = remotecall_fetch(execute_base_benchmarks!, worker, config, job, :primary)
                            workerlog(worker, config, "finished primary build: $(summary(job.primary))")
                            results = Dict("primary" => primary_result)
                            if !(isnull(job.against))
                                workerlog(worker, config, "running comparison build: $(summary(get(job.against)))")
                                job, against_result = remotecall_fetch(execute_base_benchmarks!, worker, config, job, :against)
                                workerlog(worker, config, "finished comparison build: $(summary(get(job.against)))")
                                results["against"] = against_result
                            end
                            report_results(config, job, worker, results)
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

const VALID_TAG_PRED_SYMS = (:!, :&&, :||, :call, :ALL)

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
                !(is_valid_tagpred(item)) && return false
            elseif isa(item, Symbol)
                !(in(item, VALID_TAG_PRED_SYMS)) && return false
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

    if buildsym == :primary && job.fromkind == :pr
        pr = get(job.prnumber)
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

    # don't enable this yet, since threading is still often broken
    # ENV["JULIA_THREADS"] = 1 # enable threading, if possible

    run(`make --silent -j $(config.makejobs)`)

    # Execute benchmarks in a new julia process using the fresh build, splicing the tag
    # predicate string into the command. The result is serialized so that we can retrieve it
    # from outside of the new process.
    #
    # This command assumes that all packages are available in the working process's Pkg
    # directory.
    benchname = string(snipsha(build.sha), "_", buildsym)
    benchout = joinpath(config.logdir,  string(benchname, ".out"))
    bencherr = joinpath(config.logdir,  string(benchname, ".err"))
    benchresult = joinpath(config.resultdir, string(benchname, ".jld"))
    cmd = """
          benchout = open(\"$(benchout)\", "w"); redirect_stdout(benchout);
          bencherr = open(\"$(bencherr)\", "w"); redirect_stderr(bencherr);
          blas_set_num_threads(1);
          addprocs(1); # add worker that can be used by parallel benchmarks
          using BaseBenchmarks;
          using BenchmarkTools;
          using JLD;
          println("FILTERING SUITE...");
          benchmarks = BaseBenchmarks.SUITE[@tagged($(job.tagpredstr))];
          println("RUNNING WARMUP...");
          @warmup(benchmarks);
          println("RUNNING BENCHMARKS...");
          result = minimum(run(benchmarks; verbose = true));
          println("SAVING RESULT...");
          JLD.save(\"$(benchresult)\", "result", result);
          println("DONE!");
          close(benchout); close(bencherr);
          """
    cd(juliapath)
    run(`./julia -e $(cmd)`)

    result = JLD.load(benchresult, "result")

    # Get the verbose output of versioninfo for the build, throwing away
    # environment information that is useless/potentially risky to expose.
    try
        build.vinfo = first(split(readstring(`./julia -e 'versioninfo(true)'`), "Environment"))
    end

    cd(config.workdir)

    # delete the buildpath now that we're done with it
    rm(buildpath, recursive = true)

    return job, result
end

#############################
# Summary Report Generation #
#############################

# Generate a more detailed markdown report in the JuliaCI/BenchmarkReports repo,
# and link to this report in the final status on the relevant commit.
function report_results(config::ServerConfig, job::BenchmarkJob, worker, results)
    jobsummary = summary(job)
    filepath = report_filepath(job)
    filename = report_filename(job)
    url = ""
    workerlog(worker, config, "reporting results for job: $(jobsummary)")
    if isempty(results["primary"])
        state = "error"
        statusmessage = "no benchmarks were executed"
        commentmessage = "[Your benchmark job]($(job.triggerurl)) has completed, but no benchmarks were actually executed. Perhaps your tag predicate contains mispelled tags? cc @jrevels"
        create_job_status(config, job, state, statusmessage, url)
        create_report_comment(config, job, commentmessage)
        workerlog(worker, config, "job complete: $(statusmessage)")
    else
        # upload raw result data to the report repository
        try
            resultpath = joinpath(filepath, "$(filename).json")
            resultdata = base64encode(JSON.json(results))
            message = "add result data for job: $(jobsummary)"
            url = upload_report_file(config, resultpath, resultdata, message)
            workerlog(worker, config, "committed result data to $(config.reportrepo) at $(resultpath)")
        catch err
            workerlog(worker, config, "error when committing result data: $(err)")
        end

        # judge the results and generate the corresponding status messages
        if !(isnull(job.against))
            judged = BenchmarkTools.judge(results["primary"], results["against"])
            results["judged"] = judged
            issuccess = !(BenchmarkTools.isregression(judged))
            state = issuccess ? "success" : "failure"
            statusmessage = issuccess ? "no performance regressions were detected" : "possible performance regressions were detected"
        else
            state = "success"
            statusmessage = "successfully executed benchmarks"
        end

        # upload markdown report to the report repository
        try
            reportpath = joinpath(filepath, "$(filename).md")
            reportmarkdown = base64encode(sprint(io -> printreport(io, job, results)))
            message = "add markdown report for job: $(jobsummary)"
            url = upload_report_file(config, reportpath, reportmarkdown, message)
            workerlog(worker, config, "committed markdown report to $(config.reportrepo) at $(reportpath)")
        catch err
            workerlog(worker, config, "error when committing markdown report: $(err)")
        end

        # post a status and comment for job
        create_job_status(config, job, state, statusmessage, url)
        if isempty(url)
            commentmessage = "[Your benchmark job]($(job.triggerurl)) has completed, but something went wrong when trying to upload the result data. cc @jrevels"
        else
            commentmessage = "[Your benchmark job]($(job.triggerurl)) has completed - $(statusmessage). A full report can be found [here]($(url)). cc @jrevels"
        end
        create_report_comment(config, job, commentmessage)
        workerlog(worker, config, "job complete: $(statusmessage)")
    end
end

# Comment Report #
#----------------#

function create_report_comment(config::ServerConfig, job::BenchmarkJob, message::AbstractString)
    commentplace = isnull(job.prnumber) ? job.statussha : get(job.prnumber)
    commentkind = job.fromkind == :review ? :pr : job.fromkind
    return GitHub.create_comment(config.buildrepo, commentplace, commentkind;
                                 auth = config.auth, params = Dict("body" => message))
end

# Markdown Report #
#-----------------#

const REGRESS_MARK = ":x:"
const IMPROVE_MARK = ":white_check_mark:"

report_filepath(job::BenchmarkJob) = snipsha(job.primary.sha)

function report_filename(job::BenchmarkJob)
    reportpath = report_filepath(job)
    filename = isnull(job.against) ? reportpath : "$(reportpath)_vs_$(snipsha(get(job.against).sha))"
    return filename
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

function printreport(io, job, results)
    primaryref = string(job.primary.repo, SHA_SEPARATOR, job.primary.sha)
    primarylink = "https://github.com/$(job.primary.repo)/commit/$(job.primary.sha)"
    jobsummary = "[$(primaryref)]($(primarylink))"
    iscomparisonjob = !(isnull(job.against))

    if iscomparisonjob
        againstbuild = get(job.against)
        againstref = string(againstbuild.repo, SHA_SEPARATOR, againstbuild.sha)
        againstlink = "https://github.com/$(againstbuild.repo)/commit/$(againstbuild.sha)"
        jobsummary = "$(jobsummary) vs [$(againstref)]($(againstlink))"
        table = results["judged"]
    else
        table = results["primary"]
    end

    # print report preface + job properties

    println(io, """
                # Benchmark Report

                ## Job Properties

                *Commit(s):* $(jobsummary)

                *Tag Predicate:* `$(job.tagpredstr)`

                *Triggered By:* [link]($(job.triggerurl))

                ## Results

                Below is a table of this job's results. If available, the data used to generate this
                table can be found in the JSON file in this directory.

                Benchmark definitions can be found in [JuliaCI/BaseBenchmarks.jl](https://github.com/JuliaCI/BaseBenchmarks.jl).

                The percentages accompanying time and memory values in the below table are noise tolerances. The "true"
                time/memory value for a given benchmark is expected to fall within this percentage of the reported value.
                """)

    # print benchmark results

    if iscomparisonjob
        print(io, """
                  The values in the below table take the form `primary_result / comparison_result`. A ratio greater than
                  `1.0` denotes a possible regression (marked with $(REGRESS_MARK)), while a ratio less than `1.0` denotes
                  a possible improvement (marked with $(IMPROVE_MARK)).

                  Only significant results - results that indicate possible regressions or improvements - are shown below
                  (thus, an empty table means that all benchmark results remained invariant between builds).

                  | Group ID | Benchmark ID | time ratio | memory ratio |
                  |----------|--------------|------------|--------------|
                  """)
    else
        print(io, """
                  | Group ID | Benchmark ID | time | GC time | memory | allocations |
                  |----------|--------------|------|---------|--------|-------------|
                  """)
    end

    groupids = collect(keys(table))

    try
        sort!(groupids)
    end

    for gid in groupids
        group = table[gid]
        benchids = collect(keys(group))
        try
            sort!(benchids; lt = idlessthan)
        end
        for bid in benchids
            t = group[bid]
            if !(iscomparisonjob) || BenchmarkTools.isregression(t) || BenchmarkTools.isimprovement(t)
                println(io, resultrow(gid, bid, t))
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

    if iscomparisonjob
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

    for gid in groupids
        println(io, "- `", repr(gid), "`")
    end
end

idlessthan(a::Tuple, b::Tuple) = isless(a, b)
idlessthan(a, b::Tuple) = false
idlessthan(a::Tuple, b) = true
idlessthan(a, b) = isless(a, b)

function resultrow(groupid, benchid, t::BenchmarkTools.TrialEstimate)
    t_tol = BenchmarkTools.prettypercent(BenchmarkTools.params(t).time_tolerance)
    m_tol = BenchmarkTools.prettypercent(BenchmarkTools.params(t).memory_tolerance)
    timestr = string(BenchmarkTools.prettytime(BenchmarkTools.time(t)), " (", t_tol, ")")
    memstr = string(BenchmarkTools.prettymemory(BenchmarkTools.memory(t)), " (", m_tol, ")")
    gcstr = BenchmarkTools.prettytime(BenchmarkTools.gctime(t))
    allocstr = string(BenchmarkTools.allocs(t))
    return "| `$(repr(groupid))` | `$(repr(benchid))` | $(timestr) | $(gcstr) | $(memstr) | $(allocstr) |"
end

function resultrow(groupid, benchid, t::BenchmarkTools.TrialJudgement)
    t_tol = BenchmarkTools.prettypercent(BenchmarkTools.params(t).time_tolerance)
    m_tol = BenchmarkTools.prettypercent(BenchmarkTools.params(t).memory_tolerance)
    t_ratio = @sprintf("%.2f", BenchmarkTools.time(BenchmarkTools.ratio(t)))
    m_ratio =  @sprintf("%.2f", BenchmarkTools.memory(BenchmarkTools.ratio(t)))
    t_mark = resultmark(BenchmarkTools.time(t))
    m_mark = resultmark(BenchmarkTools.memory(t))
    timestr = "$(t_ratio) ($(t_tol)) $(t_mark)"
    memstr = "$(m_ratio) ($(m_tol)) $(m_mark)"
    return "| `$(repr(groupid))` | `$(repr(benchid))` | $(timestr) | $(memstr) |"
end

resultmark(sym::Symbol) = sym == :regression ? REGRESS_MARK : (sym == :improvement ? IMPROVE_MARK : "")

#############
# Utilities #
#############

snip(str, len) = length(str) > len ? str[1:len] : str

# abbreviate a SHA to the first 7 characters
snipsha(sha::AbstractString) = snip(sha, 7)

function create_job_status(config::ServerConfig, job::BenchmarkJob, state, description, url=nothing)
    params = Dict("state" => state,
                  "context" => "NanosoldierBenchmark",
                  "description" => snip(description, 140))
    url != nothing && (params["target_url"] = url)
    return GitHub.create_status(config.buildrepo, job.statussha; auth = config.auth, params = params)
end

function workerlog(worker, config, message)
    persistdir!(config.workdir)
    path = joinpath(config.workdir, "worker$(worker).log")
    open(path, "a") do file
        println(file, now(), " | ", worker, " | ", message)
    end
end

function persistdir!(path)
    !(isdir(path)) && mkdir(path)
    return path
end

end # module
