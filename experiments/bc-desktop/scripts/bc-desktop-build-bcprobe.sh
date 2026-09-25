#!/usr/bin/env bash
# bc-desktop: dry-run then build the tiny bc_probe module (.lgx) that calls blockchain_module via
# the generated modules().blockchain_module client, then install it next to blockchain_module.
set -u
source ${REPO_ROOT}/.work/scripts/bc-desktop-common.sh
F="path:$E/src/bc_probe"
LOG="$E/logs"
{
nix build --dry-run "$F#lgx" > "$LOG/bcprobe-dryrun.txt" 2>&1
echo "dry-run exit=$?"
grep -n -E 'will be built|will be fetched|error' "$LOG/bcprobe-dryrun.txt" | head
awk '/will be built/{f=1;next} /will be fetched/{f=0} f' "$LOG/bcprobe-dryrun.txt" | sed 's#.*/[a-z0-9]\{32\}-##'
echo "== build =="
T0=$(date +%s)
nix build -L --cores 8 --max-jobs 2 "$F#lgx" -o "$E/bcprobe-lgx" > "$LOG/bcprobe-build.txt" 2>&1
RC=$?
echo "build exit=$RC in $(( $(date +%s) - T0 )) s"
grep -n -i -E 'error|blockchain_module|logos_sdk' "$LOG/bcprobe-build.txt" | head -40
tail -n 25 "$LOG/bcprobe-build.txt"
ls -laL "$E/bcprobe-lgx" 2>&1
if [ "$RC" = 0 ]; then
  rm -rf "$MODS/bc_probe"
  "$LGPM" --modules-dir "$MODS" --allow-unsigned install --file "$E"/bcprobe-lgx/*.lgx
  echo "lgpm exit=$?"
  ls -la "$MODS/bc_probe"; cat "$MODS/bc_probe/manifest.json"; echo
  readelf -d "$MODS"/bc_probe/*.so | grep -E 'NEEDED|RUNPATH'
fi
} 2>&1 | tee "$LOG/bcprobe-summary.txt"
