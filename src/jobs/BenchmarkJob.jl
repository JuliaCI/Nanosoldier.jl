############################
# Tag Predicate Validation #
############################
# The tag predicate is valid if it is simply a single tag, "ALL", or an
# expression joining multiple tags with the allowed symbols. This validation is
# only to prevent server-side evaluation of arbitrary code. No check is
# performed to ensure that the tag predicate is grammatically correct.

const VALID_TAG_PRED_SYMS = (:!, :&&, :||, :call, :ALL)

function is_valid_tagpred(tagpred::AbstractString)
    parsed = parse(tagpred)
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

type BenchmarkJob <: AbstractJob
    submission::JobSubmission
    tagpred::UTF8String         # predicate string to be fed to @tagged
    against::Nullable{BuildRef} # the comparison build (if available)
    skipbuild::Bool
end

function BenchmarkJob(submission::JobSubmission)
    if haskey(submission.kwargs, :vs)
        againststr = parse(submission.kwargs[:vs])
        if in(SHA_SEPARATOR, againststr) # e.g. againststr == jrevels/julia@e83b7559df94b3050603847dbd6f3674058027e6
            reporef, againstsha = split(againststr, SHA_SEPARATOR)
            againstrepo = isempty(reporef) ? submission.config.trackrepo : reporef
            againstbuild = BuildRef(againstrepo, againstsha)
        elseif in(BRANCH_SEPARATOR, againststr)
            reporef, againstbranch = split(againststr, BRANCH_SEPARATOR)
            againstrepo = isempty(reporef) ? submission.config.trackrepo : reporef
            againstbuild = branchref(submission.config, againstrepo, againstbranch)
        else
            error("invalid argument to `vs` keyword")
        end
        against = Nullable(againstbuild)
    else
        against = Nullable{BuildRef}()
    end
    if haskey(submission.kwargs, :skipbuild)
        skipbuild = submission.kwargs[:skipbuild] == "true"
    else
        skipbuild = false
    end
    return BenchmarkJob(submission, first(submission.args), against, skipbuild)
end

function branchref(config::Config, reponame::AbstractString, branchname::AbstractString)
    shastr = get(get(GitHub.branch(reponame, branchname; auth = config.auth).commit).sha)
    return BuildRef(reponame, shastr)
end

function Base.summary(job::BenchmarkJob)
    result = "BenchmarkJob $(summary(submission(job).build))"
    if !(isnull(job.against))
        result = "$(result) vs. $(summary(get(job.against)))"
    end
    return result
end

function isvalid(submission::JobSubmission, ::Type{BenchmarkJob})
    args, kwargs = submission.args, submission.kwargs
    return (submission.func == "runbenchmarks" &&
            (length(args) == 1 && is_valid_tagpred(first(args))) &&
            (isempty(kwargs) || (length(kwargs) < 3)))
end

submission(job::BenchmarkJob) = job.submission

##########################
# BenchmarkJob Execution #
##########################

function Base.run(job::BenchmarkJob)
    node = myid()
    cfg = submission(job).config

    # update BaseBenchmarks for all Julia versions
    branchname = cfg.testmode ? "test" : "nanosoldier"
    oldpwd = pwd()
    versiondirs = ("v0.4", "v0.5")
    for v in versiondirs
        cd(joinpath(homedir(), ".julia", v, "BaseBenchmarks"))
        run(`git fetch --all --quiet`)
        run(`git reset --hard --quiet origin/$(branchname)`)
    end
    cd(oldpwd)

    # run primary job
    nodelog(cfg, node, "running primary build for $(summary(job))")
    primary_results = execute_benchmarks!(job, :primary)
    nodelog(cfg, node, "finished primary build for $(summary(job))")
    results = Dict("primary" => primary_results)

    # run comparison job
    if !(isnull(job.against))
        nodelog(cfg, node, "running comparison build for $(summary(job))")
        against_results = execute_benchmarks!(job, :against)
        nodelog(cfg, node, "finished comparison build for $(summary(job))")
        results["against"] = against_results
        results["judged"] = BenchmarkTools.judge(primary_results, against_results)
    end

    # report results
    nodelog(cfg, node, "reporting results for $(summary(job))")
    report(job, results)
    nodelog(cfg, node, "completed $(summary(job))")
end

