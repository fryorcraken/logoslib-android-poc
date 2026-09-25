#!/usr/bin/env bash
# bc-desktop run2: REAL WORK offline. Start the node from the node repo's own standalone pair
# (nodes/node/standalone-node-config.yaml + standalone-deployment-config.yaml at the pinned rev 35a4a666):
# a one-node "standalone-local" chain whose genesis gives this node's key stake, so it should win slots,
# prove leadership (PoL circuit) and produce blocks alone. Observe ~12 min: height, events, RSS/CPU,
# disk, ports, opened files (strace), mapped .so set.
set -u
source ${REPO_ROOT}/.work/scripts/bc-desktop-common.sh
RUN=run2
DURATION=${DURATION:-720}
LOG="$E/logs/$RUN"
SA="$E/standalone"
DATA="$E/standalone-data"
rm -rf "$LOG" "$DATA"; mkdir -p "$LOG/strace" "$LOG/nodelog" "$SA" "$DATA"
exec > >(tee "$LOG/run.log") 2>&1
echo "== $RUN start $(date -Is) =="
NS=$(cat "$E/logs/nodesrc.path")
cp "$NS/nodes/node/standalone-deployment-config.yaml" "$SA/deployment.yaml"
sed -e 's#^      port: 3000$#      port: 3210#' \
    -e 's#listen_address: 127.0.0.1:8080#listen_address: 127.0.0.1:18481#' \
    -e "s#^  base_folder: ./state\$#  base_folder: $DATA/state#" \
    -e "s#^      directory: \\.\$#      directory: $LOG/nodelog#" \
    "$NS/nodes/node/standalone-node-config.yaml" > "$SA/node.yaml"
