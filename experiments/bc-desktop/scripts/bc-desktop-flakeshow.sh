#!/usr/bin/env bash
# bc-desktop: inspect the blockchain module flake at the fresh rev (outputs + what a #lgx build would do).
set -u
E=${REPO_ROOT}/.work/experiments/bc-desktop
LOG="$E/logs"
mkdir -p "$LOG" "$E/patches" "$E/src"
F='github:logos-blockchain/logos-blockchain-module/4b07e58b8ae9bfea3e953f234c97d1f276e799a0'
{
echo "== date =="; date -Is
echo "== df / =="; df -h / | tail -1
echo "== load / mem =="; uptime; free -g | head -2
echo "== nix version =="; nix --version
echo "== nix show-config (jobs/cores/substituters) =="
nix config show 2>/dev/null | grep -E '^(max-jobs|cores|substituters|trusted-users|sandbox) '
echo "== flake metadata =="
nix flake metadata "$F" 2>&1 | head -40
echo "== flake show =="
nix flake show "$F" 2>&1 | head -80
} 2>&1 | tee "$LOG/flakeshow.txt"

echo "== dry-run #lgx =="
nix build --dry-run "$F#lgx" > "$LOG/lgx-dryrun.txt" 2>&1
echo "dry-run exit=$?"
grep -n -E 'will be built|will be fetched|error' "$LOG/lgx-dryrun.txt" | head
echo "-- derivations to build (names):"
awk '/will be built/{f=1;next} /will be fetched/{f=0} f' "$LOG/lgx-dryrun.txt" | sed 's#.*/[a-z0-9]\{32\}-##' | tee "$LOG/lgx-tobuild.txt" | head -150
echo "count: $(wc -l < "$LOG/lgx-tobuild.txt")"
echo "-- paths to fetch: $(awk '/will be fetched/{f=1;next} f' "$LOG/lgx-dryrun.txt" | wc -l)"
grep -n -E 'will be fetched' "$LOG/lgx-dryrun.txt"
