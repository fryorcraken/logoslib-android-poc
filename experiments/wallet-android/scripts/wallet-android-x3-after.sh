#!/usr/bin/env bash
# wallet-android X3 (after patch 01): cargo tree diff, native crate list, inverse trees.
set -u
EXP=${REPO_ROOT}/.work/experiments/wallet-android
LEZ="$EXP/lez"
OUT="$EXP/out"
exec > >(tee "$EXP/logs/x3-after.log") 2>&1
export CARGO_TARGET_DIR="$EXP/target"
cd "$LEZ" || exit 1
T=x86_64-linux-android
TREE="cargo tree --offline -p wallet-ffi --no-default-features --target $T -e normal,build"

echo "== cargo tree AFTER (updates Cargo.lock offline)"
$TREE --prefix none > "$OUT/tree-after-raw.txt" 2> "$OUT/tree-after.stderr"
echo "exit=$?"
tail -5 "$OUT/tree-after.stderr"
sed -e 's/ (\*)$//' -e 's/ (proc-macro)$//' "$OUT/tree-after-raw.txt" | sort -u > "$OUT/tree-after.txt"
wc -l "$OUT/tree-before.txt" "$OUT/tree-after.txt"

echo "== patch 01 diff"
git diff --stat
git diff > "$EXP/patches/01-common-drop-bedrock-http-client.diff"
wc -l "$EXP/patches/01-common-drop-bedrock-http-client.diff"

echo "== tree diff (before -> after), paths normalised"
diff "$OUT/tree-before.txt" "$OUT/tree-after.txt" > "$OUT/tree-diff.txt"
grep -c '^<' "$OUT/tree-diff.txt"
grep -c '^>' "$OUT/tree-diff.txt"
grep '^>' "$OUT/tree-diff.txt"

echo "== remaining bedrock-ish crates AFTER (expect none)"
grep -E -i 'logos-blockchain|lbc|rapidsnark|gmp|circuits-(poc|pol|poq|signature|build|common|types|prover)' "$OUT/tree-after.txt"
echo "grep-exit=$?"

echo "== native crates AFTER"
cargo metadata --offline --format-version 1 --filter-platform $T > "$OUT/metadata-after.json" 2>/dev/null
python3 ${REPO_ROOT}/.work/scripts/wallet-android-nativecrates.py \
  "$OUT/metadata-after.json" "$OUT/tree-after.txt" > "$OUT/native-after.txt"
cat "$OUT/native-after.txt"

echo "== inverse trees for interesting crates"
for c in pcsc-sys ring jni-sys@0.3.1 jni-sys@0.4.1 rustls-platform-verifier netlink-sys quinn dirs-sys risc0-circuit-recursion risc0-zkvm reqwest jsonrpsee-http-client hyper-rustls openssl-sys; do
  echo "--- -i $c"
  $TREE -i "$c" --depth 4 2>&1 | head -25
done

echo "== features reaching risc0 crates (is 'prove' on anywhere?)"
cargo tree --offline -p wallet-ffi --no-default-features --target $T -e features -i risc0-circuit-recursion --depth 2 2>&1 | head -40
cargo tree --offline -p wallet-ffi --no-default-features --target $T -e features -i risc0-zkvm --depth 2 2>&1 | head -40
cargo tree --offline -p wallet-ffi --no-default-features --target $T -e features -i lee --depth 1 2>&1 | head -20

echo "== same with default features (prove) for reference"
cargo tree --offline -p wallet-ffi --target $T -e normal,build --prefix none 2>/dev/null | sed -e 's/ (\*)$//' -e 's/ (proc-macro)$//' | sort -u > "$OUT/tree-after-prove.txt"
wc -l "$OUT/tree-after-prove.txt"
diff "$OUT/tree-after.txt" "$OUT/tree-after-prove.txt" | grep '^>' | head -80
echo DONE
