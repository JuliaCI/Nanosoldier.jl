using PkgEval
using DataFrames
using Feather
using JSON
using Dates
using LibGit2
using CommonMark
using Pkg
import Downloads
import TOML
import RegistryTools


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

@enum PkgEvalType begin
    PkgEvalTypeJulia        # test a Julia version against packages
    PkgEvalTypePackage      # test a package version against other packages
end

mutable struct PkgEvalJob <: AbstractJob
    submission::JobSubmission        # the original submission
    type::PkgEvalType                # the type of job
    pkgsel::Vector{String}           # selection of packages
    against::Union{BuildRef,Nothing} # the comparison build (if available)
    date::Dates.Date                 # the date of the submitted job
    isdaily::Bool                    # is the job a daily job?
    configuration::Configuration
    against_configuration::Configuration
    use_blacklist::Bool
    subdir::String                   # which subdirectory to use (for package tests)
end

function PkgEvalJob(submission::JobSubmission)
    # preliminary validation
    for kwarg in keys(submission.kwargs)
        if !in(kwarg, (:vs, :isdaily, :configuration, :vs_configuration, :subdir))
            nanosoldier_error("invalid keyword argument `$kwarg`")
        end
    end
    if isempty(submission.args)
        # all good
    elseif length(submission.args) == 1
        if !is_valid_pkgsel(submission.args[1])
            nanosoldier_error("invalid package selection")
        end
    else
        nanosoldier_error("expected zero or one positional argument; got $(length(submission.args))")
    end

    # based on the repo name, we'll be running in Julia or in Package test mode
    repo_owner, repo_name = split(submission.repo, "/")
    jobtype = if repo_name == "julia"
        PkgEvalTypeJulia
    else
        PkgEvalTypePackage
    end

    pkgsel = if isempty(submission.args) || first(submission.args) == "ALL"
        String[]
    else
        pkgs = eval(Meta.parse(first(submission.args)))
        if pkgs isa Vector
            pkgs
        else
            [pkgs]
        end
    end

    if haskey(submission.kwargs, :vs)
        againststr = Meta.parse(submission.kwargs[:vs])
        if in(SHA_SEPARATOR, againststr) # e.g. againststr == christopher-dG/julia@e83b7559df94b3050603847dbd6f3674058027e6
            reporef, againstsha = split(againststr, SHA_SEPARATOR)
            againstrepo = isempty(reporef) ? submission.repo : reporef
            againstbuild = commitref(submission.config, againstrepo, againstsha)
        elseif in(BRANCH_SEPARATOR, againststr)
            reporef, againstbranch = split(againststr, BRANCH_SEPARATOR)
            againstrepo = isempty(reporef) ? submission.repo : reporef
            againstbuild = branchref(submission.config, againstrepo, againstbranch)
        elseif in(TAG_SEPARATOR, againststr)
            reporef, againsttag = split(againststr, TAG_SEPARATOR)
            againstrepo = isempty(reporef) ? submission.repo : reporef
            againstbuild = tagref(submission.config, againstrepo, againsttag)
        elseif againststr == SPECIAL_SELF
            againstbuild = copy(submission.build)
        else
            nanosoldier_error("invalid argument to `vs` keyword")
        end
        against = againstbuild
    elseif submission.prnumber !== nothing
        # if there is a PR number, we compare against the base branch.
        # this does not apply to packages, where we compare against the latest release.
        pr_details = GitHub.pull_request(submission.repo, submission.prnumber;
                                         auth=submission.config.auth)
        base_branch = pr_details.base.ref
        merge_base = GitHub.compare(submission.repo,
                                    base_branch, "refs/pull/$(submission.prnumber)/head";
                                    auth=submission.config.auth).merge_base_commit
        against = commitref(submission.config, submission.repo, merge_base.sha)
    else
        against = nothing
    end

    if haskey(submission.kwargs, :isdaily)
        jobtype == PkgEvalTypeJulia ||
            nanosoldier_error("`isdaily` keyword is only allowed when testing Julia")
        isdaily = submission.kwargs[:isdaily] == "true"
        validatate_isdaily(submission)
    else
        isdaily = false
    end

    if haskey(submission.kwargs, :subdir)
        jobtype == PkgEvalTypePackage ||
            nanosoldier_error("`subdir` keyword is only allowed when testing packages")
        subdir = Meta.parse(submission.kwargs[:subdir])
        if !isa(subdir, String)
            nanosoldier_error("invalid argument to `subdir` keyword (expected a string)")
        end
    else
        subdir = ""
    end

    configuration = if jobtype == PkgEvalTypePackage
        Configuration(name="primary", julia="stable")
    else
        Configuration(buildflags=["LLVM_ASSERTIONS=1", "FORCE_ASSERTIONS=1"],
                      rr=(isdaily ? PkgEval.RREnabledOnRetry : PkgEval.RRDisabled),
                      name="primary")
    end
    if haskey(submission.kwargs, :configuration)
        expr = Meta.parse(submission.kwargs[:configuration])
        if !is_valid_configuration(expr)
            nanosoldier_error("invalid argument to `configuration` keyword (expected a tuple)")
        end
        tup = eval(expr)
        configuration = Configuration(configuration; tup...)
    end

    against_configuration = if jobtype == PkgEvalTypePackage
        Configuration(name="against", julia="stable")
    else
        Configuration(buildflags=["LLVM_ASSERTIONS=1", "FORCE_ASSERTIONS=1"],
                      name="against")
    end
    if haskey(submission.kwargs, :vs_configuration)
        expr = Meta.parse(submission.kwargs[:vs_configuration])
        if !is_valid_configuration(expr)
            nanosoldier_error("invalid argument to `vs_configuration` keyword (expected a tuple)")
        end
        tup = eval(expr)
        against_configuration = Configuration(against_configuration; tup...)
    elseif haskey(submission.kwargs, :configuration)
        # if only :configuration was specified, use that for both primary and against
        expr = Meta.parse(submission.kwargs[:configuration])
        if !is_valid_configuration(expr)
            nanosoldier_error("invalid argument to `configuration` keyword (expected a tuple)")
        end
        tup = eval(expr)
        against_configuration = Configuration(against_configuration; tup...)
    end

    # determine whether to use a blacklist.
    use_blacklist = true
    if haskey(submission.kwargs, :use_blacklist)
        use_blacklist = parse(Bool, submission.kwargs[:use_blacklist])
    elseif jobtype == PkgEvalTypeJulia
        if isdaily
            # daily evaluations, which are used to _create_ the blacklist, obviously need to
            # test all packages
            use_blacklist = false
        else
            # when comparing against an older version of Julia, e.g., a release branch, we
            # have to check if that branch hasn't diverged too much from upstream master,
            # which is what's used to generate the blacklist.
            function has_diverged(ref)
                merge_base = GitHub.compare("JuliaLang/julia", "master", ref.sha;
                                            auth=submission.config.auth).merge_base_commit
                commit = commitref(submission.config, submission.repo, merge_base.sha)
                return Dates.now() - commit.time > Dates.Day(14)
            end
            if against !== nothing
                if has_diverged(against)
                    use_blacklist = false
                end
            else
                if has_diverged(submission.build)
                    use_blacklist = false
                end
            end
        end
    else
        # for package tests, we can only use the blacklist when using a very recent Julia
        if !(configuration.julia         in ["master", "nightly"] &&
             against_configuration.julia in ["master", "nightly"])
            use_blacklist = false
        end
    end

    return PkgEvalJob(submission, jobtype, pkgsel, against,
                      Date(submission.build.time), isdaily,
                      configuration, against_configuration,
                      use_blacklist, subdir)
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

