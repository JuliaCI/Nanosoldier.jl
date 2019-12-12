using NewPkgEval
using DataFrames
using Feather
using JSON
using Base: UUID


################################
# Package Selection Validation #
################################

# The package selection is valid if it is simply a single package, "ALL", or an
# array expression that lists several packages. This validation is
# only to prevent server-side evaluation of arbitrary code. No check is
# performed to ensure that the tag predicate is grammatically correct.

function is_valid_pkgsel(pkgsel::AbstractString)
    parsed = Meta.parse(pkgsel)
    if isa(parsed, Expr)
        return is_valid_pkgsel(parsed)
    elseif parsed == :ALL
        return true
    else
        return isa(parsed, AbstractString)
    end
end

function is_valid_pkgsel(pkgsel::Expr)
    if pkgsel.head != :vect
        return false
    else
        for item in pkgsel.args
            if !isa(item, AbstractString)
                return false
            end
        end
    end
    return true
end

##############
# PkgEvalJob #
##############

mutable struct PkgEvalJob <: AbstractJob
    submission::JobSubmission        # the original submission
    pkgsel::String                   # selection of packages
    against::Union{BuildRef,Nothing} # the comparison build (if available)
    date::Dates.Date                 # the date of the submitted job
    isdaily::Bool                    # is the job a daily job?
end

function PkgEvalJob(submission::JobSubmission)
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
        elseif in(TAG_SEPARATOR, againststr)
            reporef, againsttag = split(againststr, TAG_SEPARATOR)
            againstrepo = isempty(reporef) ? submission.config.trackrepo : reporef
            againstbuild = tagref(submission.config, againstrepo, againsttag)
        else
            error("invalid argument to `vs` keyword")
        end
        against = againstbuild
    else
        against = nothing
    end

    if haskey(submission.kwargs, :isdaily)
        isdaily = submission.kwargs[:isdaily] == "true"
    else
        isdaily = false
    end

    return PkgEvalJob(submission, first(submission.args), against,
                      Dates.today(), isdaily)
end

function Base.summary(job::PkgEvalJob)
    result = "PkgEvalJob $(summary(submission(job).build))"
    if job.isdaily
        result *= " [daily]"
    elseif job.against !== nothing
        result *= " vs. $(summary(job.against))"
    end
    return result
end

function isvalid(submission::JobSubmission, ::Type{PkgEvalJob})
    allowed_kwargs = (:vs, :isdaily)
    args, kwargs = submission.args, submission.kwargs
    has_valid_args = length(args) == 1 && is_valid_pkgsel(first(args))
    has_valid_kwargs = (all(in(allowed_kwargs), keys(kwargs)) &&
                        (length(kwargs) <= length(allowed_kwargs)))
    return (submission.func == "runtests") && has_valid_args && has_valid_kwargs
end

submission(job::PkgEvalJob) = job.submission

#############
# Utilities #
#############

function jobdirname(job::PkgEvalJob)
    tag = if job.isdaily
        datedirname(job.date)
    else
        primarysha = snipsha(submission(job).build.sha)
        if job.against === nothing
            primarysha
        else
            againstsha = snipsha(job.against.sha)
            string(primarysha, "_vs_", againstsha)
        end
    end
    return "pkgeval-$tag"
end

reportdir(job::PkgEvalJob) = joinpath(reportdir(submission(job).config), jobdirname(job))
tmpdir(job::PkgEvalJob) = joinpath(workdir(submission(job).config), "tmpresults")
tmplogdir(job::PkgEvalJob) = joinpath(tmpdir(job), "logs")
tmpdatadir(job::PkgEvalJob) = joinpath(tmpdir(job), "data")

function retrieve_daily_tests!(results, key, cfg, date)
    dailydir = joinpath(reportdir(cfg), "pkgeval-" * datedirname(date))
    found_previous_date = false
    if isdir(dailydir)
        cd(dailydir) do
            datapath = joinpath(dailydir, "data")
            try
                run(`tar -xzf data.tar.gz`)
                results[key] = Feather.read(joinpath(datapath, "primary.feather"))
                found_previous_date = true

                # undo stringification
                for col in (:julia, :version, :status, :reason, :uuid)
                    results[key][!, col] = map(str->eval(Meta.parse(str)), results[key][!, col])
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

########################
# PkgEvalJob Execution #
########################

