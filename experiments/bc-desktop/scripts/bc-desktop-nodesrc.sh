#!/usr/bin/env bash
# bc-desktop: locate the logos-blockchain source the module lock pins (35a4a666) and show its embedded
# default deployment (network identity: protocol names, genesis inscription, chain start).
set -u
E=${REPO_ROOT}/.work/experiments/bc-desktop
LOG="$E/logs"
mkdir -p "$LOG"
{
S=$(nix flake metadata --json 'github:logos-blockchain/logos-blockchain/35a4a666e22a51eb98fe8a050854e57fe3420899' 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["path"])')
echo "node source (35a4a666): $S"
echo "$S" > "$LOG/nodesrc.path"
D="$S/nodes/node/binary/src/config/deployment/settings.yaml"
echo "== $D (non-numeric-list lines) =="
grep -n -v -E '^\s+- [0-9]+$' "$D"
echo "== inscription decoded =="
grep -o "inscription: '[0-9a-f]*'" "$D" | sed "s/inscription: '//; s/'//" | xxd -r -p | strings -n 3
echo "== Cargo workspace version =="
grep -n -m3 '^version' "$S/Cargo.toml"
echo "== c-bindings Cargo.toml =="
cat "$S/c-bindings/Cargo.toml"
echo "== deployment ceremony inscribe files =="
for f in "$S"/deployment/ceremony/genesis/*/inscribe.yaml; do echo "--- $f"; cat "$f"; done
echo "== providers (bootstrap locators) =="
for f in "$S"/deployment/ceremony/genesis/*/providers.yaml; do echo "--- $f"; grep -n -E 'locator|/ip4|/dns' "$f" | head -10; done
echo "== .env files =="
ls -la "$S/deployment" | grep -i env
for f in "$S"/deployment/.env*; do echo "--- $f"; grep -v -E '^\s*#|^\s*$' "$f"; done
echo "== any testnet/devnet bootstrap multiaddrs in source =="
grep -rn -E '/p2p/12D3Koo' "$S" --include='*.yaml' --include='*.yml' --include='*.md' --include='*.rs' --include='*.env' 2>/dev/null | head -20
echo "== standalone configs =="
ls -la "$S/nodes/node/" | grep -i yaml
} 2>&1 | tee "$LOG/nodesrc.txt"
