#!/usr/bin/env bash
# bc-desktop: block until run2 logs its end marker (max ~25 min), then print the tail.
set -u
F=${REPO_ROOT}/.work/experiments/bc-desktop/logs/run2/run.log
for i in $(seq 1 1500); do
  if grep -q '== run2 end ' "$F" 2>/dev/null; then echo "run2 finished"; exit 0; fi
  sleep 1
done
echo "timeout; tail:"; tail -n 5 "$F"
