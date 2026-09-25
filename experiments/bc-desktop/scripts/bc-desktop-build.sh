#!/usr/bin/env bash
# bc-desktop: build the blockchain_module .lgx at the fresh rev 4b07e58, time it, record closure sizes.
set -u
E=${REPO_ROOT}/.work/experiments/bc-desktop
LOG="$E/logs"
mkdir -p "$LOG"
F='github:logos-blockchain/logos-blockchain-module/4b07e58b8ae9bfea3e953f234c97d1f276e799a0'
{
echo "== start $(date -Is) =="
df -h / | tail -1
T0=$(date +%s)
nix build -L --cores 8 --max-jobs 2 "$F#lgx" -o "$E/blockchain-lgx" > "$LOG/lgx-build.txt" 2>&1
RC=$?
T1=$(date +%s)
echo "lgx build exit=$RC wall=$(( T1 - T0 )) s"
df -h / | tail -1
tail -n 30 "$LOG/lgx-build.txt"
if [ "$RC" = 0 ]; then
  echo "== build the plain module lib output too (should be cached now) =="
  nix build --cores 8 --max-jobs 2 "$F#default" -o "$E/blockchain-lib" 2>&1 | tail -5
  echo "== outputs =="
  ls -laL "$E/blockchain-lgx" "$E/blockchain-lib"
  echo "== closure sizes =="
  nix path-info -Sh "$E/blockchain-lgx" "$E/blockchain-lib"
  echo "== lgx closure paths =="
  nix path-info -rSh "$E/blockchain-lgx" | sort -k2 -h | tail -20
  echo "== lib closure: largest 25 paths =="
  nix path-info -rsh "$E/blockchain-lib" | sort -k2 -h | tail -25
  echo "== logos_blockchain derivation(s) built in this run (from log) =="
  grep -E "^(building|copying path)" "$LOG/lgx-build.txt" | grep -i -E 'blockchain|circuit|rapidsnark' | head -40
fi
echo "== end $(date -Is) =="
} 2>&1 | tee "$LOG/build-summary.txt"
