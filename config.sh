#Setting THP tunables
sudo sh -c "echo "never" > /sys/kernel/mm/transparent_hugepage/defrag"
sudo sh -c "echo "never" > /sys/kernel/mm/transparent_hugepage/enabled"


#Here you should enable colloid, by first loading the files the user-level files you should compile. I assume the files are like this, but you probably should double check the directories:
sudo insmod /local/colloid/tpp/tierinit/tierinit.ko
sudo insmod /local/colloid/tpp/colloid-mon/colloid-mon.ko
sudo insmod /local/colloid/tpp/kswapdrst/kswapdrst.ko

sudo sh -c "echo 1 > /sys/kernel/mm/numa/demotion_enabled"
sudo sh -c "echo 6 > /proc/sys/kernel/numa_balancing"

sudo swapoff -a
sudo sync
sudo sh -c "echo 3 > /proc/sys/vm/drop_caches"

sudo sh -c "echo 100 > /proc/sys/vm/watermark_scale_factor"