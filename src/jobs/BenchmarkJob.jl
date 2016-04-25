############################
# Tag Predicate Validation #
############################
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

################
# BenchmarkJob #
################

type BenchmarkJob
    submission::JobSubmission
    tagpred::UTF8String # predicate string to be fed to @tagged
    against::BuildRef   # the comparison build (if available)
end

function BenchmarkJob(submission::JobSubmission)
    tagpred, againststr = parse_benchmark_args(submission.args)
    if !(is_valid_tagpred(tagpred))
        error("invalid tag predicate: $(tagpred)")
    end
    if isnull(againststr)
        against = Nullable{BuildRef}()
    else
        againststr = get(againststr)
        if in(SHA_SEPARATOR, againststr) # e.g. againststr == jrevels/julia@e83b7559df94b3050603847dbd6f3674058027e6
            against = Nullable(BuildRef(split(againststr, SHA_SEPARATOR)...))
        elseif in(BRANCH_SEPARATOR, againststr)
            againstrepo, againstbranch = split(againststr, BRANCH_SEPARATOR)
            against = branchref(submission.config, againstrepo, againstbranch)
        elseif in('/', againststr) # e.g. againststr == jrevels/julia
            against = branchref(submission.config, againststr, "master")
        else # e.g. againststr == e83b7559df94b3050603847dbd6f3674058027e6
            against = Nullable(BuildRef(submission.build.repo, againststr))
        end
    end
    return BenchmarkJob(submission, tagpred, against)
end

function parse_benchmark_args(argstr::AbstractString)
    parsed = parse(argstr)
    # if provided, extract a comparison ref from the trigger arguments
    againststr = Nullable{UTF8String}()
    if (isa(parsed, Expr) && length(parsed.args) == 2 &&
        isa(parsed.args[2], Expr) && parsed.args[2].head == :(=))
        vskv = parsed.args[2].args
        tagpredexpr = parsed.args[1]
        if length(vskv) == 2 && vskv[1] == :vs
            againststr = Nullable(UTF8String(vskv[2]))
        else
            error("malformed comparison argument: $vskv")
        end
    else
        tagpredexpr = parsed
    end
    # If `tagpredexpr` is just a single tag, it'll just be a string, in which case
    # we'll need to wrap it in escaped quotes so that it can be interpolated later.
    if isa(tagpred, AbstractString)
        tagpredstr = string('"', tagpredexpr, '"')
    else
        tagpredstr = string(tagpredexpr)
    end
    return tagpredstr, againststr
end

function branchref(config::Config, reponame::AbstractString, branchname::AbstractString)
    shastr = get(get(GitHub.branch(reponame, branchname; auth = config.auth).commit).sha)
    return Nullable(BuildRef(reponame, shastr))
end

function Base.summary(job::BenchmarkJob)
    result = "BenchmarkJob $(summary(job.primary))"
    if !(isnull(job.against))
        result = "$(result) vs. $(summary(get(job.against)))"
    end
    return result
end

isvalid(submission::JobSubmission, ::Type{BenchmarkJob}) = submission.func == "runbenchmarks"
submission(job::BenchmarkJob) = job.submission

function Base.run(job::BenchmarkJob)
    node = myid()
    nodelog(config, node, "running primary build for $(summary(job))")
    primary_results = execute_benchmarks!(job, :primary)
    results = Dict("primary" => primary_results)
    if !(isnull(job.against))
        workerlog(worker, config, "running comparison build: $(summary(get(job.against)))")
        job, against_result = remotecall_fetch(execute_base_benchmarks!, worker, config, job, :against)
        workerlog(worker, config, "finished comparison build: $(summary(get(job.against)))")
        results["against"] = against_result
    end
    report_results(config, job, worker, results)
end

#################
# Job Execution #
#################

