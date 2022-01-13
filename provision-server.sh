#!/bin/bash

set -euv -o pipefail
HERE=`realpath $(dirname $0)`
cd "$HERE/.."

VERSION=1.6.3

MAJOR=`echo $VERSION | cut -d . -f 1`
MINOR=`echo $VERSION | cut -d . -f 2`
PATCH=`echo $VERSION | cut -d . -f 3`

# create a (non-privileged) user to run the server:
sudo useradd nanosoldier || true
sudo usermod -aG nanosoldier `whoami`

sudo -u nanosoldier [ -f ~nanosoldier/.ssh/id_rsa.pub ] || sudo -u nanosoldier ssh-keygen -N '' -f ~nanosoldier/.ssh/id_rsa
sudo -u nanosoldier git config --global user.name "nanosoldier"
sudo -u nanosoldier git config --global user.email "nanosoldierjulia@gmail.com"

[ -d julia-$VERSION ] || curl -fL https://julialang-s3.julialang.org/bin/linux/x64/$MAJOR.$MINOR/julia-$VERSION-linux-x86_64.tar.gz | tar xz
[ -d PkgEval.jl ] || git clone https://github.com/JuliaCI/PkgEval.jl
sudo -u nanosoldier julia-$VERSION/bin/julia --project=$HERE -e 'using Pkg; Pkg.instantiate()'

set +v

echo
echo "-------------"
echo "manual steps (for master machine, not workers):"
echo "-------------"
echo
echo "install this ssh key in github for user @nanosoldier at"
echo "  https://github.com/settings/ssh/new"
echo "  and on all worker machines at ~nanosoldier/.ssh/authorized_keys"
sudo -u nanosoldier cat ~nanosoldier/.ssh/id_rsa.pub
echo
echo "and generate an auth-token for later at"
echo "  https://github.com/settings/tokens/new"
echo "  scopes: 'repo' (all), 'notifications'"
echo
echo "install this webhook in github at"
echo "  https://github.com/JuliaLang/julia/settings/hooks"
echo "  url: http://<this-ip>:<random-port>"
echo "  content-type: application/json"
echo "  secret: <random-string>"
echo "  events: 'Commit comments', 'Issue comments', 'Pull request review comments'"
echo
echo "firewall configuration:"
echo "  ensure TCP <random-port> is not blocked"
echo "  ensure ssh (TCP 22) is not blocked for your ip address"
echo "  ensure all other ports are blocked"
echo
echo "these special values, you will insert into env."
echo "to use, as user 'nanosoldier':"
echo "  cd `dirname $0`"
echo "  export GITHUB_AUTH=<auth-token>"
echo "  export GITHUB_SECRET=<random-string>"
echo "  export GITHUB_PORT=<random-port>"
echo "  export JULIA_PROJECT=`dirname $0`"
echo "  . ../cset/bin/activate"
echo "  setarch -R ../julia-$VERSION/bin/julia -L bin/setup_test_ci.jl -e 'using Sockets; run(server, IPv4(0), ENV[\"GITHUB_PORT\"])'"
echo
echo "or with a helper script:"
echo "  cp bin/run_base_ci.jl .."
echo "  chmod 660 ../run_base_ci.jl"
echo "  \${EDITOR:-vim} ../run_base_ci.jl"
echo "  sudo -u nanosoldier nohup ./run_base_ci"
