############################
# Tag Predicate Validation #
############################
# The tag predicate is valid if it is simply a single tag, "ALL", or an
# expression joining multiple tags with the allowed symbols. This validation is
# only to prevent server-side evaluation of arbitrary code. No check is
# performed to ensure that the tag predicate is grammatically correct.

const VALID_TAG_PRED_SYMS = (:!, :&&, :||, :call, :ALL)

function is_valid_tagpred(tagpred::AbstractString)
    parsed = Meta.parse(tagpred)
    if isa(parsed, Expr)
        return is_valid_tagpred(parsed)
    elseif parsed == :ALL
        return true
    else
        return isa(parsed, AbstractString)
    end
end

function is_valid_tagpred(tagpred::Expr)
    if !in(tagpred.head, VALID_TAG_PRED_SYMS)
        return false
    else
        for item in tagpred.args
            if isa(item, Expr)
                is_valid_tagpred(item) || return false
            elseif isa(item, Symbol)
                in(item, VALID_TAG_PRED_SYMS) || return false
            elseif !isa(item, AbstractString)
                return false
            end
        end
    end
    return true
end

################
# BenchmarkJob #
################

mutable struct BenchmarkJob <: AbstractJob
    submission::JobSubmission        # the original submission
    tagpred::String                  # predicate string to be fed to @tagged
    against::Union{BuildRef,Nothing} # the comparison build (if available)
    date::Dates.Date                 # the date of the submitted job
    isdaily::Bool                    # is the job a daily job?
    skipbuild::Bool                  # use local julia install instead of a fresh build (for testing)
end

function BenchmarkJob(submission::JobSubmission)
    if haskey(submission.kwargs, :vs)
        againststr = Meta.parse(submission.kwargs[:vs])
        if in(SHA_SEPARATOR, againststr) # e.g. againststr == ararslan/julia@e83b7559df94b3050603847dbd6f3674058027e6
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
        against = againstbuild
    else
        against = nothing
    end

    if haskey(submission.kwargs, :skipbuild)
        skipbuild = submission.kwargs[:skipbuild] == "true"
    else
        skipbuild = false
    end

    if haskey(submission.kwargs, :isdaily)
        isdaily = submission.kwargs[:isdaily] == "true"
    else
        isdaily = false
    end

    return BenchmarkJob(submission, first(submission.args), against,
                        Dates.today(), isdaily, skipbuild)
end

function Base.summary(job::BenchmarkJob)
    result = "BenchmarkJob $(summary(submission(job).build))"
    if job.isdaily
        result *= " [daily]"
    elseif job.against !== nothing
        result *= " vs. $(summary(job.against))"
    end
    return result
end

function isvalid(submission::JobSubmission, ::Type{BenchmarkJob})
    allowed_kwargs = (:vs, :skipbuild, :isdaily)
    args, kwargs = submission.args, submission.kwargs
    has_valid_args = length(args) == 1 && is_valid_tagpred(first(args))
    has_valid_kwargs = (all(in(allowed_kwargs), keys(kwargs)) &&
                        (length(kwargs) <= length(allowed_kwargs)))
    return (submission.func == "runbenchmarks") && has_valid_args && has_valid_kwargs
end

submission(job::BenchmarkJob) = job.submission

#############
# Utilities #
#############

function jobdirname(job::BenchmarkJob)
    if job.isdaily
        return datedirname(job.date)
    else
        primarysha = snipsha(submission(job).build.sha)
        if job.against === nothing
            return primarysha
        else
            againstsha = snipsha(job.against.sha)
            return string(primarysha, "_vs_", againstsha)
        end
    end
end

reportdir(job::BenchmarkJob) = joinpath(reportdir(submission(job).config), jobdirname(job))
tmpdir(job::BenchmarkJob) = joinpath(workdir(submission(job).config), "tmpresults")
tmplogdir(job::BenchmarkJob) = joinpath(tmpdir(job), "logs")
tmpdatadir(job::BenchmarkJob) = joinpath(tmpdir(job), "data")

function retrieve_daily_data!(results, key, cfg, date)
    dailydir = joinpath(reportdir(cfg), datedirname(date))
    found_previous_date = false
    if isdir(dailydir)
        cd(dailydir) do
            datapath = joinpath(dailydir, "data")
            try
                run(`tar -xvzf data.tar.gz`)
                datafiles = readdir(datapath)
                primary_index = findfirst(fname -> endswith(fname, "_primary.json"), datafiles)
                if primary_index > 0
                    primary_file = datafiles[primary_index]
                    results[key] = BenchmarkTools.load(joinpath(datapath, primary_file))[1]
                    found_previous_date = true
                end
            catch err
                nodelog(cfg, myid(),
                        "encountered error when retrieving daily data: " * sprint(showerror, err),
                        error=(err, stacktrace(catch_backtrace())))
            finally
                isdir(datapath) && rm(datapath, recursive=true)
            end
        end
    end
    return found_previous_date