function retrieve_daily_pkgeval_data!(cfg, date)
    dailydir = joinpath(reportdir(cfg), "pkgeval", "by_date", datedirname(date))
    isdir(dailydir) || return nothing

    # NOTE: we don't actually use the data from the previous day, just the
    #       build properties, since packages upgrades might cause failures too.
    dbpath = joinpath(dailydir, "db.json")
    isfile(dbpath) || return nothing

    db = JSON.parsefile(dbpath)
    return db
end

# determine a list of packages to blacklist
function determine_blacklist(job::PkgEvalJob)
    node = myid()
    cfg = submission(job).config

    blacklist = String[]

    if job.use_blacklist
        try
            packages_url = "https://juliaci.github.io/NanosoldierReports/pkgeval_packages.toml"
            packages_contents = sprint(io->Downloads.download(packages_url, io))
            packages = TOML.parse(packages_contents)
            append!(blacklist, packages["unreliable"])
            nodelog(cfg, node, "Blacklisted $(length(blacklist)) packages")
        catch err
            nodelog(cfg, node, "Failed to retrieve package blacklist",
                    error=(err, stacktrace(catch_backtrace())))
        end
    else
        nodelog(cfg, node, "Not using a package blacklist")
    end

    return blacklist
end

# determine the direct dependencies of a given package and version
# by reading the registry and parsing deps/compat sections.
function direct_dependencies(registry_path::String, package::String, version::VersionNumber)
    dependents = []
    registry = Pkg.Registry.RegistryInstance(registry_path)
    for (uuid, candidate_package) in registry
        info = Pkg.Registry.registry_info(candidate_package)

        # PkgEval only tests the latest version of each package
        latest_version = maximum(keys(info.version_info))

        # determine the dependencies for the latest version of this candidate
        all_deps = Dict()
        for (version_range, deps) in info.deps
            latest_version in version_range || continue
            merge!(all_deps, deps)
        end

        # does it depend on the package we're testing?
        haskey(all_deps, package) || continue

        # check if there's no compat bound restricting the version
        compat = true
        for (version_range, bounds) in info.compat
            latest_version in version_range || continue
            haskey(bounds, package) || continue
            if version ∉ bounds[package]
                compat = false
            end
        end
        compat || continue

        push!(dependents, candidate_package.name)
    end
    return dependents
