#!/usr/bin/env bash
# bc-desktop: full tag list + testnet candidates (the release that points at 65.109.51.37).
set -u
E=${REPO_ROOT}/.work/experiments/bc-desktop
LOG="$E/logs"
D="$E/deployments"
mkdir -p "$LOG" "$D"
{
git ls-remote --tags https://github.com/logos-blockchain/logos-blockchain > "$D/ls-remote-tags.txt"
echo "== all tags (version-sorted) =="
awk '{print $2}' "$D/ls-remote-tags.txt" | grep -v '\^{}' | sed 's#refs/tags/##' | sort -V | tr '\n' ' '; echo
for T in v0.3 v0.2 0.2.3 0.3.0-rc.4; do
  U="https://raw.githubusercontent.com/logos-blockchain/logos-blockchain/$T/nodes/node/binary/src/config/deployment/settings.yaml"
  if curl -fsSL "$U" -o "$D/settings-$T.yaml"; then
    echo "--- $T: $(grep -m1 -o 'chain_sync_protocol_name: .*' "$D/settings-$T.yaml") | locator: $(grep -m1 -o '/ip4/[0-9.]*/udp/[0-9]*' "$D/settings-$T.yaml") | tx_ttl: $(grep -c tx_ttl "$D/settings-$T.yaml") | pow_config: $(grep -c pow_config "$D/settings-$T.yaml")"
  else
    echo "--- $T: no settings.yaml at that path"
  fi
done
echo "== commit dates of candidate tags =="
for T in v0.3 v0.2 0.3.0-rc.4; do
  C=$(grep "refs/tags/$T^{}" "$D/ls-remote-tags.txt" | awk '{print $1}')
  [ -n "$C" ] || C=$(grep "refs/tags/$T\$" "$D/ls-remote-tags.txt" | awk '{print $1}')
  echo "$T -> $C"
done
} 2>&1 | tee "$LOG/releases2.txt"
