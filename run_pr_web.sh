sudo bash /local/repository/config.sh
cat /proc/vmstat | grep numa_pages_migrated
cat /proc/vmstat | grep pgpromote_success
cat /proc/vmstat | grep nr_active_file
sudo /usr/bin/time --verbose perf stat -a --per-socket -e dTLB-load-misses,dTLB-loads,dTLB-store-misses,dTLB-stores,cache-misses,cache-references,bus-cycles -- taskset -c 0,1,2,3,4,5,6,7 /local/gapbs/pr -f gapbs/benchmark/graphs/web.sg -t1e-4 -n20
cat /proc/vmstat | grep numa_pages_migrated
cat /proc/vmstat | grep pgpromote_success
cat /proc/vmstat | grep nr_active_file
sudo cat /sys/kernel/mm/transparent_hugepage/defrag
sudo cat /sys/kernel/mm/transparent_hugepage/enabled
sudo cat /proc/sys/vm/watermark_scale_factor
sudo cat /proc/sys/vm/zone_reclaim_mode
sudo cat /proc/sys/vm/swappiness