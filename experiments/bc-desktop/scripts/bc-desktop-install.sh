#!/usr/bin/env bash
# bc-desktop: install the blockchain_module .lgx with lgpm into .work/experiments/bc-desktop/modules,
# seed logoscore's built-in modules (as probe-daemon-start.sh does), inspect the installed payload.
set -u
source ${REPO_ROOT}/.work/scripts/bc-desktop-common.sh
{
echo "== lgx package =="
ls -laL "$E/blockchain-lgx"
LGX=$(ls "$E"/blockchain-lgx/*.lgx | head -1)
echo "lgx: $LGX size=$(stat -L -c %s "$LGX")"
echo "== lgx contents =="
tar -tzvf "$LGX"
echo "== seed built-in modules =="
cp -RL "$P/logos/modules/." "$MODS/"
chmod -R u+w "$MODS"
echo "== lgpm install =="
time "$LGPM" --modules-dir "$MODS" --allow-unsigned install --file "$LGX" 2>&1
echo "== lgpm list =="
"$LGPM" --modules-dir "$MODS" list 2>&1
echo "== modules dir =="
ls -la "$MODS" "$MODS/blockchain_module"
echo "== manifest =="
cat "$MODS/blockchain_module/manifest.json"; echo
cat "$MODS/blockchain_module/variant" 2>/dev/null; echo
echo "== file / NEEDED / RUNPATH / SONAME =="
for f in "$MODS"/blockchain_module/*.so*; do
  echo "--- $f ($(stat -c %s "$f") B)"
  file -L "$f"
  readelf -d "$f" | grep -E 'NEEDED|RUNPATH|RPATH|SONAME'
done
} 2>&1 | tee "$E/logs/install.txt"