end

##########################
# BenchmarkJob Execution #
##########################

function Base.run(job::BenchmarkJob)
    node = myid()
    cfg = submission(job).config

    # make temporary directory for job results
    # Why not create the job's actual report directory now instead? The answer is that
    # the commit SHA that currently describes the job might change if we find out that
    # we should use a merge commit instead. To avoid confusion, we dump all the results
    # to this temporary directory first, then move the data to the correct location
    # in the reporting phase.
    nodelog(cfg, node, "creating temporary directory for benchmark results")
    if isdir(tmpdir(job))
        nodelog(cfg, node, "...removing old temporary directory...")
        rm(tmpdir(job), recursive=true)
    end
    nodelog(cfg, node, "...creating $(tmpdir(job))...")
    mkdir(tmpdir(job))
    nodelog(cfg, node, "...creating $(tmplogdir(job))...")
    mkdir(tmplogdir(job))
    nodelog(cfg, node, "...creating $(tmpdatadir(job))...")
    mkdir(tmpdatadir(job))

    # instantiate the dictionary that will hold all of the info needed by `report`
    results = Dict{Any,Any}()

    # run primary job
    try
        nodelog(cfg, node, "running primary build for $(summary(job))")
        results["primary"] = execute_benchmarks!(job, :primary)
        nodelog(cfg, node, "finished primary build for $(summary(job))")
    catch err
        results["error"] = NanosoldierError("failed to run benchmarks against primary commit", err)
    end

    # as long as our primary job didn't error, run the comparison job (or if it's a daily job, gather results to compare against)
    if !haskey(results, "error")
        if job.isdaily # get results from previous day (if it exists, check the past 30 days)
            try
                nodelog(cfg, node, "retrieving results from previous daily build")
                found_previous_date = false
                i = 1
                while !found_previous_date && i < 31
                    check_date = job.date - Dates.Day(i)
                    found_previous_date = retrieve_daily_data!(results, "against", cfg, check_date)
                    found_previous_date && (results["previous_date"] = check_date)
                    i += 1
                end
                found_previous_date || nodelog(cfg, node, "didn't find previous daily build data in the past 31 days")
            catch err
                rethrow(NanosoldierError("encountered error when retrieving old daily build data", err))
            end
        elseif job.against !== nothing # run comparison build
            try
                nodelog(cfg, node, "running comparison build for $(summary(job))")
                results["against"] = execute_benchmarks!(job, :against)
                nodelog(cfg, node, "finished comparison build for $(summary(job))")
            catch err
                results["error"] = NanosoldierError("failed to run benchmarks against comparison commit", err)
            end
        end
        if haskey(results, "against")
            results["judged"] = BenchmarkTools.judge(minimum(results["primary"]), minimum(results["against"]))
        end
    end

    # report results
    nodelog(cfg, node, "reporting results for $(summary(job))")
    report(job, results)
    nodelog(cfg, node, "completed $(summary(job))")
end

