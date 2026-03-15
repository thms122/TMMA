#!/usr/bin/env bash
set -euo pipefail

LOGDIR="/local/logs/bench_logs"
CHECKPOINT="$LOGDIR/checkpoint.idx"
TASKFILE="$LOGDIR/all_tasks.txt"

mkdir -p "$LOGDIR"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
ckpt_read() { [[ -f "$CHECKPOINT" ]] && cat "$CHECKPOINT" || echo "-1"; }
ckpt_write() { echo "$1" >"$CHECKPOINT"; sync; }

# ----------------------------- Configuration -----------------------------
# Select system: "linux" or "colloid"
SYSTEM="linux"

BENCH_NAMES=(llama)
BENCH_CMDS=(
  #"/local/gapbs/pr -u 27 -k 20"
  #"/local/gapbs/pr -f /local/gapbs/benchmark/graphs/twitter.sg -t1e-4 -n20"
  #"/local/gapbs/pr -f /local/gapbs/benchmark/graphs/web.sg -t1e-4 -n20"
  #"/local/gapbs/bc -f /local/gapbs/benchmark/graphs/kron.sg -n20"
  "/local/llama.cpp/build/bin/llama-bench   -m /local/llama.cpp/Meta-Llama-3-70B-Instruct-Q4_K_M.gguf -t 8 -p 1 -n 2"
  #"/local/liblinear/train -s 6 /local/liblinear/HIGGS"
  #"python /local/dlrm/dlrm_s_pytorch.py --mini-batch-size=512 --test-mini-batch-size=1024 --test-num-workers=0 --num-batches=200 --data-generation=random --arch-mlp-bot=1024-1024-256 --arch-mlp-top=512-512-1 --arch-sparse-feature-size=256 --arch-embedding-size=1000000-1000000-1000000-1000000-1000000-1000000-1000000 --num-indices-per-lookup=100 --arch-interaction-op=dot --numpy-rand-seed=727"
)

THP_MODES=(madvise)
DEFRAG_ALWAYS=(madvise)
DEFRAG_NEVER=(never)

WM_VALUES=(10)
VFS_VALUES=(100)
SWAP_VALUES=(60)
ZONE_VALUES=(0)

# Valid TTL values (0 is valid)
# If MGLRU is unavailable, the TTL sweep will be skipped and "NA" will be used in logs.
MGLRU_TTLS=(0)

CPUSET="0,1,2,3,4,5,6,7"
PERF_EVENTS="dTLB-load-misses,dTLB-loads,dTLB-store-misses,dTLB-stores,cache-misses,cache-references,bus-cycles"

MGLRU_TTL_PATH="/sys/kernel/mm/lru_gen/min_ttl_ms"

# ----------------------------- System helpers ----------------------------
repo_setup_linux() {
  sudo insmod /local/Linux-6-16-Tiers/tierinit.ko 2>/dev/null || true
  sudo sh -c "echo 2 > /proc/sys/kernel/numa_balancing"
  sudo sh -c "echo 1000 > /sys/kernel/debug/sched/numa_balancing/hot_threshold_ms" #adjust hot threshold here
  sudo swapoff -a || true
  sudo sync
}

perf_bin_for_system() {
  case "$1" in
    linux)   echo "/local/Linux-6-16-Tiers/linux-6.16.1/tools/perf/perf" ;;
    colloid) echo "/local/colloid/tpp/linux-6.3/tools/perf/perf" ;;  # <- set your real path
    *) echo "Unknown SYSTEM: $1 (expected: linux|colloid)" >&2; exit 1 ;;
  esac
}

repo_setup_colloid() {
  sudo insmod /local/colloid/tpp/tierinit/tierinit.ko 2>/dev/null || true
  sudo insmod /local/colloid/tpp/colloid-mon/colloid-mon.ko 2>/dev/null || true
  sudo insmod /local/colloid/tpp/kswapdrst/kswapdrst.ko 2>/dev/null || true

  sudo sh -c 'echo 1 > /sys/kernel/mm/numa/demotion_enabled' || true
  sudo sh -c 'echo 6 > /proc/sys/kernel/numa_balancing' || true
  sudo sh -c "echo 1000 > /sys/kernel/debug/sched/numa_balancing/hot_threshold_ms" #adjust hot threshold here

  sudo swapoff -a || true
  sudo sync
  sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' || true
}

repo_setup() {
  case "$1" in
    linux)   repo_setup_linux ;;
    colloid) repo_setup_colloid ;;
    *) echo "Unknown SYSTEM: $1 (expected: linux|colloid)" >&2; exit 1 ;;
  esac
}

thp_enabled() { sudo sh -c "echo $1 > /sys/kernel/mm/transparent_hugepage/enabled"; }
thp_defrag()  { sudo sh -c "echo $1 > /sys/kernel/mm/transparent_hugepage/defrag"; }
sysctl_set()  { sudo sysctl -w "$1=$2" >/dev/null; }

