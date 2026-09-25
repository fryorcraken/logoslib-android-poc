#!/usr/bin/env bash
# wallet-android: final comparisons + stop the emulator this task started.
set -u
EXP=${REPO_ROOT}/.work/experiments/wallet-android
LEZ="$EXP/lez"
OUT="$EXP/out"
TC=${HOME}/android-ndk/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64/bin
exec > >(tee "$EXP/logs/final.log") 2>&1
export CARGO_TARGET_DIR="$EXP/target"
cd "$LEZ" || exit 1

echo "== desktop lez_core libwallet_ffi.so (825d2a4 lgx, default features incl. prove)"
D=${REPO_ROOT}/.work/probe/modules/lez_core/libwallet_ffi.so
stat -L -c '%n %s' "$D"
"$TC/llvm-readelf" -SW "$D" | grep -E ' \.(rodata|text) '
"$TC/llvm-readelf" -d "$D" | grep NEEDED
echo -n "zip local-file headers: "; grep -c -a -P 'PK\x03\x04' "$D"
echo -n "recursion_zkr refs: "; grep -c -a 'recursion_zkr' "$D"
echo -n "exported wallet_ffi_*: "; "$TC/llvm-nm" -D --defined-only "$D" | grep -c ' T wallet_ffi_'

echo "== cargo tree: webpki-roots variant vs no-feature (x86_64-linux-android)"
cargo tree --offline -p wallet-ffi --no-default-features --features webpki-roots --target x86_64-linux-android \
  -e normal,build --prefix none 2>/dev/null | sed -e 's/ (\*)$//' -e 's/ (proc-macro)$//' | sort -u > "$OUT/tree-webpki.txt"
wc -l < "$OUT/tree-webpki.txt"
diff "$OUT/tree-after.txt" "$OUT/tree-webpki.txt"
echo -n "aws-lc crates in webpki tree: "; grep -c 'aws-lc' "$OUT/tree-webpki.txt"
cargo tree --offline -p wallet-ffi --no-default-features --features webpki-roots --target x86_64-linux-android \
  -e features -i rustls --depth 1 2>/dev/null | head -20

echo "== cargo tree: aarch64 native crates (should equal x86_64 list)"
cargo tree --offline -p wallet-ffi --no-default-features --target aarch64-linux-android \
  -e normal,build --prefix none 2>/dev/null | sed -e 's/ (\*)$//' -e 's/ (proc-macro)$//' | sort -u > "$OUT/tree-after-aarch64.txt"
diff "$OUT/tree-after.txt" "$OUT/tree-after-aarch64.txt" | head -20
echo "tree-diff-exit=$?"

echo "== git state of working copy"
git -C "$LEZ" log -1 --format='%H %s'
git -C "$LEZ" status --short
ls -la "$EXP/patches"

echo "== stop emulator started by this task"
adb emu kill 2>&1 | tail -1
sleep 5
adb devices
echo DONE