function execute_benchmarks!(job::BenchmarkJob, whichbuild::Symbol)
    node = myid()
    cfg = submission(job).config
    build = whichbuild == :against ? job.against : submission(job).build

    if job.skipbuild
        nodelog(cfg, node, "...skipping julia build...")
        builddir = mktempdir(workdir(cfg))
        juliapath = joinpath(homedir(), "julia6/julia") # TODO: Rename directory
    else
        nodelog(cfg, node, "...building julia...")
        # If we're doing the primary build from a PR, feed `build_julia!` the PR number
        # so that it knows to attempt a build from the merge commit
        if whichbuild == :primary && submission(job).fromkind == :pr
            builddir = build_julia!(cfg, build, tmplogdir(job), submission(job).prnumber)
        else
            builddir = build_julia!(cfg, build, tmplogdir(job))
        end
        juliapath = joinpath(builddir, "julia")
    end

    nodelog(cfg, node, "...setting up benchmark scripts/environment...")

    cd(builddir)

    # update local Julia packages for the relevant Julia version
    run(`$juliapath -e 'VERSION >= v"0.7.0-DEV.3656" && using Pkg; Pkg.update()'`)

    # add/update BaseBenchmarks for the relevant Julia version + use branch specified by cfg
    nodelog(cfg, node, "updating local BaseBenchmarks repo")
    branchname = cfg.testmode ? "test" : "nanosoldier"
    try
        run(```
            $juliapath -e '
                VERSION >= v"0.7.0-DEV.3656" && using Pkg
                url = "https://github.com/JuliaCI/BaseBenchmarks.jl"
                if VERSION >= v"0.7.0-DEV.5183"
                    Pkg.develop(PackageSpec(name="BaseBenchmarks", url=url))
                else
                    Pkg.clone(url)
                end
                # These are referenced by name so they need to be added explicitly
                foreach(Pkg.add, ("Compat", "BenchmarkTools", "JSON"))
            '
            ```)
    catch
    end
    cd(read(```
        $juliapath -e '
            if VERSION >= v"0.7.0-beta2.203"
                import BaseBenchmarks
                print(dirname(dirname(pathof(BaseBenchmarks))))
            else
                print(Pkg.dir("BaseBenchmarks"))
            end
        '
        ```, String)) do
        run(`git fetch --all --quiet`)
        run(`git reset --hard --quiet origin/$(branchname)`)
    end

    # The following code sets up a CPU shield, then spins up a new julia process on the
    # shielded CPU that runs the benchmarks. The results from this new process are
    # then serialized to a JSON file so that we can retrieve them.
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
    benchout = joinpath(tmplogdir(job), string(benchname, ".out"))
    bencherr = joinpath(tmplogdir(job), string(benchname, ".err"))
    benchresults = joinpath(tmpdatadir(job), string(benchname, ".json"))

    open(jlscriptpath, "w") do file
        println(file, """
                      using Compat
                      using Compat.Dates # needed for `now`
                      using Compat.Distributed # needed for `addprocs`
                      using Compat.LinearAlgebra # needed for `BLAS.set_num_threads`

                      using BaseBenchmarks
                      using BenchmarkTools
                      using JSON

                      println(now(), " | starting benchscript.jl (STDOUT/STDERR will be redirected to the result folder)")
                      benchout = open(\"$(benchout)\", "w")
                      oldout = stdout
                      redirect_stdout(benchout)
                      bencherr = open(\"$(bencherr)\", "w")
                      olderr = stderr
                      redirect_stderr(bencherr)

                      # ensure we don't leak file handles when something goes wrong
                      try
                          # move ourselves onto the first CPU in the shielded set
                          run(`sudo cset proc -m -p \$(getpid()) -t /user/child`)

                          BLAS.set_num_threads(1) # ensure BLAS threads do not trample each other
                          addprocs(1)             # add worker that can be used by parallel benchmarks

                          println("LOADING SUITE...")
                          BaseBenchmarks.loadall!()

                          println("FILTERING SUITE...")
                          benchmarks = BaseBenchmarks.SUITE[@tagged($(job.tagpred))]

                          println("WARMING UP BENCHMARKS...")
                          warmup(benchmarks)

                          println("RUNNING BENCHMARKS...")
                          results = run(benchmarks; verbose=true)

                          println("SAVING RESULT...")
                          BenchmarkTools.save(\"$(benchresults)\", results)

                          println("DONE!")
                      finally
                          redirect_stdout(oldout)
                          close(benchout)
                          redirect_stderr(olderr)
                          close(bencherr)
                      end
                      """)
    end

    # make shscript executable
    run(`chmod +x $(shscriptpath)`)
    # make jlscript executable
    run(`chmod +x $(jlscriptpath)`)
    # clean up old cpusets, if they exist
    try
        run(`sudo cset set -d /user/child`)
    catch
    end
    try
        run(`sudo cset shield --reset`)
    catch
    end
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

    results = BenchmarkTools.load(benchresults)[1]

    # Get the verbose output of versioninfo for the build, throwing away
    # environment information that is useless/potentially risky to expose.
    try
        build.vinfo = first(split(read(```
            $juliapath -e '
                VERSION >= v"0.7.0-DEV.3630" && using InteractiveUtils
                VERSION >= v"0.7.0-DEV.467" ? versioninfo(verbose=true) : versioninfo(true)
                '
            ```, String), "Environment"))
    catch err
        build.vinfo = string("retrieving versioninfo() failed: ", sprint(showerror, err))
    end

    cd(workdir(cfg))

    # delete the builddir now that we're done with it
    rm(builddir, recursive=true)

    return results
end

##########################
# BenchmarkJob Reporting #
##########################