function execute_tests!(job::PkgEvalJob, build::BuildRef, whichbuild::Symbol)
    # determine Julia version to use
    julia = nothing
    if whichbuild == :primary && submission(job).fromkind == :pr
        # if we're dealing with a PR, try the merge commit
        pr = submission(job).prnumber
        if prnumber !== nothing
            try
                julia = NewPkgEval.obtain_julia_build("pull/$pr/merge", build.repo)
            catch err
                isa(err, LibGit2.GitError) || rethrow()
                # there might not be a merge commit (e.g. in the case of merge conflicts)
            end
        end
    end
    if julia === nothing
        # fall back to the last commit in the PR
        julia = NewPkgEval.obtain_julia_build(build.sha, build.repo)
    end
    NewPkgEval.prepare_julia(julia)

    # get some version info
    try
        out = Pipe()
        NewPkgEval.run_sandboxed_julia(julia, ```-e '
                VERSION >= v"0.7.0-DEV.3630" && using InteractiveUtils
                VERSION >= v"0.7.0-DEV.467" ? versioninfo(verbose=true) : versioninfo(true)
                '
            ```; stdout=out, stderr=out, stdin=devnull, interactive=false)
        close(out.in)
        build.vinfo = first(split(read(out, String), "Environment"))
    catch err
        build.vinfo = string("retrieving versioninfo() failed: ", sprint(showerror, err))
    end

    # determine packages to test
    pkgsel = Meta.parse(job.pkgsel)
    pkg_names = if pkgsel == :ALL
        String[]
    else
        eval(pkgsel)    # should be safe, it's a :vec of Strings
    end
    pkgs = NewPkgEval.read_pkgs(pkg_names)

    # run tests
    results = withenv("CI" => true) do
        cpus = mycpus(submission(job).config)
        NewPkgEval.run([julia], pkgs; ninstances=length(cpus))
    end

    # write logs
    cd(tmplogdir(job)) do
        for test in eachrow(results)
            isdir(test.name) || mkdir(test.name)
            open(joinpath(test.name, "$(test.julia).log"), "w") do io
                if !ismissing(test.log)
                    write(io, test.log)
                end
            end
        end
    end

    # write data
    cd(tmpdatadir(job)) do
        let results = copy(results)
            # Feather can't handle non-primitive types, so stringify them
            for col in (:julia, :version, :status, :reason, :uuid)
                results[!, col] = map(repr, results[!, col])
            end
            Feather.write("$(whichbuild).feather", results)
        end
    end

    return results
end

function Base.run(job::PkgEvalJob)
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

    # prepare NewPkgEval
    NewPkgEval.prepare_registry("General"; update=true)
    NewPkgEval.prepare_runner()

    # instantiate the dictionary that will hold all of the info needed by `report`
    results = Dict{Any,Any}()

    # run primary job
    try
        nodelog(cfg, node, "running primary build for $(summary(job))")
        results["primary"] = execute_tests!(job, submission(job).build, :primary)
        nodelog(cfg, node, "running primary build for $(summary(job))")
    catch err
        results["error"] = NanosoldierError("failed to run tests against primary commit", err)
        results["backtrace"] = catch_backtrace()
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
                    found_previous_date = retrieve_daily_tests!(results, "against", cfg, check_date)
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
                results["against"] = execute_tests!(job, job.against, :against)
                nodelog(cfg, node, "finished comparison build for $(summary(job))")
            catch err
                results["error"] = NanosoldierError("failed to run tests against comparison commit", err)
                results["backtrace"] = catch_backtrace()
            end
        end
    end

    NewPkgEval.purge()

    # report results
    nodelog(cfg, node, "reporting results for $(summary(job))")
    report(job, results)
    nodelog(cfg, node, "completed $(summary(job))")

    return
end

########################
# PkgEvalJob Reporting #
########################

# report job results back to GitHub
function report(job::PkgEvalJob, results)
    node = myid()
    cfg = submission(job).config
    if haskey(results, "primary") && isempty(results["primary"])
        reply_status(job, "error", "no tests were executed")
        reply_comment(job, "[Your test job]($(submission(job).url)) has completed, " *
                      "but no tests were actually executed. Perhaps your package selection " *
                      "contains misspelled names? cc @$(cfg.admin)")
    else
        #  prepare report + data and push it to report repo
        target_url = ""
        try
            nodelog(cfg, node, "...generating report...")
            reportname = "report.md"
            open(joinpath(tmpdir(job), reportname), "w") do file
                printreport(file, job, results)
            end
            if job.isdaily && !haskey(results, "error")
                nodelog(cfg, node, "...generating database...")
                dbname = "db.json"
                open(joinpath(tmpdir(job), dbname), "w") do file
                    printdb(file, job, results)
                end
            end
            nodelog(cfg, node, "...tarring data...")
            cd(tmpdir(job)) do
                run(`tar -zcf data.tar.gz data`)
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
            # TODO: throw with backtrace?
            if haskey(results, "backtrace")
                @error("An exception occurred during job execution",
                       exception=(results["error"], results["backtrace"]))
            else
                @error("An exception occurred during job execution",
                       exception=results["error"])
            end
            err = results["error"]
            err.url = target_url
            throw(err)
        else
            # determine the job's final status
            state = results["has_issues"] ? "failure" : "success"
            if job.against !== nothing || haskey(results, "previous_date")
                status = results["has_issues"] ? "possible new issues were detected" :
                                                 "no new issues were detected"
            else
                status = results["has_issues"] ? "possible issues were detected" :
                                                 "no issues were detected"
            end
            # reply with the job's final status
            reply_status(job, state, status, target_url)
            if isempty(target_url)
                comment = "[Your test job]($(submission(job).url)) has completed, but " *
                          "something went wrong when trying to upload the result data. cc @$(cfg.admin)"
            else
                comment = "[Your test job]($(submission(job).url)) has completed - " *
                          "$(status). A full report can be found [here]($(target_url)). cc @$(cfg.admin)"
            end
            reply_comment(job, comment)
        end
    end
