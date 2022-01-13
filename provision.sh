#!/bin/bash

set -euv -o pipefail
HERE=`realpath $(dirname $0)`
cd "$HERE/.."

VERSION=1.6.3

# See https://github.com/JuliaCI/BenchmarkTools.jl/blob/master/doc/linuxtips.md#introduction
# for an explanation of these configuration options

sudo apt update
sudo apt install build-essential libatomic1 python3 gfortran perl wget m4 cmake pkg-config curl ninja-build ccache
sudo apt install virtualenv
virtualenv cset
set +v
. cset/bin/activate
set -v
pip install cpuset-py3
deactivate
echo "ALL ALL= NOPASSWD: `pwd`/cset/bin/cset" | sudo tee /etc/sudoers.d/99-nanosoldier

MAJOR=`echo $VERSION | cut -d . -f 1`
MINOR=`echo $VERSION | cut -d . -f 2`
PATCH=`echo $VERSION | cut -d . -f 3`

[ -d julia-$VERSION ] || curl -fL https://julialang-s3.julialang.org/bin/linux/x64/$MAJOR.$MINOR/julia-$VERSION-linux-x86_64.tar.gz | tar xz
[ -d PkgEval.jl ] || git clone https://github.com/JuliaCI/PkgEval.jl
julia-$VERSION/bin/julia --project=$HERE -e 'using Pkg; Pkg.instantiate()'

#sudo ln -f "$HERE/sysctl.conf" /etc/sysctl.d/99-nanosoldier.conf
sudo cp "$HERE/sysctl.conf" /etc/sysctl.d/99-nanosoldier.conf
sudo service procps force-reload
echo "1" | sudo tee /sys/devices/system/cpu/cpu*/online > /dev/null
echo "performance" | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
#echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost

(cd /sys/devices/system/cpu &&
for cpu in {0..255}; do
    if [ -f cpu$cpu/topology/thread_siblings_list ]; then
        for other in `sed -e 's/,/ /' < cpu$cpu/topology/thread_siblings_list`; do
            [ $other == $cpu ] && continue
            echo "disabling cpu $other (shared with $cpu)"
            echo 0 | sudo tee /sys/devices/system/cpu/cpu$other/online > /dev/null
        done
    fi
done)

echo "informational status:"
cat /proc/interrupts
# echo 0-2 | sudo tee /proc/irq/22/smp_affinity_list
# irqbalance

# create a (non-privileged) user to run the server:
sudo useradd nanosoldier || true

sudo -u nanosoldier [ -f ~nanosoldier/.ssh/id_rsa.pub ] || sudo -u nanosoldier ssh-keygen
sudo -u nanosoldier git config --global user.name "nanosoldier"
sudo -u nanosoldier git config --global user.email "nanosoldierjulia@gmail.com"

# create a (non-privileged) user to run the build and test:
sudo useradd nanosoldier-worker || true

set +v

echo
echo "-------------"
echo "manual steps (for master machine, not workers):"
echo "-------------"
echo
echo "install this ssh key in github for user @nanosoldier at"
echo "  https://github.com/settings/ssh/new"
echo "  and on any worker machines at ~/.ssh/authorized_keys"
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
echo "  chmod 600 ../run_base_ci.jl"
echo "  \${EDITOR:-vim} ../run_base_ci.jl"
echo "  ./run_base_ci"