function execute_benchmarks!(job::BenchmarkJob, whichbuild::Symbol)
    node = myid()
    cfg = submission(job).config
    build = whichbuild == :against ? get(job.against) : submission(job).build

    if job.skipbuild
        nodelog(cfg, node, "...skipping julia build...")
        builddir = mktempdir(workdir(cfg))
        juliapath = joinpath(homedir(), "julia5/julia")
    else
        nodelog(cfg, node, "...building julia...")
        # If we're doing the primary build from a PR, feed `build_julia!` the PR number
        # so that it knows to attempt a build from the merge commit
        if whichbuild == :primary && submission(job).fromkind == :pr
            builddir = build_julia!(cfg, build, submission(job).prnumber)
        else
            builddir = build_julia!(cfg, build)
        end
        juliapath = joinpath(builddir, "julia")
    end

    nodelog(cfg, node, "...setting up benchmark scripts/environment...")

    cd(builddir)

    # The following code sets up a CPU shield, then spins up a new julia process on the
    # shielded CPU that runs the benchmarks. The results from this new process are
    # then serialized to a JLD file so that we can retrieve them.
    #
    # CPU shielding requires passwordless sudo access to `cset`. To enable this for the
    # server user, run `sudo visudo` and add the following line:
    #
    #   `user ALL=(ALL:ALL) NOPASSWD: /path_to_cset/cset`
    #
    # where `user` is replaced by the server user and `path_to_*` is the full path to the
    # `cset` executable.
    #
    # Note that `cset` only allows `root` to run a process on the shielded CPU, but our
    # benchmark julia process needs to be executed as the server user, since the server
    # user is the only user guaranteed to have the correct write permissions for the
    # server workspace. Thus, we start a subshell as the server user on the shielded CPU
    # using `su`, and then call our scripts from there.

    shscriptname = "benchscript.sh"
    shscriptpath = joinpath(builddir, shscriptname)
    jlscriptpath = joinpath(builddir, "benchscript.jl")

    open(shscriptpath, "w") do file
        println(file, """
                      #!/bin/sh
                      $(juliapath) $(jlscriptpath)
                      """)
    end

    benchname = string(build.sha, "_", whichbuild)
    benchout = joinpath(logdir(cfg),  string(benchname, ".out"))
    bencherr = joinpath(logdir(cfg),  string(benchname, ".err"))
    benchresults = joinpath(resultdir(cfg), string(benchname, ".jld"))

    open(jlscriptpath, "w") do file
        println(file, """
                      println(now(), " | starting benchscript.jl (STDOUT/STDERR will be redirected to the logs folder)")
                      benchout = open(\"$(benchout)\", "w"); redirect_stdout(benchout)
                      bencherr = open(\"$(bencherr)\", "w"); redirect_stderr(bencherr)

                      # move ourselves onto the first CPU in the shielded set
                      run(`sudo cset proc -m -p \$(getpid()) -t /user/child`)

                      blas_set_num_threads(1) # ensure BLAS threads do not trample each other
                      addprocs(1)             # add worker that can be used by parallel benchmarks

                      using BaseBenchmarks
                      using BenchmarkTools
                      using JLD

                      println("LOADING SUITE...")
                      BaseBenchmarks.loadall!()

                      println("FILTERING SUITE...")
                      benchmarks = BaseBenchmarks.SUITE[@tagged($(job.tagpred))]

                      println("WARMING UP BENCHMARKS...")
                      warmup(benchmarks)

                      println("RUNNING BENCHMARKS...")
                      results = minimum(run(benchmarks; verbose = true))

                      println("SAVING RESULT...")
                      JLD.save(\"$(benchresults)\", "results", results)

                      println("DONE!")

                      close(benchout)
                      close(bencherr)
                      """)
    end

    # make shscript executable
    run(`chmod +x $(shscriptpath)`)
    # make jlscript executable
    run(`chmod +x $(jlscriptpath)`)
    # clean up old cpusets, if they exist
    try run(`sudo cset set -d /user/child`) end
    try run(`sudo cset shield --reset`) end
    # shield our CPUs
    run(`sudo cset shield -c $(join(cfg.cpus, ",")) -k on`)
    run(`sudo cset set -c $(first(cfg.cpus)) -s /user/child --cpu_exclusive`)

    # execute our script as the server user on the shielded CPU
    nodelog(cfg, node, "...executing benchmarks...")
    run(`sudo cset shield -e su $(cfg.user) -- -c ./$(shscriptname)`)

    # clean up the cpusets
    nodelog(cfg, node, "...post processing/environment cleanup...")
    run(`sudo cset set -d /user/child`)
    run(`sudo cset shield --reset`)

    results = JLD.load(benchresults, "results")

    # Get the verbose output of versioninfo for the build, throwing away
    # environment information that is useless/potentially risky to expose.
    try
        build.vinfo = first(split(readstring(`$(juliapath) -e 'versioninfo(true)'`), "Environment"))
    end

    cd(workdir(cfg))

    # delete the builddir now that we're done with it
    rm(builddir, recursive = true)

    return results
