# Deploying Nanosoldier

This document describes how to deploy Nanosoldier.jl.

## Repository configuration

Repositories that should be monitored by Nanosoldier.jl should install a webhook with the
following properties:

- payload URL: depends on where the server is hosted, e.g.,
  `http://pkgeval.nanosoldier.julialang.org:8888`
- content type: `application/json`
- secret: ask an administrator
- select "Let me select individual events" and check "Commit comments", "Issue comments",
  "Pull request review comments" and "Pull requests"


## BenchmarkJob

Julia is managed via [juliaup](https://github.com/JuliaLang/juliaup). The provision scripts
install it for the `nanosoldier` user and configure two settings:

- `manifestversiondetect true` — automatically selects the Julia version matching the
  `julia_version` field in `Manifest.toml`, so no hardcoded version is needed anywhere.
- `autoinstallchannels true` — automatically installs any required Julia version on first use.

To update Julia, update `Manifest.toml` (e.g. via `Pkg.update()` with the new version) and
juliaup will install and use the new version automatically on the next run.

On all computers:

```
echo "if this is a shared machine, you must use a password to secure this:"
[ -f ~/.ssh/id_ed25519.pub ] || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
echo "add to https://github.com/settings/keys:"
cat ~/.ssh/id_ed25519.pub
EDITOR=vim git config --global --edit
sudo mkdir /nanosoldier
sudo chown `whoami` /nanosoldier
cd /nanosoldier
git clone <URL>
cd ./Nanosoldier.jl
git checkout <branch>
./provision-<worker|server>.sh
```

On main server:

```
scp ~nanosoldier/.ssh/id_ed25519 ~nanosoldier/.ssh/id_ed25519.pub <workers>:
ssh -t <workers> sudo chown nanosoldier:nanosoldier id_ed25519 id_ed25519.pub
ssh -t <workers> sudo mv id_ed25519 id_ed25519.pub ~nanosoldier/.ssh
ssh -t <workers> sudo -u nanosoldier cat .ssh/id_ed25519.pub >> .ssh/authorized_keys
ssh -t <workers> sudo -u nanosoldier "bash -c 'cat ~nanosoldier/.ssh/id_ed25519.pub >> ~nanosoldier/.ssh/authorized_keys'"
sudo -u nanosoldier ssh <workers> exit
# repeat above for every worker, then:
sudo -u nanosoldier scp ~nanosoldier/.ssh/known_hosts <workers>:.ssh
```

To run:

```
cd /nanosoldier/Nanosoldier.jl
byobu
./run_base_ci
```

## Upgrading for BenchmarkJob

### Server

```
cd /nanosoldier/Nanosoldier.jl
git pull
chmod 666 *.toml
sudo -u nanosoldier sh -c '$HOME/.juliaup/bin/julia --project=. -e '\''using Pkg; Pkg.update()'\'''
chmod 664 *.toml
./provision-server.sh
git add -u
git commit
git push
```

### Workers
```
cd /nanosoldier/Nanosoldier.jl
git pull
./provision-worker.sh
```

`provision-worker.sh` also sets up the workers' memory so that transparent huge pages stay
available to the benchmarks: it caps the ZFS ARC (`ZFS_ARC_MAX`, default 4 GiB), adds
`movablecore=` to the kernel command line (`MOVABLECORE`, default RAM minus about 8 GiB),
mounts a tmpfs for the Julia build trees (`BUILDDIR=/nanosoldier-build`, size
`BUILDDIR_SIZE`) and allows the server to run `res/nanosoldier-prep-memory` through sudo
before each benchmark process, to drop caches and compact memory. The ARC cap
and `movablecore=` only take effect after a reboot. Each benchmark node builds Julia under
`/nanosoldier-build` when that is a mount point on its host, and otherwise in the
Scratch.jl `workdir` as before; set `NANOSOLDIER_BUILDDIR` in the node's environment to use
another directory (for example, if provisioned with a different `BUILDDIR`).

To check a worker after rebooting:

```
grep -A1 'zone *Movable' /proc/zoneinfo
cat /sys/module/zfs/parameters/zfs_arc_max
df -h /nanosoldier-build
```

For each benchmark run, the node log records the change in the THP and compaction counters
of `/proc/vmstat` during the run. `thp_fault_fallback` should stay close to 0.
