#!/bin/bash
# ==========================================
# GAPBS Benchmark Automation Script
# Runs all benchmarks in fixed order
# Reboots after every single benchmark
# Correctly resumes after reboot
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

            # If resuming, skip until we find the last completed benchmark
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

            set_thp "$thp"
            set_wm "$wm"

            $cmd 2>&1 | tee -a "$logfile"

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

            # --- No next benchmark → all done ---
            rm -f "$CHECKPOINT"S
            echo "All benchmarks completed successfully!"
            exit 0
        done
    done
done
