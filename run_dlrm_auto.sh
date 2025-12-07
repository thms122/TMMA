#!/usr/bin/env bash
# run_dlrm_auto.sh
# Runs DLRM benchmark for each THP x DEFRAG x WM combination.
# Fixed permissions, proper Python execution, and better error handling.
#
# Author: generated for you
set -u
# -----------------------------------------------------------------------------
LOGDIR="$HOME/dlrm_logs"
mkdir -p "$LOGDIR"
chmod 755 "$LOGDIR"
CHECKPOINT="$LOGDIR/checkpoint.idx"
# Benchmarks (fixed order)
BENCH_NAMES=("dlrm")
BENCH_CMDS=(
"/local/dlrm/dlrm_s_pytorch.py --mini-batch-size=2048 --test-mini-batch-size=16384 --test-num-workers=0 --num-batches=400 --data-generation=random --arch-mlp-bot=2048-2048-512 --arch-mlp-top=1024-1024-1024-1 --arch-sparse-feature-size=512 --arch-embedding-size=1000000-1000000-1000000-1000000-1000000-1000000-1000000 --num-indices-per-lookup=200 --arch-interaction-op=dot --numpy-rand-seed=727"
)
# Parameter values
THP_MODES=("never" "always")
# For THP=always we will test this defrag order:
DEFRAG_FOR_ALWAYS=("always" "never" "defer+madvise" "madvise")
# For THP=never, defrag must be never
DEFRAG_FOR_NEVER=("never")
WM_VALUES=(10 100 500 1000 2000 3000)
# -----------------------------------------------------------------------------
# Helpers
log() { echo "[$(date '+%F %T')] $*"; }
write_checkpoint() {
    local idx=$1
    echo "$idx" > "$CHECKPOINT"
    sync
}
read_checkpoint() {
    if [ -f "$CHECKPOINT" ]; then
        cat "$CHECKPOINT"
    else
        echo "-1"
    fi
}
# THP/defrag helpers: set enabled (always/never) and defrag value
set_thp_enabled() {
    local thp_mode=$1
    log "Applying THP enabled: $thp_mode"
    if [[ "$thp_mode" != "always" && "$thp_mode" != "never" ]]; then
        log "Invalid thp_mode: $thp_mode"
        return 1
    fi
    sudo sh -c "echo $thp_mode > /sys/kernel/mm/transparent_hugepage/enabled" 2>/dev/null || true
}
set_thp_defrag() {
    local defrag_val=$1
    log "Applying THP defrag: $defrag_val"
    sudo sh -c "echo $defrag_val > /sys/kernel/mm/transparent_hugepage/defrag" 2>/dev/null || true
}
# Apply watermark_scale_factor
set_wm() {
    local val=$1
    log "Setting vm.watermark_scale_factor=$val"
    sudo sysctl -w vm.watermark_scale_factor="$val" 2>/dev/null || true
}
# Run repository config actions (insmod etc.)
run_repo_config() {
    local thp_mode=$1
    log "--- Running repository config actions (config.sh contents) ---"
    
    # Only apply THP tunables here if the desired mode is "never"
    if [ "$thp_mode" = "never" ]; then
        log "Setting THP tunables to 'never' as requested by config (thp=never)"
        sudo sh -c 'echo "never" > /sys/kernel/mm/transparent_hugepage/defrag' 2>/dev/null || true
        sudo sh -c 'echo "never" > /sys/kernel/mm/transparent_hugepage/enabled' 2>/dev/null || true
    else
        log "Skipping config.sh THP lines because outer loop requested thp=always"
    fi

    # Load kernel modules if not already loaded
    if [ -f /local/colloid/tpp/tierinit/tierinit.ko ]; then
        sudo insmod /local/colloid/tpp/tierinit/tierinit.ko 2>/dev/null || true
    fi

    if [ -f /local/colloid/tpp/colloid-mon/colloid-mon.ko ]; then
        sudo insmod /local/colloid/tpp/colloid-mon/colloid-mon.ko 2>/dev/null || true
    fi

    if [ -f /local/colloid/tpp/kswapdrst/kswapdrst.ko ]; then
        sudo insmod /local/colloid/tpp/kswapdrst/kswapdrst.ko 2>/dev/null || true
    fi

    sudo sh -c 'echo 1 > /sys/kernel/mm/numa/demotion_enabled' 2>/dev/null || true
    sudo sh -c 'echo 6 > /proc/sys/kernel/numa_balancing' 2>/dev/null || true

    # Disable swap and drop caches
    sudo swapoff -a 2>/dev/null || true
    sudo sync 2>/dev/null || true
    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true

    log "--- Finished repository config actions ---"
}
# -----------------------------------------------------------------------------
# Build linear TASKS list (each line: idx|thp|defrag|wm|bench|cmd)
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
            for i in "${!BENCH_NAMES[@]}"; do
                bench="${BENCH_NAMES[$i]}"
                cmd="${BENCH_CMDS[$i]}"
                TASKS+=("${thp}|${defrag}|${wm}|${bench}|${cmd}")
                idx=$((idx+1))
            done
        done
    done