function execute_benchmarks!(job::BenchmarkJob, whichbuild::Symbol)
    cfg = config(job)
    build = whichbuild == :against ? get(job.against) : job.submission.build

    if whichbuild == :primary && syjob.submission.fromkind == :pr
        builddir = build_julia!(cfg, build, job.submission.prnumber)
    else
        builddir = build_julia!(cfg, build)
    end

    juliapath = joinpath(builddir, "julia")

    # Execute benchmarks in a new julia process using the fresh build, splicing the tag
    # predicate string into the command. The result is serialized so that we can retrieve it
    # from outside of the new process.
    #
    # This command assumes that all packages are available in the working process's Pkg
    # directory.
    benchname = string(snip(build.sha, 7), "_", whichbuild)
    benchout = joinpath(logdir(cfg),  string(benchname, ".out"))
    bencherr = joinpath(logdir(cfg),  string(benchname, ".err"))
    benchresult = joinpath(resultdir(cfg), string(benchname, ".jld"))
    # cmd = """
    #       benchout = open(\"$(benchout)\", "w"); redirect_stdout(benchout);
    #       bencherr = open(\"$(bencherr)\", "w"); redirect_stderr(bencherr);
    #       addprocs(1); # add worker that can be used by parallel benchmarks
    #       using BaseBenchmarks;
    #       using BenchmarkTools;
    #       using JLD;
    #       println("LOADING SUITE...");
    #       BaseBenchmarks.loadall!();
    #       println("FILTERING SUITE...");
    #       benchmarks = BaseBenchmarks.SUITE[@tagged($(job.tagpredstr))];
    #       println("RUNNING WARMUP...");
    #       @warmup(benchmarks);
    #       println("RUNNING BENCHMARKS...");
    #       result = minimum(run(benchmarks; verbose = true));
    #       println("SAVING RESULT...");
    #       JLD.save(\"$(benchresult)\", "result", result);
    #       println("DONE!");
    #       close(benchout); close(bencherr);
    #       """
    #
    juliapath = "/mirror/revels/julia-dev/julia-0.5/julia"
    run(`$(juliapath) -e $(cmd)`)
    result = JLD.load(benchresult, "result")
    # Get the verbose output of versioninfo for the build, throwing away
    # environment information that is useless/potentially risky to expose.
    try
        build.vinfo = first(split(readstring(`$(juliapath) -e 'versioninfo(true)'`), "Environment"))
    end
    cd(workdir(config))
    # delete the builddir now that we're done with it
    rm(builddir, recursive = true)
    return result
end

