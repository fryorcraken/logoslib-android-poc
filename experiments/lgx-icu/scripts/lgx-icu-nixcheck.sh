#!/usr/bin/env bash
# lgx-icu: build logos-package 4cdb302 (upstream, unpatched) and the patched
# copy with their own flake (#all = CLI + liblgx + full ctest suite) on the
# desktop, to prove the ICU C-API port + CMake change keep every upstream test
# green and that liblgx then needs only libicuuc (no libicui18n).
set -u
EXP=${REPO_ROOT}/.work/experiments/lgx-icu
mkdir -p "$EXP/logs" "$EXP/out"
LOG="$EXP/logs/nixcheck.log"
exec > >(tee "$LOG") 2>&1
NIX="nix --extra-experimental-features nix-command --extra-experimental-features flakes"

run() { # label flakeref
  echo "== $1: $2"
  local start=$(date +%s)
  $NIX build "$2#all" --no-link --print-out-paths -L > "$EXP/out/nix-$1.out" 2> "$EXP/logs/nix-$1.build.log"
  local rc=$?
  echo "exit=$rc after $(( $(date +%s) - start ))s; out=$(cat "$EXP/out/nix-$1.out")"
  grep -e 'tests passed' -e 'tests failed' -e 'Total Test time' -e '\*\*\*Failed' -e 'error:' "$EXP/logs/nix-$1.build.log" | tail -8
  local o=$(cat "$EXP/out/nix-$1.out")
  if [ -n "$o" ] && [ -e "$o/lib/liblgx.so" ]; then
    echo "-- $1 liblgx.so NEEDED:"; readelf -d "$o/lib/liblgx.so" | grep NEEDED
    echo "-- $1 liblgx.so ICU imports (count, sample):"
    nm -D --undefined-only "$o/lib/liblgx.so" | grep -c -e '_76' ; nm -D --undefined-only "$o/lib/liblgx.so" | grep -e '_76' | sed 's/^ *//' | head -12
  fi
}

run upstream "github:logos-co/logos-package/4cdb302051ebcd231eeaeeaa2011fcf857541ce4"
run patched "path:$EXP/src/logos-package-4cdb302"
