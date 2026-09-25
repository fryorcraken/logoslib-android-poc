#!/usr/bin/env bash
# bc-desktop: which logos-blockchain releases exist, and what deployment (network) each embeds.
# Fetches the release tags' embedded settings.yaml (the node's default deployment) so we can try
# to point the master-built module at testnet/devnet with an explicit deployment file.
set -u
E=${REPO_ROOT}/.work/experiments/bc-desktop
LOG="$E/logs"
D="$E/deployments"
mkdir -p "$LOG" "$D"
{
echo "== remote tags (newest 15 by version sort) =="
git ls-remote --tags --refs https://github.com/logos-blockchain/logos-blockchain | awk '{print $2}' | sed 's#refs/tags/##' | sort -V | tail -15 | tee "$D/tags.txt"
REL=$(grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' "$D/tags.txt" | tail -1)
RC=$(grep -E '^[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$' "$D/tags.txt" | tail -1)
echo "latest release: $REL   latest rc: $RC"
for T in "$REL" "$RC"; do
  [ -n "$T" ] || continue
  U="https://raw.githubusercontent.com/logos-blockchain/logos-blockchain/$T/nodes/node/binary/src/config/deployment/settings.yaml"
  curl -fsSL "$U" -o "$D/settings-$T.yaml"
  echo "--- $T settings.yaml rc=$? size=$(stat -c %s "$D/settings-$T.yaml" 2>/dev/null)"
  grep -n -E 'protocol_name|gossipsub_protocol|pubsub_topic|faucet_pk|slot_duration' "$D/settings-$T.yaml"
  echo "inscription: $(grep -o "inscription: '[0-9a-f]*'" "$D/settings-$T.yaml" | sed "s/inscription: '//; s/'//" | xxd -r -p | strings -n 3 | head -1)"
  echo "locators:"; grep -n -A1 'locators:' "$D/settings-$T.yaml" | grep -E '/ip4|/dns' | head -6
  echo "top-level + 2nd-level keys vs master (35a4a666):"
  diff <(grep -E '^[a-z_]+:|^  [a-z_]+:' "$D/settings-$T.yaml") <(grep -E '^[a-z_]+:|^  [a-z_]+:' "$(cat "$LOG/nodesrc.path")/nodes/node/binary/src/config/deployment/settings.yaml") && echo "(same key skeleton)"
  curl -fsSL "https://raw.githubusercontent.com/logos-blockchain/logos-blockchain/$T/deployment/ceremony/genesis/testnet/inscribe.yaml" 2>/dev/null | grep -v '^#' | head -5
done
} 2>&1 | tee "$LOG/releases.txt"
