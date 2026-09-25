#!/usr/bin/env bash
# bc-desktop run3: can the master-built module (node 35a4a666) join the public devnet?
# Deployment = devnet 0.3.0-rc.4's embedded settings.yaml (+ tx_ttl, the one key master added);
# config generated through the module (explicit paths, NOT the instance dir, since run1 owns that keystore)
# with the devnet hosts as dial-only initial peers. Phase A: dial + learn peer ids from the node's HTTP
# API. Phase B: restart with those ids as IBD peers and watch sync.
set -u
source ${REPO_ROOT}/.work/scripts/bc-desktop-common.sh
RUN=run3
LOG="$E/logs/$RUN"
DD="$E/devnet-data"
rm -rf "$LOG" "$DD"; mkdir -p "$LOG/strace" "$DD"
exec > >(tee "$LOG/run.log") 2>&1
echo "== $RUN start $(date -Is) =="
DEP="$DD/deployment-devnet-0.3.0-rc.4.yaml"
cp "$E/deployments/settings-0.3.0-rc.4.yaml" "$DEP"
chmod u+w "$DEP"
grep -q 'tx_ttl' "$DEP" || printf "  tx_ttl: '86400.000000000'\n" >> "$DEP"
tail -n 3 "$DEP"
API=127.0.0.1:18482
# run2 showed rapidsnark writes MyLogFile.log into the host's cwd: keep the daemon's cwd in the run dir.
cd "$LOG" || exit 1

setsid nohup "$STRACE" -f -ff --seccomp-bpf -e trace=openat,execve -o "$LOG/strace/tr" \
  "$L" --config-dir "$CFG" -D -m "$MODS" --persistence-path "$PERSIST" > "$LOG/daemon.log" 2>&1 < /dev/null &
SPID=$!
for i in $(seq 1 150); do lc status --json > /dev/null 2>&1 && break; sleep 0.2; done
timed load-module blockchain_module
HP=$(host_pid blockchain_module)
echo "host pid $HP"
setsid nohup "$L" --config-dir "$CFG" watch blockchain_module --json > "$LOG/events.jsonl" 2> "$LOG/watch.err" < /dev/null &
WPID=$!

cat > "$LOG/gen-args.json" <<JSON
{
  "initial_peers": [
    "/ip4/65.108.203.235/udp/3000/quic-v1",
    "/ip4/65.108.203.235/udp/3001/quic-v1",
    "/ip4/65.108.203.235/udp/3002/quic-v1",
    "/ip4/65.108.203.235/udp/50001/quic-v1"
  ],
  "net_port": 3220,
  "blend_port": 3221,
  "http_addr": "$API",
  "output": "$DD/user_config.yaml",
  "kms_file": "$DD/keystore.yaml",
  "state_path": "$DD/state",
  "storage_path": "$DD/db",
  "logs_path": "$DD/logs"
}
JSON
timed call blockchain_module generate_user_config "@$LOG/gen-args.json"
UC="$DD/user_config.yaml"
ls -la "$DD"
grep -n -A6 'initial_peers' "$UC" | head -8
grep -n -A1 'ibd:' "$UC"

echo "== phase A: start against devnet deployment, dial-only peers =="
T2=$(date +%s%N)
timed call blockchain_module start "$UC" "$DEP"
echo "start wall: $(( ($(date +%s%N) - T2) / 1000000 )) ms"
timed call blockchain_module get_chain_id
for i in $(seq 1 6); do
  sleep 10
  CLIP=300 timed call blockchain_module get_network_info
  CLIP=300 timed call blockchain_module get_cryptarchia_info
  sample "$HP" "A t+$((i * 10))s"
done
echo "== HTTP API: /version /network/info =="
curl -s -m 5 "http://$API/version"; echo
curl -s -m 5 "http://$API/network/info" > "$LOG/network-info-A.json"; head -c 3000 "$LOG/network-info-A.json"; echo
PEERS=$(grep -o '12D3Koo[1-9A-HJ-NP-Za-km-z]*' "$LOG/network-info-A.json" | sort -u | tr '\n' ' ')
echo "peer ids seen: $PEERS"
ss -tunp 2>/dev/null | grep "pid=$HP," | head -20
timed call blockchain_module stop

if [ -n "$PEERS" ]; then
  echo "== phase B: restart with IBD peers =="
  LIST=$(echo "$PEERS" | sed 's/ *$//; s/ /, /g')
  awk -v L="$LIST" '{ if (prev ~ /ibd:$/ && $0 ~ /peers: \[\]/) { sub(/peers: \[\]/, "peers: [" L "]") } print; prev=$0 }' "$UC" > "$UC.tmp" && mv "$UC.tmp" "$UC"
  grep -n -A1 'ibd:' "$UC"
  T3=$(date +%s%N)
  timed call blockchain_module start "$UC" "$DEP"
  echo "start wall: $(( ($(date +%s%N) - T3) / 1000000 )) ms"
  for i in $(seq 1 20); do
    sleep 15
    CLIP=300 timed call blockchain_module get_cryptarchia_info
    CLIP=200 timed call blockchain_module get_network_info
    sample "$HP" "B t+$((i * 15))s"
    echo "   data_bytes=$(du -sb "$DD" | cut -f1) events=$(wc -l < "$LOG/events.jsonl")"
  done
  curl -s -m 5 "http://$API/network/info" > "$LOG/network-info-B.json"; head -c 1500 "$LOG/network-info-B.json"; echo
  timed call blockchain_module stop
fi
kill "$WPID" 2>/dev/null
echo "events: $(wc -l < "$LOG/events.jsonl")"; head -c 1500 "$LOG/events.jsonl"; echo
timed stop
for i in $(seq 1 100); do kill -0 "$SPID" 2>/dev/null || break; sleep 0.2; done
kill -0 "$SPID" 2>/dev/null && echo "strace/daemon $SPID STILL RUNNING" || echo "daemon (strace $SPID) exited"
echo "leftover:"; ps -eo pid,ppid,args | grep -E 'logos_host|logoscore|strace' | grep -v grep | cut -c1-160
echo "== node log lines of interest =="
grep -h -i -E 'ibd|chainsync|AllPeersFailed|peer|genesis|error|panic' "$LOG/daemon.log" | cut -c1-300 | head -80
echo "== $RUN end $(date -Is) =="
