#!/bin/bash

set -euv -o pipefail
HERE=`realpath $(dirname $0)`
cd "$HERE/.."
"$HERE/provision-server.sh"
set +v

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

set +v

echo
echo "-------------"
echo "manual steps (for each worker)"
echo "-------------"
echo
echo "replace ~nanosoldier/.ssh/id_rsa* with those files from the master"