end

##########################
# BenchmarkJob Reporting #
##########################

# report job results back to GitHub
function report(job::BenchmarkJob, results)
    node = myid()
    cfg = submission(job).config
    target_url = ""
    if isempty(results["primary"])
        reply_status(job, "error", "no benchmarks were executed")
        reply_comment(job, "[Your benchmark job]($(submission(job).url)) has completed, but no benchmarks were actually executed. Perhaps your tag predicate contains mispelled tags? cc @jrevels")
    else
        # To upload our JLD file, we'd need to use the Git Data API, which allows uploading
        # of large binary blobs. Unfortunately, GitHub.jl doesn't yet implement the Git Data
        # API, so we don't yet do this. The old code here uploaded a JSON file, but
        # unfortunately didn't work very consistently because the JSON was often over the
        # size limit.
        # try
        #     datapath = joinpath(reportdir(job), "$(reportfile(job)).json")
        #     datastr = base64encode(JSON.json(results))
        #     target_url = upload_report_file(job, datapath, datastr, "upload result data for $(summary(job))")
        #     nodelog(cfg, node, "uploaded $(datapath) to $(cfg.reportrepo)")
        # catch err
        #     nodelog(cfg, node, "error when uploading result JSON file: $(err)")
        # end

        # determine the job's final status
        if !(isnull(job.against))
            found_regressions = BenchmarkTools.isregression(results["judged"])
            state = found_regressions ? "failure" : "success"
            status = found_regressions ? "possible performance regressions were detected" : "no performance regressions were detected"
        else
            state = "success"
            status = "successfully executed benchmarks"
        end

        # upload markdown report to the report repository
        try
            reportpath = joinpath(reportdir(job), "$(reportfile(job)).md")
            reportstr = base64encode(sprint(io -> printreport(io, job, results)))
            target_url = upload_report_file(job, reportpath, reportstr, "upload markdown report for $(summary(job))")
            nodelog(cfg, node, "uploaded $(reportpath) to $(cfg.reportrepo)")
        catch err
            nodelog(cfg, node, "error when uploading markdown report: $(err)")
        end

        # reply with the job's final status
        reply_status(job, state, status, target_url)
        if isempty(target_url)
            comment = "[Your benchmark job]($(submission(job).url)) has completed, but something went wrong when trying to upload the result data. cc @jrevels"
        else
            comment = "[Your benchmark job]($(submission(job).url)) has completed - $(status). A full report can be found [here]($(target_url)). cc @jrevels"
        end
        reply_comment(job, comment)
    end
end

reportdir(job::BenchmarkJob) = snipsha(submission(job).build.sha)

function reportfile(job::BenchmarkJob)
    dir = reportdir(job)
    return isnull(job.against) ? dir : "$(dir)_vs_$(snipsha(get(job.against).sha))"
end


# Markdown Report Generation #
#----------------------------#

const REGRESS_MARK = ":x:"
const IMPROVE_MARK = ":white_check_mark:"

