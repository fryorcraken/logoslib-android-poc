#!/usr/bin/env bash
# bc-desktop run1: the module's own runtime doctest flow (blockchain-module-runtime.test.yaml), headless,
# all state under .work/experiments/bc-desktop: daemon (under strace: openat/execve) -> load-module ->
# module-info -> generate_user_config(skip_ibd, use_persistence_paths) -> shorten bootstrap -> start ->
# poll chain state + resources -> read-only calls -> stop -> does_state_exist -> stop daemon.
set -u
source ${REPO_ROOT}/.work/scripts/bc-desktop-common.sh
RUN=run1
LOG="$E/logs/$RUN"
rm -rf "$LOG"; mkdir -p "$LOG/strace"
exec > >(tee "$LOG/run.log") 2>&1
echo "== $RUN start $(date -Is) =="
echo "sun_path check: ${#SOCK} + 37 = $(( ${#SOCK} + 37 )) (must be < 108)"
ps -eo pid,args | grep -E 'logos_host|logoscore' | grep -v grep && echo "WARNING: logos processes already running"

T0=$(date +%s%N)
setsid nohup "$STRACE" -f -ff --seccomp-bpf -e trace=openat,execve -o "$LOG/strace/tr" \
  "$L" --config-dir "$CFG" -D -m "$MODS" --persistence-path "$PERSIST" > "$LOG/daemon.log" 2>&1 < /dev/null &
SPID=$!
echo "$SPID" > "$LOG/strace.pid"
for i in $(seq 1 150); do lc status --json > /dev/null 2>&1 && break; sleep 0.2; done
echo "daemon up after $(( ($(date +%s%N) - T0) / 1000000 )) ms (strace pid $SPID)"
timed list-modules
T1=$(date +%s%N)
timed load-module blockchain_module
echo "load-module wall: $(( ($(date +%s%N) - T1) / 1000000 )) ms"
timed status
lc module-info blockchain_module --json > "$LOG/module-info.json" 2>&1
lc module-info blockchain_module > "$LOG/module-info.txt" 2>&1
echo "module-info: $(wc -c < "$LOG/module-info.json") bytes json"
cat "$LOG/module-info.txt"
HP=$(host_pid blockchain_module)
echo "blockchain_module host pid: $HP"
tr '\0' ' ' < "/proc/$HP/cmdline" | cut -c1-400; echo
sample "$HP" loaded

# event stream (the CLI's watch command), left running until the end of the run
setsid nohup "$L" --config-dir "$CFG" watch blockchain_module --json > "$LOG/events.jsonl" 2> "$LOG/watch.err" < /dev/null &
WPID=$!
sleep 1

echo "== node not running yet =="
timed call blockchain_module get_cryptarchia_info

cat > "$LOG/runtime-args.json" <<'JSON'
{
  "skip_ibd": true,
  "net_port": 3200,
  "blend_port": 3201,
  "http_addr": "127.0.0.1:18480",
  "output": "user_config.yaml",
  "use_persistence_paths": true
}
JSON
echo "== generate_user_config =="
timed call blockchain_module generate_user_config "@$LOG/runtime-args.json"
UC=$(find "$PERSIST/blockchain_module" -name user_config.yaml | head -1)
echo "generated: $UC"
ls -la "$(dirname "$UC")"
grep -n -A1 'ibd:' "$UC"
sed "s/prolonged_bootstrap_period: '3600.000000000'/prolonged_bootstrap_period: '5.000000000'/" "$UC" > "$UC.tmp" && mv "$UC.tmp" "$UC"
grep -n prolonged_bootstrap_period "$UC"
# keep a copy for the report (throwaway local-test keys)
cp "$UC" "$LOG/user_config.yaml"
echo "persist before start: $(du -sb "$PERSIST" | cut -f1) B"

echo "== start =="
T2=$(date +%s%N)
timed call blockchain_module start "$UC" ""
echo "start wall: $(( ($(date +%s%N) - T2) / 1000000 )) ms"
sample "$HP" started
for i in $(seq 1 8); do
  sleep 5
  CLIP=400 timed call blockchain_module get_cryptarchia_info
  sample "$HP" "t+$((i * 5))s"
done
echo "== read-only calls =="
timed call blockchain_module get_chain_id
timed call blockchain_module get_time_info
timed call blockchain_module get_network_info
timed call blockchain_module blend_info
timed call blockchain_module wallet_get_known_addresses
ADDR=$(lc call blockchain_module wallet_get_known_addresses 2>/dev/null | grep -o '[0-9a-f]\{64\}' | head -1)
timed call blockchain_module wallet_get_balance "$ADDR"
timed call blockchain_module wallet_get_notes "$ADDR" ""
timed call blockchain_module pow_claimable_rewards
timed call blockchain_module get_peer_id "$UC"
timed call blockchain_module read_accounts "$UC"
timed call blockchain_module get_blocks 0 10
echo "== sockets / ports of the host =="
ss -tulpn 2>/dev/null | grep "pid=$HP,"
echo "== unix listeners =="
ss -xlpn 2>/dev/null | grep -E 'logos' | awk '{print $5, $NF}'
echo "== open files of the host (non socket/pipe) =="
ls -l "/proc/$HP/fd" 2>/dev/null | awk '{print $NF}' | grep -v -E '^(socket|pipe|anon_inode)' | sort | uniq -c | sort -rn | head -40
echo "== persist tree =="
find "$PERSIST/blockchain_module" -maxdepth 4 | head -60
du -sb "$PERSIST/blockchain_module"/*/* 2>/dev/null

echo "== stop node =="
timed call blockchain_module stop
timed call blockchain_module get_cryptarchia_info
timed call blockchain_module does_state_exist
sample "$HP" stopped
echo "== events captured =="
kill "$WPID" 2>/dev/null
wc -l "$LOG/events.jsonl"; head -c 1500 "$LOG/events.jsonl"; echo
echo "== stop daemon =="
timed stop
for i in $(seq 1 75); do kill -0 "$SPID" 2>/dev/null || break; sleep 0.2; done
kill -0 "$SPID" 2>/dev/null && echo "strace/daemon $SPID STILL RUNNING" || echo "daemon (strace $SPID) exited"
echo "leftover logos processes:"; ps -eo pid,ppid,args | grep -E 'logos_host|logoscore|strace' | grep -v grep | cut -c1-160
echo "leftover sockets in $SOCK:"; ls -la "$SOCK"
echo "== daemon log (tail 120) =="
tail -n 120 "$LOG/daemon.log"
echo "== $RUN end $(date -Is) =="
