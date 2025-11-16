#!/bin/bash
# ==========================================
# GAPBS Benchmark Automation Script
# Runs all benchmarks in fixed order
# Reboots after every single benchmark
# Correctly resumes after reboot
# Integrates config.sh actions without overriding THP loop
# ==========================================

LOGDIR="/local/logs/gapbs_logs"
mkdir -p "$LOGDIR"

CHECKPOINT="$LOGDIR/checkpoint.txt"

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
WM_VALUES=(10 100 500 1000 2000 3000)

# Resume from checkpoint if available
if [ -f "$CHECKPOINT" ]; then
    IFS=',' read -r LAST_THP LAST_WM LAST_BENCH < "$CHECKPOINT"
    echo "Resuming from checkpoint: THP=$LAST_THP, WM=$LAST_WM, BENCH=$LAST_BENCH"
    RESUME=true
else
    LAST_THP=""
    LAST_WM=""
    LAST_BENCH=""
    RESUME=false
fi

# Helper functions
set_thp() {
    local mode=$1
    echo "Applying THP mode: $mode"
    sudo sh -c "echo $mode > /sys/kernel/mm/transparent_hugepage/defrag"
    sudo sh -c "echo $mode > /sys/kernel/mm/transparent_hugepage/enabled"
}

set_wm() {
    local val=$1
    echo "Setting vm.watermark_scale_factor=$val"
    sudo sysctl -w vm.watermark_scale_factor=$val
}

# Function: run repository config actions but do NOT override THP when thp=always
run_repo_config() {
    local thp_mode=$1
    echo "--- Running repository config actions (config.sh contents) ---"
    # Only apply THP tunables here if the desired mode is "never"
    if [ "$thp_mode" = "never" ]; then
        echo "Setting THP tunables to 'never' as requested by config.sh (thp=never)"
        sudo sh -c 'echo "never" > /sys/kernel/mm/transparent_hugepage/defrag'
        sudo sh -c 'echo "never" > /sys/kernel/mm/transparent_hugepage/enabled'
    else
        echo "Skipping config.sh THP lines because outer loop requested thp=$thp_mode"
    fi

    # Load kernel modules (insmod). If already loaded, insmod will error — that's OK.
    if [ -f /local/colloid/tpp/tierinit/tierinit.ko ]; then
        sudo insmod /local/colloid/tpp/tierinit/tierinit.ko || true
    else
        echo "Warning: tierinit.ko not found at /local/colloid/tpp/tierinit/tierinit.ko"
    fi

    if [ -f /local/colloid/tpp/colloid-mon/colloid-mon.ko ]; then
        sudo insmod /local/colloid/tpp/colloid-mon/colloid-mon.ko || true
    else
        echo "Warning: colloid-mon.ko not found at /local/colloid/tpp/colloid-mon/colloid-mon.ko"
    fi

    if [ -f /local/colloid/tpp/kswapdrst/kswapdrst.ko ]; then
        sudo insmod /local/colloid/tpp/kswapdrst/kswapdrst.ko || true
    else
        echo "Warning: kswapdrst.ko not found at /local/colloid/tpp/kswapdrst/kswapdrst.ko"
    fi

    sudo sh -c 'echo 1 > /sys/kernel/mm/numa/demotion_enabled' || true
    sudo sh -c 'echo 6 > /proc/sys/kernel/numa_balancing' || true

    # Disable swap and drop caches (dangerous on machines with little RAM; keep as in config.sh)
    sudo swapoff -a || true
    sudo sync || true
    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' || true

    # NOTE: config.sh sets watermark_scale_factor=100. We do not force it here;
    # we will let set_wm() from the loop apply the desired value afterwards.
    echo "--- Finished repository config actions ---"
}

# Main loop
skip=true
if [ "$RESUME" = false ]; then
    skip=false
fi

