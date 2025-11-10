#!/bin/bash
# ==========================================
# GAPBS Benchmark Automation Script
# Reboots after every single benchmark
# ==========================================

LOGDIR="/local/logs/gapbs_logs"
mkdir -p "$LOGDIR"

CHECKPOINT="$LOGDIR/checkpoint.txt"

# Benchmarks
declare -A BENCHES=(
    ["pr_kron"]="/local/gapbs/pr -u 27 -k 20"
    ["pr_twitter"]="/local/gapbs/pr -f /local/gapbs/benchmark/graphs/twitter.sg -t1e-4 -n20"
    ["pr_web"]="/local/gapbs/pr -f /local/gapbs/benchmark/graphs/web.sg -t1e-4 -n20"
    ["bc_kron"]="/local/gapbs/bc -f /local/gapbs/benchmark/graphs/kron.sg -n20"
)

THP_MODES=("never" "always")
WM_VALUES=(10 100 500 1000 2000 3000)

# Resume from checkpoint if available
if [ -f "$CHECKPOINT" ]; then
    IFS=',' read -r LAST_THP LAST_WM LAST_BENCH < "$CHECKPOINT"
    echo "Resuming from checkpoint: THP=$LAST_THP, WM=$LAST_WM, BENCH=$LAST_BENCH"
else
    LAST_THP=""
    LAST_WM=""
    LAST_BENCH=""
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
for thp in "${THP_MODES[@]}"; do
    [[ -n "$LAST_THP" && "$thp" < "$LAST_THP" ]] && continue
    set_thp "$thp"

    for wm in "${WM_VALUES[@]}"; do
        [[ -n "$LAST_WM" && "$thp" == "$LAST_THP" && "$wm" < "$LAST_WM" ]] && continue
        set_wm "$wm"

        for bench in "${!BENCHES[@]}"; do
            # Resume logic
            if [[ -n "$LAST_BENCH" && "$thp" == "$LAST_THP" && "$wm" == "$LAST_WM" ]]; then
                if [[ "$bench" != "$LAST_BENCH" ]]; then
                    continue
                else
                    LAST_BENCH=""
                fi
            fi

            logfile="$LOGDIR/${bench}_THP-${thp}_WM-${wm}.log"
            echo "=== Running $bench | THP=$thp | WM=$wm ==="
            echo "Timestamp: $(date)" | tee -a "$logfile"
            echo "Command: ${BENCHES[$bench]}" | tee -a "$logfile"

            ${BENCHES[$bench]} 2>&1 | tee -a "$logfile"

            echo "=== Finished $bench | THP=$thp | WM=$wm ===" | tee -a "$logfile"
            echo "$thp,$wm,$bench" > "$CHECKPOINT"

            echo "Rebooting after $bench (THP=$thp, WM=$wm)..."
            sudo reboot
            exit 0
        done
    done
done

rm -f "$CHECKPOINT"
echo "All benchmarks completed successfully!"
