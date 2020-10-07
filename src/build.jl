############
# BuildRef #
############

mutable struct BuildRef
    repo::String  # the build repo
    sha::String   # the build + status SHA
    vinfo::String # versioninfo() taken during the build
end

BuildRef(repo, sha) = BuildRef(repo, sha, "retrieving versioninfo() failed")

function Base.:(==)(a::BuildRef, b::BuildRef)
    return (a.repo == b.repo &&
            a.sha == b.sha &&
            a.vinfo == b.vinfo)
end

Base.summary(build::BuildRef) = string(build.repo, SHA_SEPARATOR, snipsha(build.sha))

# if a PR number is included, attempt to build from the PR's merge commit
# FIXME: re-use NewPkgEval's BinaryBuilder-based build
function build_julia!(config::Config, build::BuildRef, logpath, prnumber::Union{Int,Nothing}=nothing)
    # make a temporary workdir for our build
    builddir = mktempdir(workdir(config))
    cd(workdir(config))

    # clone/fetch the appropriate Julia version
    if prnumber !== nothing
        # clone from `trackrepo`, not `build.repo`, since that's where the merge commit is
        gitclone!(config.trackrepo, builddir)
        cd(builddir)
        try
            run(`git fetch --quiet origin +refs/pull/$(prnumber)/merge:`)
        catch
            # if there's not a merge commit on the remote (likely due to
            # merge conflicts) then fetch the head commit instead.
            run(`git fetch --quiet origin +refs/pull/$(prnumber)/head:`)
        end
        run(`git checkout --quiet --force FETCH_HEAD`)
        build.sha = readchomp(`git rev-parse HEAD`)
    else
        gitclone!(build.repo, builddir)
        cd(builddir)
        run(`git checkout --quiet $(build.sha)`)
    end

    # set up logs for STDOUT and STDERR
    logname = string(build.sha, "_build")
    outfile = joinpath(logpath, string(logname, ".out"))
    errfile = joinpath(logpath, string(logname, ".err"))

    # run the build
    cpus = mycpus(config)
    run(pipeline(`make -j$(length(cpus)) USECCACHE=1 USE_BINARYBUILDER_LLVM=0`,
                 stdout=outfile, stderr=errfile))
    cd(workdir(config))
    return builddir
end