#############################
# Summary Report Generation #
#############################
#
# # Generate a more detailed markdown report in the JuliaCI/BenchmarkReports repo,
# # and link to this report in the final status on the relevant commit.
# function report_results(config::ServerConfig, job::BenchmarkJob, worker, results)
#     jobsummary = summary(job)
#     filepath = report_filepath(job)
#     filename = report_filename(job)
#     url = ""
#     workerlog(worker, config, "reporting results for job: $(jobsummary)")
#     if isempty(results["primary"])
#         state = "error"
#         statusmessage = "no benchmarks were executed"
#         commentmessage = "[Your benchmark job]($(job.triggerurl)) has completed, but no benchmarks were actually executed. Perhaps your tag predicate contains mispelled tags? cc @jrevels"
#         create_job_status(config, job, state, statusmessage, url)
#         create_report_comment(config, job, commentmessage)
#         workerlog(worker, config, "job complete: $(statusmessage)")
#     else
#         # upload raw result data to the report repository
#         try
#             resultpath = joinpath(filepath, "$(filename).json")
#             resultdata = base64encode(JSON.json(results))
#             message = "add result data for job: $(jobsummary)"
#             url = upload_report_file(config, resultpath, resultdata, message)
#             workerlog(worker, config, "committed result data to $(config.reportrepo) at $(resultpath)")
#         catch err
#             workerlog(worker, config, "error when committing result data: $(err)")
#         end
#
#         # judge the results and generate the corresponding status messages
#         if !(isnull(job.against))
#             judged = BenchmarkTools.judge(results["primary"], results["against"])
#             results["judged"] = judged
#             issuccess = !(BenchmarkTools.isregression(judged))
#             state = issuccess ? "success" : "failure"
#             statusmessage = issuccess ? "no performance regressions were detected" : "possible performance regressions were detected"
#         else
#             state = "success"
#             statusmessage = "successfully executed benchmarks"
#         end
#
#         # upload markdown report to the report repository
#         try
#             reportpath = joinpath(filepath, "$(filename).md")
#             reportmarkdown = base64encode(sprint(io -> printreport(io, job, results)))
#             message = "add markdown report for job: $(jobsummary)"
#             url = upload_report_file(config, reportpath, reportmarkdown, message)
#             workerlog(worker, config, "committed markdown report to $(config.reportrepo) at $(reportpath)")
#         catch err
#             workerlog(worker, config, "error when committing markdown report: $(err)")
#         end
#
#         # post a status and comment for job
#         create_job_status(config, job, state, statusmessage, url)
#         if isempty(url)
#             commentmessage = "[Your benchmark job]($(job.triggerurl)) has completed, but something went wrong when trying to upload the result data. cc @jrevels"
#         else
#             commentmessage = "[Your benchmark job]($(job.triggerurl)) has completed - $(statusmessage). A full report can be found [here]($(url)). cc @jrevels"
#         end
#         create_report_comment(config, job, commentmessage)
#         workerlog(worker, config, "job complete: $(statusmessage)")
#     end
# end
#
# # Comment Report #
# #----------------#
#
# function create_report_comment(config::ServerConfig, job::BenchmarkJob, message::AbstractString)
#     commentplace = isnull(job.prnumber) ? job.statussha : get(job.prnumber)
#     commentkind = job.fromkind == :review ? :pr : job.fromkind
#     return GitHub.create_comment(config.buildrepo, commentplace, commentkind;
#                                  auth = config.auth, params = Dict("body" => message))
# end
#
# # Markdown Report #
# #-----------------#
#
# const REGRESS_MARK = ":x:"
# const IMPROVE_MARK = ":white_check_mark:"
#
# report_filepath(job::BenchmarkJob) = snipsha(job.primary.sha)
#
# function report_filename(job::BenchmarkJob)
#     reportpath = report_filepath(job)
#     filename = isnull(job.against) ? reportpath : "$(reportpath)_vs_$(snipsha(get(job.against).sha))"
#     return filename
# end
#
# function upload_report_file(config, path, content, message)
#     params = Dict("content" => content, "message" => message)
#     priorfile = GitHub.file(config.reportrepo, path; auth = config.auth, handle_error = false)
#     if isnull(priorfile.sha)
#         results = GitHub.create_file(config.reportrepo, path; auth = config.auth, params = params)
#     else
#         params["sha"] = get(priorfile.sha)
#         results = GitHub.update_file(config.reportrepo, path; auth = config.auth, params = params)
#     end
#     return string(GitHub.permalink(results["content"], results["commit"]))
# end
#
# function printreport(io, job, results)
#     primaryref = string(job.primary.repo, SHA_SEPARATOR, job.primary.sha)
#     primarylink = "https://github.com/$(job.primary.repo)/commit/$(job.primary.sha)"
#     jobsummary = "[$(primaryref)]($(primarylink))"
#     iscomparisonjob = !(isnull(job.against))
#
#     if iscomparisonjob
#         againstbuild = get(job.against)
#         againststr = string(againstbuild.repo, SHA_SEPARATOR, againstbuild.sha)
#         againstlink = "https://github.com/$(againstbuild.repo)/commit/$(againstbuild.sha)"
#         jobsummary = "$(jobsummary) vs [$(againststr)]($(againstlink))"
#         table = results["judged"]
#     else
#         table = results["primary"]
#     end
#
#     # print report preface + job properties
#
#     println(io, """
#                 # Benchmark Report
#
#                 ## Job Properties
#
#                 *Commit(s):* $(jobsummary)
#
#                 *Tag Predicate:* `$(job.tagpredstr)`
#
#                 *Triggered By:* [link]($(job.triggerurl))
#
#                 ## Results
#
#                 *Note: If Chrome is your browser, I strongly recommend installing the [Wide GitHub](https://chrome.google.com/webstore/detail/wide-github/kaalofacklcidaampbokdplbklpeldpj?hl=en)
#                 extension, which makes the result table easier to read.*
#
#                 Below is a table of this job's results, obtained by running the benchmarks found in
#                 [JuliaCI/BaseBenchmarks.jl](https://github.com/JuliaCI/BaseBenchmarks.jl). The values
#                 listed in the `ID` column have the structure `[parent_group, child_group, ..., key]`,
#                 and can be used to index into the BaseBenchmarks suite to retrieve the corresponding
#                 benchmarks.
#
#                 The percentages accompanying time and memory values in the below table are noise tolerances. The "true"
#                 time/memory value for a given benchmark is expected to fall within this percentage of the reported value.
#                 """)
#
#     # print benchmark results
#
#     if iscomparisonjob
#         print(io, """
#                   The values in the below table take the form `primary_result / comparison_result`. A ratio greater than
#                   `1.0` denotes a possible regression (marked with $(REGRESS_MARK)), while a ratio less than `1.0` denotes
#                   a possible improvement (marked with $(IMPROVE_MARK)).
#
#                   Only significant results - results that indicate possible regressions or improvements - are shown below
#                   (thus, an empty table means that all benchmark results remained invariant between builds).
#
#                   | ID | time ratio | memory ratio |
#                   |----|------------|--------------|
#                   """)
#     else
#         print(io, """
#                   | ID | time | GC time | memory | allocations |
#                   |----|------|---------|--------|-------------|
#                   """)
#     end
#
#     entries = BenchmarkTools.leaves(table)
#
#     try
#         sort!(entries; lt = leaflessthan)
#     end
#
#     for (ids, t) in entries
#         if !(iscomparisonjob) || BenchmarkTools.isregression(t) || BenchmarkTools.isimprovement(t)
#             println(io, resultrow(ids, t))
#         end
#     end
#
#     println(io)
#
#     # print version info for Julia builds
#
#     println(io, """
#                 ## Version Info
#
#                 #### Primary Build
#
#                 ```
#                 $(job.primary.vinfo)
#                 ```
#                 """)
#
#     if iscomparisonjob
#         println(io, """
#                     #### Comparison Build
#
#                     ```
#                     $(get(job.against).vinfo)
#                     ```
#                     """)
#     end
#
#     # print list of executed benchmarks
#
#     println(io, """
#                 ## Benchmark Group List
#
#                 Here's a list of all the benchmark groups executed by this job:
#                 """)
#
#     for id in unique(map(pair -> pair[1][1:end-1], entries))
#         println(io, "- `", idrepr(id), "`")
#     end
# end
#
# idrepr(id) = (str = repr(id); str[searchindex(str, '['):end])
#
# idlessthan(a::Tuple, b::Tuple) = isless(a, b)
# idlessthan(a, b::Tuple) = false
# idlessthan(a::Tuple, b) = true
# idlessthan(a, b) = isless(a, b)
#
# function leaflessthan(kv1, kv2)
#     k1 = kv1[1]
#     k2 = kv2[1]
#     for i in eachindex(k1)
#         if idlessthan(k1[i], k2[i])
#             return true
#         elseif k1[i] != k2[i]
#             return false
#         end
#     end
#     return false
# end
#
# function resultrow(ids, t::BenchmarkTools.TrialEstimate)
#     t_tol = BenchmarkTools.prettypercent(BenchmarkTools.params(t).time_tolerance)
#     m_tol = BenchmarkTools.prettypercent(BenchmarkTools.params(t).memory_tolerance)
#     timestr = string(BenchmarkTools.prettytime(BenchmarkTools.time(t)), " (", t_tol, ")")
#     memstr = string(BenchmarkTools.prettymemory(BenchmarkTools.memory(t)), " (", m_tol, ")")
#     gcstr = BenchmarkTools.prettytime(BenchmarkTools.gctime(t))
#     allocstr = string(BenchmarkTools.allocs(t))
#     return "| `$(idrepr(ids))` | $(timestr) | $(gcstr) | $(memstr) | $(allocstr) |"
# end
#
# function resultrow(ids, t::BenchmarkTools.TrialJudgement)
#     t_tol = BenchmarkTools.prettypercent(BenchmarkTools.params(t).time_tolerance)
#     m_tol = BenchmarkTools.prettypercent(BenchmarkTools.params(t).memory_tolerance)
#     t_ratio = @sprintf("%.2f", BenchmarkTools.time(BenchmarkTools.ratio(t)))
#     m_ratio =  @sprintf("%.2f", BenchmarkTools.memory(BenchmarkTools.ratio(t)))
#     t_mark = resultmark(BenchmarkTools.time(t))
#     m_mark = resultmark(BenchmarkTools.memory(t))
#     timestr = "$(t_ratio) ($(t_tol)) $(t_mark)"
#     memstr = "$(m_ratio) ($(m_tol)) $(m_mark)"
#     return "| `$(idrepr(ids))` | $(timestr) | $(memstr) |"
# end
#
# resultmark(sym::Symbol) = sym == :regression ? REGRESS_MARK : (sym == :improvement ? IMPROVE_MARK : "")
