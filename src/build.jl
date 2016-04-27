############
# BuildRef #
############

type BuildRef
    repo::UTF8String  # the build repo
    sha::UTF8String   # the build + status SHA
    vinfo::UTF8String # versioninfo() taken during the build
    flags::UTF8String # arguments passed to make
end

BuildRef(repo, sha) = BuildRef(repo, sha, "?", "")

function Base.(:(==))(a::BuildRef, b::BuildRef)
    return (a.repo == b.repo &&
            a.sha == b.sha &&
            a.vinfo == b.vinfo &&
            a.flags == b.flags)
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
        run(`git clone --quiet https://github.com/$(cfg.trackrepo) $(builddir)`)
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
        run(`git clone --quiet https://github.com/$(build.repo) $(builddir)`)
        cd(builddir)
        run(`git checkout --quiet $(build.sha)`)
    end

    # string interpolation + parse/eval needed to thwart weird quoting behavior
    run(eval(parse("`make --silent $(build.flags)`")))

    cd(workdir(config))

    return builddir
end