chmod u+w "$SA"/*.yaml
echo "== config diff vs upstream standalone-node-config.yaml =="
diff "$NS/nodes/node/standalone-node-config.yaml" "$SA/node.yaml"
ps -eo pid,args | grep -E 'logos_host|logoscore' | grep -v grep && echo "WARNING: logos processes already running"

T0=$(date +%s%N)
setsid nohup "$STRACE" -f -ff --seccomp-bpf -e trace=openat,execve -o "$LOG/strace/tr" \
  "$L" --config-dir "$CFG" -D -m "$MODS" --persistence-path "$PERSIST" > "$LOG/daemon.log" 2>&1 < /dev/null &
SPID=$!
echo "$SPID" > "$LOG/strace.pid"
for i in $(seq 1 150); do lc status --json > /dev/null 2>&1 && break; sleep 0.2; done
echo "daemon up after $(( ($(date +%s%N) - T0) / 1000000 )) ms"
timed load-module blockchain_module
HP=$(host_pid blockchain_module)
echo "blockchain_module host pid: $HP"
sample "$HP" loaded
setsid nohup "$L" --config-dir "$CFG" watch blockchain_module --json > "$LOG/events.jsonl" 2> "$LOG/watch.err" < /dev/null &
WPID=$!
sleep 1

echo "== start (standalone node config + standalone deployment) =="
T2=$(date +%s%N)
timed call blockchain_module start "$SA/node.yaml" "$SA/deployment.yaml"
echo "start wall: $(( ($(date +%s%N) - T2) / 1000000 )) ms"
sample "$HP" started
timed call blockchain_module get_time_info
timed call blockchain_module get_chain_id
echo "== sockets / ports of the host after start =="
ss -tulpn 2>/dev/null | grep "pid=$HP,"
cp "/proc/$HP/maps" "$LOG/host.maps"
PROBE=0
if [ -d "$MODS/bc_probe" ]; then
  echo "== inter-module: load bc_probe (declares dependencies [blockchain_module]) =="
  timed load-module bc_probe
  BP=$(host_pid bc_probe)
  echo "bc_probe host pid: $BP"
  timed call bc_probe ping
  timed call bc_probe chain_info_via_bc
  timed call bc_probe time_info_via_bc
  PROBE=1
fi

# poll loop
END=$(( $(date +%s) + DURATION ))
N=0
while [ "$(date +%s)" -lt "$END" ]; do
  sleep 15
  N=$((N + 1))
  CI=$(lc call blockchain_module get_cryptarchia_info 2>&1 | tr -d '\n ' | cut -c1-300)
  echo "$(date +%T) poll=$N cryptarchia=$CI"
  sample "$HP" "poll=$N"
  echo "$(date +%T) poll=$N data_bytes=$(du -sb "$DATA" | cut -f1) nodelog_bytes=$(du -sb "$LOG/nodelog" | cut -f1) daemonlog_bytes=$(stat -c %s "$LOG/daemon.log") events=$(wc -l < "$LOG/events.jsonl") newBlock=$(grep -c newBlock "$LOG/events.jsonl") processedBlock=$(grep -c processedBlock "$LOG/events.jsonl") libBlock=$(grep -c libBlock "$LOG/events.jsonl")"
  if [ $((N % 8)) = 0 ]; then
    CLIP=300 timed call blockchain_module get_network_info
    CLIP=300 timed call blockchain_module wallet_get_balance e3635f207984ae779cf76b5f20714b514373f61ff96260879fe0a6d71f2dce07
  fi
  if [ "$PROBE" = 1 ] && [ $((N % 4)) = 0 ]; then
    CLIP=300 timed call bc_probe height_via_bc
  fi
done
if [ "$PROBE" = 1 ]; then
  echo "== inter-module: final probe calls =="
  timed call bc_probe chain_info_via_bc
  timed call bc_probe network_info_via_bc
  timed call bc_probe height_via_bc
  t0=$(date +%s%N)
  for i in $(seq 1 20); do lc call bc_probe height_via_bc > /dev/null 2>&1; done
  echo "20 CLI calls bc_probe.height_via_bc (each = CLI->bc_probe->blockchain_module) took $(( ($(date +%s%N) - t0) / 1000000 )) ms total"
  echo "== unix stream connections held by the bc_probe host =="
  ss -xpn 2>/dev/null | grep "pid=$BP," | awk '{print $5, $6, $7, $8, $NF}'
  sample "$BP" bc_probe
fi

echo "== end-of-run read-only calls =="
timed call blockchain_module get_cryptarchia_info
TIP=$(lc call blockchain_module get_cryptarchia_info 2>/dev/null | grep -o '"tip[^,]*' | grep -o '[0-9a-f]\{64\}' | head -1)
echo "tip=$TIP"
CLIP=3000 timed call blockchain_module get_block "$TIP"
CLIP=1500 timed call blockchain_module get_block_events "$TIP"
timed call blockchain_module get_time_info
timed call blockchain_module get_network_info
timed call blockchain_module blend_info
timed call blockchain_module wallet_get_known_addresses
for A in $(lc call blockchain_module wallet_get_known_addresses 2>/dev/null | grep -o '[0-9a-f]\{64\}'); do
  CLIP=300 timed call blockchain_module wallet_get_balance "$A"
done
CLIP=2000 timed call blockchain_module wallet_get_leader_aged_notes ""
CLIP=1000 timed call blockchain_module wallet_get_claimable_vouchers
timed call blockchain_module pow_claimable_rewards
echo "== ports =="
ss -tulpn 2>/dev/null | grep "pid=$HP,"
echo "== established inet conns of host =="
ss -tunp 2>/dev/null | grep "pid=$HP," | head -20
echo "== open files of host (non socket/pipe) =="
ls -l "/proc/$HP/fd" 2>/dev/null | awk '{print $NF}' | grep -v -E '^(socket|pipe|anon_inode)' | sort | uniq -c | sort -rn | head -40
cp "/proc/$HP/maps" "$LOG/host.maps.end"
cp "/proc/$HP/status" "$LOG/host.status.end"
echo "== data dir tree =="
find "$DATA" -maxdepth 4 -printf '%s\t%p\n' | head -60
du -sb "$DATA"/state/* 2>/dev/null

echo "== stop node =="
T3=$(date +%s%N)
timed call blockchain_module stop
echo "stop wall: $(( ($(date +%s%N) - T3) / 1000000 )) ms"
sample "$HP" stopped
kill "$WPID" 2>/dev/null
echo "events: $(wc -l < "$LOG/events.jsonl") lines; first 2000 bytes:"; head -c 2000 "$LOG/events.jsonl"; echo
echo "== stop daemon =="
timed stop
for i in $(seq 1 100); do kill -0 "$SPID" 2>/dev/null || break; sleep 0.2; done
kill -0 "$SPID" 2>/dev/null && echo "strace/daemon $SPID STILL RUNNING" || echo "daemon (strace $SPID) exited"
echo "leftover:"; ps -eo pid,ppid,args | grep -E 'logos_host|logoscore|strace' | grep -v grep | cut -c1-160
ls -la "$SOCK"
echo "== $RUN end $(date -Is) =="
