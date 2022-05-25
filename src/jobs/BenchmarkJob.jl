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
        if in(SHA_SEPARATOR, againststr) # e.g. againststr == christopher-dG/julia@e83b7559df94b3050603847dbd6f3674058027e6
            reporef, againstsha = split(againststr, SHA_SEPARATOR)
            againstrepo = isempty(reporef) ? submission.config.trackrepo : reporef
            againstbuild = BuildRef(againstrepo, againstsha)
        elseif in(BRANCH_SEPARATOR, againststr)
            reporef, againstbranch = split(againststr, BRANCH_SEPARATOR)
            againstrepo = isempty(reporef) ? submission.config.trackrepo : reporef
            againstbuild = branchref(submission.config, againstrepo, againstbranch)
        elseif in(TAG_SEPARATOR, againststr)
            reporef, againsttag = split(againststr, TAG_SEPARATOR)
            againstrepo = isempty(reporef) ? submission.config.trackrepo : reporef
            againstbuild = tagref(submission.config, againstrepo, againsttag)
        elseif againststr == SPECIAL_SELF
            againstbuild = copy(submission.build)
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
        validatate_isdaily(submission)
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
        joinpath("by_date", datedirname(job.date))
    else
        primarysha = snipsha(submission(job).build.sha)
        tag = if job.against === nothing
            primarysha
        else
            againstsha = snipsha(job.against.sha)
            string(primarysha, "_vs_", againstsha)
        end
        joinpath("by_hash", tag)
    end
end

reportdir(job::BenchmarkJob) = joinpath(reportdir(submission(job).config), "benchmark", jobdirname(job))
tmpdir(job::BenchmarkJob) = joinpath(workdir, "tmpresults")
tmplogdir(job::BenchmarkJob) = joinpath(tmpdir(job), "logs")
tmpdatadir(job::BenchmarkJob) = joinpath(tmpdir(job), "data")

function retrieve_daily_data!(cfg, date)
    dailydir = joinpath(reportdir(cfg), "benchmark", "by_date", datedirname(date))
    if isdir(dailydir)
        cd(dailydir) do
            datapath = joinpath(dailydir, "data")
            try
                open("data.tar.zst") do io
                    stream = XzDecompressorStream(io)
                    Tar.extract(stream, datapath)
                end
                datafiles = readdir(datapath)
                primary_index = findfirst(fname -> endswith(fname, "_primary.minimum.json"), datafiles)
                if primary_index !== nothing
                    against = match(r"Commit.+\(https://github.com/([^/)]+/[^/)]+)/commit/(\w+).*\)", read(joinpath(dailydir, "report.md"), String))
                    (repo::String, commit::String) = against === nothing ? ("", "") : (against[1], against[2])
                    primary_file = datafiles[primary_index]
                    results = BenchmarkTools.load(joinpath(datapath, primary_file))[1]
                    return results, repo, commit
                end
            catch err
                nodelog(cfg, myid(), "encountered error when retrieving daily data";
                        error=(err, catch_backtrace()))
            finally
                isdir(datapath) && rm(datapath, recursive=true)
            end
            nothing
        end
    end
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
    chmod(tmplogdir(job), 0o777)
    nodelog(cfg, node, "...creating $(tmpdatadir(job))...")
    mkdir(tmpdatadir(job))
    chmod(tmpdatadir(job), 0o777)

    # instantiate the dictionary that will hold all of the info needed by `report`
    results = Dict{Any,Any}()
    cleanup = String[]

    # build jobs in parallel to better utilize machine cores
    julia_primary = @async build_benchmarksjulia!(job, :primary, cleanup)
    local julia_against
    try
        @sync begin
            julia_against = @async begin
                if job.isdaily || job.against === nothing
                    nothing
                else
                    build_benchmarksjulia!(job, :against, cleanup)
                end
            end
        end
    catch ex
        # we'll handle Task errors individually later
        # right now we just wanted to make sure they've all ended
        # before we start benchmarking
        ex isa TaskFailedException || rethrow()
    end

    try
        # run primary job
        julia_primary = fetch(julia_primary)
        nodelog(cfg, node, "running primary build for $(summary(job))")
        results["primary"] = execute_benchmarks!(job, julia_primary, :primary)
        nodelog(cfg, node, "finished primary build for $(summary(job))")

        # run the comparison job (or if it's a daily job, gather results to compare against)
        if job.isdaily # get results from previous day (if it exists, check the past 120 days)
            try
                nodelog(cfg, node, "retrieving results from previous daily build")
                found_previous_date = false
                i = 1
                while !found_previous_date && i < 121
                    check_date = job.date - Dates.Day(i)
                    check_data = retrieve_daily_data!(cfg, check_date)
                    if check_data !== nothing
                        found_previous_date = true
                        results["against"] = check_data[1]
                        results["previous_repo"] = check_data[2]
                        results["previous_sha"] = check_data[3]
                        results["previous_date"] = check_date
                    end
                    i += 1
                end
                found_previous_date || nodelog(cfg, node, "didn't find previous daily build data in the past 31 days")
            catch err
                rethrow(NanosoldierError("encountered error when retrieving old daily build data", err))
            end
        elseif job.against !== nothing # run comparison build
            julia_against = fetch(julia_against)
            nodelog(cfg, node, "running comparison build for $(summary(job))")
            results["against"] = execute_benchmarks!(job, julia_against, :against)
            nodelog(cfg, node, "finished comparison build for $(summary(job))")
        end
        if haskey(results, "against")
            results["judged"] = BenchmarkTools.judge(results["primary"], results["against"])
        end
    finally
        for dir in cleanup
            if ispath(dir)
                run(sudo(cfg.user, `chmod -R ug+rwX $dir/julia`)) # make it rwx
                Base.Filesystem.prepare_for_deletion(dir)
                rm(dir, recursive=true)
            end
        end
    end

    # report results
    nodelog(cfg, node, "reporting results for $(summary(job))")
    report(job, results)
    nodelog(cfg, node, "completed $(summary(job))")
