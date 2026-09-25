#!/usr/bin/env bash
# wallet-android: emit progress lines from the p01b log until it prints DONE.
LOG=${REPO_ROOT}/.work/experiments/wallet-android/logs/p01b.log
until grep -q '^DONE' "$LOG" 2>/dev/null; do
  sleep 5
done
grep -E 'exit=|identical|seconds=' "$LOG"
