#!/usr/bin/env bash
# bc-surface step 2: relate the module-pinned node rev (35a4a666, master) to the
# public release tags, and read the module release tags' pins.
set -u
W=${REPO_ROOT}/.work
EXP=$W/experiments/bc-surface
PIN=35a4a666e22a51eb98fe8a050854e57fe3420899
LB_URL=https://github.com/logos-blockchain/logos-blockchain.git
LBM_URL=https://github.com/logos-blockchain/logos-blockchain-module.git
TAGS=$EXP/src/tags.git
MOD=$EXP/src/module.git
mkdir -p "$EXP/logs" "$EXP/out"
exec > >(tee "$EXP/logs/rel.log") 2>&1
echo "== $(date -Is) bc-surface-rel"

echo "== 1. node history since 2026-08-20 (master + release tags)"
git -C "$TAGS" fetch -q --shallow-since=2026-08-20 "$LB_URL" \
  "refs/heads/master:refs/remotes/origin/master" \
  "refs/tags/0.3.0-rc.4:refs/tags/0.3.0-rc.4" \
  "refs/tags/0.3.0-rc.3:refs/tags/0.3.0-rc.3" \
  "refs/tags/0.2.4:refs/tags/0.2.4" || echo "history fetch failed"
git -C "$TAGS" cat-file -e "$PIN^{commit}" 2>/dev/null && echo "pin present in history" || echo "pin NOT present"
for T in 0.3.0-rc.3 0.3.0-rc.4 0.2.4; do
  MB=$(git -C "$TAGS" merge-base "$PIN" "$T" 2>/dev/null)
  echo "-- $T: $(git -C "$TAGS" log -1 --format='%h %ci' "$T")  merge-base(pin,$T)=${MB:-none}"
  [ -n "$MB" ] && git -C "$TAGS" log -1 --format='   mb: %h %ci %s' "$MB"
  git -C "$TAGS" merge-base --is-ancestor "$T" "$PIN" 2>/dev/null && echo "   $T is ancestor of pin"
  git -C "$TAGS" merge-base --is-ancestor "$PIN" "$T" 2>/dev/null && echo "   pin is ancestor of $T"
  if [ -n "$MB" ]; then
    echo "   commits on $T not on pin: $(git -C "$TAGS" rev-list --count "$PIN..$T")"
    git -C "$TAGS" log --oneline "$PIN..$T" | head -15
    echo "   commits on pin not on $T: $(git -C "$TAGS" rev-list --count "$T..$PIN")"
    git -C "$TAGS" log --oneline "$T..$PIN" | head -40
    echo "   diffstat pin..$T (c-bindings, nodes/node, services, Cargo.lock):"
    git -C "$TAGS" diff --stat "$PIN" "$T" -- c-bindings nodes/node/binary/src services Cargo.lock Cargo.toml rust-toolchain.toml | tail -25
  fi
done

echo "== 2. module release tags"
[ -d "$MOD" ] || git init -q --bare "$MOD"
git -C "$MOD" fetch -q "$W/upstream/logos-blockchain-module" "refs/heads/*:refs/remotes/local/*" 2>/dev/null
git -C "$MOD" fetch -q --depth 1 "$LBM_URL" "refs/tags/0.3.0-rc.4:refs/tags/0.3.0-rc.4" "refs/tags/0.2.4:refs/tags/0.2.4" || echo "module tag fetch failed"
for T in 0.3.0-rc.4 0.2.4; do
  echo "---- module $T: $(git -C "$MOD" log -1 --format='%H %ci %s' "$T")"
  git -C "$MOD" show "$T:flake.nix" | grep -n -E 'logos-blockchain.url|logos-module-builder.url'
  git -C "$MOD" show "$T:flake.lock" | grep -n -A 14 '"logos-blockchain": {' | grep -E '"rev"|"ref"|lastModified'
  git -C "$MOD" show "$T:metadata.json" | grep -E '"version"|"name"'
  echo "   src diff tag..HEAD(4b07e58) stat:"
  git -C "$MOD" diff --stat "$T" 4b07e58b8ae9bfea3e953f234c97d1f276e799a0 -- src CMakeLists.txt metadata.json 2>&1 | tail -6
done
echo "== DONE $(date -Is)"