for thp in "${THP_MODES[@]}"; do
    for wm in "${WM_VALUES[@]}"; do
        for i in "${!BENCH_NAMES[@]}"; do
            bench="${BENCH_NAMES[$i]}"
            cmd="${BENCH_CMDS[$i]}"

            # If resuming, skip until last finished benchmark
            if [ "$skip" = true ]; then
                if [[ "$thp" == "$LAST_THP" && "$wm" == "$LAST_WM" && "$bench" == "$LAST_BENCH" ]]; then
                    echo "Found last completed benchmark: $bench (THP=$thp, WM=$wm)"
                    skip=false
                    continue  # start with next one
                else
                    continue
                fi
            fi

            logfile="$LOGDIR/${bench}_THP-${thp}_WM-${wm}.log"
            echo "=== Running $bench | THP=$thp | WM=$wm ==="
            echo "Timestamp: $(date)" | tee -a "$logfile"
            echo "Command: $cmd" | tee -a "$logfile"

            # Apply THP requested by main loop first (so subsequent config steps that skip THP won't override)
            set_thp "$thp"

            # Run repository config actions (insmod, numa toggles, swapoff, drop_caches, etc.)
            # We pass `$thp` so the config step won't forcibly change THP when thp="always".
            run_repo_config "$thp"

            # Apply the desired watermark_scale_factor from the loop (overrides any value set by config.sh)
            set_wm "$wm"

            echo "--- Running full measurement pipeline ---" | tee -a "$logfile"

            # Pre-run vmstat snapshot
            cat /proc/vmstat | grep numa_pages_migrated     2>&1 | tee -a "$logfile"
            cat /proc/vmstat | grep pgpromote_success       2>&1 | tee -a "$logfile"
            cat /proc/vmstat | grep nr_active_file          2>&1 | tee -a "$logfile"

            # perf timed run with dynamic command substituted here
            sudo /usr/bin/time --verbose perf stat -a --per-socket \
                -e dTLB-load-misses,dTLB-loads,dTLB-store-misses,dTLB-stores,cache-misses,cache-references,bus-cycles \
                -- taskset -c 0,1,2,3,4,5,6,7 $cmd           2>&1 | tee -a "$logfile"

            # Post-run metrics
            cat /proc/vmstat | grep numa_pages_migrated     2>&1 | tee -a "$logfile"
            cat /proc/vmstat | grep pgpromote_success       2>&1 | tee -a "$logfile"
            cat /proc/vmstat | grep nr_active_file          2>&1 | tee -a "$logfile"

            sudo cat /sys/kernel/mm/transparent_hugepage/defrag           2>&1 | tee -a "$logfile"
            sudo cat /sys/kernel/mm/transparent_hugepage/enabled          2>&1 | tee -a "$logfile"
            sudo cat /proc/sys/vm/watermark_scale_factor                  2>&1 | tee -a "$logfile"
            sudo cat /proc/sys/vm/zone_reclaim_mode                       2>&1 | tee -a "$logfile"
            sudo cat /proc/sys/vm/swappiness                              2>&1 | tee -a "$logfile"

            echo "=== Finished $bench | THP=$thp | WM=$wm ===" | tee -a "$logfile"

            # --- Find next combination for checkpoint ---
            found_current=false
            for next_thp in "${THP_MODES[@]}"; do
                for next_wm in "${WM_VALUES[@]}"; do
                    for next_bench in "${BENCH_NAMES[@]}"; do
                        if [ "$found_current" = true ]; then
                            echo "$next_thp,$next_wm,$next_bench" > "$CHECKPOINT"
                            sync
                            echo "Rebooting before next benchmark: $next_bench (THP=$next_thp, WM=$next_wm)"
                            sleep 5
                            sudo reboot
                            exit 0
                        fi

                        if [[ "$next_thp" == "$thp" && "$next_wm" == "$wm" && "$next_bench" == "$bench" ]]; then
                            found_current=true
                        fi
                    done
                done
            done

            # --- No next benchmark → done ---
            rm -f "$CHECKPOINT"
            echo "All benchmarks completed successfully!"
            exit 0
        done
    done
done