end

# determine how many packages depend on each package (for sorting purposes).
# this doesn't need to be super accurate, so we just use the local registry.
function package_dependents(; transitive::Bool=true)
    dependents = Dict{String,Set{String}}()

    # populate with direct dependents/dependencies
    for registry in Pkg.Registry.reachable_registries()
        for (uuid, package) in registry
            info = Pkg.Registry.registry_info(package)

            # PkgEval only tests the latest version of each package
            latest_version = maximum(keys(info.version_info))

            # determine the dependencies for the latest version of this candidate
            all_deps = Dict()
            for (version_range, deps) in info.deps
                latest_version in version_range || continue
                for dep in keys(deps)
                    if !haskey(dependents, dep)
                        dependents[dep] = Set{String}()
                    end
                    push!(dependents[dep], package.name)
                end
            end
        end
    end

    if transitive
        # now iteratively add transitive dependencies to the set of dependents
        while true
            changed = false
            for package in keys(dependents)
                transitive_deps = Set{String}()
                for dep in dependents[package]
                    haskey(dependents, dep) || continue
                    for transitive_dep in dependents[dep]
                        transitive_dep in dependents[package] && continue
                        push!(transitive_deps, transitive_dep)
                    end
                end
                if !isempty(transitive_deps)
                    union!(dependents[package], transitive_deps)
                    changed = true
                end
            end
            if !changed
                break
            end
        end
    end

    # now flatten to a dictionary of counts
    Dict(package => length(dependents[package]) for package in keys(dependents))
end

# read the version info of a Julia configuration
function get_versioninfo!(job::PkgEvalJob, config::Configuration, results::Dict)
    node = myid()
    cfg = submission(job).config

    try
        out = Pipe()
        PkgEval.sandboxed_julia(config, ```-e '
                using InteractiveUtils
                versioninfo(verbose=true)
                '
            ```; stdout=out, stderr=out, stdin=devnull)
        close(out.in)
        first(split(read(out, String), "Environment"))
    catch err
        nodelog(cfg, node, "Failed to retrieve versioninfo()",
                error=(err, stacktrace(catch_backtrace())))
        string("retrieving versioninfo() failed; consult server logs for more details")
    end
