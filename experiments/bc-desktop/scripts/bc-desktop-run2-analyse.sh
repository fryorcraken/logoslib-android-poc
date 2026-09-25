#!/usr/bin/env bash
# bc-desktop: digest run2 (standalone block production): distinct WARN/ERROR messages, leader/proof
# log lines, per-poll resource deltas (CPU cores used, RSS, data growth), events stats.
set -u
E=${REPO_ROOT}/.work/experiments/bc-desktop
R="$E/logs/run2"
{
echo "== daemon.log size / lines =="; stat -c %s "$R/daemon.log"; wc -l < "$R/daemon.log"
echo "== distinct WARN/ERROR messages from the node (ANSI stripped, timestamps/ids collapsed) =="
sed -E 's/\x1b\[[0-9;]*m//g' "$R/daemon.log" | grep -E ' (WARN|ERROR) ' | sed -E 's/^.*(WARN|ERROR) +//; s/[0-9a-f]{16,}/<hex>/g; s/[0-9]+/N/g' | sort | uniq -c | sort -rn | head -30
echo "== INFO lines mentioning leader / proposal / proof (collapsed) =="
sed -E 's/\x1b\[[0-9;]*m//g' "$R/daemon.log" | grep -i -E 'leader|propos|proof|winning|won' | sed -E 's/^.*(INFO|DEBUG) +//; s/[0-9a-f]{16,}/<hex>/g; s/[0-9]+/N/g' | sort | uniq -c | sort -rn | head -20
echo "== stderr lines from the module plugin itself (non-[out]) =="
grep -v '\[out\]' "$R/daemon.log" | sed -E 's/[0-9a-f]{16,}/<hex>/g' | cut -c1-200 | sort | uniq -c | sort -rn | head -15
echo "== per-poll resources: cores used between samples (100 ticks/s), RSS MB, data MB, blocks =="
awk '/ pid=.* cpu_ticks=/ && /poll=/ {
  split($0,a," "); t=a[1]; for(i=1;i<=NF;i++){ if($i ~ /^cpu_ticks=/){split($i,b,"=");c=b[2]} if($i ~ /^rss_kb=/){split($i,r,"=");rss=r[2]} if($i ~ /^poll=/){p=$i} }
  split(t,h,":"); s=h[1]*3600+h[2]*60+h[3];
  if (ps!="") printf "%s %s cores=%.2f rss_mb=%.0f\n", t, p, (c-pc)/100/(s-ps), rss/1024;
  ps=s; pc=c }' "$R/run.log" | awk 'NR%4==0'
echo "== average cores over the whole run =="
awk '/ pid=.* cpu_ticks=/ && /poll=/ { for(i=1;i<=NF;i++) if($i ~ /^cpu_ticks=/){split($i,b,"=");c=b[2]}; split($1,h,":"); s=h[1]*3600+h[2]*60+h[3]; if(fs==""){fs=s;fc=c}; ls=s; lc=c }
  END { printf "from %d to %d s: %.2f cores avg\n", fs, ls, (lc-fc)/100/(ls-fs) }' "$R/run.log"
echo "== events =="
echo "total: $(wc -l < "$R/events.jsonl")"
for ev in newBlock processedBlock libBlock; do
  echo "$ev: count=$(grep -c "\"event\":\"$ev\"" "$R/events.jsonl") avg_bytes=$(grep "\"event\":\"$ev\"" "$R/events.jsonl" | awk '{t+=length($0)} END {if (NR) printf "%d", t/NR}')"
done
echo "one libBlock event:"; grep -m1 '"event":"libBlock"' "$R/events.jsonl" | cut -c1-600
echo "== node file log =="
ls -la "$R/nodelog"
echo "== rapidsnark MyLogFile.log (moved) =="
ls -la "$R/MyLogFile.log"
} 2>&1 | tee "$R/analysis.txt"
