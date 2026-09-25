#!/usr/bin/env bash
# wallet-android X4 common body. Sourced by wallet-android-x4-<arch>.sh with
# T (rust target triple) and LOGNAME_SUFFIX set. Builds the pcsc stub, then
# cargo build -p wallet-ffi --release --no-default-features --target $T,
# then inspects the resulting .so.
set -u
EXP=${REPO_ROOT}/.work/experiments/wallet-android
LEZ="$EXP/lez"
OUT="$EXP/out/$T"
API=34
NDK=${HOME}/android-ndk/android-ndk-r27c
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
mkdir -p "$EXP/logs" "$OUT" "$EXP/pcsc-stub/$T"
exec > >(tee "$EXP/logs/x4-$LOGNAME_SUFFIX.log") 2>&1
echo "== $(date -Is) target=$T api=$API"

TU=$(echo "$T" | tr 'a-z-' 'A-Z_')
Tl=$(echo "$T" | tr '-' '_')
CLANG="$TC/${T}${API}-clang"
export CARGO_TARGET_DIR="$EXP/target"
export "CC_${Tl}=$CLANG"
export "CXX_${Tl}=${CLANG}++"
export "AR_${Tl}=$TC/llvm-ar"
export "RANLIB_${Tl}=$TC/llvm-ranlib"
export "CARGO_TARGET_${TU}_LINKER=$CLANG"
export "CARGO_TARGET_${TU}_AR=$TC/llvm-ar"
export RUSTFLAGS="-C link-arg=-Wl,-z,max-page-size=16384"
export ANDROID_NDK_HOME="$NDK"
export ANDROID_NDK_ROOT="$NDK"
env | grep -E "^(CC_|CXX_|AR_|RANLIB_|CARGO_TARGET_|RUSTFLAGS|PCSC)" | sort

echo "== pcsc stub"
"$CLANG" -shared -fPIC -O2 -fvisibility=hidden -Wl,-soname,libpcsclite.so \
  -Wl,-z,max-page-size=16384 -o "$EXP/pcsc-stub/$T/libpcsclite.so" "$EXP/pcsc-stub/pcsclite_stub.c"
echo "stub-exit=$?"
"$TC/llvm-nm" -D --defined-only "$EXP/pcsc-stub/$T/libpcsclite.so"
export PCSC_LIB_DIR="$EXP/pcsc-stub/$T"
export PCSC_LIB_NAME=pcsclite

cd "$LEZ" || exit 1
echo "== cargo build"
START=$(date +%s)
cargo build -p wallet-ffi --release --no-default-features --target "$T" 2>&1 | tee "$OUT/cargo-build.txt" | grep -v '^\s*Compiling\|^\s*Downloaded\|^\s*Downloading'
RC=${PIPESTATUS[0]}
END=$(date +%s)
echo "cargo-exit=$RC build-seconds=$((END-START))"
grep -c '^\s*Compiling' "$OUT/cargo-build.txt"
git -C "$LEZ" status --short

SO="$CARGO_TARGET_DIR/$T/release/libwallet_ffi.so"
if [ "$RC" -ne 0 ] || [ ! -f "$SO" ]; then
  echo "BUILD FAILED"
  grep -n -B2 -A20 '^error' "$OUT/cargo-build.txt" | head -150
  exit 1
fi

echo "== artifact"
ls -la "$CARGO_TARGET_DIR/$T/release/" | grep -i wallet_ffi
cp "$SO" "$OUT/libwallet_ffi.so"
"$TC/llvm-strip" -o "$OUT/libwallet_ffi.stripped.so" "$SO"
stat -c '%n %s' "$OUT/libwallet_ffi.so" "$OUT/libwallet_ffi.stripped.so"
cp "$LEZ/lez/wallet-ffi/wallet_ffi.h" "$OUT/" 2>/dev/null

echo "== file / header"
file "$OUT/libwallet_ffi.stripped.so"
"$TC/llvm-readelf" -h "$OUT/libwallet_ffi.stripped.so" | grep -E 'Class|Machine|Type'

echo "== NEEDED / SONAME / RUNPATH"
"$TC/llvm-readelf" -d "$OUT/libwallet_ffi.stripped.so" | grep -E 'NEEDED|SONAME|RUNPATH|RPATH|FLAGS'

echo "== exported wallet_ffi_* symbols"
"$TC/llvm-nm" -D --defined-only "$OUT/libwallet_ffi.stripped.so" | grep -c ' T wallet_ffi_'
"$TC/llvm-nm" -D --defined-only "$OUT/libwallet_ffi.stripped.so" | grep ' T wallet_ffi_' > "$OUT/exports.txt"
"$TC/llvm-nm" -D --defined-only "$OUT/libwallet_ffi.stripped.so" | grep -c ' [TtDdBbRrVvWw] '
echo "-- undefined dynamic symbols (count, then non-libc-looking sample)"
"$TC/llvm-nm" -D --undefined-only "$OUT/libwallet_ffi.stripped.so" > "$OUT/undefined.txt"
wc -l < "$OUT/undefined.txt"
grep -i 'scard\|jni\|java\|gmp\|__gmp\|rapidsnark\|witness' "$OUT/undefined.txt"

echo "== program headers (LOAD p_align)"
"$TC/llvm-readelf" -lW "$OUT/libwallet_ffi.stripped.so" | grep -E 'LOAD|GNU_RELRO|Type'

echo "== sections (sizes)"
"$TC/llvm-readelf" -SW "$OUT/libwallet_ffi.stripped.so" | grep -E ' \.(text|rodata|data\.rel\.ro|data|bss|eh_frame|gcc_except_table|dynsym|rela\.dyn) '
"$TC/llvm-size" -A "$OUT/libwallet_ffi.stripped.so" | grep -E 'rodata|text|Total'

echo "== recursion zkr presence"
"$TC/llvm-strings" -n 6 "$OUT/libwallet_ffi.stripped.so" > "$OUT/strings.txt"
echo -n "strings with 'recursion': "; grep -c -i 'recursion' "$OUT/strings.txt"
echo -n "strings with 'zkr': "; grep -c -i 'zkr' "$OUT/strings.txt"
echo -n "raw grep -c recursion_zkr: "; grep -c -a 'recursion_zkr' "$OUT/libwallet_ffi.stripped.so"
echo -n "zip local-file headers (PK\\x03\\x04): "; grep -c -a -P 'PK\x03\x04' "$OUT/libwallet_ffi.stripped.so"
echo -n "strings with 'pcsc'/'SCard': "; grep -c -i 'scard' "$OUT/strings.txt"
echo -n "strings with 'rustls-platform-verifier': "; grep -c -i 'platform-verifier\|platform_verifier' "$OUT/strings.txt"
echo -n "strings with 'circuit': "; grep -c -i 'circuit' "$OUT/strings.txt"
echo -n "strings with 'gmp': "; grep -c -i '__gmp' "$OUT/strings.txt"

echo "== guest ELFs embedded (risc0 program binaries)"
ls -la "$LEZ/artifacts/lez/programs" "$LEZ/artifacts/lee/privacy_preserving_circuit" | grep '\.bin'
echo DONE