end

# process the results of a PkgEval job, uploading logs and saving other data to disk
function process_results!(job::PkgEvalJob, builds::Dict, all_tests::DataFrame, results::Dict)
    node = myid()
    cfg = submission(job).config

    nodelog(cfg, node, "proccessing results...")
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
                        nodelog(cfg, node, "Failed to upload test log",
                                error=(err, stacktrace(catch_backtrace())))
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
        if build !== nothing
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
    nodelog(cfg, node, "finished proccessing results")
end

########################
# PkgEvalJob Execution #
########################

# execute package tests using one or more Julia builds
function test_julia!(job::PkgEvalJob, builds::Dict, base_configs::Dict, results::Dict)
    node = myid()
    cfg = submission(job).config

    # determine configurations to use
    configs = Configuration[]
    for (whichbuild, build) in builds
        # determine Julia version matching requested BuildRef
        julia = "$(build.repo)#$(build.sha)"
        nodelog(cfg, node, "Resolved $whichbuild build to commit $(build.sha) at $(build.repo)")

        # create a configuration
        config = Configuration(base_configs[whichbuild]; julia)
        results["$(whichbuild).vinfo"] = get_versioninfo!(job, config, results)
        push!(configs, config)
    end

    # determine packages to test/skip
    pkgs = if isempty(job.pkgsel)
        nothing
    else
        [Package(; name) for name in job.pkgsel]
    end
    blacklist = determine_blacklist(job)

    # run tests
    all_tests = withenv("CI" => true) do
        cpus = mycpus(submission(job).config)
        results["duration"] = @elapsed if pkgs !== nothing
            tests = PkgEval.evaluate(configs, pkgs; ninstances=length(cpus), blacklist)
        else
            tests = PkgEval.evaluate(configs; ninstances=length(cpus), blacklist)
        end
        tests
    end

    process_results!(job, builds, all_tests, results)
end