end

function build_benchmarksjulia!(job::BenchmarkJob, whichbuild::Symbol, cleanup::Vector{String})
    node = myid()
    cfg = submission(job).config
    build = whichbuild == :against ? job.against : submission(job).build
    if job.skipbuild
        nodelog(cfg, node, "...skipping julia build...")
        juliapath = joinpath(Sys.BINDIR, "julia")
    else
        nodelog(cfg, node, "...building julia...")
        # If we're doing the primary build from a PR, feed `build_julia!` the PR number
        # so that it knows to attempt a build from the merge commit
        if whichbuild == :primary && submission(job).fromkind == :pr
            juliadir = build_julia!(cfg, build, tmplogdir(job), submission(job).prnumber)
        else
            juliadir = build_julia!(cfg, build, tmplogdir(job))
        end
        push!(cleanup, juliadir)
        juliapath = joinpath(juliadir, "julia", "julia")
    end
    return juliapath
end

function execute_benchmarks!(job::BenchmarkJob, juliapath, whichbuild::Symbol)
    node = myid()
    cfg = submission(job).config
    build = whichbuild == :against ? job.against : submission(job).build
    builddir = mktempdir(workdir)
    gid = parse(Int, readchomp(`id -g $(cfg.user)`))
    chmod(builddir, 0o755) # make it r-x to other than owner

    # create a hermetic environment (similar to after sudo later)
    tmpproject = joinpath(builddir, "environment")
    mkdir(tmpproject, mode=0o775)
    chown(tmpproject, -1, gid)
    juliacmd = setenv(`$juliapath --project=$tmpproject --startup-file=no`,
        "LANG" => get(ENV, "LANG", "C.UTF-8"),
        "HOME" => ENV["HOME"],
        "USER" => ENV["USER"],
        "PATH" => ENV["PATH"];
        dir = builddir)

    nodelog(cfg, node, "...setting up benchmark scripts/environment...")

    # add/update BaseBenchmarks for the relevant Julia version + use branch specified by cfg
    nodelog(cfg, node, "updating local BaseBenchmarks repo")
    branchname = cfg.testmode ? "master" : "nanosoldier"
    try
        run(```$juliacmd -e '
                using Pkg
                # update local Julia packages for the relevant Julia version
                Pkg.update()
                url = "https://github.com/JuliaCI/BaseBenchmarks.jl"
                Pkg.develop(PackageSpec(name="BaseBenchmarks", url=url))
                # These are referenced by name so they need to be added explicitly
                foreach(Pkg.add, ("BenchmarkTools", "JSON"))
                ' ```)
    catch ex
        @error "updating BaseBenchmarks failed (attempting to continue)" _exception=ex
    end
    let BaseBenchmarks = read(```
            $juliacmd -e '
                import BaseBenchmarks
                print(dirname(dirname(pathof(BaseBenchmarks))))
                ' ```, String)
        run(`$(git()) -C $BaseBenchmarks fetch --all --quiet`)
        run(`$(git()) -C $BaseBenchmarks reset --hard --quiet origin/$(branchname)`)
    end

    run(sudo(cfg.user, `$(setenv(juliacmd, nothing, dir=builddir)) -e 'using Pkg; Pkg.instantiate(); Pkg.status()'`))

    cset = abspath("cset/bin/cset")
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

    shscriptpath = joinpath(builddir, "benchscript.sh")
    jlscriptpath = joinpath(builddir, "benchscript.jl")

    benchname = string(build.sha, "_", whichbuild)
    benchout = joinpath(tmplogdir(job), string(benchname, ".out"))
    bencherr = joinpath(tmplogdir(job), string(benchname, ".err"))
    benchminimum = joinpath(tmpdatadir(job), string(benchname, ".minimum.json"))
    benchmedian = joinpath(tmpdatadir(job), string(benchname, ".median.json"))
    benchmean = joinpath(tmpdatadir(job), string(benchname, ".mean.json"))
    benchstd = joinpath(tmpdatadir(job), string(benchname, ".std.json"))

    open(shscriptpath, "w") do file
        println(file, """
                      #!/bin/sh
                      cd \$(dirname \$0)
                      exec $(Base.shell_escape_posixly(juliacmd)) $(Base.shell_escape_posixly(jlscriptpath))
                      """)
    end

    open(jlscriptpath, "w") do file
        println(file, """
                      using Dates # needed for `now`
                      using Distributed # needed for `addprocs`
                      using LinearAlgebra # needed for `BLAS.set_num_threads`
                      using BaseBenchmarks
                      using BenchmarkTools
                      using Statistics
                      using JSON

                      println(now(), " | starting benchscript.jl (STDOUT/STDERR will be redirected to the result folder)")
                      benchout = open($(repr(benchout)), "w")
                      oldout = stdout
                      redirect_stdout(benchout)
                      bencherr = open($(repr(bencherr)), "w")
                      olderr = stderr
                      redirect_stderr(bencherr)

                      # ensure we don't leak file handles when something goes wrong
                      try
                          println("LOADING SUITE...")
                          BaseBenchmarks.loadall!()

                          println("FILTERING SUITE...")
                          benchmarks = BaseBenchmarks.SUITE[@tagged($(job.tagpred))]

                          println("SETTING UP FOR RUN...")
                          # move ourselves onto the first CPU in the shielded set
                          run(`sudo -n -- $cset proc -m -p \$(getpid()) -t /user/child`))
                          BLAS.set_num_threads(1) # ensure BLAS threads do not trample each other
                          addprocs(1)             # add worker that can be used by parallel benchmarks

                          println("WARMING UP BENCHMARKS...")
                          warmup(benchmarks)

                          println("RUNNING BENCHMARKS...")
                          results = run(benchmarks; verbose=true)

                          println("SAVING RESULT...")
                          BenchmarkTools.save($(repr(benchminimum)), minimum(results))
                          BenchmarkTools.save($(repr(benchmedian)), median(results))
                          BenchmarkTools.save($(repr(benchmean)), mean(results))
                          BenchmarkTools.save($(repr(benchstd)), std(results))

                          println("DONE!")
                      finally
                          redirect_stdout(oldout)
                          close(benchout)
                          redirect_stderr(olderr)
                          close(bencherr)
                      end
                      """)
    end

    # make shscript r-x
    chmod(shscriptpath, 0o555)
    # make jlscript r-x
    chmod(jlscriptpath, 0o555)

    # clean up old cpusets, if they exist
    try
        run(sudo(`$cset set -d /user/child`))
    catch ex
        @warn "(expected) removing old cset failed" _exception=ex
    end
    try
        run(sudo(`$cset shield --reset`))
    catch ex
        @warn "(expected) removing old cset failed" _exception=ex
    end
    # shield our CPUs
    cpus = mycpus(cfg)
    run(sudo(`$cset shield -c $(join(cpus, ",")) -k on`))
    run(sudo(`$cset set -c $(first(cpus)) -s /user/child --cpu_exclusive`))

    # execute our script as the server user on the shielded CPU
    nodelog(cfg, node, "...executing benchmarks...")
    run(sudo(`$cset shield -e -- sudo -n -u $(cfg.user) -- $(shscriptpath)`))

    # clean up the cpusets
    nodelog(cfg, node, "...post processing/environment cleanup...")
    run(sudo(`$cset set -d /user/child`))
    run(sudo(`$cset shield --reset`))

    results = BenchmarkTools.load(benchresults)[1]

    # Get the verbose output of versioninfo for the build, throwing away
    # environment information that is useless/potentially risky to expose.
    try
        build.vinfo = first(split(read(```
            $juliacmd -e '
                using InteractiveUtils
                versioninfo(verbose=true)
                '
            ```, String), "Environment"))
    catch err
        build.vinfo = string("retrieving versioninfo() failed: ", sprint(showerror, err))
    end

    # delete the builddir now that we're done with it
    rm(builddir, recursive=true)

    return minimum(results)
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
                      "contains misspelled tags? cc @$(cfg.admin)")
    else
        # prepare report + data and push it to report repo
        target_url = ""
        try
            nodelog(cfg, node, "...generating report...")
            reportname = "report.md"
            open(joinpath(tmpdir(job), reportname), "w") do file
                printreport(file, job, results)
            end
            nodelog(cfg, node, "...tarring data...")
            open(joinpath(tmpdir(job), "data.tar.zst"), "w") do io
                stream = ZstdCompressorStream(io; level=9)
                Tar.create(tmpdatadir(job), stream)
                close(stream)
            end
            rm(tmpdatadir(job), recursive=true)
            nodelog(cfg, node, "...moving $(tmpdir(job)) to $(reportdir(job))...")
            mkpath(reportdir(job))
            mv(tmpdir(job), reportdir(job); force=true)
            nodelog(cfg, node, "...pushing $(reportdir(job)) to GitHub...")
            target_url = upload_report_repo!(job, joinpath("benchmark", jobdirname(job), reportname),
                                             "upload report for $(summary(job))")
        catch err
            rethrow(NanosoldierError("error when preparing/pushing to report repo", err))
        end

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
                        "something went wrong when trying to upload the result data. cc @$(cfg.admin)"
        else
            comment = "[Your benchmark job]($(submission(job).url)) has completed - " *
                        "$(status). A full report can be found [here]($(target_url))."
        end
        reply_comment(job, comment)
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

        if build.repo == againstbuild.repo
            comparelink = "https://github.com/$(againstbuild.repo)/compare/$(againstbuild.sha)..$(build.sha)"
        else
            comparelink = "https://github.com/$(againstbuild.repo)/compare/$(againstbuild.sha)..$(build.repo):$(build.sha)"
        end
        joblink = "$(joblink)\n\n*Comparison Diff:* [link]($(comparelink))"
    end

    if job.isdaily && hasprevdate
        previous_sha = results["previous_sha"]
        # previous_repo = results["previous_repo"] # unnecessary
        if !isempty(previous_sha)
            comparelink = "https://github.com/$(build.repo)/compare/$(previous_sha)...$(build.sha)"
            joblink = "$(joblink)\n\n*Comparison Range:* [link]($(comparelink))"
        end
    end

    # print report preface + job properties #
    #---------------------------------------#

    println(io, """
                # Benchmark Report

                ## Job Properties

                *Commit$(hasagainstbuild ? "s" : ""):* $(joblink)

                *Triggered By:* [link]($(submission(job).url))

                *Tag Predicate:* $(markdown_escaped_code(job.tagpred))
                """)

    if job.isdaily
        if hasprevdate
            previous_date = results["previous_date"]
            previous_date = "[$(previous_date)](../../$(datedirname(previous_date))/report.md)"
            dailystr = string(job.date, " vs ", previous_date)
        else
            dailystr = string(job.date)
        end
        println(io, """
                    *Daily Job:* $(dailystr)
                    """)
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
    catch ex
        @error "result sorting failed (attempting to continue)" _exception=ex
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
        println(io, "- ", idrepr_md(id))
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

