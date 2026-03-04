#!/usr/bin/env bash
# run_all_benchmarks.sh
# Runs all benchmarks for each THP x DEFRAG x WM x VFS x SWAP combination.
# Reboots after every single benchmark and correctly resumes after reboot.
# Checkpoint format: single integer -> index of last COMPLETED task.

set -u

# -----------------------------------------------------------------------------
# ENV SETUP
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# LOGGING / CHECKPOINT
# -----------------------------------------------------------------------------
LOGDIR="/local/logs/16gb_liblinear_logs_l1000"
mkdir -p "$LOGDIR"
CHECKPOINT="$LOGDIR/checkpoint.idx"

log() { echo "[$(date '+%F %T')] $*"; }

write_checkpoint() {
    echo "$1" > "$CHECKPOINT"
    sync
}

read_checkpoint() {
    [ -f "$CHECKPOINT" ] && cat "$CHECKPOINT" || echo "-1"
}

# -----------------------------------------------------------------------------
# BENCHMARK DEFINITIONS (EDIT ONLY THIS SECTION TO CHANGE BENCHMARKS)
# -----------------------------------------------------------------------------
BENCH_NAMES=(
  "liblinear"
)

BENCH_CMDS=(
    "/local/liblinear/train -s 6 /local/liblinear/HIGGS"
    )

# -----------------------------------------------------------------------------
# PARAMETER SWEEPS
# -----------------------------------------------------------------------------
THP_MODES=("never" "always")

DEFRAG_FOR_ALWAYS=("always" "never" "defer+madvise")
DEFRAG_FOR_NEVER=("never")

WM_VALUES=(10)
VFS_VALUES=(100)
SWAP_VALUES=(60)
ZONE_VALUES=(1 3 7)

# -----------------------------------------------------------------------------
# SYSTEM TUNING HELPERS
# -----------------------------------------------------------------------------
set_thp_enabled() {
    sudo sh -c "echo $1 > /sys/kernel/mm/transparent_hugepage/enabled"
}

set_thp_defrag() {
    sudo sh -c "echo $1 > /sys/kernel/mm/transparent_hugepage/defrag"
}

set_wm() {
    sudo sysctl -w vm.watermark_scale_factor="$1"
}

set_vfs() {
    sudo sysctl -w vm.vfs_cache_pressure="$1"
}

set_swap() {
    sudo sysctl -w vm.swappiness="$1"
}

set_zone_reclaim() {
    sudo sysctl -w vm.zone_reclaim_mode="$1"
}

run_repo_config() {
    local thp_mode=$1

    if [ "$thp_mode" = "never" ]; then
        sudo sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled' || true
        sudo sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag' || true
    fi

    sudo insmod /local/Linux-6-16-Tiers/tierinit.ko 2>/dev/null || true

    sudo sh -c "echo 2 > /proc/sys/kernel/numa_balancing" 

    sudo sh -c "echo 1000 > /sys/kernel/debug/sched/numa_balancing/hot_threshold_ms"

    sudo swapoff -a || true
    sudo sync
}

# -----------------------------------------------------------------------------
# BUILD TASK LIST
# -----------------------------------------------------------------------------
TASKS=()
idx=0

for thp in "${THP_MODES[@]}"; do
    if [ "$thp" = "never" ]; then
        defrag_list=("${DEFRAG_FOR_NEVER[@]}")
    else
        defrag_list=("${DEFRAG_FOR_ALWAYS[@]}")
    fi

    for defrag in "${defrag_list[@]}"; do
        for wm in "${WM_VALUES[@]}"; do
            for vfs in "${VFS_VALUES[@]}"; do
                for swap in "${SWAP_VALUES[@]}"; do
                    for zone in "${ZONE_VALUES[@]}"; do
                        for i in "${!BENCH_NAMES[@]}"; do
                            TASKS+=("${thp}|${defrag}|${wm}|${vfs}|${swap}|${zone}|${BENCH_NAMES[$i]}|${BENCH_CMDS[$i]}")
                            idx=$((idx+1))
                        done
                    done
                done
            done
        done
    done
done

