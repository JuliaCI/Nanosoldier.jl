############
# BuildRef #
############

struct BuildRef
    repo::String    # the build repo
    sha::String     # the build + status SHA
    time::DateTime  # a timestamp for the build
end

Base.copy(x::BuildRef) = BuildRef(x.repo, x.sha, x.time)

function Base.:(==)(a::BuildRef, b::BuildRef)
    return (a.repo == b.repo &&
            a.sha == b.sha &&
            a.time == b.time)
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

# Root directory for the per-build Julia trees. On the benchmark workers this is a
# size-limited tmpfs (see res/provision-worker.sh), so that building Julia does not churn
# the ZFS ARC, which fragments kernel memory and starves the benchmarks of huge pages.
# It is detected on the host the job runs on, since workers may be started over ssh
# without the server's environment; NANOSOLDIER_BUILDDIR overrides it. Persistent state
# (mirrors/, srccache/) always stays on disk under `workdir`.
const DEFAULT_BUILDROOT = "/nanosoldier-build"

function buildroot(default=DEFAULT_BUILDROOT)
    root = get(ENV, "NANOSOLDIER_BUILDDIR", "")
    isempty(root) || return root
    return ismount(default) ? default : workdir
end

# Delete a build tree created by `build_julia!`. Its `julia` subdirectory is owned by
# `config.user` and was made read-only, so restore write permissions as that user first.
function rm_build!(config::Config, dir)
    ispath(dir) || return
    srcdir = joinpath(dir, "julia")
    ispath(srcdir) && run(sudo(config.user, `chmod -R ug+rwX $srcdir`)) # make it rwx
    Base.Filesystem.prepare_for_deletion(dir)
    rm(dir, recursive=true)
    return
end

# TODO: re-use PkgEval's BinaryBuilder-based build?
function build_julia!(config::Config, build::BuildRef, logpath)
    # make a temporary workdir for our build
    gid = parse(Int, readchomp(`id -g $(config.user)`))
    tmpdir = mktempdir(buildroot())
    try
        build_julia!(config, build, logpath, tmpdir, gid)
    catch
        # don't leave a partial build behind: on tmpfs it would hold on to RAM
        try
            rm_build!(config, tmpdir)
        catch err
            @error "failed to remove build directory $tmpdir" exception=(err, catch_backtrace())
        end
        rethrow()
    end
    return tmpdir
end

function build_julia!(config::Config, build::BuildRef, logpath, tmpdir, gid)
    chown(tmpdir, -1, gid)
    chmod(tmpdir, 0o775)
    srcdir = joinpath(tmpdir, "julia")
    run(sudo(config.user, `mkdir -m 775 $srcdir`))
    chmod(tmpdir, 0o555)

    mirrordir = joinpath(workdir, "mirrors", "julia")
    mkpath(dirname(mirrordir), mode=0o755)
    mkpidlock(mirrordir * ".lock") do
        if ispath(mirrordir, "config")
            run(`$(git()) -C $mirrordir fetch --quiet --all`)
        else
            mkpath(mirrordir)
            gitclone!("JuliaLang/julia", mirrordir, `--mirror`)
        end
    end

    # clone/fetch the appropriate Julia version
    gitclone!(build.repo, srcdir, `-c core.sharedRepository=group --reference $mirrordir --dissociate`; user=config.user)
    run(sudo(config.user, `$(git()) -C $srcdir checkout --quiet $(build.sha)`))

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
    return
end
