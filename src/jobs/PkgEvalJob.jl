using NewPkgEval
using DataFrames
using Feather
using JSON
using Base: UUID
using LibGit2


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

function jobdirname(job::PkgEvalJob; latest::Bool=false)
    if job.isdaily
        joinpath("by_date", latest ? "latest" : datedirname(job.date))
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

reportdir(job::PkgEvalJob; kwargs...) = joinpath(reportdir(submission(job).config), "pkgeval", jobdirname(job; kwargs...))
tmpdir(job::PkgEvalJob) = joinpath(workdir(submission(job).config), "tmpresults")
tmplogdir(job::PkgEvalJob) = joinpath(tmpdir(job), "logs")
tmpdatadir(job::PkgEvalJob) = joinpath(tmpdir(job), "data")

########################
# PkgEvalJob Execution #
########################

# execute the tests of all packages specified by a PkgEvalJob on one or more Julia builds
function execute_tests!(job::PkgEvalJob, builds::Dict{String,BuildRef}, results::Dict)
    # determine Julia versions to use
    julia_versions = Dict{String,VersionNumber}()
    for (whichbuild, build) in builds
        # obtain Julia version matching requested BuildRef
        julia = nothing
        if whichbuild == "primary" && submission(job).fromkind == :pr
            # if we're dealing with a PR, try the merge commit
            pr = submission(job).prnumber
            if pr !== nothing
                try
                    # NOTE: the merge head only exists in the upstream Julia repository,
                    #       and not in the repository where the pull request originated.
                    julia = NewPkgEval.obtain_julia_build("pull/$pr/merge", "JuliaLang/julia")
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
        @assert !in(julia, values(julia_versions)) "Cannot compare identical Julia builds"
        julia_versions[whichbuild] = julia

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
    all_tests = withenv("CI" => true) do
        cpus = mycpus(submission(job).config)
        NewPkgEval.run(collect(values(julia_versions)), pkgs; ninstances=length(cpus))
    end

    # process the results for each Julia version separately
    for (whichbuild, build) in builds
        tests = all_tests[all_tests[!, :julia] .== julia_versions[whichbuild], :]
        results[whichbuild] = tests

        # write logs
        cd(tmplogdir(job)) do
            for test in eachrow(tests)
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
            # dataframe with test results
            let tests = copy(tests)
                # Feather can't handle non-primitive types, so stringify them
                for col in (:julia, :version, :status, :reason, :uuid)
                    tests[!, col] = map(repr, tests[!, col])
                end
                Feather.write("$(whichbuild).feather", tests)
            end

            # dict with build properties
            open("$(whichbuild).json", "w") do io
                json = Dict{String,Any}(
                    "build" => Dict(
                        "repo"  => build.repo,
                        "sha"   => build.sha,
                    )
                )
                JSON.print(io, json)
            end
        end
    end
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

    if job.isdaily
        # get build from previous day
        try
            nodelog(cfg, node, "retrieving results from previous daily build")
            latest_dir = reportdir(job; latest=true)
            latest_db = joinpath(latest_dir, "db.json")
            if isfile(latest_db)
                latest = JSON.parsefile(latest_db)

                # NOTE: we don't actually use the results from the previous day, just the
                #       build properties, since packages upgrades might cause failures too.
                results["against_date"] = parse(Date, latest["date"])
                job.against = BuildRef(latest["build"]["repo"], latest["build"]["sha"])
            else
                nodelog(cfg, node, "didn't find previous daily build data")
            end
        catch err
            rethrow(NanosoldierError("encountered error when retrieving old daily build data", err))
        end
    end

    # refuse to test against an identical build
    if job.against !== nothing && job.against.sha == submission(job).build.sha
        nodelog(cfg, node, "refusing to compare identical builds, demoting to non-comparing evaluation")
        delete!(results, "against_date")
        job.against = nothing
    end

    # run tests
    builds = Dict("primary" => submission(job).build)
    if job.against !== nothing
        builds["against"] = job.against
    end
    try
        nodelog(cfg, node, "running tests for $(summary(job))")
        execute_tests!(job, builds, results)
        nodelog(cfg, node, "running tests for $(summary(job))")
    catch err
        results["error"] = NanosoldierError("failed to run tests", err)
        results["backtrace"] = catch_backtrace()
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
            mkpath(reportdir(job))
            mv(tmpdir(job), reportdir(job); force=true)
            if job.isdaily
                latest = reportdir(job; latest=true)
                islink(latest) && rm(latest)
                symlink(datedirname(job.date), latest)
            end
            nodelog(cfg, node, "...pushing $(reportdir(job)) to GitHub...")
            target_url = upload_report_repo!(job, joinpath("pkgeval", jobdirname(job), reportname),
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
            if job.against !== nothing
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

    # in contrast to BenchmarkJob, comparison jobs always have an against build, even daily
    # ones (so we don't need `iscomparisonjob`). in the case of a daily comparison job,
    # `results["against_date"]` is guaranteed to be set (so we don't need `hasprevdate`).

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
        if hasagainstbuild
            dailystr = string(job.date, " vs ", results["against_date"])
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

    # print summary of tested packages #
    #----------------------------------#

    # we don't care about the distinction between failed and killed tests,
    # so lump them together
    for key in ("primary", "against", "previous")
        if haskey(results, key)
            df = results[key]
            df[df[!, :status] .== :kill, :status] .= :fail
        end
    end

    o = count(==(:ok),      results["primary"].status)
    s = count(==(:skip),    results["primary"].status)
    f = count(==(:fail),    results["primary"].status)
    x = nrow(results["primary"])

    println(io, """
                In total, $x packages were tested, out of which $o succeeded, $f failed and $s were skipped.
                """)

    println(io)

    # print result list #
    #-------------------#

    if hasagainstbuild
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
                                    :skip   => ("were skipped", ":heavy_minus_sign:"))
        # NOTE: no `groupby(package_results, :status)` because we can't impose ordering
        group = package_results[package_results[!, :status] .== status, :]
        sort!(group, :name)

        if !isempty(group)
            println(io, "## $emoji Packages that $verb\n")

            # report on a single test
            function reportrow(test)
                verstr(version) = ismissing(version) ? "" : " v$(version)"

                primary_log = "logs/$(test.name)/$(test.julia).log"
                print(io, "- [$(test.name)$(verstr(test.version))]($primary_log)")

                # "against" entries are suffixed with `_1` because of the join
                if test.source == "both"
                    against_log = "logs/$(test.name_1)/$(test.julia_1).log"
                    print(io, " vs. [$(test.name_1)$(verstr(test.version_1))]($against_log)")

                    print(io, " ($(NewPkgEval.statusses[test.status_1])")
                    if !ismissing(test.reason_1)
                        print(io, ", $(NewPkgEval.reasons[test.reason_1])")
                    end
                    print(io, ")")
                end

                println(io)
            end

            # report on a group of tests, prefixed with the reason
            function reportgroup(group)
                subgroups = groupby(group, :reason; skipmissing=true)
                for subgroup in subgroups
                    println(io, uppercasefirst(NewPkgEval.reasons[first(subgroup).reason]), ":")
                    println(io)
                    foreach(reportrow, eachrow(subgroup))
                    println(io)
                end

                # print tests without a reason separately, at the end
                subgroup = group[group[!, :reason] .=== missing, :]
                if !isempty(subgroup)
                    if length(subgroups) > 0
                        println(io, "Other:")
                        println(io)
                    end
                    foreach(reportrow, eachrow(subgroup))
                    println(io)
                end
            end

            if hasagainstbuild
                # first report on tests that changed status
                changed_tests = filter(test->test.source == "both" &&
                                             test.status != test.status_1, group)
                if !isempty(changed_tests)
                    println(io, "**$(nrow(changed_tests)) packages $verb only on the current version.**")
                    println(io)
                    reportgroup(changed_tests)

                    if status == :fail
                        results["has_issues"] |= true

                        # if this was an explicit "vs" build (i.e., not a daily comparison
                        # against a previous day), give the syntax to re-test failures.
                        if haskey(submission(job).kwargs, :vs)
                            vs = submission(job).kwargs[:vs]
                            println(io,  """
                                <details><summary>Click here for the Nanosoldier invocation to re-run these tests.</summary>
                                <p>

                                ```
                                @nanosoldier `runtests($(repr(changed_tests.name)), vs = $vs)`
                                ```

                                </p>
                                </details>
                                """)

                            println(io)
                        end
                    end
                end

                # now report the other ones
                unchanged_tests = filter(test->test.source == "left_only" ||
                                               test.status == test.status_1, group)
                if !isempty(unchanged_tests)
                    println(io, """
                        <details><summary><strong>$(nrow(unchanged_tests)) packages $verb on the previous version too.</strong></summary>
                        <p>
                        """)
                    unchanged_tests = copy(unchanged_tests)     # only report the
                    unchanged_tests[!, :source] .= "left_only"  # primary result
                    reportgroup(unchanged_tests)
                    println(io, """
                        </p>
                        </details>
                        """)
                end
            else
                # just report on all tests
                println(io, "$(nrow(group)) packages $verb.")
                println(io)
                reportgroup(group)

                if status == :fail
                    results["has_issues"] |= true
                end
            end

            println(io)
        end
    end

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
        ),
        "date" => job.date,
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
