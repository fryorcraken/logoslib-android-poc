#!/usr/bin/env bash
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# desktop-probe: byte length of each socket path from run3 vs the 108-byte sun_path limit.
set -u
D=${REPO_ROOT}/.work/probe/sock
for n in logos_capability_module_d5e35d7d4eea logos_modules_state_d5e35d7d4eea logos_core_service_d5e35d7d4eea logos_lez_core_d5e35d7d4eea logos_lez_probe_d5e35d7d4eea; do
  p="$D/$n"
  echo "${#p} bytes  $p"
done
echo "typical Android cache dir example: /data/user/0/com.example.logoslib/cache/logos_capability_module_d5e35d7d4eea -> $(printf '%s' /data/user/0/com.example.logoslib/cache/logos_capability_module_d5e35d7d4eea | wc -c) bytes"
