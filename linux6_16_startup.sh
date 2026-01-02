#!/bin/bash
# ==========================================
# TPP + Colloid Kernel + Benchmark Setup
# Safe version for CloudLab (Ubuntu 22.04)
# ==========================================

set -x

LOGFILE=/local/logs/linux6_16-setup.log
MARKER_FILE=/local/logs/setup_done
MARKER_FILE2=/local/logs/setup_complete
mkdir -p /local/logs
exec > >(tee -a "$LOGFILE") 2>&1

echo "===== [STARTUP] $(date) ====="

# --- Skip if setup already completed ---
if [ -f "$MARKER_FILE2" ]; then
    echo "Linux 6.16 ready to run."
    exit 0
fi

if [ -f "$MARKER_FILE" ]; then
    echo "Setup already completed. Building linux_6.16-mon kernel module."
    cd /local/Linux-6-16-Tiers
    make 

    # --- Limit node0 memory to 8GB ---
    sudo sed -i '/^GRUB_CMDLINE_LINUX=/d' /etc/default/grub
    echo 'GRUB_CMDLINE_LINUX="memmap=88G!8G"' | sudo tee -a /etc/default/grub
    sudo update-grub

    touch "$MARKER_FILE2"    

    echo "All tools built successfully!"        
    sudo reboot
    exit 0
fi

echo "===== [1/9] Updating system ====="
sudo apt-get update -y
sudo apt-get upgrade -y

echo "===== [2/9] Installing build dependencies ====="
sudo apt-get install -y build-essential libncurses-dev bison flex libssl-dev \
    libelf-dev fakeroot dwarves git numactl hwloc linux-tools-common \
    linux-tools-$(uname -r) python3 python3-pip

echo "===== [3/9] Downloading Linux 6.3 kernel source ====="
cd /local/Linux-6-16-Tiers/linux-6.16.1

echo "===== [4/9] Preparing kernel configuration ====="
scripts/config --disable CONFIG_SYSTEM_TRUSTED_KEYS
scripts/config --disable CONFIG_SYSTEM_REVOCATION_KEYS
cp /boot/config-$(uname -r) .config
yes "" | make olddefconfig

# Add "-linux_6.16" suffix to kernel name
sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-linux_6.16"/' .config
sed -i 's/^CONFIG_SYSTEM_TRUSTED_KEYS=.*/CONFIG_SYSTEM_TRUSTED_KEYS=""/' .config
sed -i 's/^CONFIG_SYSTEM_REVOCATION_KEYS=.*/CONFIG_SYSTEM_REVOCATION_KEYS=""/' .config

echo "===== [5/9] Compiling kernel (this takes ~20–40 min) ====="
make -j$(nproc)
sudo make modules_install
sudo make install

echo "===== [6/9] Setting new kernel as default ====="
sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT="1>Ubuntu, with Linux 6.16.1"/' /etc/default/grub
sudo update-grub

echo "===== [7/9] Marking setup complete ====="
touch "$MARKER_FILE"

echo "===== [8/9] Scheduling reboot ====="
# Schedule a reboot in 15 seconds to ensure CloudLab marks this as "booted"
(sleep 15 && sudo reboot) &

echo "===== [9/9] Exiting cleanly for CloudLab ====="
exit 0
