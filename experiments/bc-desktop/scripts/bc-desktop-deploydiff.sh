#!/usr/bin/env bash
# bc-desktop: key-skeleton diff (all nesting levels, values dropped) between the devnet 0.3.0-rc.4
# deployment and the deployment schema the module's pinned node (35a4a666) embeds.
set -u
E=${REPO_ROOT}/.work/experiments/bc-desktop
D="$E/deployments"
M="$(cat "$E/logs/nodesrc.path")/nodes/node/binary/src/config/deployment/settings.yaml"
skel() { grep -v -E '^\s*#|^\s*- ' "$1" | grep -E '^\s*[a-z_A-Z]+:' | sed -E 's/:.*$/:/'; }
{
echo "== skeleton diff: < devnet-0.3.0-rc.4   > master-35a4a666 =="
diff <(skel "$D/settings-0.3.0-rc.4.yaml") <(skel "$M")
echo "== genesis tx ops in rc.4 (opcodes) =="
grep -n -E 'opcode:' "$D/settings-0.3.0-rc.4.yaml" | head -20
echo "== genesis time bytes? inscription line rc.4 =="
grep -n -E 'inscription' "$D/settings-0.3.0-rc.4.yaml" | cut -c1-200
} 2>&1 | tee "$E/logs/deploydiff.txt"