# report job results back to GitHub
function report(job::BenchmarkJob, results)
    node = myid()
    cfg = submission(job).config
    if haskey(results, "primary") && isempty(results["primary"])
        reply_status(job, "error", "no benchmarks were executed")
        reply_comment(job, "[Your benchmark job]($(submission(job).url)) has completed, " *
                      "but no benchmarks were actually executed. Perhaps your tag predicate " *
                      "contains misspelled tags? cc @ararslan")
    else
        #  prepare report + data and push it to report repo
        target_url = ""
        try
            nodelog(cfg, node, "...generating report...")
            reportname = "report.md"
            open(joinpath(tmpdir(job), reportname), "w") do file
                printreport(file, job, results)
            end
            nodelog(cfg, node, "...tarring data...")
            cd(tmpdir(job)) do
                run(`tar -zcvf data.tar.gz data`)
                rm(tmpdatadir(job), recursive=true)
            end
            nodelog(cfg, node, "...moving $(tmpdir(job)) to $(reportdir(job))...")
            mv(tmpdir(job), reportdir(job); force=true)
            nodelog(cfg, node, "...pushing $(reportdir(job)) to GitHub...")
            target_url = upload_report_repo!(job, joinpath(jobdirname(job), reportname),
                                             "upload report for $(summary(job))")
        catch err
            rethrow(NanosoldierError("error when preparing/pushing to report repo", err))
        end

        if haskey(results, "error")
            err = results["error"]
            err.url = target_url
            throw(err)
        else
            # determine the job's final status
            if job.against !== nothing || haskey(results, "previous_date")
                found_regressions = BenchmarkTools.isregression(results["judged"])
                state = found_regressions ? "failure" : "success"
                status = found_regressions ? "possible performance regressions were detected" :
                                             "no performance regressions were detected"
            else
                state = "success"
                status = "successfully executed benchmarks"
            end
            # reply with the job's final status
            reply_status(job, state, status, target_url)
            if isempty(target_url)
                comment = "[Your benchmark job]($(submission(job).url)) has completed, but " *
                          "something went wrong when trying to upload the result data. cc @ararslan"
            else
                comment = "[Your benchmark job]($(submission(job).url)) has completed - " *
                          "$(status). A full report can be found [here]($(target_url)). cc @ararslan"
            end
            reply_comment(job, comment)
        end
    end
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
    hasagainstbuild = job.against !== nothing
    hasprevdate = haskey(results, "previous_date")
    iscomparisonjob = hasagainstbuild || hasprevdate

    if hasagainstbuild
        againstbuild = job.against
        againstname = string(againstbuild.repo, SHA_SEPARATOR, againstbuild.sha)
        againstlink = "https://github.com/$(againstbuild.repo)/commit/$(againstbuild.sha)"
        joblink = "$(joblink) vs [$(againstname)]($(againstlink))"
    end

    # print report preface + job properties #
    #---------------------------------------#

    println(io, """
                # Benchmark Report

                ## Job Properties

                *Commit(s):* $(joblink)

                *Triggered By:* [link]($(submission(job).url))

                *Tag Predicate:* `$(job.tagpred)`
                """)

    if job.isdaily
        if hasprevdate
            dailystr = string(job.date, " vs ", results["previous_date"])
        else
            dailystr = string(job.date)
        end
        println(io, """
                    *Daily Job:* $(dailystr)
                    """)
    end

    # if errors are found, end the report now #
    #-----------------------------------------#

    if haskey(results, "error")
        println(io, """
                    ## Error

                    The build could not finish due to an error:

                    ```
                    $(results["error"])
                    ```

                    Check the logs folder in this directory for more detailed output.
                    """)
        return nothing
    end

    # print result table #
    #--------------------#

    tablegroup = iscomparisonjob ? results["judged"] : results["primary"]

    println(io, """
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
        entries = entries[sortperm(map(string∘first, entries))]
    catch
    end

    for (ids, t) in entries
        if !iscomparisonjob || BenchmarkTools.isregression(t) || BenchmarkTools.isimprovement(t)
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

    if hasagainstbuild
        println(io)
        print(io, """
                  #### Comparison Build

                  ```
                  $(job.against.vinfo)
                  ```
                  """)
    end
    return nothing
end

function idrepr(id)
    str = repr(id)
    ind = findfirst(isequal('['), str)
    ind === nothing && error("Malformed id")
    return str[ind:end]
end

intpercent(p) = string(ceil(Int, p * 100), "%")

resultrow(ids, t::BenchmarkTools.Trial) = resultrow(ids, minimum(t))

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
