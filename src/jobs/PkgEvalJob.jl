using PkgEval
using DataFrames
using Feather
using JSON
using LibGit2
using CommonMark
using Pkg


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
        return is_valid_stringvector(parsed)
    elseif parsed == :ALL
        return true
    else
        return isa(parsed, AbstractString)
    end
end

function is_valid_stringvector(pkgsel::Expr)
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

function is_valid_configuration(config::Expr)
    if config.head != :tuple
        return false
    else
        for item in config.args
            if Meta.isexpr(item, :(=))
                if !isa(item.args[1], Symbol) || !is_valid_tupleitem(item.args[2])
                    return false
                end
            elseif !is_valid_tupleitem(item)
                return false
            end
        end
    end
    return true
end

const valid_tupleitem_literals = [String, Int, Bool]
function is_valid_tupleitem(item)
    if typeof(item) in valid_tupleitem_literals
        return true
    elseif item.head == :vect
        for element in item.args
            if !is_valid_tupleitem(element)
                return false
            end
        end
    else
        return false
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
    configuration::Configuration
    against_configuration::Configuration
    # FIXME: put configuration in BuildRef? currently created too early for that (when the
    #        GitHub event is parsed, while we get the configuration from the comment)
end

function PkgEvalJob(submission::JobSubmission)
    if haskey(submission.kwargs, :vs)
        againststr = Meta.parse(submission.kwargs[:vs])
        if in(SHA_SEPARATOR, againststr) # e.g. againststr == christopher-dG/julia@e83b7559df94b3050603847dbd6f3674058027e6
            reporef, againstsha = split(againststr, SHA_SEPARATOR)
            againstrepo = isempty(reporef) ? submission.config.trackrepo : reporef
            againstbuild = commitref(submission.config, againstrepo, againstsha)
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

    if haskey(submission.kwargs, :isdaily)
        isdaily = submission.kwargs[:isdaily] == "true"
        validatate_isdaily(submission)
    else
        isdaily = false
    end

    if haskey(submission.kwargs, :configuration)
        expr = Meta.parse(submission.kwargs[:configuration])
        if !is_valid_configuration(expr)
            error("invalid argument to `configuration` keyword (expected a tuple)")
        end
        tup = eval(expr)
        configuration = Configuration(; tup...)
    else
        configuration = Configuration(; rr=true)
    end

    if haskey(submission.kwargs, :vs_configuration)
        expr = Meta.parse(submission.kwargs[:vs_configuration])
        if !is_valid_configuration(expr)
            error("invalid argument to `vs_configuration` keyword (expected a tuple)")
        end
        tup = eval(expr)
        against_configuration = Configuration(; tup...)
    else
        against_configuration = Configuration()
    end

    return PkgEvalJob(submission, first(submission.args), against,
                      Date(submission.build.time), isdaily,
                      configuration, against_configuration)
end

function Base.summary(job::PkgEvalJob)
    result = "PkgEvalJob $(summary(submission(job).build))"
    if job.isdaily
        result *= " [$(Date(submission(job).build.time))]"
    elseif job.against !== nothing
        result *= " vs. $(summary(job.against))"
    end
    return result
end

function isvalid(submission::JobSubmission, ::Type{PkgEvalJob})
    allowed_kwargs = (:vs, :isdaily, :configuration, :vs_configuration)
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
tmpdir(job::PkgEvalJob) = joinpath(workdir, "tmpresults")
tmplogdir(job::PkgEvalJob) = joinpath(tmpdir(job), "logs")
tmpdatadir(job::PkgEvalJob) = joinpath(tmpdir(job), "data")

########################
# PkgEvalJob Execution #
########################

