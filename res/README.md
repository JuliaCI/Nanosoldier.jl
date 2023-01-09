# Deploying Nanosoldier

This document describes how to deploy Nanosoldier.jl.

## Repository configuration

Repositories that should be monitored by Nanosoldier.jl should install a webhook with the
following properties:

- payload URL: depends on where the server is hosted, e.g.,
  `http://amdci8.julia.csail.mit.edu:8888`
- content type: `application/json`
- select "Let me select individual events" and check "Commit comments", "Issue comments" and
  "Pull request reviews"


## BenchmarkJob

On all computers:

```
echo "if this is a shared machine, you must use a password to secure this:"
[ -f ~/.ssh/id_rsa ] || ssh-keygen -f ~/.ssh/id_rsa
echo "add to https://github.com/settings/keys:"
cat ~/.ssh/id_rsa.pub
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
scp ~nanosoldier/.ssh/id_rsa ~nanosoldier/.ssh/id_rsa.pub <workers>:
ssh -t <workers> sudo chown nanosoldier:nanosoldier id_rsa id_rsa.pub
ssh -t <workers> sudo mv id_rsa id_rsa.pub ~nanosoldier/.ssh
ssh -t <workers> sudo -u nanosoldier cat .ssh/id_rsa.pub >> .ssh/authorized_keys
ssh -t <workers> sudo -u nanosoldier "bash -c 'cat ~nanosoldier/.ssh/id_rsa.pub >> ~nanosoldier/.ssh/authorized_keys'"
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
sudo -u nanosoldier ../julia-1.6.6/bin/julia --project=. -e 'using Pkg; Pkg.update()'
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