done
TOTAL=${#TASKS[@]}
printf "%s\n" "${TASKS[@]}" > "$LOGDIR/all_tasks.txt"
log "Total tasks to run: $TOTAL"
log "All tasks saved to: $LOGDIR/all_tasks.txt"
# Determine start index from checkpoint (last completed index + 1)
last_completed_index=$(read_checkpoint)
if [[ "$last_completed_index" =~ ^-?[0-9]+$ ]]; then
    start_index=$((last_completed_index + 1))
else
    start_index=0
fi
if [ "$start_index" -ge "$TOTAL" ]; then
    log "All tasks already completed (checkpoint shows last index = $last_completed_index). Removing checkpoint and exiting."
    rm -f "$CHECKPOINT"
    exit 0
fi
log "Resuming from task index: $start_index (last completed: $last_completed_index)"
# -----------------------------------------------------------------------------
# Main linear iteration: run from start_index ... TOTAL-1
for (( id = start_index; id < TOTAL; id++ )); do
    IFS='|' read -r thp defrag wm bench cmd <<< "${TASKS[$id]}"
    logfile="$LOGDIR/${bench}_THP-${thp}_DEFRAG-${defrag}_WM-${wm}.log"
    log "=== TASK $id/$((TOTAL-1)): $bench | THP=$thp | DEFRAG=$defrag | WM=$wm ==="
    log "Logfile: $logfile"
    {
        echo "Timestamp: $(date)"
        echo "Task ID: $id"
        echo "Command: python $cmd"
        echo "----------------------------------------"
    } >> "$logfile"

    # Apply THP enabled and defrag as requested BEFORE repo config
    {
        set_thp_enabled "$thp"
        set_thp_defrag "$defrag"
    } >> "$logfile" 2>&1

    # Run repo config actions
    run_repo_config "$thp" >> "$logfile" 2>&1

    # Apply watermark
    set_wm "$wm" >> "$logfile" 2>&1

    echo "--- Running full measurement pipeline ---" >> "$logfile"

    # Pre-run vmstat snapshot
    {
        echo "=== Pre-run statistics ==="
        grep -E "numa_pages_migrated|pgpromote_success|nr_active_file" /proc/vmstat
        echo "--- System THP settings ---"
        cat /sys/kernel/mm/transparent_hugepage/defrag
        cat /sys/kernel/mm/transparent_hugepage/enabled
        echo "--- System memory settings ---"
        sysctl vm.watermark_scale_factor vm.zone_reclaim_mode vm.swappiness vm.vfs_cache_pressure
    } >> "$logfile" 2>&1

    # Run the benchmark under perf
    log "Starting DLRM benchmark..."
    cd /local/dlrm
    
    # Execute Python command - FIXED: removed -c flag
    sudo /usr/bin/time --verbose /local/colloid/tpp/linux-6.3/tools/perf/perf stat -a --per-socket \
        -e dTLB-load-misses,dTLB-loads,dTLB-store-misses,dTLB-stores,cache-misses,cache-references,bus-cycles \
        -- taskset -c 0,1,2,3,4,5,6,7 /local/dlrm/venv/bin/python $cmd 2>&1 | tee -a "$logfile"
    
    exit_status=${PIPESTATUS[0]}
    echo "Exit status: $exit_status" >> "$logfile"

    # Post-run metrics
    {
        echo ""
        echo "=== Post-run statistics ==="
        grep -E "numa_pages_migrated|pgpromote_success|nr_active_file" /proc/vmstat
        echo "--- Final system settings ---"
        cat /sys/kernel/mm/transparent_hugepage/defrag
        cat /sys/kernel/mm/transparent_hugepage/enabled
        sysctl vm.watermark_scale_factor vm.zone_reclaim_mode vm.swappiness vm.vfs_cache_pressure
    } >> "$logfile" 2>&1

    if [ "$exit_status" -ne 0 ]; then
        log "ERROR: Benchmark returned non-zero exit status ($exit_status)."
        log "Check logfile for details: $logfile"
        
        # Don't advance checkpoint - retry same task
        if [ -f "$CHECKPOINT" ]; then
            log "Keeping checkpoint at index: $(cat $CHECKPOINT)"
        else
            echo "-1" > "$CHECKPOINT"
            sync
        fi
        
        # Ask user what to do
        read -p "Task failed. Press Enter to continue to next task, or 'r' to reboot and retry: " choice
        if [[ "$choice" == "r" ]]; then
            log "Rebooting to retry failed task..."
            sleep 3
            #sudo reboot
        fi
        continue
    fi

    # Task succeeded
    write_checkpoint "$id"
    log "=== SUCCESS: Finished $bench | THP=$thp | DEFRAG=$defrag | WM=$wm (task id=$id) ==="
    
    # Ask if user wants to continue or reboot
    if [ $((id + 1)) -lt $TOTAL ]; then
        read -p "Task completed successfully. Press Enter to continue to next task, or 'r' to reboot: " choice
        if [[ "$choice" == "r" ]]; then
            log "Rebooting before next benchmark..."
            sleep 3
            #sudo reboot
            exit 0
        fi
    fi
done

# If loop finishes, all tasks completed
log "All benchmarks completed successfully!"
log "Results saved in: $LOGDIR"
log "Summary of all tasks: $LOGDIR/all_tasks.txt"
rm -f "$CHECKPOINT"
exit 0