# execute the tests of all packages specified by a PkgEvalJob on one or more Julia builds
function execute_tests!(job::PkgEvalJob, builds::Dict, base_configs::Dict, results::Dict)
    node = myid()
    cfg = submission(job).config

    # determine configurations to use
    configs = Dict{String,Configuration}()
    for (whichbuild, build) in builds
        # determine Julia version matching requested BuildRef
        julia = "$(build.repo)#$(build.sha)"
        nodelog(cfg, node, "Resolved $whichbuild build to Julia commit $(build.sha) at $(build.repo)")

        # create a configuration
        configs[whichbuild] = Configuration(base_configs[whichbuild]; julia)

        # get some version info
        try
            out = Pipe()
            PkgEval.sandboxed_julia(configs[whichbuild], ```-e '
                    using InteractiveUtils
                    versioninfo(verbose=true)
                    '
                ```; stdout=out, stderr=out, stdin=devnull)
            close(out.in)
            build.vinfo = first(split(read(out, String), "Environment"))
        catch err
            build.vinfo = string("retrieving versioninfo() failed: ", sprint(showerror, err))
        end
    end

    # determine packages to test
    pkgsel = Meta.parse(job.pkgsel)
    pkgs = if pkgsel == :ALL
        nothing
    else
        # safe to evaluate, it's a :vec of Strings
        [Package(; name) for name in eval(pkgsel)]
    end

    # run tests
    all_tests = withenv("CI" => true) do
        cpus = mycpus(submission(job).config)
        results["duration"] = @elapsed if pkgs !== nothing
            tests = PkgEval.evaluate(configs, pkgs; ninstances=length(cpus))
        else
            tests = PkgEval.evaluate(configs; ninstances=length(cpus))
        end
        tests
    end

    # process the results for each Julia version separately
    for (whichbuild, build) in builds
        tests = all_tests[(all_tests[!, :configuration] .== whichbuild), :]
        results[whichbuild] = tests

        # write logs
        if cfg.bucket !== nothing
            for test in eachrow(tests)
                if !ismissing(test.log)
                    try
                        S3.put_object("$(cfg.bucket)/pkgeval/$(jobdirname(job))",
                                      "$(test.package).$(whichbuild).log",
                                      Dict("body"       => test.log,
                                           "x-amz-acl"  => "public-read",
                                           "headers"    => Dict("Content-Type"=>"text/plain; charset=utf-8")))
                    catch err
                        rethrow(NanosoldierError("failed to upload test log", err))
                    end
                end
            end
        else
            for test in eachrow(tests)
                dir = joinpath(tmplogdir(job), test.package)
                isdir(dir) || mkdir(dir)
                open(joinpath(dir, "$(whichbuild).log"), "w") do io
                    if !ismissing(test.log)
                        write(io, test.log)
                    end
                end
            end
        end

        # write data
        ## dataframe with test results
        let tests = copy(tests)
            # remove logs; these are terribly large and probably not interesting anyway
            select!(tests, Not([:log]))

            # Feather can't handle non-primitive types, so stringify them
            for col in (:version, :status, :reason)
                tests[!, col] = map(repr, tests[!, col])
            end

            Feather.write(joinpath(tmpdatadir(job), "$(whichbuild).feather"), tests)
        end
        ## dict with build properties
        open(joinpath(tmpdatadir(job), "$(whichbuild).json"), "w") do io
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
    if cfg.bucket === nothing
        nodelog(cfg, node, "...creating $(tmplogdir(job))...")
        mkdir(tmplogdir(job))
    end
    nodelog(cfg, node, "...creating $(tmpdatadir(job))...")
    mkdir(tmpdatadir(job))

    # update packages
    Pkg.Registry.update()

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
                job.against = commitref(cfg, latest["build"]["repo"], latest["build"]["sha"])
                nodelog(cfg, node, "comparing against daily build from $(Date(job.against.time))")
            else
                nodelog(cfg, node, "didn't find previous daily build data")
            end
        catch err
            rethrow(NanosoldierError("encountered error when retrieving old daily build data", err))
        end
    end

    # refuse to test against an identical build
    if job.against !== nothing && job.against.sha == submission(job).build.sha &&
       job.against_configuration == job.configuration
        nodelog(cfg, node, "refusing to compare identical builds, demoting to non-comparing evaluation")
        job.against = nothing
    end

    # run tests
    builds = Dict("primary" => submission(job).build)
    configs = Dict("primary" => job.configuration)
    if job.against !== nothing
        builds["against"] = job.against
        configs["against"] = job.against_configuration
    end
    try
        nodelog(cfg, node, "running tests for $(summary(job))")
        execute_tests!(job, builds, configs, results)
        nodelog(cfg, node, "running tests for $(summary(job))")
    finally
        PkgEval.purge()
    end

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
        reply_comment(job, "[Your package evaluation job]($(submission(job).url)) has completed, " *
                      "but no tests were actually executed. Perhaps your package selection " *
                      "contains misspelled names? cc @$(cfg.admin)")
    else
        #  prepare report + data and push it to report repo
        target_url = ""
        try
            nodelog(cfg, node, "...generating report...")
            reportname = "report.md"
            report_md = sprint(io->printreport(io, job, results))
            write(joinpath(tmpdir(job), reportname), report_md)
            if job.isdaily
                nodelog(cfg, node, "...generating database...")
                dbname = "db.json"
                open(joinpath(tmpdir(job), dbname), "w") do file
                    printdb(file, job, results)
                end
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
            if job.isdaily
                latest = reportdir(job; latest=true)
                islink(latest) && rm(latest)
                symlink(datedirname(job.date), latest)
            end
            nodelog(cfg, node, "...pushing $(reportdir(job)) to GitHub...")
            target_url = upload_report_repo!(job, joinpath("pkgeval", jobdirname(job), reportname),
                                             "upload report for $(summary(job))")

            # if we have a working S3 bucket, put a rendered version of the report there
            if cfg.bucket !== nothing
                reportname = "report.html"
                parser = Parser()
                ast = parser(report_md)
                body = html(ast)
                report_html = """
                    <!DOCTYPE html>
                    <html>
                    <head>
                        <meta charset="utf-8">
                        <title>$(summary(job))</title>
                        <style>
                        body {
                            font-family: sans-serif;
                            max-width: 65rem;
                        }
                        </style>
                    </head>
                    <body>$body</body>
                    </html>
                """
                try
                    S3.put_object("$(cfg.bucket)/pkgeval/$(jobdirname(job))",
                                  "report.html",
                                  Dict("body"       => report_html,
                                       "x-amz-acl"  => "public-read",
                                       "headers"    => Dict("Content-Type"=>"text/html; charset=utf-8")))
                    target_url = "https://s3.amazonaws.com/$(cfg.bucket)/pkgeval/$(jobdirname(job))/$(reportname)"
                catch err
                    rethrow(NanosoldierError("failed to upload test report", err))
                end
            end
        catch err
            rethrow(NanosoldierError("error when preparing/pushing to report repo", err))
        end

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
            comment = "[Your package evaluation job]($(submission(job).url)) has completed, but " *
                        "something went wrong when trying to upload the result data. cc @$(cfg.admin)"
        else
            comment = "[Your package evaluation job]($(submission(job).url)) has completed - " *
                        "$(status). A full report can be found [here]($(target_url))."
        end
        reply_comment(job, comment)
    end
