#!/bin/bash
# ==========================================
# TPP + Colloid Kernel + Benchmark Setup
# Safe version for CloudLab (Ubuntu 22.04)
# ==========================================

set -x

LOGFILE=/local/logs/colloid-tpp-setup.log
MARKER_FILE=/local/logs/setup_done
MARKER_FILE2=/local/logs/setup_complete
mkdir -p /local/logs
exec > >(tee -a "$LOGFILE") 2>&1

echo "===== [STARTUP] $(date) ====="

# --- Skip if setup already completed ---
if [ -f "$MARKER_FILE2" ]; then
    echo "Colloid ready to run."
    sudo chmod +x /local/repository/app.sh
    sudo /local/repository/app.sh
    exit 0
fi

if [ -f "$MARKER_FILE" ]; then
    echo "Setup already completed. Building colloid-mon kernel module."
    sudo sed -i 's/^DEFAULT_TIER_NUMA * *.*/DEFAULT_TIER_NUMA ?= 0/' /local/colloid/tpp/colloid-mon/config.mk
    sudo sed -i 's/^CORE_MON * *.*/CORE_MON ?= 0/' /local/colloid/tpp/colloid-mon/config.mk
    cd /local/colloid/tpp/colloid-mon
    make

    sudo sed -i "s/^#define LOCAL_NUMA.*/#define LOCAL_NUMA 0/" /local/colloid/tpp/tierinit/tierinit.c
    sudo sed -i "s/^#define FARMEM_NUMA.*/#define FARMEM_NUMA 1/" /local/colloid/tpp/tierinit/tierinit.c
    cd /local/colloid/tpp/tierinit
    make 

    sudo sed -i "s/^#define LOCAL_NUMA.*/#define LOCAL_NUMA 0/" /local/colloid/tpp/memeater/memeater.c
    sudo sed -i "s/^#define FARMEM_NUMA.*/#define FARMEM_NUMA 1/" /local/colloid/tpp/memeater/memeater.c
    cd /local/colloid/tpp/memeater
    make

    sudo sed -i "s/^#define LOCAL_NUMA.*/#define LOCAL_NUMA 0/" /local/colloid/tpp/kswapdrst/kswapdrst.c
    sudo sed -i "s/^#define FARMEM_NUMA.*/#define FARMEM_NUMA 1/" /local/colloid/tpp/kswapdrst/kswapdrst.c
    cd /local/colloid/tpp/kswapdrst
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
cd /local
if [ ! -d "colloid" ]; then
    git clone https://github.com/host-architecture/colloid.git
else
    cd colloid && git pull
fi
cd /local/colloid/tpp/linux-6.3

echo "===== [4/9] Preparing kernel configuration ====="
cp /boot/config-$(uname -r) .config
yes "" | make olddefconfig

# Add "-colloid" suffix to kernel name
sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-colloid"/' .config
sed -i 's/^CONFIG_SYSTEM_TRUSTED_KEYS=.*/CONFIG_SYSTEM_TRUSTED_KEYS=""/' .config
sed -i 's/^CONFIG_SYSTEM_REVOCATION_KEYS=.*/CONFIG_SYSTEM_REVOCATION_KEYS=""/' .config

echo "===== [5/9] Compiling kernel (this takes ~20–40 min) ====="
make -j"$(nproc)" bzImage
make -j"$(nproc)" modules
sudo make modules_install
sudo make install

echo "===== [6/9] Setting new kernel as default ====="
sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT="1>Ubuntu, with Linux 6.3.0-colloid"/' /etc/default/grub
sudo update-grub

echo "===== [7/9] Marking setup complete ====="
touch "$MARKER_FILE"

echo "===== [8/9] Scheduling reboot ====="
# Schedule a reboot in 15 seconds to ensure CloudLab marks this as "booted"
(sleep 15 && sudo reboot) &

echo "===== [9/9] Exiting cleanly for CloudLab ====="
exit 0
