#!/usr/bin/env bash
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# desktop-probe: install lez_core .lgx into .work/probe/modules with lgpm and inspect the result.
set -u
P=${REPO_ROOT}/.work/probe
mkdir -p "$P/modules"
echo "== lgpm --help (head) =="
"$P/lgpm/bin/lgpm" --help 2>&1 | head -40
echo "== install lez_core =="
time "$P/lgpm/bin/lgpm" --modules-dir "$P/modules" --allow-unsigned install --file "$P"/lez-lgx/*.lgx 2>&1
echo "== list =="
"$P/lgpm/bin/lgpm" --modules-dir "$P/modules" list 2>&1
echo "== tree =="
ls -laR "$P/modules/lez_core"
echo "== manifest =="
cat "$P/modules/lez_core/manifest.json"
echo
echo "== file / NEEDED / RUNPATH =="
for f in "$P"/modules/lez_core/*.so; do
  echo "--- $f"
  file "$f"
  readelf -d "$f" | grep -E 'NEEDED|RUNPATH|RPATH|SONAME'
done
