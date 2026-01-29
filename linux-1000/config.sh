#Setting THP tunables
sudo sh -c "echo "always" > /sys/kernel/mm/transparent_hugepage/defrag"
sudo sh -c "echo "defer+madvise" > /sys/kernel/mm/transparent_hugepage/enabled"


#Here you should enable colloid, by first loading the files the user-level files you should compile. I assume the files are like this, but you probably should double check the directories:
sudo insmod /local/Linux-6-16-Tiers/tierinit.ko

sudo sh -c "echo 2 > /proc/sys/kernel/numa_balancing"

sudo sh -c "echo 1000 > /sys/kernel/debug/sched/numa_balancing/hot_threshold_ms"

sudo swapoff -a
sudo sync
