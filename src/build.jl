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

# reduce download bandwidth and time by keeping copies after the build
# TODO: intercept JLDOWNLOAD instead?
function sync_srcs!(fromdir, todir, link::Bool)
    mkpath(fromdir)
    mkpath(todir)
    for n in readdir(fromdir)
        endswith(n, ".tmp") && continue
        src = abspath(fromdir, n)
        dst = abspath(todir, n)
        if isfile(src) && !islink(src) && !ispath(dst)
            if link
                symlink(src, dst)
            else
                dsttmp = dst * ".tmp"
                cp(src, dsttmp, force=true)
                chmod(dsttmp, 0o444)
                Base.Filesystem.rename(dsttmp, dst, force=true) # mv is implemented badly in Base, so avoid it
            end
        end
    end
end

# if a PR number is included, attempt to build from the PR's merge commit
# FIXME: re-use PkgEval's BinaryBuilder-based build
function build_julia!(config::Config, build::BuildRef, logpath, prnumber::Union{Int,Nothing}=nothing)
    # make a temporary workdir for our build
    builddir = mktempdir(workdir(config))
    mirrordir = joinpath(workdir(config), "mirrors", config.trackrepo)
    mkpidlock(mirrordir * ".lock") do
        if ispath(joinpath(mirrordir))
            run(setenv(`git fetch --quiet --all`; dir=mirrordir))
        else
            mkpath(mirrordir)
            gitclone!(config.trackrepo, mirrordir, `--mirror`)
        end
    end

    # clone/fetch the appropriate Julia version
    if prnumber !== nothing
        # clone from `trackrepo`, not `build.repo`, since that's where the merge commit is
        gitclone!(config.trackrepo, builddir, `--reference $mirrordir --dissociate`)
        try
            run(setenv(`git fetch --quiet origin +refs/pull/$(prnumber)/merge:`; dir=builddir))
        catch
            # if there's not a merge commit on the remote (likely due to
            # merge conflicts) then fetch the head commit instead.
            run(setenv(`git fetch --quiet origin +refs/pull/$(prnumber)/head:`; dir=builddir))
        end
        run(setenv(`git checkout --quiet --force FETCH_HEAD`; dir=builddir))
        build.sha = readchomp(`git rev-parse HEAD`)
    else
        gitclone!(build.repo, builddir, `--reference $mirrordir --dissociate`)
        run(setenv(`git checkout --quiet $(build.sha)`; dir=builddir))
    end

    # set up logs for STDOUT and STDERR
    logname = string(build.sha, "_build")
    outfile = joinpath(logpath, string(logname, ".out"))
    errfile = joinpath(logpath, string(logname, ".err"))

    mirrordir1 = joinpath(workdir(config), "srccache", "deps")
    srccache1 = joinpath(builddir, "deps", "srccache")
    mirrordir2 = joinpath(workdir(config), "srccache", "stdlib")
    srccache2 = joinpath(builddir, "stdlib", "srccache")

    # TODO: support user build flags (like PkgEval)
    buildflags = ["JULIA_PRECOMPILE=0"]

    # run the build
    cpus = mycpus(config)
    sync_srcs!(mirrordir1, srccache1, true)
    sync_srcs!(mirrordir2, srccache2, true)
    run(pipeline(setenv(`make -j$(length(cpus)) --output-sync=target $buildflags`; dir=builddir), stdout=outfile, stderr=errfile))
    sync_srcs!(srccache1, mirrordir1, false)
    sync_srcs!(srccache2, mirrordir2, false)
    return builddir
end
