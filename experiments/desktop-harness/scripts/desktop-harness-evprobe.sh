#!/usr/bin/env bash
# desktop-harness (d): build the tiny ev_probe universal module (.lgx) with the same
# logos-module-builder rev as lez_probe, then install it with lgpm into the harness modules dir.
set -u
W=${REPO_ROOT}/.work
E=$W/experiments/desktop-harness
P=$W/probe
SRC=$E/src/ev_probe
LOG=$E/logs
mkdir -p "$LOG" "$E/modules"
exec > >(tee "$LOG/evprobe-build.log") 2>&1

# Reuse lez_probe's lock so the builder (and its SDK/Qt closure) resolve to the same store paths.
if [ ! -f "$SRC/flake.lock" ]; then
  cp "$P/src/lez_probe/flake.lock" "$SRC/flake.lock"
  chmod u+w "$SRC/flake.lock"
fi

T0=$(date +%s)
nix build -L "path:$SRC#lgx" -o "$E/evprobe-lgx" > "$LOG/evprobe-nix.log" 2>&1
RC=$?
echo "nix build exit=$RC in $(( $(date +%s) - T0 )) s"
grep -n -i 'error\|Generated LIDL\|events' "$LOG/evprobe-nix.log" | head -40
tail -n 15 "$LOG/evprobe-nix.log"
ls -laL "$E/evprobe-lgx" 2>&1
[ $RC -eq 0 ] || exit $RC

rm -rf "$E/modules/ev_probe"
"$P/lgpm/bin/lgpm" --modules-dir "$E/modules" --allow-unsigned install --file "$E"/evprobe-lgx/*.lgx
echo "lgpm exit=$?"
ls -la "$E/modules/ev_probe"
cat "$E/modules/ev_probe/manifest.json"
echo
find -L "$E/evprobe-lgx" -maxdepth 3 | head -20