TOTAL=${#TASKS[@]}
printf "%s\n" "${TASKS[@]}" > "$LOGDIR/all_tasks.txt"
log "Total tasks: $TOTAL"

# -----------------------------------------------------------------------------
# RESUME FROM CHECKPOINT
# -----------------------------------------------------------------------------
last_completed=$(read_checkpoint)
start_index=$((last_completed + 1))

if [ "$start_index" -ge "$TOTAL" ]; then
    log "All tasks completed."
    rm -f "$CHECKPOINT"
    exit 0
fi

log "Resuming from task index $start_index"

# -----------------------------------------------------------------------------
# MAIN LOOP (ONE TASK PER BOOT)
# -----------------------------------------------------------------------------
for (( id=start_index; id<TOTAL; id++ )); do
    IFS='|' read -r thp defrag wm vfs swap zone bench cmd <<< "${TASKS[$id]}"

    logfile="$LOGDIR/${bench}_THP-${thp}_DEFRAG-${defrag}_WM-${wm}_VFS-${vfs}_SWAP-${swap}_zone-${zone}.log"

    log "TASK $id: $bench | THP=$thp DEFRAG=$defrag WM=$wm VFS=$vfs SWAP=$swap zone=$zone"
    echo "Command: $cmd" | sudo tee -a "$logfile"

    set_thp_enabled "$thp"    2>&1 | sudo tee -a "$logfile"
    set_thp_defrag  "$defrag" 2>&1 | sudo tee -a "$logfile"
    run_repo_config "$thp"    2>&1 | sudo tee -a "$logfile"

    set_wm   "$wm"   2>&1 | sudo tee -a "$logfile"
    set_vfs  "$vfs"  2>&1 | sudo tee -a "$logfile"
    set_swap "$swap" 2>&1 | sudo tee -a "$logfile"

    set_zone_reclaim "$zone" 2>&1 | sudo tee -a "$logfile" 

    # Pre-run metrics
    cat /proc/vmstat | grep numa_pages_migrated     2>&1 | sudo tee -a "$logfile"
    cat /proc/vmstat | grep pgpromote_success       2>&1 | sudo tee -a "$logfile"
    cat /proc/vmstat | grep nr_active_file          2>&1 | sudo tee -a "$logfile"

    #Command execution with perf and time
    sudo /usr/bin/time --verbose \
    /local/Linux-6-16-Tiers/linux-6.16.1/tools/perf/perf stat -a --per-socket \
    -e dTLB-load-misses,dTLB-loads,dTLB-store-misses,dTLB-stores,cache-misses,cache-references,bus-cycles \
    -- taskset -c 0,1,2,3,4,5,6,7 bash -c "$cmd" 2>&1 | sudo tee -a "$logfile"


    exit_status=${PIPESTATUS[0]}
    echo "Exit status: $exit_status" | sudo tee -a "$logfile"

    # Post-run metrics
    cat /proc/vmstat | grep numa_pages_migrated     2>&1 | sudo tee -a "$logfile"
    cat /proc/vmstat | grep pgpromote_success       2>&1 | sudo tee -a "$logfile"
    cat /proc/vmstat | grep nr_active_file          2>&1 | sudo tee -a "$logfile"

    sudo cat /sys/kernel/mm/transparent_hugepage/defrag           2>&1 | sudo tee -a "$logfile"
    sudo cat /sys/kernel/mm/transparent_hugepage/enabled          2>&1 | sudo tee -a "$logfile"
    echo "vm.watermark_scale_factor:"  | sudo tee -a "$logfile"
    sudo cat /proc/sys/vm/watermark_scale_factor | sudo tee -a "$logfile"

    echo "vm.zone_reclaim_mode:"       | sudo tee -a "$logfile"
    sudo cat /proc/sys/vm/zone_reclaim_mode | sudo tee -a "$logfile"

    echo "vm.swappiness:"               | sudo tee -a "$logfile"
    sudo cat /proc/sys/vm/swappiness | sudo tee -a "$logfile"
    
    echo "vm.vfs_cache_pressure:"       | sudo tee -a "$logfile"
    sudo cat /proc/sys/vm/vfs_cache_pressure                      2>&1 | sudo tee -a "$logfile"

    ls /sys/devices/virtual/memory_tiering/                      2>&1 | sudo tee -a "$logfile"

    if [ "$exit_status" -ne 0 ]; then
        log "Task failed, retrying after reboot"
        [ -f "$CHECKPOINT" ] || echo "-1" > "$CHECKPOINT"
        sudo reboot
        exit 0
    fi

    write_checkpoint "$id"
    log "Task completed, rebooting"
    sleep 5
    sudo reboot
    exit 0
done

log "All tasks finished."
rm -f "$CHECKPOINT"
exit 0
