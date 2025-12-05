#Setting THP tunables
sudo sh -c "echo "never" > /sys/kernel/mm/transparent_hugepage/defrag"
sudo sh -c "echo "never" > /sys/kernel/mm/transparent_hugepage/enabled"


#Here you should enable colloid, by first loading the files the user-level files you should compile. I assume the files are like this, but you probably should double check the directories:
sudo insmod colloid/tpp/tierinit/tierinit.ko
sudo insmod colloid/tpp/colloid-mon/colloid-mon.ko
sudo insmod colloid/tpp/kswapdrst/kswapdrst.ko

sudo sh -c "echo 1 > /sys/kernel/mm/numa/demotion_enabled"
sudo sh -c "echo 6 > /proc/sys/kernel/numa_balancing"

sudo swapoff -a
sudo sync
sudo sh -c "echo 3 > /proc/sys/vm/drop_caches"

cat /proc/vmstat | grep numa_pages_migrated
cat /proc/vmstat | grep pgpromote_success
cat /proc/vmstat | grep nr_active_file
sudo /usr/bin/time --verbose /users/thmsvlk/bin/perf stat -a --per-socket -e dTLB-load-misses,dTLB-loads,dTLB-store-misses,dTLB-stores,cache-misses,cache-references,bus-cycles -- taskset -c 0,1,2,3,4,5,6,7 python /local/dlrm/dlrm_s_pytorch.py --mini-batch-size=2048 --test-mini-batch-size=16384 --test-num-workers=0 --num-batches=400 --data-generation=random --arch-mlp-bot=2048-2048-512 --arch-mlp-top=1024-1024-1024-1 --arch-sparse-feature-size=512 --arch-embedding-size=1000000-1000000-1000000-1000000-1000000-1000000-1000000 --num-indices-per-lookup=200 --arch-interaction-op=dot --numpy-rand-seed=727
cat /proc/vmstat | grep numa_pages_migrated
cat /proc/vmstat | grep pgpromote_success
cat /proc/vmstat | grep nr_active_file
sudo cat /sys/kernel/mm/transparent_hugepage/defrag
sudo cat /sys/kernel/mm/transparent_hugepage/enabled
sudo cat /proc/sys/vm/watermark_scale_factor
sudo cat /proc/sys/vm/zone_reclaim_mode
sudo cat /proc/sys/vm/swappiness
