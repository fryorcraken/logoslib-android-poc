#!/usr/bin/env bash
# lgx-icu: resolve which logos-package (liblgx) revision logos-package-manager
# d88abaa (pinned by liblogos) and 2c56ec7 (the probe's lgpm) lock, and whether
# /nix/store/7f6d5ba9...-source is one of them. Copies the matching source.
set -u
EXP=${REPO_ROOT}/.work/experiments/lgx-icu
mkdir -p "$EXP/logs" "$EXP/patches" "$EXP/meta"
LOG="$EXP/logs/revs.log"
exec > >(tee "$LOG") 2>&1

CAND=/nix/store/7f6d5ba9jv4hkn2r923kxjxac271i5hn-source
LGPM_BIN=/nix/store/7rrg4ql1g94nmn5ylfsx6bv2gfh0nxws-logos-package-manager-cli-1.0.0-dev

lock_lp() {
  # $1 = flake.lock path; prints every logos-package-manager node and the
  # logos-package node it resolves to (following 'follows' paths), plus the
  # root's own logos-package input if any.
  python3 - "$1" <<'EOF'
import json, sys
lock = json.load(open(sys.argv[1]))
nodes = lock['nodes']
root = lock.get('root', 'root')
def resolve(inp):
    if isinstance(inp, str):
        return inp
    n = root
    for p in inp:
        n = resolve(nodes[n]['inputs'][p])
    return n
def show(label, nodename):
    l = nodes[nodename].get('locked', {})
    print(f"  {label}: node={nodename} rev={l.get('rev')} narHash={l.get('narHash')}")
ri = nodes[root].get('inputs', {})
if 'logos-package' in ri:
    show('root.inputs.logos-package', resolve(ri['logos-package']))
for name, node in nodes.items():
    l = node.get('locked', {})
    if l.get('repo') == 'logos-package-manager':
        lp = node.get('inputs', {}).get('logos-package')
        print(f" lpm node {name} rev={l.get('rev')}")
        if lp is not None:
            show('  -> logos-package', resolve(lp))
EOF
}

echo "== 1. liblogos (local checkout) flake.lock"
git -C ${HOME}/src/logos-co/logos-liblogos log -1 --format='%h %cI %s'
lock_lp ${HOME}/src/logos-co/logos-liblogos/flake.lock

echo
echo "== 2. local logos-package-manager checkout"
git -C ${HOME}/src/logos-co/logos-package-manager log -1 --format='%H %cI %s'
lock_lp ${HOME}/src/logos-co/logos-package-manager/flake.lock

for REV in d88abaa1f3f5d4a4268d7cdfbec98d816e0a0385 2c56ec7bf1e187523d6ed0cb2abde04737c24414; do
  echo
  echo "== 3. nix flake metadata github:logos-co/logos-package-manager/$REV"
  nix --extra-experimental-features 'nix-command flakes' flake metadata --json \
    "github:logos-co/logos-package-manager/$REV" > "$EXP/meta/lpm-$REV.json" 2> "$EXP/meta/lpm-$REV.err"
  echo "exit=$?"
  P=$(jq -r '.path' "$EXP/meta/lpm-$REV.json" 2>/dev/null)
  echo "source path: $P"
  jq -r '"lastModified=\(.lastModified) rev=\(.revision // .locked.rev)"' "$EXP/meta/lpm-$REV.json" 2>/dev/null
  if [ -n "$P" ] && [ -f "$P/flake.lock" ]; then
    cp "$P/flake.lock" "$EXP/meta/lpm-$REV.flake.lock"
    lock_lp "$P/flake.lock"
  else
    cat "$EXP/meta/lpm-$REV.err"
  fi
done

echo
echo "== 4. prefetch every distinct logos-package rev seen and map to store paths"
REVS=$(cat "$LOG" | grep -o 'logos-package: node=[^ ]* rev=[0-9a-f]*' | sed 's/.*rev=//' | sort -u)
echo "distinct logos-package revs: $REVS"
for R in $REVS; do
  OUT=$(nix --extra-experimental-features 'nix-command flakes' flake prefetch --json "github:logos-co/logos-package/$R" 2>&1)
  SP=$(echo "$OUT" | jq -r '.storePath' 2>/dev/null)
  echo "  $R -> ${SP:-ERROR: $OUT}"
  if [ "$SP" = "$CAND" ]; then echo "     ^^^ MATCHES candidate $CAND"; fi
done

echo
echo "== 5. lgpm probe binary closure: liblgx / logos-package paths"
nix-store -qR "$LGPM_BIN" | grep -i -e lgx -e logos-package
DRV=$(nix-store -q --deriver "$LGPM_BIN")
echo "deriver: $DRV"
if [ -e "$DRV" ]; then
  nix --extra-experimental-features 'nix-command flakes' derivation show -r "$DRV" > "$EXP/meta/lgpm-drv-closure.json" 2>/dev/null
  python3 - "$EXP/meta/lgpm-drv-closure.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
if isinstance(d, dict) and 'derivations' in d:
    d = d['derivations']
for path, drv in d.items():
    name = drv.get('name') or drv.get('env', {}).get('name', '')
    if 'lgx' in name.lower() or 'logos-package' in name.lower() and 'manager' not in name.lower():
        env = drv.get('env', {})
        print(' ', path, 'name=', name, 'src=', env.get('src'))
EOF
else
  echo "deriver .drv not present locally"
fi

echo
echo "== 6. every logos-package source tree in the store (has src/lgx.h + platform_variant.cpp)"
for d in /nix/store/*-source; do
  if [ -f "$d/src/lgx.h" ] && [ -f "$d/src/core/path_normalizer.cpp" ]; then
    pv=$(sha256sum "$d/src/core/platform_variant.cpp" 2>/dev/null | cut -c1-12)
    pn=$(sha256sum "$d/src/core/path_normalizer.cpp" | cut -c1-12)
    cm=$(sha256sum "$d/CMakeLists.txt" | cut -c1-12)
    hv=$(grep -c hostVariant "$d/src/core/platform_variant.cpp" 2>/dev/null)
    echo "  $d pv=$pv pn=$pn cmake=$cm hostVariant_refs=$hv"
  fi
done
