# bc-desktop: shared variables/helpers, SOURCED by the other bc-desktop-*.sh scripts (not run directly).
W=${REPO_ROOT}/.work
E=$W/experiments/bc-desktop
P=$W/probe
L="$P/logos/bin/logoscore"
LGPM="$P/lgpm/bin/lgpm"
STRACE="$E/strace/bin/strace"
CFG="$E/cfg"
PERSIST="$E/persist"
MODS="$E/modules"
# QtRO sockets live at <QDir::tempPath()>/logos_<module>_<12hex>. sun_path is 108 bytes and
# "<dir>/logos_capability_module_<12hex>" adds 37 bytes, so the dir must be <= ~70 bytes.
# Anything under .work/experiments/bc-desktop/ is >= 84 bytes (too long, crashes capability_module,
# see desktop-probe C13), so the socket dir is the shortest path under .work instead:
SOCK="$W/bcs"
export QT_QPA_PLATFORM=offscreen
export TMPDIR="$SOCK"
mkdir -p "$CFG" "$PERSIST" "$MODS" "$SOCK" "$E/logs"
lc() { "$L" --config-dir "$CFG" "$@"; }
# timed <label> <logoscore args...>: run a CLI call (json), print rc, ms and a clipped result.
timed() {
  local t0 t1 out rc
  t0=$(date +%s%N)
  out=$(lc "$@" --json 2>&1); rc=$?
  t1=$(date +%s%N)
  echo "\$ logoscore $* -> rc=$rc ($(( (t1 - t0) / 1000000 )) ms)"
  echo "  $out" | head -c "${CLIP:-1500}"; echo
}
# host_pid <module>: pid of the logos_host_qt child serving that module
host_pid() { pgrep -f -- "--name $1( |$)" | head -1; }
# sample <pid> <label>: one resource sample line for a host process
sample() {
  local pid=$1 lab=$2 rss hwm thr ut st ports
  [ -r "/proc/$pid/status" ] || { echo "$(date +%T) $lab pid=$pid GONE"; return; }
  rss=$(awk '/^VmRSS/{print $2}' /proc/$pid/status)
  hwm=$(awk '/^VmHWM/{print $2}' /proc/$pid/status)
  thr=$(awk '/^Threads/{print $2}' /proc/$pid/status)
  read -r ut st < <(awk '{print $14, $15}' /proc/$pid/stat)
  echo "$(date +%T) $lab pid=$pid rss_kb=$rss hwm_kb=$hwm threads=$thr cpu_ticks=$((ut + st)) fds=$(ls /proc/$pid/fd 2>/dev/null | wc -l)"
}