idrepr(id::Vector) = sprint(idrepr, id)
function idrepr(io::IO, id::Vector)
    print(io, "[")
    first = true
    for i in id
        first ? (first = false) : print(io, ", ")
        show(io, i)
    end
    print(io, "]")
end

idrepr_md(id::Vector) = markdown_escaped_code(idrepr(id))

intpercent(p) = string(ceil(Int, p * 100), "%")

resultrow(ids, t::BenchmarkTools.Trial) = resultrow(ids, minimum(t))

function resultrow(ids, t::BenchmarkTools.TrialEstimate)
    t_tol = intpercent(BenchmarkTools.params(t).time_tolerance)
    m_tol = intpercent(BenchmarkTools.params(t).memory_tolerance)
    timestr = string(BenchmarkTools.prettytime(BenchmarkTools.time(t)), " (", t_tol, ")")
    memstr = string(BenchmarkTools.prettymemory(BenchmarkTools.memory(t)), " (", m_tol, ")")
    gcstr = BenchmarkTools.prettytime(BenchmarkTools.gctime(t))
    allocstr = string(BenchmarkTools.allocs(t))
    return "| $(idrepr_md(ids)) | $(timestr) | $(gcstr) | $(memstr) | $(allocstr) |"
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
    return "| $(idrepr_md(ids)) | $(timestr) | $(memstr) |"
end

resultmark(sym::Symbol) = sym == :regression ? REGRESS_MARK : (sym == :improvement ? IMPROVE_MARK : "")