function printreport(io::IO, job::BenchmarkJob, results)
    build = submission(job).build
    buildname = string(build.repo, SHA_SEPARATOR, build.sha)
    buildlink = "https://github.com/$(build.repo)/commit/$(build.sha)"
    joblink = "[$(buildname)]($(buildlink))"
    iscomparisonjob = !(isnull(job.against))

    if iscomparisonjob
        againstbuild = get(job.against)
        againstname = string(againstbuild.repo, SHA_SEPARATOR, againstbuild.sha)
        againstlink = "https://github.com/$(againstbuild.repo)/commit/$(againstbuild.sha)"
        joblink = "$(joblink) vs [$(againstname)]($(againstlink))"
        tablegroup = results["judged"]
    else
        tablegroup = results["primary"]
    end

    # print report preface + job properties #
    #---------------------------------------#

    println(io, """
                # Benchmark Report

                ## Job Properties

                *Commit(s):* $(joblink)

                *Triggered By:* [link]($(submission(job).url))

                *Tag Predicate:* `$(job.tagpred)`

                ## Results

                *Note: If Chrome is your browser, I strongly recommend installing the [Wide GitHub](https://chrome.google.com/webstore/detail/wide-github/kaalofacklcidaampbokdplbklpeldpj?hl=en)
                extension, which makes the result table easier to read.*

                Below is a table of this job's results, obtained by running the benchmarks found in
                [JuliaCI/BaseBenchmarks.jl](https://github.com/JuliaCI/BaseBenchmarks.jl). The values
                listed in the `ID` column have the structure `[parent_group, child_group, ..., key]`,
                and can be used to index into the BaseBenchmarks suite to retrieve the corresponding
                benchmarks.

                The percentages accompanying time and memory values in the below table are noise tolerances. The "true"
                time/memory value for a given benchmark is expected to fall within this percentage of the reported value.
                """)

    # print result table #
    #--------------------#
    if iscomparisonjob
        print(io, """
                  A ratio greater than `1.0` denotes a possible regression (marked with $(REGRESS_MARK)), while a ratio less
                  than `1.0` denotes a possible improvement (marked with $(IMPROVE_MARK)). Only significant results - results
                  that indicate possible regressions or improvements - are shown below (thus, an empty table means that all
                  benchmark results remained invariant between builds).

                  | ID | time ratio | memory ratio |
                  |----|------------|--------------|
                  """)
    else
        print(io, """
                  | ID | time | GC time | memory | allocations |
                  |----|------|---------|--------|-------------|
                  """)
    end

    entries = BenchmarkTools.leaves(tablegroup)

    try
        entries = entries[sortperm(map(x -> string(first(x)), entries))]
    end

    for (ids, t) in entries
        if !(iscomparisonjob) || BenchmarkTools.isregression(t) || BenchmarkTools.isimprovement(t)
            println(io, resultrow(ids, t))
        end
    end

    println(io)

    # print list of executed benchmarks #
    #-----------------------------------#
    println(io, """
                ## Benchmark Group List

                Here's a list of all the benchmark groups executed by this job:
                """)

    for id in unique(map(pair -> pair[1][1:end-1], entries))
        println(io, "- `", idrepr(id), "`")
    end

    println(io)

    # print build version info #
    #--------------------------#
    print(io, """
              ## Version Info

              #### Primary Build

              ```
              $(build.vinfo)
              ```
              """)

    if iscomparisonjob
        println(io)
        print(io, """
                  #### Comparison Build

                  ```
                  $(get(job.against).vinfo)
                  ```
                  """)
    end
end

idrepr(id) = (str = repr(id); str[searchindex(str, '['):end])

intpercent(p) = string(ceil(Int, p * 100), "%")

function resultrow(ids, t::BenchmarkTools.TrialEstimate)
    t_tol = intpercent(BenchmarkTools.params(t).time_tolerance)
    m_tol = intpercent(BenchmarkTools.params(t).memory_tolerance)
    timestr = string(BenchmarkTools.prettytime(BenchmarkTools.time(t)), " (", t_tol, ")")
    memstr = string(BenchmarkTools.prettymemory(BenchmarkTools.memory(t)), " (", m_tol, ")")
    gcstr = BenchmarkTools.prettytime(BenchmarkTools.gctime(t))
    allocstr = string(BenchmarkTools.allocs(t))
    return "| `$(idrepr(ids))` | $(timestr) | $(gcstr) | $(memstr) | $(allocstr) |"
end

function resultrow(ids, t::BenchmarkTools.TrialJudgement)
    t_tol = intpercent(BenchmarkTools.params(t).time_tolerance)
    m_tol = intpercent(BenchmarkTools.params(t).memory_tolerance)
    t_ratio = @sprintf("%.2f", BenchmarkTools.time(BenchmarkTools.ratio(t)))
    m_ratio =  @sprintf("%.2f", BenchmarkTools.memory(BenchmarkTools.ratio(t)))
    t_mark = resultmark(BenchmarkTools.time(t))
    m_mark = resultmark(BenchmarkTools.memory(t))
    timestr = "$(t_ratio) ($(t_tol)) $(t_mark)"
    memstr = "$(m_ratio) ($(m_tol)) $(m_mark)"
    return "| `$(idrepr(ids))` | $(timestr) | $(memstr) |"
end

resultmark(sym::Symbol) = sym == :regression ? REGRESS_MARK : (sym == :improvement ? IMPROVE_MARK : "")
