#!/usr/bin/env bash
# bc-surface step 3: deepen the release tags so their fork point from master is visible.
set -u
W=${REPO_ROOT}/.work
EXP=$W/experiments/bc-surface
PIN=35a4a666e22a51eb98fe8a050854e57fe3420899
LB_URL=https://github.com/logos-blockchain/logos-blockchain.git
TAGS=$EXP/src/tags.git
exec > >(tee "$EXP/logs/rel2.log") 2>&1
echo "== $(date -Is) bc-surface-rel2"
git -C "$TAGS" fetch -q --deepen=60 "$LB_URL" "refs/tags/0.3.0-rc.4:refs/tags/0.3.0-rc.4" "refs/tags/0.2.4:refs/tags/0.2.4" || echo "deepen failed"
for T in 0.3.0-rc.4 0.2.4; do
  MB=$(git -C "$TAGS" merge-base "$PIN" "$T" 2>/dev/null)
  echo "-- $T merge-base(pin,$T)=${MB:-none}"
  [ -n "$MB" ] || continue
  git -C "$TAGS" log -1 --format='   mb: %h %ci %s' "$MB"
  git -C "$TAGS" merge-base --is-ancestor "$PIN" "$T" && echo "   pin IS an ancestor of $T"
  echo "   commits on $T not on pin: $(git -C "$TAGS" rev-list --count "$PIN..$T")"
  git -C "$TAGS" log --oneline "$PIN..$T" | head -12
  echo "   commits on pin not on $T: $(git -C "$TAGS" rev-list --count "$T..$PIN")"
  git -C "$TAGS" log --oneline "$T..$PIN" | head -30
  echo "   c-bindings diff pin..$T:"
  git -C "$TAGS" diff --stat "$PIN" "$T" -- c-bindings | tail -12
  echo "   node/services/core/zk diffstat pin..$T:"
  git -C "$TAGS" diff --shortstat "$PIN" "$T" -- nodes services core zk blend consensus ledger libp2p
done
echo "-- master tip:"
git -C "$TAGS" log -1 --format='%h %ci %s' refs/remotes/origin/master
echo "== DONE $(date -Is)"
