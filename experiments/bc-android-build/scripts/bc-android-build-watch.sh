#!/usr/bin/env bash
# Emit one line when the x86_64 cargo build log reaches a terminal state (or shows an error), else progress every 5 min.
LOG=${REPO_ROOT}/.work/experiments/bc-android-build/logs/cargo-${WATCH_T:-x86_64-linux-android}.log
TXT=${REPO_ROOT}/.work/experiments/bc-android-build/out/${WATCH_T:-x86_64-linux-android}/cargo-build.txt
n=0
while true; do
  if grep -q -E '^DONE$|^BUILD FAILED$' "$LOG" 2>/dev/null; then
    grep -E 'cargo-exit=|BUILD FAILED|^DONE$' "$LOG"
    exit 0
  fi
  n=$((n+1))
  if [ $((n % 60)) -eq 0 ]; then
    echo "progress: $(grep -c '^\s*Compiling' "$TXT" 2>/dev/null) crates compiled; last: $(tail -1 "$TXT" 2>/dev/null)"
  fi
  sleep 5
done
