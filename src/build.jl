############
# BuildRef #
############

type BuildRef
    repo::UTF8String  # the build repo
    sha::UTF8String   # the build + status SHA
    vinfo::UTF8String # versioninfo() taken during the build
end

BuildRef(repo, sha) = BuildRef(repo, sha, "?")

function Base.(:(==))(a::BuildRef, b::BuildRef)
    return (a.repo == b.repo &&
            a.sha == b.sha &&
            a.vinfo == b.vinfo)
end

Base.summary(build::BuildRef) = string(build.repo, SHA_SEPARATOR, snipsha(build.sha))

# if a PR number is included, attempt to build from the PR's merge commit
function build_julia!(config::Config, build::BuildRef, prnumber::Nullable{Int} = Nullable{Int}())
    # make a temporary workdir for our build
    builddir = mktempdir(workdir(config))
    cd(workdir(config))

    # clone/fetch the appropriate Julia version
    if !(isnull(prnumber))
        pr = get(prnumber)
        # clone from `trackrepo`, not `build.repo`, since that's where the merge commit is
        gitclone!(config.trackrepo, builddir)
        cd(builddir)
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
        gitclone!(build.repo, builddir)
        cd(builddir)
        run(`git checkout --quiet $(build.sha)`)
    end

    # set up logs for STDOUT and STDERR
    logname = string(build.sha, "_build")
    outfile = joinpath(logdir(config), string(logname, ".out"))
    errfile = joinpath(logdir(config), string(logname, ".err"))

    # run the build
    run(pipeline(`make`, stdout = outfile, stderr = errfile))
    cd(workdir(config))
    return builddir
end
