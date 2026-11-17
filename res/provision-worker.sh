#!/bin/bash

set -euv -o pipefail
HERE=`realpath $(dirname $0)/..`
cd "$HERE/.."
"$HERE/res/provision-server.sh"
set +v
: ${NEWUSER:=nanosoldier}

# See https://juliaci.github.io/BenchmarkTools.jl/stable/linuxtips/
# for an explanation of these configuration options

sudo apt install build-essential libatomic1 python3 gfortran perl wget m4 cmake pkg-config curl ninja-build ccache
sudo apt install virtualenv
virtualenv cset
set +v
. cset/bin/activate
set -v
pip install cpuset-py3
deactivate

#sudo ln -f "$HERE/res/sysctl.conf" /etc/sysctl.d/99-nanosoldier.conf
sudo cp "$HERE/res/sysctl.conf" /etc/sysctl.d/99-nanosoldier.conf
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
sudo useradd -m nanosoldier-worker || true
sudo usermod -aG nanosoldier-worker `whoami`
sudo usermod -aG nanosoldier-worker $NEWUSER

echo "$NEWUSER ALL= NOPASSWD:\\
        /nanosoldier/cset/bin/cset set *,\\
        /nanosoldier/cset/bin/cset shield *,\\
       !/nanosoldier/cset/bin/cset shield *-e*,\\
        /nanosoldier/cset/bin/cset shield -e -- sudo -n -u nanosoldier-worker -- *
$NEWUSER,nanosoldier-worker ALL= NOPASSWD:\\
        /nanosoldier/cset/bin/cset proc *,\\
       !/nanosoldier/cset/bin/cset proc *-e*
$NEWUSER ALL= NOPASSWD: $HERE/res/nanosoldier-prep-memory \"\"
$NEWUSER ALL= (nanosoldier-worker) NOPASSWD: ALL
`whoami` ALL= (nanosoldier-worker) NOPASSWD: ALL
Defaults> nanosoldier-worker umask=0777" | sudo tee /etc/sudoers.d/99-nanosoldier-worker

# Keep memory unfragmented enough that transparent huge pages stay available to the
# benchmarks (julia madvise()s large arrays with MADV_HUGEPAGE). On a long-running host,
# kernel allocations, mostly the ZFS ARC, end up scattered over nearly every 2 MiB
# pageblock and compaction can no longer build huge pages, which makes some benchmarks
# several times slower depending on the host's history rather than on the commit.
# The boot options and initramfs changes below only take effect after a reboot.

# 1. Cap the ZFS ARC: it is unmovable kernel memory and must fit below the non-movable
#    memory left by `movablecore=` (and without the cap may grow to half of RAM).
: ${ZFS_ARC_MAX:=4294967296}
if [ -d /sys/module/zfs ]; then
    echo "options zfs zfs_arc_max=$ZFS_ARC_MAX" | sudo tee /etc/modprobe.d/zfs-arc.conf
    sudo update-initramfs -u # root may be on ZFS: the module then loads from the initramfs
    echo "$ZFS_ARC_MAX" | sudo tee /sys/module/zfs/parameters/zfs_arc_max # apply now
fi

# 2. Put most of RAM in ZONE_MOVABLE. The kernel never places its own allocations there,
#    so compaction can always rebuild 2 MiB blocks for page faults in huge-page regions.
#    Keep about 8 GiB non-movable for the kernel (about 0.6 GiB) plus the ZFS ARC
#    (with 32 GB of RAM, this gives movablecore=24G).
: ${MOVABLECORE:=$(( $(awk '/^MemTotal:/ { print $2 }' /proc/meminfo) / 1048576 - 7 ))G}
if grep -qE '^GRUB_CMDLINE_LINUX=.*movablecore=' /etc/default/grub; then
    sudo sed -i -E "/^GRUB_CMDLINE_LINUX=/s/movablecore=[^ \"]*/movablecore=$MOVABLECORE/" /etc/default/grub
else
    sudo sed -i -E "s/^(GRUB_CMDLINE_LINUX=\"[^\"]*)\"/\1 movablecore=$MOVABLECORE\"/" /etc/default/grub
fi
if ! grep -qE "^GRUB_CMDLINE_LINUX=.*movablecore=$MOVABLECORE" /etc/default/grub; then
    echo "error: failed to add movablecore=$MOVABLECORE to GRUB_CMDLINE_LINUX in /etc/default/grub" >&2
    exit 1
fi
sudo update-grub

# 3. Build Julia in a size-limited tmpfs instead of on ZFS, so builds don't churn the ARC.
#    The server finds it through NANOSOLDIER_BUILDDIR (set by res/run_base_ci). A PR job
#    keeps two build trees here while its benchmarks run, and there is no swap, so this
#    memory is unavailable to the benchmarks. A build tree (with .git) of julia 1.15-DEV was
#    about 2.3 GB at its peak; the cap only bounds what a runaway build can take.
: ${BUILDDIR:=/nanosoldier-build}
: ${BUILDDIR_SIZE:=8G}
sudo mkdir -p "$BUILDDIR"
FSTAB_LINE="tmpfs $BUILDDIR tmpfs size=$BUILDDIR_SIZE,mode=0755,uid=$(id -u $NEWUSER),gid=$(id -g $NEWUSER),nosuid,nodev,noatime 0 0"
sudo sed -i "\# $BUILDDIR tmpfs #d" /etc/fstab
echo "$FSTAB_LINE" | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
if mountpoint -q "$BUILDDIR"; then
    sudo mount -o remount "$BUILDDIR"
else
    sudo mount "$BUILDDIR"
fi
df -h "$BUILDDIR"

set +v

echo
echo "-------------"
echo "manual steps (for each worker)"
echo "-------------"
echo
echo "install ssh key from master server to this worker"
echo "sudo -u $NEWUSER vim ~$NEWUSER/.ssh/authorized_keys"
echo "sudo -u $NEWUSER chmod 600 ~$NEWUSER/.ssh/authorized_keys"
echo " # on server # sudo -u $NEWUSER scp /home/$NEWUSER/.ssh/id_ed25519 /home/$NEWUSER/.ssh/id_ed25519.pub `hostname`:.ssh"
