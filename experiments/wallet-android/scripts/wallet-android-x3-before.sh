#!/usr/bin/env bash
# wallet-android X3 (before patch): android targets + cargo tree of wallet-ffi.
set -u
EXP=${REPO_ROOT}/.work/experiments/wallet-android
LEZ="$EXP/lez"
OUT="$EXP/out"
mkdir -p "$EXP/logs" "$OUT"
exec > >(tee "$EXP/logs/x3-before.log") 2>&1
export CARGO_TARGET_DIR="$EXP/target"
cd "$LEZ" || exit 1

echo "== toolchain / targets"
rustup target add --toolchain 1.94.0 x86_64-linux-android aarch64-linux-android
rustc --version
cargo --version
rustup target list --toolchain 1.94.0 --installed

echo "== git status (must be clean)"
git status --short

echo "== cargo tree BEFORE (x86_64-linux-android)"
time cargo tree --locked -p wallet-ffi --no-default-features --target x86_64-linux-android \
  -e normal,build --prefix none > "$OUT/tree-before-raw.txt" 2> "$OUT/tree-before.stderr"
echo "exit=$?"
tail -20 "$OUT/tree-before.stderr"
sed -e 's/ (\*)$//' -e 's/ (proc-macro)$//' "$OUT/tree-before-raw.txt" | sort -u > "$OUT/tree-before.txt"
wc -l "$OUT/tree-before.txt"

echo "== cargo tree BEFORE with default features (prove) for reference"
cargo tree --locked -p wallet-ffi --target x86_64-linux-android \
  -e normal,build --prefix none 2>/dev/null | sed -e 's/ (\*)$//' -e 's/ (proc-macro)$//' | sort -u > "$OUT/tree-before-prove.txt"
wc -l "$OUT/tree-before-prove.txt"

echo "== cargo metadata (android filter)"
cargo metadata --locked --format-version 1 --filter-platform x86_64-linux-android > "$OUT/metadata-before.json" 2> "$OUT/metadata-before.stderr"
echo "exit=$?"
python3 ${REPO_ROOT}/.work/scripts/wallet-android-nativecrates.py \
  "$OUT/metadata-before.json" "$OUT/tree-before.txt" > "$OUT/native-before.txt"
cat "$OUT/native-before.txt"

echo "== bedrock-ish crates BEFORE"
grep -E -i '^(lbc|logos-blockchain|rust-rapidsnark|rapidsnark|gmp|circuits|groth16|witness)' "$OUT/tree-before.txt"
grep -i 'circuit\|rapidsnark\|gmp' "$OUT/tree-before.txt"

echo "== inverse: who pulls logos-blockchain-common-http-client"
cargo tree --locked -p wallet-ffi --no-default-features --target x86_64-linux-android \
  -e normal,build -i logos-blockchain-common-http-client --depth 3 2>&1 | head -30
echo DONE
