############
# BuildRef #
############

mutable struct BuildRef
    repo::String    # the build repo
    sha::String     # the build + status SHA
    time::DateTime  # a timestamp for the build
    vinfo::String   # versioninfo() taken during the build
end

BuildRef(repo, sha, time) = BuildRef(repo, sha, time, "retrieving versioninfo() failed")

Base.copy(x::BuildRef) = BuildRef(x.repo, x.sha, x.time, x.vinfo)

function Base.:(==)(a::BuildRef, b::BuildRef)
    return (a.repo == b.repo &&
            a.sha == b.sha &&
            a.time == b.time &&
            a.vinfo == b.vinfo)
end

Base.summary(build::BuildRef) = string(build.repo, SHA_SEPARATOR, snipsha(build.sha))

# reduce download bandwidth and time by keeping copies after the build
# TODO: intercept JLDOWNLOAD instead?
function sync_srcs!(fromdir, todir, link::Bool)
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
# TODO: re-use PkgEval's BinaryBuilder-based build?
function build_julia!(config::Config, build::BuildRef, logpath, prnumber::Union{Int,Nothing}=nothing)
    # make a temporary workdir for our build
    gid = parse(Int, readchomp(`id -g $(config.user)`))
    tmpdir = mktempdir(workdir)
    chown(tmpdir, -1, gid)
    chmod(tmpdir, 0o775)
    srcdir = joinpath(tmpdir, "julia")
    run(sudo(config.user, `mkdir -m 775 $srcdir`))
    chmod(tmpdir, 0o555)

    mirrordir = joinpath(workdir, "mirrors", split(config.trackrepo, "/")...)
    mkpath(dirname(mirrordir), mode=0o755)
    mkpidlock(mirrordir * ".lock") do
        if ispath(mirrordir, "config")
            run(`$(git()) -C $mirrordir fetch --quiet --all`)
        else
            mkpath(mirrordir)
            gitclone!(config.trackrepo, mirrordir, `--mirror`)
        end
    end

    # clone/fetch the appropriate Julia version
    if prnumber !== nothing
        # clone from `trackrepo`, not `build.repo`, since that's where the merge commit is
        gitclone!(config.trackrepo, srcdir, `-c core.sharedRepository=group --reference $mirrordir --dissociate`; user=config.user)
        try
            run(sudo(config.user, `$(git()) -C $srcdir fetch --quiet origin +refs/pull/$(prnumber)/merge:`))
        catch
            # if there's not a merge commit on the remote (likely due to
            # merge conflicts) then fetch the head commit instead.
            run(sudo(config.user, `$(git()) -C $srcdir fetch --quiet origin +refs/pull/$(prnumber)/head:`))
        end
        run(sudo(config.user, `$(git()) -C $srcdir checkout --quiet --force FETCH_HEAD`))
        build.sha = readchomp(sudo(config.user, `$(git()) -C $srcdir rev-parse HEAD`))
        # XXX: update build.time here?
    else
        gitclone!(build.repo, srcdir, `-c core.sharedRepository=group --reference $mirrordir --dissociate`; user=config.user)
        run(sudo(config.user, `$(git()) -C $srcdir checkout --quiet $(build.sha)`))
    end

    # set up logs for STDOUT and STDERR
    logname = string(build.sha, "_build")
    outfile = joinpath(logpath, string(logname, ".out"))
    errfile = joinpath(logpath, string(logname, ".err"))

    mirrordir1 = joinpath(workdir, "srccache", "deps")
    mirrordir2 = joinpath(workdir, "srccache", "stdlib")
    mkpath(mirrordir1, mode=0o755)
    mkpath(mirrordir2, mode=0o755)
    srccache1 = joinpath(srcdir, "deps", "srccache")
    srccache2 = joinpath(srcdir, "stdlib", "srccache")
    run(sudo(config.user, `mkdir -m 775 $srccache2 $srccache1`))

    # TODO: support user build flags (like PkgEval)
    buildflags = ["JULIA_PRECOMPILE=0"]

    # run the build
    cpus = mycpus(config)
    sync_srcs!(mirrordir1, srccache1, true)
    sync_srcs!(mirrordir2, srccache2, true)
    run(pipeline(sudo(config.user, `make -C $srcdir -j$(length(cpus)) --output-sync=target $buildflags`), stdout=outfile, stderr=errfile))
    sync_srcs!(srccache1, mirrordir1, false)
    sync_srcs!(srccache2, mirrordir2, false)
    run(sudo(config.user, `rm -rf $srccache2 $srccache1`)) # erase the cloned files (which might have difficult permissions))
    run(sudo(config.user, `chmod -R a-w $srcdir`)) # make it r-x to all)
    # TODO: symlink("bin/julia", joinpath(tmpdir, "julia"))
    return tmpdir
end
