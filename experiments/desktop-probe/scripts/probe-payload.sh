#!/usr/bin/env bash
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# desktop-probe: measure the native payload actually mapped by the running daemon + module hosts.
# Source of truth = /proc/<pid>/maps of each live process (what the loader really pulled in).
set -u
P=${REPO_ROOT}/.work/probe
OUT="$P/logs/payload"
mkdir -p "$OUT"
DPID=$(cat "$P/logs/run/daemon.pid")
PIDS="$DPID $(pgrep -P "$DPID" | tr '\n' ' ')"
echo "pids: $PIDS"
: > "$OUT/all.txt"
for pid in $PIDS; do
  name=$(tr '\0' ' ' < /proc/$pid/cmdline | awk '{for(i=1;i<=NF;i++) if($i=="--name"){print $(i+1); exit}}')
  [ -z "$name" ] && name=daemon
  awk '{print $6}' /proc/$pid/maps | grep -E '\.so' | sort -u > "$OUT/$name.txt"
  cat "$OUT/$name.txt" >> "$OUT/all.txt"
  tot=0; n=0
  while read -r f; do s=$(stat -L -c %s "$f"); tot=$((tot + s)); n=$((n + 1)); done < "$OUT/$name.txt"
  echo "process=$name pid=$pid mapped_so_count=$n mapped_so_bytes=$tot ($((tot / 1048576)) MiB)  exe=$(readlink /proc/$pid/exe)"
done
sort -u "$OUT/all.txt" > "$OUT/union.txt"
echo
echo "== UNION of all mapped .so across daemon + hosts =="
tot=0
while read -r f; do s=$(stat -L -c %s "$f"); tot=$((tot + s)); printf '%11d  %s\n' "$s" "$f"; done < "$OUT/union.txt" | sort -n -r | tee "$OUT/union-sized.txt"
echo
awk '{t+=$1} END {printf "UNION total: %d files, %d bytes (%.1f MiB)\n", NR, t, t/1048576}' "$OUT/union-sized.txt"
echo
echo "== grouped =="
awk '{
  f=$2; g="other";
  if (f ~ /lez_core_plugin/) g="lez_core plugin";
  else if (f ~ /libwallet_ffi/) g="lez_core wallet_ffi (Rust)";
  else if (f ~ /qt-6\/plugins/) g="Qt plugins";
  else if (f ~ /libQt6/) g="Qt6 libs";
  else if (f ~ /liblogos|logos_host|capability_module|modules_state|liblgx|package_manager/) g="logos runtime";
  else if (f ~ /boost/) g="boost";
  else if (f ~ /openssl|libssl|libcrypto/) g="openssl";
  else if (f ~ /glibc|libc\.so|libm\.so|ld-linux|libpthread|libdl|librt/) g="glibc";
  else if (f ~ /gcc|libstdc|libgcc/) g="libstdc++/libgcc";
  else if (f ~ /icu/) g="icu";
  s[g]+=$1; c[g]++
} END { for (g in s) printf "%-30s %3d files %10d bytes (%.1f MiB)\n", g, c[g], s[g], s[g]/1048576 }' "$OUT/union-sized.txt" | sort -k4 -n -r
echo
echo "== lez_core host only: its own mapped set =="
tot=0
while read -r f; do s=$(stat -L -c %s "$f"); printf '%11d  %s\n' "$s" "$f"; done < "$OUT/lez_core.txt" | sort -n -r | head -60
echo
echo "== logos_host binary + logos libs =="
ls -laL /nix/store/7jcna50jgjmzx28nk6a14x5y6f5dwlrb-logos-liblogos/bin/ /nix/store/7jcna50jgjmzx28nk6a14x5y6f5dwlrb-logos-liblogos/lib/ 2>&1