# execute package tests after upgrading to a specific version of a package
function test_package!(job::PkgEvalJob, builds::Dict, base_configs::Dict, results::Dict)
    node = myid()
    cfg = submission(job).config

    # determine configurations to use
    configs = Configuration[]
    dependencies = Dict()
    for (whichbuild, build) in builds
        # determine package version matching requested BuildRef
        package = "$(build.repo)#$(build.sha)"
        nodelog(cfg, node, "Resolved $whichbuild build to commit $(build.sha) at $(build.repo)")

        # get the package source
        package_url = "https://github.com/$(build.repo).git"
        package_repo = PkgEval.get_github_checkout(build.repo, build.sha)
        package_path = joinpath(package_repo, job.subdir)
        package_hash = string(Base.SHA1(Pkg.GitTools.tree_hash(package_path)))

        # parse the Project.toml
        package_project_path = joinpath(package_path, "Project.toml")
        isfile(package_project_path) ||
            nanosoldier_error("package project file not found")
        package_project = RegistryTools.Project(package_project_path)

        # generate a custom registry
        reference_registry = PkgEval.get_registry(base_configs[whichbuild])
        registry_path = mktempdir()
        cp(reference_registry, registry_path; force=true)

        # get rid of all existing versions
        package_registry_path =
            joinpath(registry_path, uppercase(package_project.name[1:1]),
                        package_project.name)
        if isdir(package_registry_path)
            rm(joinpath(package_registry_path, "Versions.toml"); force=true)
            rm(joinpath(package_registry_path, "Compat.toml"); force=true)
        end

        # register our package
        regbr = RegistryTools.RegBranch(package_project, "pkgeval")
        status = RegistryTools.ReturnStatus()
        RegistryTools.check_and_update_registry_files(package_project, package_url,
                                                        package_hash, registry_path,
                                                        #=registry_deps=# String[],
                                                        status; job.subdir)
        if RegistryTools.haserror(status)
            RegistryTools.set_metadata!(regbr, status)
            nanosoldier_error("could not register new version ($(regbr.metadata["error"]))")
        end

        # note our package dependencies
        dependencies[whichbuild] =
            direct_dependencies(reference_registry,
                                package_project.name, package_project.version)
        nodelog(cfg, node, "$(length(dependencies[whichbuild])) packages depend on $(package_project.name) v$(package_project.version)")

        # create a configuration
        config = Configuration(base_configs[whichbuild]; registry=registry_path)
        results["$(whichbuild).vinfo"] = get_versioninfo!(job, config, results)
        push!(configs, config)
    end

    # determine packages to test/skip
    pkgs = if isempty(job.pkgsel)
        # test packages that are compatible with the latest version of our package.
        # this may result in failures when a package isn't compatible with the "against"
        # dependency, but instead of discarding such dependents (by intersecting the lists)
        # we include the package such that it'll error, which is more informative.
        dependencies = dependencies["primary"]

        [Package(; name) for name in dependencies]
    else
        [Package(; name) for name in job.pkgsel]
    end
    blacklist = determine_blacklist(job)

    # run tests
    all_tests = withenv("CI" => true) do
        cpus = mycpus(submission(job).config)
        results["duration"] = @elapsed if pkgs !== nothing
            tests = PkgEval.evaluate(configs, pkgs; ninstances=length(cpus), blacklist)
        else
            tests = PkgEval.evaluate(configs; ninstances=length(cpus), blacklist)
        end
        tests
    end

    process_results!(job, builds, all_tests, results)
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

    # instantiate the dictionary that will hold all of the info needed by `report`
    results = Dict{Any,Any}()

    if job.isdaily
        # get build from previous day
        try
            nodelog(cfg, node, "retrieving results from previous daily build")
            found_previous_date = false
            i = 1
            while !found_previous_date && i < 31
                check_date = job.date - Dates.Day(i)
                check_db = retrieve_daily_pkgeval_data!(cfg, check_date)
                if check_db !== nothing
                    found_previous_date = true
                    job.against = commitref(cfg, check_db["build"]["repo"], check_db["build"]["sha"])
                    nodelog(cfg, node, "comparing against daily build from $(Date(job.against.time))")
                end
                i += 1
            end
            found_previous_date || nodelog(cfg, node, "didn't find previous daily build data in the past 31 days")
        catch err
            nanosoldier_error("encountered error when retrieving old daily build data", err)
        end
    end

    # refuse to test against an identical build
    if job.against !== nothing && job.against.sha == submission(job).build.sha &&
       job.against_configuration == job.configuration
        nodelog(cfg, node, "refusing to compare identical builds, demoting to non-comparing evaluation")
        job.against = nothing
    end

    # run tests
    builds = Dict{String,Union{BuildRef,Nothing}}("primary" => submission(job).build)
    configs = Dict{String,Configuration}("primary" => job.configuration)
    try
        nodelog(cfg, node, "running tests for $(summary(job))")
        if job.against !== nothing
            builds["against"] = job.against
            configs["against"] = job.against_configuration
        end
        if job.type == PkgEvalTypeJulia
            test_julia!(job, builds, configs, results)
        else
            test_package!(job, builds, configs, results)
        end
        nodelog(cfg, node, "finished tests for $(summary(job))")
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

const COLOR_MAP = map(('▁' => ("#666", "skip"),
                       '▃' => ("#60F", "crash"),
                       '▅' => ("#F03", "fail"),
                       '▆' => ("#F60", "load"),
                       '▇' => ("#0F0", "test"),
                      )) do (char, (color, title))
    Regex("($char+)") => SubstitutionString("<span style=\"color: $color\" title=\"$title\">\\1</span>")
end

