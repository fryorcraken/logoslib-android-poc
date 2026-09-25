#!/usr/bin/env bash
# wallet-android: build the "recommended" Android variant of wallet-ffi:
#   --no-default-features (no prove) + --features webpki-roots (patch 02)
#   + pcsc stub linked STATICALLY (PCSC_LIB_NAME=static=pcsclite) so the .so
#   has no NEEDED libpcsclite.so.
# Both android targets. Outputs under out/<target>-webpki/.
set -u
EXP=${REPO_ROOT}/.work/experiments/wallet-android
LEZ="$EXP/lez"
API=34
NDK=${HOME}/android-ndk/android-ndk-r27c
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
mkdir -p "$EXP/logs"
exec > >(tee "$EXP/logs/x5-webpki.log") 2>&1
export CARGO_TARGET_DIR="$EXP/target"
export RUSTFLAGS="-C link-arg=-Wl,-z,max-page-size=16384"
cd "$LEZ" || exit 1

for T in x86_64-linux-android aarch64-linux-android; do
  echo "================ $T  $(date -Is)"
  OUT="$EXP/out/$T-webpki"
  mkdir -p "$OUT" "$EXP/pcsc-stub/$T-static"
  TU=$(echo "$T" | tr 'a-z-' 'A-Z_')
  Tl=$(echo "$T" | tr '-' '_')
  CLANG="$TC/${T}${API}-clang"
  export "CC_${Tl}=$CLANG" "CXX_${Tl}=${CLANG}++" "AR_${Tl}=$TC/llvm-ar" "RANLIB_${Tl}=$TC/llvm-ranlib"
  export "CARGO_TARGET_${TU}_LINKER=$CLANG" "CARGO_TARGET_${TU}_AR=$TC/llvm-ar"

  echo "== static pcsc stub"
  "$CLANG" -c -fPIC -O2 -fvisibility=hidden -o "$EXP/pcsc-stub/$T-static/pcsclite_stub.o" "$EXP/pcsc-stub/pcsclite_stub.c"
  rm -f "$EXP/pcsc-stub/$T-static/libpcsclite.a"
  "$TC/llvm-ar" rcs "$EXP/pcsc-stub/$T-static/libpcsclite.a" "$EXP/pcsc-stub/$T-static/pcsclite_stub.o"
  export PCSC_LIB_DIR="$EXP/pcsc-stub/$T-static"
  export PCSC_LIB_NAME=static=pcsclite
  # pcsc-sys build.rs has no rerun-if-env-changed: force it to rerun.
  cargo clean -p pcsc-sys --release --target "$T" 2>&1 | tail -1

  echo "== cargo build (no-prove + webpki-roots + static pcsc)"
  START=$(date +%s)
  cargo build -p wallet-ffi --release --no-default-features --features webpki-roots --target "$T" > "$OUT/cargo-build.txt" 2>&1
  RC=$?
  END=$(date +%s)
  grep -v '^\s*Compiling\|^\s*Download' "$OUT/cargo-build.txt" | tail -40
  echo "cargo-exit=$RC build-seconds=$((END-START))"
  [ "$RC" -ne 0 ] && continue

  SO="$CARGO_TARGET_DIR/$T/release/libwallet_ffi.so"
  cp "$SO" "$OUT/libwallet_ffi.so"
  "$TC/llvm-strip" -o "$OUT/libwallet_ffi.stripped.so" "$SO"
  cp "$LEZ/lez/wallet-ffi/wallet_ffi.h" "$OUT/"
  stat -c '%n %s' "$OUT/libwallet_ffi.so" "$OUT/libwallet_ffi.stripped.so"
  gzip -9 -c "$OUT/libwallet_ffi.stripped.so" | wc -c
  "$TC/llvm-readelf" -d "$OUT/libwallet_ffi.stripped.so" | grep -E 'NEEDED'
  echo -n "exported wallet_ffi_*: "; "$TC/llvm-nm" -D --defined-only "$OUT/libwallet_ffi.stripped.so" | grep -c ' T wallet_ffi_'
  echo -n "dynamic SCard* (defined or undefined): "; "$TC/llvm-nm" -D "$OUT/libwallet_ffi.stripped.so" | grep -c 'SCard'
  "$TC/llvm-readelf" -lW "$OUT/libwallet_ffi.stripped.so" | grep -E 'LOAD'
  echo -n "webpki root CA names present (ISRG Root X1): "; grep -c -a 'ISRG Root X1' "$OUT/libwallet_ffi.stripped.so"
done

echo "== patch 02 diff (wallet + wallet-ffi + lock)"
git status --short
git diff -- lez/wallet/Cargo.toml lez/wallet/src/multi_client.rs lez/wallet-ffi/Cargo.toml > "$EXP/patches/02-wallet-webpki-roots-feature.diff"
git diff -- Cargo.lock
wc -l "$EXP/patches/02-wallet-webpki-roots-feature.diff"
git diff > "$EXP/patches/all-combined.diff"
wc -l "$EXP/patches/all-combined.diff"
echo DONE