mglru_available() { [[ -e "$MGLRU_TTL_PATH" ]]; }

set_mglru_ttl() {
  local ttl="$1"
  sudo sh -c "echo $ttl > $MGLRU_TTL_PATH"
}


vmstat_snap() {
  grep -E 'numa_pages_migrated|pgpromote_success|nr_active_file' /proc/vmstat 2>/dev/null \
    | sudo tee -a "$1" >/dev/null || true
}

config_snap() {
  local lf="$1"
  {
    echo "thp.enabled: $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)"
    echo "thp.defrag:  $(cat /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null)"
    echo "vm.watermark_scale_factor: $(cat /proc/sys/vm/watermark_scale_factor 2>/dev/null)"
    echo "vm.vfs_cache_pressure:     $(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null)"
    echo "vm.swappiness:             $(cat /proc/sys/vm/swappiness 2>/dev/null)"
    echo "vm.zone_reclaim_mode:      $(cat /proc/sys/vm/zone_reclaim_mode 2>/dev/null)"
    if mglru_available; then
      echo "mglru.min_ttl_ms:          $(cat "$MGLRU_TTL_PATH" 2>/dev/null)"
    fi
  } | sudo tee -a "$lf" >/dev/null
}

# ----------------------------- Task generation ---------------------------

build_tasks() {
  : >"$TASKFILE"

  local ttl_list=("NA")
  if mglru_available; then
    ttl_list=("${MGLRU_TTLS[@]}")
  fi

  for thp in "${THP_MODES[@]}"; do
    if [[ "$thp" == "never" ]]; then
      defrags=("${DEFRAG_NEVER[@]}")
    else
      defrags=("${DEFRAG_ALWAYS[@]}")
    fi

    for defrag in "${defrags[@]}"; do
      for wm in "${WM_VALUES[@]}"; do
        for vfs in "${VFS_VALUES[@]}"; do
          for swp in "${SWAP_VALUES[@]}"; do
            for zone in "${ZONE_VALUES[@]}"; do
              for ttl in "${ttl_list[@]}"; do
                for i in "${!BENCH_NAMES[@]}"; do
                  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
                    "$thp" "$defrag" "$wm" "$vfs" "$swp" "$zone" "$ttl" \
                    "${BENCH_NAMES[$i]}" "${BENCH_CMDS[$i]}" >>"$TASKFILE"
                done
              done
            done
          done
        done
      done
    done
  done
}

build_tasks

TOTAL="$(wc -l <"$TASKFILE" | tr -d ' ')"
last_done="$(ckpt_read)"
start="$((last_done + 1))"

if (( start >= TOTAL )); then
  log "All tasks completed."
  rm -f "$CHECKPOINT"
  exit 0
fi

log "Total tasks: $TOTAL"
log "Resuming at index: $start"

# ----------------------------- Execute one task --------------------------

task_line="$(sed -n "$((start + 1))p" "$TASKFILE")"
IFS='|' read -r thp defrag wm vfs swp zone ttl bench cmd <<<"$task_line"

logfile="$LOGDIR/${bench}_THP-${thp}_DEFRAG-${defrag}_WM-${wm}_VFS-${vfs}_SWAP-${swp}_ZONE-${zone}_MGLRU-${ttl}.log"

log "TASK $start: $bench | THP=$thp DEFRAG=$defrag WM=$wm VFS=$vfs SWAP=$swp ZONE=$zone MGLRU=$ttl"
echo "cmd: $cmd" | sudo tee -a "$logfile" >/dev/null

thp_enabled "$thp"
thp_defrag  "$defrag"
repo_setup "$SYSTEM"

sysctl_set vm.watermark_scale_factor "$wm"
sysctl_set vm.vfs_cache_pressure     "$vfs"
sysctl_set vm.swappiness             "$swp"
sysctl_set vm.zone_reclaim_mode      "$zone"

if [[ "$ttl" != "NA" ]]; then
  if mglru_available; then
    set_mglru_ttl "$ttl"
  else
    echo "mglru unavailable; skipping set min_ttl_ms" | sudo tee -a "$logfile" >/dev/null
  fi
fi

vmstat_snap "$logfile"
config_snap "$logfile"

PERF_BIN="$(perf_bin_for_system "$SYSTEM")"

set +e
sudo /usr/bin/time --verbose \
  "$PERF_BIN" stat -a --per-socket -e "$PERF_EVENTS" -- \
  taskset -c "$CPUSET" bash -c "$cmd" 2>&1 | sudo tee -a "$logfile"
rc="${PIPESTATUS[0]}"
set -e

echo "exit_status: $rc" | sudo tee -a "$logfile" >/dev/null

vmstat_snap "$logfile"
config_snap "$logfile"

if (( rc != 0 )); then
  log "Task failed (rc=$rc). Rebooting."
  sudo reboot
  exit 0
fi

ckpt_write "$start"
log "Task completed. Rebooting."
sleep 2
sudo reboot