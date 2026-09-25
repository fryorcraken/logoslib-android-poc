#!/usr/bin/env bash
# bc-desktop: summarise the strace (openat/execve) captures of a run: what the daemon + module hosts
# executed and opened at runtime (circuit artefacts? config/data paths? certs? /proc?).
set -u
E=${REPO_ROOT}/.work/experiments/bc-desktop
for RUN in run1 run2 run3; do
  S="$E/logs/$RUN/strace"
  [ -d "$S" ] || continue
  O="$E/logs/$RUN/strace-summary.txt"
  {
  echo "== $RUN: $(ls "$S" | wc -l) per-task trace files =="
  echo "== execve (success) =="
  grep -h 'execve(' "$S"/tr.* | grep -v -E '= -1' | grep -o 'execve("[^"]*"' | sort | uniq -c
  grep -h -o 'openat([^"]*"[^"]*"[^)]*) = [-0-9]*' "$S"/tr.* | sed -E 's/^openat\([^"]*"([^"]*)".*= (-?[0-9]+)$/\2 \1/' | awk '{ok=($1>=0)?"OK":"ERR"; print ok, $2}' > "$E/logs/$RUN/opened.txt"
  echo "== opened OK: unique paths $(grep '^OK' "$E/logs/$RUN/opened.txt" | sort -u | wc -l), failed: $(grep '^ERR' "$E/logs/$RUN/opened.txt" | sort -u | wc -l) =="
  echo "== circuit / proving artefacts (zkey, .dat, verification key, circuits, rapidsnark, witness) =="
  grep -i -E 'zkey|\.dat$|verification_key|circuit|rapidsnark|witness|groth|\.wasm$' "$E/logs/$RUN/opened.txt" | sort | uniq -c
  echo "== paths outside /nix/store, /proc, /sys, /dev (data/config/state) =="
  awk '{print $2}' "$E/logs/$RUN/opened.txt" | grep -v -E '^/nix/store|^/proc|^/sys|^/dev' | sed -E 's#/[0-9a-f]{12}(/|$)#/<inst>\1#' | sort | uniq -c | sort -rn | head -60
  echo "== /proc and /sys paths (grouped) =="
  awk '{print $2}' "$E/logs/$RUN/opened.txt" | grep -E '^/proc|^/sys' | sed -E 's#/proc/[0-9]+#/proc/<pid>#; s#/task/[0-9]+#/task/<tid>#' | sort | uniq -c | sort -rn | head -25
  echo "== /etc and certs =="
  awk '{print $2}' "$E/logs/$RUN/opened.txt" | grep -E '^/etc|cert|ssl' | sort | uniq -c | sort -rn | head -20
  echo "== /nix/store: distinct store paths opened (top-level) =="
  awk '{print $2}' "$E/logs/$RUN/opened.txt" | grep '^/nix/store' | cut -d/ -f1-4 | sort | uniq -c | sort -rn | head -40
  } > "$O" 2>&1
  echo "wrote $O ($(wc -l < "$O") lines)"
done
