#!/usr/bin/env bash
# lgx-icu: follow-up: which lpm node is liblogos' DIRECT input, which liblgx
# source the probe's logoscore (6a0a2f4) was built from, how the candidate
# logos-package trees differ, then copy the matching source into the
# experiment dir.
set -u
EXP=${REPO_ROOT}/.work/experiments/lgx-icu
mkdir -p "$EXP/logs" "$EXP/meta"
LOG="$EXP/logs/revs2.log"
exec > >(tee "$LOG") 2>&1

CAND=/nix/store/7f6d5ba9jv4hkn2r923kxjxac271i5hn-source
LOGOSCORE=/nix/store/vhys5csf7rh78a3ikqkagwxdxqi0gm0h-logos-logoscore-cli

echo "== A. liblogos flake.lock: root input logos-package-manager and parents of every lpm node"
python3 - ${HOME}/src/logos-co/logos-liblogos/flake.lock <<'EOF'
import json, sys
lock = json.load(open(sys.argv[1])); nodes = lock['nodes']; root = lock['root']
def resolve(inp):
    if isinstance(inp, str): return inp
    n = root
    for p in inp: n = resolve(nodes[n]['inputs'][p])
    return n
ri = nodes[root]['inputs']
for k in sorted(ri):
    if 'package' in k:
        t = resolve(ri[k]); print(f"  root.{k} -> {t} rev={nodes[t].get('locked',{}).get('rev')}")
for name, node in nodes.items():
    for k, v in node.get('inputs', {}).items():
        t = resolve(v)
        if nodes[t].get('locked', {}).get('repo') == 'logos-package-manager':
            print(f"  {name} ({node.get('locked',{}).get('repo')}@{str(node.get('locked',{}).get('rev'))[:8]}).{k} -> {t} rev={nodes[t]['locked']['rev'][:8]}")
EOF

echo
echo "== B. the probe's logoscore (6a0a2f4) closure: which lgx-lib / liblgx it runs"
nix-store -qR "$LOGOSCORE" | grep -i -e lgx -e package-manager
LDRV=$(nix-store -q --deriver "$LOGOSCORE")
echo "deriver: $LDRV"
if [ -e "$LDRV" ]; then
  nix --extra-experimental-features 'nix-command flakes' derivation show -r "$LDRV" > "$EXP/meta/logoscore-drv-closure.json" 2>/dev/null
  python3 - "$EXP/meta/logoscore-drv-closure.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
if isinstance(d, dict) and 'derivations' in d: d = d['derivations']
for path, drv in d.items():
    name = drv.get('name') or drv.get('env', {}).get('name', '') or ''
    if name.startswith('lgx') or 'package-manager' in name:
        print(' ', path, 'name=', name, 'src=', drv.get('env', {}).get('src'))
EOF
fi

echo
echo "== C. candidate trees vs 7f6d5ba9 (4cdb302, lgpm 2c56ec7)"
echo "-- vs rdzzxz (542305b, local lpm checkout 40930aa):"
diff -rq "$CAND" /nix/store/rdzzxzbyjjf22gx3iypkc0655rl23cgf-source
echo "-- vs ias6bmsz (49151f0, lpm d88abaa):"
diff -rq "$CAND" /nix/store/ias6bmsz9p8vilcg0f473m03w4y0568n-source
echo "-- path_normalizer.cpp/.h identical across 7f6d5ba9 / 49151f0 / 542305b / 1eae01c / 3cb520c?"
sha256sum "$CAND/src/core/path_normalizer.cpp" /nix/store/ias6bmsz9p8vilcg0f473m03w4y0568n-source/src/core/path_normalizer.cpp \
  /nix/store/rdzzxzbyjjf22gx3iypkc0655rl23cgf-source/src/core/path_normalizer.cpp \
  /nix/store/416a5wqisqs500gc2yzjs7bamwbv0l9r-source/src/core/path_normalizer.cpp \
  /nix/store/418s1x65hgjgcw7yspxdf0i08qy2smka-source/src/core/path_normalizer.cpp
echo "-- where is the variant logic in 49151f0 (no platform_variant.cpp)?"
grep -rn -e "linux-x86_64" -e "linux-arm64" -e "__linux__" -e "__ANDROID__" /nix/store/ias6bmsz9p8vilcg0f473m03w4y0568n-source/src

echo
echo "== D. copy 7f6d5ba9 (logos-package 4cdb302) into the experiment dir"
rm -rf "$EXP/src"
mkdir -p "$EXP/src"
cp -r "$CAND" "$EXP/src/logos-package-4cdb302"
chmod -R u+w "$EXP/src/logos-package-4cdb302"
echo "4cdb302051ebcd231eeaeeaa2011fcf857541ce4 (github:logos-co/logos-package, locked by logos-package-manager 2c56ec7; store $CAND)" > "$EXP/src/logos-package-4cdb302/REVISION.lgx-icu"
ls "$EXP/src/logos-package-4cdb302"
