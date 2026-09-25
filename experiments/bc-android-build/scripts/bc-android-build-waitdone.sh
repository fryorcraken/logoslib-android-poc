#!/usr/bin/env bash
# Block (max ~9 min) until the cargo build log for WATCH_T reaches DONE / BUILD FAILED; print status.
LOG=${REPO_ROOT}/.work/experiments/bc-android-build/logs/cargo-${WATCH_T:-x86_64-linux-android}.log
TXT=${REPO_ROOT}/.work/experiments/bc-android-build/out/${WATCH_T:-x86_64-linux-android}/cargo-build.txt
for i in $(seq 1 108); do
  if grep -q -E '^DONE$|^BUILD FAILED$' "$LOG" 2>/dev/null; then
    grep -E 'cargo-exit=|BUILD FAILED|^DONE$' "$LOG"
    exit 0
  fi
  sleep 5
done
echo "still running: $(grep -c '^\s*Compiling' "$TXT") crates; last: $(tail -1 "$TXT")"