# report job results back to GitHub
function report(job::PkgEvalJob, results)
    node = myid()
    cfg = submission(job).config
    if haskey(results, "primary") && isempty(results["primary"])
        nanosoldier_error("no tests were executed (perhaps your package selection contains misspelled names?)")
    else
        # prepare report + data and push it to report repo
        target_url = nothing
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
                enable!(parser, TableRule())
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
                        .history {
                            font-family: monospace;
                        }
                        </style>
                    </head>
                    <body>$body</body>
                    </html>
                """
                report_html = replace(report_html, COLOR_MAP...)
                try
                    S3.put_object("$(cfg.bucket)/pkgeval/$(jobdirname(job))",
                                  "report.html",
                                  Dict("body"       => report_html,
                                       "x-amz-acl"  => "public-read",
                                       "headers"    => Dict("Content-Type"=>"text/html; charset=utf-8")))
                    target_url = "https://s3.amazonaws.com/$(cfg.bucket)/pkgeval/$(jobdirname(job))/$(reportname)"
                catch err
                    nanosoldier_error("failed to upload test report", err)
                end
            end
        catch err
            nanosoldier_error("error when preparing/pushing to report repo", err)
        end
        if target_url === nothing
            nanosoldier_error("failed to upload test report")
        end

        # determine the job's final status
        status = if job.against !== nothing
            results["has_issues"] ? "possible new issues were detected" :
                                    "no new issues were detected"
        else
            results["has_issues"] ? "possible issues were detected" :
                                    "no issues were detected"
        end

        package_results = make_package_results(results, job.against !== nothing)
        report_summary = sprint(io -> printpackageresults(io, job, package_results; headlines_only=true))

        # reply with the job's final status
        comment = """
            The package evaluation job [you requested]($(submission(job).url)) has completed - $status.
            The [**full report**]($(target_url)) is available.

            $report_summary
            """
        reply_comment(submission(job), comment)
    end
end

# Markdown Report Generation #
#----------------------------#

const status_blocks = Dict{String,Int}(
    "skip"  => '▁',
    "crash" => '▃',
    "fail"  => '▅',
    "load"  => '▆',
    "test"  => '▇',

    # backwards compatibility
    "ok"    => '▇',
)

function get_history(cfg, days=30)
    # Ensure repo is available locally
    root_dir = reportdir(cfg)
    dir = joinpath(root_dir, "pkgeval", "by_date")
    isdir(dir) || gitclone!(reportrepo(cfg), root_dir, cfg.auth)

    # Determine the date of the last upload
    format = dateformat"yyyy-mm/dd"
    latest = readlink(joinpath(dir, "latest"))
    end_date = parse(Date, latest, format)
    start_date = end_date - Day(days-1)

    # Download the json data representing pkgeval results
    content = Vector{Vector{UInt8}}(undef, days)
    @sync for (i, date) in enumerate(start_date:Day(1):end_date)
        date_str = Dates.format(date, format)
        @async try
            content[i] = read(joinpath(dir, date_str, "db.json"))
        catch _
            @warn "Failed to fetch data for $date_str"
            content[i] = Vector{UInt8}[]
        end
    end

    # Convert the json data into a dict mapping packages to results
    history = Dict{String, Vector{Char}}()
    for (i, c) in enumerate(content)
        isempty(c) && continue
        json = JSON.Parser.parse(IOBuffer(c))
        for (pkg, result) in json["tests"]
            if !haskey(history, pkg)
                history[pkg] = Char[]
            end
            push!(history[pkg], status_blocks[result["status"]])
        end
    end

    # Convert the dict into a string representations
    heading = "History ($(month(start_date))-$(day(start_date)) to $(month(end_date))-$(day(end_date)))"
    history_str = Dict(((pkg => join(c for c in h)) for (pkg, h) in history))
    heading, history_str
end

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

function make_package_results(results, hasagainstbuild)
    if hasagainstbuild
        return leftjoin(results["primary"], results["against"],
                                   on=:package, makeunique=true, source=:source)
    else
        package_results = results["primary"]
        package_results[!, :source] .= "left_only" # fake a left join
        return package_results
    end
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
            comparelink = "https://github.com/$(againstbuild.repo)/compare/$(againstbuild.sha)...$(build.sha)"
        else
            comparelink = "https://github.com/$(againstbuild.repo)/compare/$(againstbuild.sha)...$(build.repo):$(build.sha)"
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
                """)

    if !isempty(job.pkgsel)
        println(io, """
                    *Package Selection:* $(markdown_escaped_code(repr(job.pkgsel)))
                    """)
    end

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
                    Testing took $(readable_duration(results["duration"])) (or, sequentially, $(readable_duration(total_duration)) to evaluate $total_tests packages).
                    """)
    end

    # we don't care about the distinction between failed and killed tests,
    # so lump them together
    for key in ("primary", "against", "previous")
        if haskey(results, key)
            df = results[key]
            df[df[!, :status] .== :kill, :status] .= :fail
        end
    end

    l = count(==(:load),    results["primary"].status)
    t = count(==(:test),    results["primary"].status)
    s = count(==(:skip),    results["primary"].status)
    c = count(==(:crash),   results["primary"].status)
    f = count(==(:fail),    results["primary"].status)
    x = nrow(results["primary"])

    println(io, """
                In total, $x packages were evaluated, out of which $t successfully tested, $l were not tested but did load successfully, $c crashed, $f failed and $s were skipped.
                """)

    println(io)

    # print result list #
    #-------------------#

    package_results = make_package_results(results, hasagainstbuild)

    if hasagainstbuild

        # if this isn't a daily job, print the invocation to retest failures.
        # we do this first so that the proposed invocation includes all failure modes.
        new_failures = filter(test->test.status in [:fail, :crash] &&
                                    test.status_1 in [:test, :load], package_results)
        if !job.isdaily && !isempty(new_failures)
            cmd = "$(repr(new_failures.package))"
            if haskey(submission(job).kwargs, :vs)
                cmd *= ", vs = $(submission(job).kwargs[:vs])"
            end
            if haskey(submission(job).kwargs, :configuration)
                cmd *= ", configuration = $(submission(job).kwargs[:configuration])"
            end
            if haskey(submission(job).kwargs, :vs_configuration)
                cmd *= ", vs_configuration = $(submission(job).kwargs[:vs_configuration])"
            end

            println(io,  """
                <details><summary>On this build, $(nrow(new_failures)) packages started failing. Click here for the Nanosoldier invocation to re-run these tests.</summary>
                <p>

                ```
                @nanosoldier `runtests($cmd)`
                ```

                </p>
                </details>
                """)

            println(io)
        end
        results["has_issues"] = !isempty(new_failures)
    else
        results["has_issues"] = !isempty(filter(test->test.status in [:fail, :crash],
                                                package_results))
    end

    # main results body
    printpackageresults(io, job, package_results)

        # print build version info #
    #--------------------------#

    print(io, """
              ## Version Info

              #### Primary Build

              ```
              $(results["primary.vinfo"])
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
                $(results["against.vinfo"])
                  ```
                  """)

        if haskey(submission(job).kwargs, :vs_configuration)
            println(io, "*Configuration*: `", submission(job).kwargs[:vs_configuration], "`")
        end
    end

    println(io, "<!-- Generated on $(now()) -->")

    return nothing
end

function printpackageresults(io::IO, job::PkgEvalJob, package_results; headlines_only::Bool=false)
    # report test results in groups based on the test status
    history_heading, history = get_history(submission(job).config)
    dependents = package_dependents()
    for (status, (title, verb, emoji)) in
            (:crash  => ("crashed",                 "crashed",              "❗"),
             :fail   => ("failed",                  "failed",               "✖"),
             :test   => ("passed tests",            "passed tests",         "✔"),
             :load   => ("at least loaded",         "successfully loaded",  "~"),
             :skip   => ("were skipped altogether", "were skipped",         "➖"))
        # NOTE: no `groupby(package_results, :status)` because we can't impose ordering
        group = package_results[package_results[!, :status] .== status, :]
        sort!(group, :package; by=pkg->get(dependents, pkg, 0), rev=true)

        if !isempty(group)
            println(io, "## $emoji Packages that $title\n")

            # report on a single test
            function reportrow(test)
                primary_log = if cfg.bucket !== nothing
                    "https://s3.amazonaws.com/$(cfg.bucket)/pkgeval/$(jobdirname(job))/$(test.package).primary.log"
                else
                    "logs/$(test.package)/primary.log"
                end
                primary_status = String(test.status)

                # "against" entries are suffixed with `_1` because of the join
                if test.source == "both"
                    # PkgEval always compares the same package versions, so only report it once
                    print(io, "| $(test.package) | ")
                    if test.version !== missing
                        print(io, "v$(test.version) | ")
                    elseif test.version_1 !== missing
                        print(io, "v$(test.version_1) | ")
                    else
                        print(io, "missing | ")
                    end

                    print(io, "[$primary_status]($primary_log) | ")

                    against_log = if cfg.bucket !== nothing
                        "https://s3.amazonaws.com/$(cfg.bucket)/pkgeval/$(jobdirname(job))/$(test.package).against.log"
                    else
                        "logs/$(test.package)/against.log"
                    end
                    against_status = String(test.status_1)
                    print(io, "[$against_status]($against_log) | ")
                    print(io, "<span class=\"history\">$(get(history, test.package, "missing"))</span> |")
                else
                    print(io, "| [$(test.package)")
                    if test.version !== missing
                        print(io, " v$(test.version)")
                    end
                    print(io, "]($primary_log) | ")
                    print(io, "<span class=\"history\">$(get(history, test.package, "missing"))</span> |")
                end

                println(io)
            end

            function reportsubgroup(subgroup)
                five_col = any(row->row.source == "both", eachrow(subgroup))
                println(io, five_col ? "| Package | Version | Primary | Against | $history_heading |" : "| Package | $history_heading |")
                println(io, five_col ? "| ------- | ------- | ------- | ------- | ------- |" : "| ------- | ------- |")
                foreach(reportrow, eachrow(subgroup))
                println(io)
            end

            # report on a group of tests, prefixed with the reason
            function reportgroup(group; headlines_only::Bool=false)
                subgroups = groupby(group, :reason; skipmissing=true)
                for key in sort(keys(subgroups); by=key->PkgEval.reason_severity(key.reason))
                    subgroup = subgroups[key]
                    headline = "$(uppercasefirst(PkgEval.reason_message(first(subgroup).reason))) ($(nrow(subgroup)) packages):"
                    if headlines_only
                        println(io, headline)
                    else
                        println(io, """
                            <details open><summary>$headline</summary>
                            <p>
                            """)
                        println(io)
                        reportsubgroup(subgroup)
                        println(io, """
                            </p>
                            </details>
                            """)
                    end
                end

                if !headlines_only
                    # print tests without a reason separately, at the end
                    subgroup = group[group[!, :reason] .=== missing, :]
                    if !isempty(subgroup)
                        if length(subgroups) > 0
                            println(io, "Other:")
                            println(io)
                        end
                        reportsubgroup(subgroup)
                    end
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
                    reportgroup(changed_tests; headlines_only)
                end

                # now report the other ones
                unchanged_tests = filter(test->test.source == "left_only" ||
                                               test.status == test.status_1, group)
                if !isempty(unchanged_tests)
                    headline = "$(nrow(unchanged_tests)) packages $verb on the previous version too."
                    if headlines_only
                        println(io, headline)
                    else
                        println(io, """
                            <details><summary><strong>$headline</strong></summary>
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
                end
            else
                # just report on all tests
                println(io, "$(nrow(group)) packages $verb.")
                println(io)
                reportgroup(group; headlines_only)
            end

            println(io)
        end
    end
end

# JSON Database Generation #
#--------------------------#

function printdb(io::IO, job::PkgEvalJob, results)
    build = submission(job).build

    # parse Julia version info
    m = match(r"Julia Version (.+)", results["primary.vinfo"])
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
