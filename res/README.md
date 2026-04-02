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