end

# Markdown Report Generation #
#----------------------------#

function printreport(io::IO, job::PkgEvalJob, results)
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
                # Package Evaluation Report

                ## Job Properties

                *Commit(s):* $(joblink)

                *Triggered By:* [link]($(submission(job).url))

                *Package Selection:* `$(job.pkgsel)`
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

                    ```""")

        Base.showerror(io, results["error"])
        if haskey(results, "backtrace")
            Base.show_backtrace(io, results["backtrace"])
        end
        println(io)

        println(io, """
                    ```

                    Check the logs folder in this directory for more detailed output.
                    """)
        return nothing
    end

    # print result list #
    #-------------------#

    if iscomparisonjob
        package_results = join(results["primary"], results["against"],
                               on=:uuid, kind=:left, makeunique=true, indicator=:source)
    else
        package_results = results["primary"]
        package_results[!, :source] .= "left_only" # fake a left join
    end

    results["has_issues"] = false

    # report test results in groups based on the test status
    for (status, (verb, emoji)) in (:fail   => ("failed tests", ":heavy_multiplication_x:"),
                                    :ok     => ("passed tests", ":heavy_check_mark:"),
                                    :kill   => ("were killed",  ":heavy_exclamation_mark:"),
                                    :skip   => ("were skipped", ":heavy_minus_sign:"))
        # NOTE: no `groupby(package_results, :status)` because we can't impose ordering
        group = package_results[package_results[!, :status] .== status, :]
        sort!(group, :name)

        if !isempty(group)
            println(io, "## $emoji Packages that", iscomparisonjob ? " now" : "", " $verb\n")

            function reportrow(test)
                verstr(version) = ismissing(version) ? "" : " v$(version)"

                primary_log = "logs/$(test.name)/$(test.julia).log"
                print(io, "- [$(test.name)$(verstr(test.version))]($primary_log)")

                if !ismissing(test.reason)
                    print(io, " ($(NewPkgEval.reasons[test.reason]))")
                end

                # "against" entries are suffixed with `_1` because of the join
                if test.source == "both"
                    against_log = "logs/$(test.name_1)/$(test.julia_1).log"
                    if hasprevdate
                        against_log = "../pkgeval-$(datedirname(results["previous_date"]))/$against_log"
                    end
                    print(io, " vs. [$(test.name_1)$(verstr(test.version_1))]($against_log)")

                    print(io, " ($(NewPkgEval.statusses[test.status_1])")
                    if !ismissing(test.reason_1)
                        print(io, ", $(NewPkgEval.reasons[test.reason_1])")
                    end
                    print(io, ")")
                end

                println(io)
            end

            if iscomparisonjob
                # first report on tests that changed status
                let changed_tests = filter(test->test.source == "both" &&
                                                 test.status != test.status_1, group)
                    println(io, "$(nrow(changed_tests)) packages $verb only on the current version.")
                    println(io)
                    foreach(reportrow, eachrow(changed_tests))

                    results["has_issues"] |= status in (:fail, :kill) && !isempty(changed_tests)
                end

                # now report the other ones
                let unchanged_tests = filter(test->test.source == "left_only" ||
                                                   test.status == test.status_1, group)
                    println(io, """
                        <details><summary>$(nrow(unchanged_tests)) packages $verb on the previous version too.</summary>
                        <p>
                        """)
                    unchanged_tests = copy(unchanged_tests)     # only report the
                    unchanged_tests[!, :source] .= "left_only"  # primary result
                    foreach(reportrow, eachrow(unchanged_tests))
                    println(io, """
                        </p>
                        </details>
                        """)
                end
            else
                # just report on all tests
                println(io, "$(nrow(group)) packages $verb.")
                foreach(reportrow, eachrow(group))

                results["has_issues"] |= status in (:fail, :kill) && !isempty(group)
            end

            println(io)
        end
    end

    # print summary of tested packages #
    #----------------------------------#

    o = count(==(:ok),      results["primary"].status)
    s = count(==(:skip),    results["primary"].status)
    f = count(==(:fail),    results["primary"].status)
    k = count(==(:kill),    results["primary"].status)
    x = nrow(results["primary"])

    println(io, """
                ## Summary

                In total, $x packages were tested, out of which $o succeeded, $f failed $k got killed and $s were skipped.
                """)

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

    println(io, "<!-- Generated on $(now()) -->")

    return nothing
end

# JSON Database Generation #
#--------------------------#

function printdb(io::IO, job::PkgEvalJob, results)
    build = submission(job).build

    # build information
    json = Dict{String,Any}(
        "build" => Dict(
            "repo"  => build.repo,
            "sha"   => build.sha,
        )
    )

    # test results
    tests = Dict()
    for test in eachrow(results["primary"])
        tests[test.uuid] = Dict(
            "julia"         => test.julia,
            "name"          => test.name,
            "version"       => test.version,
            "status"        => test.status,
            "reason"        => test.reason,
            "duration"      => test.duration,
        )
    end
    json["tests"] = tests

    JSON.print(io, json)

    return
end
