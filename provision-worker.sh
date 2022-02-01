#!/bin/bash

set -euv -o pipefail
HERE=`realpath $(dirname $0)`
cd "$HERE/.."
"$HERE/provision-server.sh"
set +v

# See https://juliaci.github.io/BenchmarkTools.jl/stable/linuxtips/
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

# create a (non-privileged) user to run the build and test:
sudo useradd nanosoldier-worker || true
sudo usermod -aG nanosoldier-worker `whoami`
sudo usermod -aG nanosoldier-worker nanosoldier

echo "nanosoldier ALL= NOPASSWD:\\
        /nanosoldier/cset/bin/cset set *,\\
        /nanosoldier/cset/bin/cset shield *,\\
       !/nanosoldier/cset/bin/cset shield *-e*,\\
        /nanosoldier/cset/bin/cset shield -e -- sudo -n -u nanosoldier-worker -- *
nanosoldier,nanosoldier-worker ALL= NOPASSWD:\\
        /nanosoldier/cset/bin/cset proc *,\\
       !/nanosoldier/cset/bin/cset proc *-e*
nanosoldier ALL= (nanosoldier-worker) NOPASSWD: ALL
`whoami` ALL= (nanosoldier-worker) NOPASSWD: ALL
Defaults> nanosoldier-worker umask=0777" | sudo tee /etc/sudoers.d/99-nanosoldier-worker

set +v

echo
echo "-------------"
echo "manual steps (for each worker)"
echo "-------------"
echo
echo "replace ~nanosoldier/.ssh/id_rsa* with those files from the master"
