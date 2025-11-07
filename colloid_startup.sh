#!/bin/bash
# ==========================================
# TPP + Colloid Kernel + Benchmark Setup
# Tested on CloudLab (Ubuntu 22.04, Intel)
# ==========================================

LOGFILE=/local/logs/colloid-tpp-setup.log
mkdir -p /local/logs
exec > >(tee -a "$LOGFILE") 2>&1

echo "===== [1/9] Updating system ====="
sudo apt-get update -y
sudo apt-get upgrade -y

echo "===== [2/9] Installing build dependencies ====="
sudo apt-get install -y build-essential libncurses-dev bison flex libssl-dev \
    libelf-dev fakeroot dwarves git numactl hwloc linux-tools-common \
    linux-tools-$(uname -r) python3 python3-pip

echo "===== [3/9] Downloading Linux 6.3 kernel source ====="
cd /local
git clone https://github.com/host-architecture/colloid.git
cd colloid/tpp/linux-6.3

echo "===== [4/9] Preparing kernel configuration ====="
cp /boot/config-$(uname -r) .config
yes "" | make olddefconfig

# Add "-colloid" suffix to kernel name
sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-colloid"/' .config
sed -i 's/^CONFIG_SYSTEM_TRUSTED_KEYS=.*/CONFIG_SYSTEM_TRUSTED_KEYS=""/' .config
sed -i 's/^CONFIG_SYSTEM_REVOCATION_KEYS=.*/CONFIG_SYSTEM_REVOCATION_KEYS=""/' .config

echo "===== [5/9] Compiling kernel (this takes ~20–40 min) ====="
make -j$(nproc) bzImage
make -j$(nproc) modules
sudo make modules_install
sudo make install

echo "===== [6/9] Setting new kernel as default ====="
sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT="1>Ubuntu, with Linux 6.3.0-colloid"/' /etc/default/grub
sudo update-grub

echo "===== [7/9] Rebooting into Colloid kernel ====="
# Use CloudLab’s reboot-safe trigger
sudo reboot
