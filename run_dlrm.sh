sudo bash /local/repository/config.sh
cat /proc/vmstat | grep numa_pages_migrated
cat /proc/vmstat | grep pgpromote_success
cat /proc/vmstat | grep nr_active_file
sudo /usr/bin/time --verbose /users/thmsvlk/bin/perf stat -a --per-socket -e dTLB-load-misses,dTLB-loads,dTLB-store-misses,dTLB-stores,cache-misses,cache-references,bus-cycles -- taskset -c 0,1,2,3,4,5,6,7 python /local/dlrm/dlrm_s_pytorch.py --mini-batch-size=512 --test-mini-batch-size=1024 --test-num-workers=0 --num-batches=200 --data-generation=random --arch-mlp-bot=1024-1024-256 --arch-mlp-top=512-512-1 --arch-sparse-feature-size=256 --arch-embedding-size=1000000-1000000-1000000-1000000-1000000-1000000-1000000 --num-indices-per-lookup=100 --arch-interaction-op=dot --numpy-rand-seed=727
cat /proc/vmstat | grep numa_pages_migrated
cat /proc/vmstat | grep pgpromote_success
cat /proc/vmstat | grep nr_active_file
sudo cat /sys/kernel/mm/transparent_hugepage/defrag
sudo cat /sys/kernel/mm/transparent_hugepage/enabled
sudo cat /proc/sys/vm/watermark_scale_factor
sudo cat /proc/sys/vm/zone_reclaim_mode
sudo cat /proc/sys/vm/swappiness
ls /sys/devices/virtual/memory_tiering/

