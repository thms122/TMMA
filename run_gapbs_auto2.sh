#!/usr/bin/env bash
# gapbs_run_all.sh
# Runs all benchmarks for each THP x DEFRAG x WM combination.
# Reboots after every single benchmark and correctly resumes after reboot.
# Checkpoint format: single integer -> index of last COMPLETED task in the TASKS list.
#
# Author: generated for you
set -u
# -----------------------------------------------------------------------------
LOGDIR="/local/logs/gapbs_logs"
mkdir -p "$LOGDIR"
CHECKPOINT="$LOGDIR/checkpoint.idx"
# Benchmarks (fixed order)
BENCH_NAMES=("pr_kron" "pr_twitter" "pr_web" "bc_kron")
BENCH_CMDS=(
    "/local/gapbs/pr -u 27 -k 20"
    "/local/gapbs/pr -f /local/gapbs/benchmark/graphs/twitter.sg -t1e-4 -n20"
    "/local/gapbs/pr -f /local/gapbs/benchmark/graphs/web.sg -t1e-4 -n20"
    "/local/gapbs/bc -f /local/gapbs/benchmark/graphs/kron.sg -n20"
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
    # Only allowed values: always or never
    if [[ "$thp_mode" != "always" && "$thp_mode" != "never" ]]; then
        log "Invalid thp_mode: $thp_mode"
        return 1
    fi
    sudo sh -c "echo $thp_mode > /sys/kernel/mm/transparent_hugepage/enabled"
}
set_thp_defrag() {
    local defrag_val=$1
    log "Applying THP defrag: $defrag_val"
    # defrag can be strings like "defer+madvise"
    sudo sh -c "echo $defrag_val > /sys/kernel/mm/transparent_hugepage/defrag"
}
# Apply watermark_scale_factor
set_wm() {
    local val=$1
    log "Setting vm.watermark_scale_factor=$val"
    sudo sysctl -w vm.watermark_scale_factor="$val"
}
# Run repository config actions (insmod etc.). Do NOT override THP enabled if outer loop requested "always".
run_repo_config() {
    local thp_mode=$1
    log "--- Running repository config actions (config.sh contents) ---"
    # Only apply THP tunables here if the desired mode is "never".
    if [ "$thp_mode" = "never" ]; then
        log "Setting THP tunables to 'never' as requested by config (thp=never)"
        sudo sh -c 'echo "never" > /sys/kernel/mm/transparent_hugepage/defrag' || true
        sudo sh -c 'echo "never" > /sys/kernel/mm/transparent_hugepage/enabled' || true
    else
        log "Skipping config.sh THP lines because outer loop requested thp=always"
    fi

    # Load kernel modules (insmod). If already loaded, insmod will error — that's OK.
    if [ -f /local/colloid/tpp/tierinit/tierinit.ko ]; then
        sudo insmod /local/colloid/tpp/tierinit/tierinit.ko || true
    else
        log "Warning: tierinit.ko not found at /local/colloid/tpp/tierinit/tierinit.ko"
    fi

    if [ -f /local/colloid/tpp/colloid-mon/colloid-mon.ko ]; then
        sudo insmod /local/colloid/tpp/colloid-mon/colloid-mon.ko || true
    else
        log "Warning: colloid-mon.ko not found at /local/colloid/tpp/colloid-mon/colloid-mon.ko"
    fi

    if [ -f /local/colloid/tpp/kswapdrst/kswapdrst.ko ]; then
        sudo insmod /local/colloid/tpp/kswapdrst/kswapdrst.ko || true
    else
        log "Warning: kswapdrst.ko not found at /local/colloid/tpp/kswapdrst/kswapdrst.ko"
    fi

    sudo sh -c 'echo 1 > /sys/kernel/mm/numa/demotion_enabled' || true
    sudo sh -c 'echo 6 > /proc/sys/kernel/numa_balancing' || true

    # Disable swap and drop caches (keep as in config.sh)
    sudo swapoff -a || true
    sudo sync || true
    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' || true

    log "--- Finished repository config actions ---"
}
# Validate graph file when a command contains "-f <file>"
validate_graph_in_cmd() {
    local cmd="$1"
    # find -f argument
    if echo "$cmd" | grep -q -- "-f"; then
        # extract file following -f
        local file
        # robustly extract argument after -f
        file=$(echo "$cmd" | sed -nE 's/.*-f[[:space:]]+([^[:space:]]+).*/\1/p')
        if [ -n "$file" ]; then
            if [ ! -f "$file" ]; then
                log "ERROR: required graph file not found: $file"
                return 1
            fi
        fi
    fi
    return 0
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
log "Total tasks to run: $TOTAL"
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
    echo "Timestamp: $(date)" | tee -a "$logfile"
    echo "Task ID: $id" | tee -a "$logfile"
    echo "Command: $cmd" | tee -a "$logfile"

    # Validate possible graph file
    if ! validate_graph_in_cmd "$cmd"; then
        echo "Graph file missing for command. Will write checkpoint for same index and reboot." | tee -a "$logfile"
        # do not mark this task as completed; write last completed as id-1 (or keep previous)
        # keep checkpoint unchanged (last_completed_index) so start will retry this task.
        log "Rebooting to allow investigation (missing graph)."
        sleep 3
        sudo reboot
        exit 0
    fi

    # Apply THP enabled and defrag as requested BEFORE repo config so config.sh won't override when we want 'always'
    set_thp_enabled "$thp" 2>&1 | tee -a "$logfile"
    set_thp_defrag "$defrag" 2>&1 | tee -a "$logfile"

    # Run repo config actions (pass thp so config.sh lines don't override when we requested always)
    run_repo_config "$thp" 2>&1 | tee -a "$logfile"

    # Apply watermark
    set_wm "$wm" 2>&1 | tee -a "$logfile"

    echo "--- Running full measurement pipeline ---" | tee -a "$logfile"

    # Pre-run vmstat snapshot
    cat /proc/vmstat | grep numa_pages_migrated     2>&1 | tee -a "$logfile"
    cat /proc/vmstat | grep pgpromote_success       2>&1 | tee -a "$logfile"
    cat /proc/vmstat | grep nr_active_file          2>&1 | tee -a "$logfile"

    # Run the benchmark under perf (time + perf stat). Put the whole invocation in a subshell to capture exit status.
    sudo /usr/bin/time --verbose perf stat -a --per-socket \
        -e dTLB-load-misses,dTLB-loads,dTLB-store-misses,dTLB-stores,cache-misses,cache-references,bus-cycles \
        -- taskset -c 0,1,2,3,4,5,6,7 bash -lc "$cmd" 2>&1 | tee -a "$logfile"
    exit_status=${PIPESTATUS[0]}
    echo "Exit status: $exit_status" | tee -a "$logfile"

    # Post-run metrics
    cat /proc/vmstat | grep numa_pages_migrated     2>&1 | tee -a "$logfile"
    cat /proc/vmstat | grep pgpromote_success       2>&1 | tee -a "$logfile"
    cat /proc/vmstat | grep nr_active_file          2>&1 | tee -a "$logfile"

    sudo cat /sys/kernel/mm/transparent_hugepage/defrag           2>&1 | tee -a "$logfile"
    sudo cat /sys/kernel/mm/transparent_hugepage/enabled          2>&1 | tee -a "$logfile"
    sudo cat /proc/sys/vm/watermark_scale_factor                  2>&1 | tee -a "$logfile"
    sudo cat /proc/sys/vm/zone_reclaim_mode                       2>&1 | tee -a "$logfile"
    sudo cat /proc/sys/vm/swappiness                              2>&1 | tee -a "$logfile"

    if [ "$exit_status" -ne 0 ]; then
        log "Benchmark returned non-zero exit status ($exit_status). Will retry this task after reboot."
        # Do NOT advance the last completed index; leave checkpoint as is (so resume will retry same task).
        # If there's no checkpoint yet (last_completed_index == -1), write -1 to keep behavior consistent.
        if [ -f "$CHECKPOINT" ]; then
            # keep existing checkpoint (last completed stays the same)
            log "Keeping existing checkpoint (last completed index = $(cat $CHECKPOINT)). Rebooting."
        else
            echo "-1" > "$CHECKPOINT"
            sync
            log "Wrote initial checkpoint -1 to indicate no tasks completed."
        fi
        sleep 3
        sudo reboot
        exit 0
    fi

    # If we get here, the task succeeded. Write its index as last completed, then reboot to continue.
    write_checkpoint "$id"
    log "=== Finished $bench | THP=$thp | DEFRAG=$defrag | WM=$wm (task id=$id) ==="
    log "Rebooting before next benchmark (or exiting if none left)."
    sleep 5
    sudo reboot
    exit 0
done

# If loop finishes, all tasks completed
log "All benchmarks completed successfully. Removing checkpoint."
rm -f "$CHECKPOINT"
exit 0