end

# Markdown Report Generation #
#----------------------------#

function readable_duration(seconds)
    str = ""
    if seconds > 60*60*24
        days = Int(seconds ÷ (60*60*24))
        seconds -= days * 60*60*24
        if days > 1
            str *= "$days days"
        else
            str *= "$days day"
        end
    end
    if seconds > 60*60
        hours = Int(seconds ÷ (60*60))
        seconds -= hours * 60*60
        isempty(str) || (str *= ", ")
        if hours > 1
            str *= "$hours hours"
        else
            str *= "$hours hour"
        end
    end
    if seconds > 60
        minutes = Int(seconds ÷ 60)
        seconds -= minutes * 60
        isempty(str) || (str *= ", ")
        if minutes > 1
            str *= "$minutes minutes"
        else
            str *= "$minutes minute"
        end
    end
    if seconds > 0 || isempty(str)
        seconds = trunc(Int, seconds)
        isempty(str) || (str *= ", ")
        if seconds > 1
            str *= "$seconds seconds"
        else
            str *= "$seconds second"
        end
    end
    return str
end

function printreport(io::IO, job::PkgEvalJob, results)
    cfg = submission(job).config
    build = submission(job).build
    buildname = string(build.repo, SHA_SEPARATOR, build.sha)
    buildlink = "https://github.com/$(build.repo)/commit/$(build.sha)"
    joblink = "[$(buildname)]($(buildlink))"
    hasagainstbuild = job.against !== nothing

    # in contrast to BenchmarkJob, comparison jobs always have an against build, even daily
    # ones (so we don't need `iscomparisonjob`). in the case of a daily comparison job,
    # we look at `against.time` (so we don't need `hasprevdate`).

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

    # print report preface + job properties #
    #---------------------------------------#

    println(io, """
                # Package Evaluation Report

                ## Job Properties

                *Commit$(hasagainstbuild ? "s" : ""):* $(joblink)

                *Triggered By:* [link]($(submission(job).url))

                *Package Selection:* $(markdown_escaped_code(job.pkgsel))
                """)

    if job.isdaily
        if hasagainstbuild
            latest_dir = reportdir(job; latest=true)
            against_date = Date(job.against.time)
            if isdir(latest_dir) && islink(latest_dir)
                prev_reportlink = "../../$(readlink(latest_dir))/report.html"
                against_date = "[$(against_date)]($(prev_reportlink))"
            end
            dailystr = string(job.date, " vs ", against_date)
        else
            dailystr = string(job.date)
        end
        println(io, """
                    *Daily Job:* $(dailystr)
                    """)
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
    c = count(==(:crash),   results["primary"].status)
    f = count(==(:fail),    results["primary"].status)
    x = nrow(results["primary"])

    println(io, """
                In total, $x packages were tested, out of which $o succeeded, $c crashed, $f failed and $s were skipped.
                """)

    if haskey(results, "duration")
        total_duration = 0
        total_tests = 0
        for key in ("primary", "against", "previous")
            if haskey(results, key)
                total_duration += sum(results[key].duration)
                total_tests += nrow(results[key])
            end
        end

        println(io, """
                    Testing took $(readable_duration(results["duration"])) (or, sequentially, $(readable_duration(total_duration)) to execute $total_tests package tests suites).
                    """)
    end

    println(io)

    # print result list #
    #-------------------#

    if hasagainstbuild
        package_results = leftjoin(results["primary"], results["against"],
                                   on=:package, makeunique=true, source=:source)
    else
        package_results = results["primary"]
        package_results[!, :source] .= "left_only" # fake a left join
    end

    results["has_issues"] = false

    # report test results in groups based on the test status
    for (status, (verb, emoji)) in (:crash  => ("crashed during testing", "❗"),
                                    :fail   => ("failed tests", "✖"),
                                    :ok     => ("passed tests", "✔"),
                                    :skip   => ("were skipped", "➖"))
        # NOTE: no `groupby(package_results, :status)` because we can't impose ordering
        group = package_results[package_results[!, :status] .== status, :]
        sort!(group, :package)

        if !isempty(group)
            println(io, "## $emoji Packages that $verb\n")

            # report on a single test
            function reportrow(test)
                primary_log = if cfg.bucket !== nothing
                    "https://s3.amazonaws.com/$(cfg.bucket)/pkgeval/$(jobdirname(job))/$(test.package).primary.log"
                else
                    "logs/$(test.package)/primary.log"
                end
                primary_status = test.status == :ok ? "good" : "bad"

                # "against" entries are suffixed with `_1` because of the join
                if test.source == "both"
                    # PkgEval always compares the same package versions, so only report it once
                    print(io, "- $(test.package)")
                    if test.version !== missing
                        print(io, " v$(test.version)")
                    elseif test.source == "both" && test.version_1 !== missing
                        print(io, " v$(test.version_1)")
                    end
                    print(io, ": ")

                    print(io, "[$primary_status]($primary_log)")

                    against_log = if cfg.bucket !== nothing
                        "https://s3.amazonaws.com/$(cfg.bucket)/pkgeval/$(jobdirname(job))/$(test.package).against.log"
                    else
                        "logs/$(test.package)/against.log"
                    end
                    against_status = test.status_1 == :ok ? "good" : "bad"
                    print(io, " vs. [$against_status]($against_log)")
                else
                    print(io, "- [$(test.package)")
                    if test.version !== missing
                        print(io, " v$(test.version)")
                    end
                    print(io, "]($primary_log)")
                end

                println(io)
            end

            # report on a group of tests, prefixed with the reason
            function reportgroup(group)
                subgroups = groupby(group, :reason; skipmissing=true)
                for key in sort(keys(subgroups); by=key->PkgEval.reason_severity(key.reason))
                    subgroup = subgroups[key]
                    println(io, """
                        <details open><summary>$(uppercasefirst(PkgEval.reason_message(first(subgroup).reason))) ($(nrow(subgroup)) packages):</summary>
                        <p>
                        """)
                    println(io)
                    foreach(reportrow, eachrow(subgroup))
                    println(io)
                    println(io, """
                        </p>
                        </details>
                        """)
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

            if hasagainstbuild && !(job.isdaily && status === :crash)
                # first report on tests that changed status. note that we don't do this for
                # crashes on daily tests, to feature them more prominently in the report.
                changed_tests = filter(test->test.source == "both" &&
                                             test.status != test.status_1, group)
                if !isempty(changed_tests)
                    println(io, "**$(nrow(changed_tests)) packages $verb only on the current version.**")
                    println(io)
                    reportgroup(changed_tests)

                    if status in [:fail, :crash]
                        results["has_issues"] |= true

                        # if this was an explicit "vs" build (i.e., not a daily comparison
                        # against a previous day), give the syntax to re-test failures.
                        if haskey(submission(job).kwargs, :vs)
                            vs = submission(job).kwargs[:vs]
                            cmd = "$(repr(changed_tests.package)), vs = $vs"
                            if haskey(submission(job).kwargs, :configuration)
                                cmd *= ", configuration = $(submission(job).kwargs[:configuration])"
                            end
                            if haskey(submission(job).kwargs, :vs_configuration)
                                cmd *= ", vs_configuration = $(submission(job).kwargs[:vs_configuration])"
                            end
                            println(io,  """
                                <details><summary>Click here for the Nanosoldier invocation to re-run these tests.</summary>
                                <p>

                                ```
                                @nanosoldier `runtests($cmd)`
                                ```

                                Note that Nanosoldier defaults to running the primary tests under `rr`, which itself may be a source of failures.
                                To disable this, add `configuration = (rr=false,)` as an argument to the `runtests` invocation.

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

                if status in [:fail, :crash]
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

    if haskey(submission(job).kwargs, :configuration)
        println(io, "*Configuration*: `", submission(job).kwargs[:configuration], "`")
    end

    if hasagainstbuild
        println(io)
        print(io, """
                  #### Comparison Build

                  ```
                  $(job.against.vinfo)
                  ```
                  """)

        if haskey(submission(job).kwargs, :vs_configuration)
            println(io, "*Configuration*: `", submission(job).kwargs[:vs_configuration], "`")
        end
    end

    println(io, "<!-- Generated on $(now()) -->")

    return nothing
end

# JSON Database Generation #
#--------------------------#

function printdb(io::IO, job::PkgEvalJob, results)
    build = submission(job).build

    # parse Julia version info
    m = match(r"Julia Version (.+)", build.vinfo)
    build_version = if m !== nothing
        tryparse(VersionNumber, m.captures[1])
    else
        nothing
    end

    # build information
    json = Dict{String,Any}(
        "build" => Dict(
            "repo"      => build.repo,
            "sha"       => build.sha,
            "version"   => something(build_version, "unknown")
        ),
        "date" => job.date,
    )

    # test results
    tests = Dict()
    for test in eachrow(results["primary"])
        tests[test.package] = Dict(
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
