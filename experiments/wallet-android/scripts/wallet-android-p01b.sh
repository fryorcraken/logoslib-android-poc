#!/usr/bin/env bash
# wallet-android: verify patch 01b (feature-gated bedrock-auth in lez/common)
# keeps wallet-ffi free of Bedrock crates, keeps sequencer/indexer wired, and
# still builds for Android. Then host `cargo check` of sequencer_core+indexer_core.
set -u
EXP=${REPO_ROOT}/.work/experiments/wallet-android
LEZ="$EXP/lez"
OUT="$EXP/out"
NDK=${HOME}/android-ndk/android-ndk-r27c
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
exec > >(tee "$EXP/logs/p01b.log") 2>&1
export CARGO_TARGET_DIR="$EXP/target"
cd "$LEZ" || exit 1
T=x86_64-linux-android

echo "== diffs"
git status --short
git diff -- lez/common lez/sequencer/core/Cargo.toml lez/indexer/core/Cargo.toml > "$EXP/patches/01b-common-bedrock-auth-feature.diff"
git diff -- Cargo.lock
git diff > "$EXP/patches/all-combined.diff"
wc -l "$EXP/patches/01b-common-bedrock-auth-feature.diff" "$EXP/patches/all-combined.diff"

echo "== wallet-ffi tree (android, no-prove, webpki) must equal the 01 tree"
cargo tree --offline -p wallet-ffi --no-default-features --features webpki-roots --target $T \
  -e normal,build --prefix none 2>/dev/null | sed -e 's/ (\*)$//' -e 's/ (proc-macro)$//' | sort -u > "$OUT/tree-01b-webpki.txt"
diff "$OUT/tree-webpki.txt" "$OUT/tree-01b-webpki.txt"
echo "tree-diff-exit=$?"
echo -n "bedrock crates: "; grep -c -E 'logos-blockchain|rapidsnark|circuits-(poc|pol|poq|signature)' "$OUT/tree-01b-webpki.txt"

echo "== sequencer_core/indexer_core still get the conversion (host)"
cargo tree --offline -p sequencer_core -e features -i common --depth 1 2>/dev/null | grep -i 'bedrock-auth\|^common'
cargo tree --offline -p indexer_core -e features -i common --depth 1 2>/dev/null | grep -i 'bedrock-auth\|^common'

echo "== Android rebuild (no-prove + webpki + static pcsc stub)"
TU=$(echo "$T" | tr 'a-z-' 'A-Z_'); Tl=$(echo "$T" | tr '-' '_'); CLANG="$TC/${T}34-clang"
export "CC_${Tl}=$CLANG" "CXX_${Tl}=${CLANG}++" "AR_${Tl}=$TC/llvm-ar" "RANLIB_${Tl}=$TC/llvm-ranlib"
export "CARGO_TARGET_${TU}_LINKER=$CLANG" "CARGO_TARGET_${TU}_AR=$TC/llvm-ar"
export RUSTFLAGS="-C link-arg=-Wl,-z,max-page-size=16384"
export PCSC_LIB_DIR="$EXP/pcsc-stub/$T-static" PCSC_LIB_NAME=static=pcsclite
START=$(date +%s)
cargo build -p wallet-ffi --release --no-default-features --features webpki-roots --target $T 2>&1 | grep -v '^\s*Compiling' | tail -5
echo "android-build-exit=${PIPESTATUS[0]} seconds=$(( $(date +%s) - START ))"
cmp "$CARGO_TARGET_DIR/$T/release/libwallet_ffi.so" "$OUT/$T-webpki/libwallet_ffi.so" && echo "identical .so to the 01+02 build"

echo "== host cargo check sequencer_core + indexer_core (default features)"
unset RUSTFLAGS PCSC_LIB_DIR PCSC_LIB_NAME
START=$(date +%s)
timeout 1500 cargo check -p sequencer_core -p indexer_core > "$OUT/host-check.txt" 2>&1
RC=$?
grep -v '^\s*Compiling\|^\s*Checking\|^\s*Download' "$OUT/host-check.txt" | tail -30
echo "host-check-exit=$RC seconds=$(( $(date +%s) - START ))"
echo DONE
