#!/usr/bin/env bash
# bc-android-build: cargo build -p logos-blockchain-c for an Android target, then inspect the .so.
# Sourced by bc-android-build-cargo-<arch>.sh with T (rust triple), ARCH (lbc-android/<ARCH>),
# RS (iden3 rapidsnark android dir name) set.
set -u
EXP=${REPO_ROOT}/.work/experiments/bc-android-build
SRC="$EXP/src/logos-blockchain"
OUT="$EXP/out/$T${VARIANT:+-$VARIANT}"
API=34
NDK=${HOME}/android-ndk/android-ndk-r27c
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
SYSROOT="$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
mkdir -p "$EXP/logs" "$OUT"
exec > >(tee "$EXP/logs/cargo-$T${VARIANT:+-$VARIANT}.log") 2>&1
echo "== $(date -Is) target=$T api=$API rev=$(git -C "$SRC" rev-parse HEAD)"

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
export "CARGO_TARGET_${TU}_RUSTFLAGS=-C link-arg=-Wl,-z,max-page-size=16384"
if [ "${VARIANT:-}" = "stdcxxshim" ]; then
  # librocksdb-sys (and unpatched lbc-build) emit -lstdc++ for *linux* targets. Put a one-line linker
  # script named libstdc++.so first on the search path so -lstdc++ resolves to libc++_shared instead of
  # the NDK's minimal system libstdc++.so.
  SHIM="$EXP/android-stdcxx-shim"
  mkdir -p "$SHIM"
  echo 'INPUT(-lc++_shared)' > "$SHIM/libstdc++.so"
  export "CARGO_TARGET_${TU}_RUSTFLAGS=-C link-arg=-Wl,-z,max-page-size=16384 -L native=$SHIM"
fi
export "BINDGEN_EXTRA_CLANG_ARGS_${Tl}=--sysroot=$SYSROOT"
export LIBCLANG_PATH=/usr/lib64
export ANDROID_NDK_HOME="$NDK"
export ANDROID_NDK_ROOT="$NDK"
export LBC_ROOT_DIR="$EXP/lbc-android/$ARCH"
export RAPIDSNARK_LIB_DIR="$EXP/inputs/$RS/lib"
env | grep -E "^(CC_|CXX_|AR_|RANLIB_|CARGO_TARGET_|BINDGEN|LIBCLANG|LBC_|RAPIDSNARK)" | sort

cd "$SRC" || exit 1
git status --short
echo "== cargo build"
START=$(date +%s)
cargo build -p logos-blockchain-c --release --target "$T" 2>&1 | tee "$OUT/cargo-build.txt" | grep -v '^\s*Compiling\|^\s*Downloaded\|^\s*Downloading\|^\s*Updating\|^\s*Locking\|^\s*Adding'
RC=${PIPESTATUS[0]}
END=$(date +%s)
echo "cargo-exit=$RC build-seconds=$((END-START))"
echo "compiled crates: $(grep -c '^\s*Compiling' "$OUT/cargo-build.txt")"
git -C "$SRC" status --short
git -C "$SRC" diff --stat

SO="$CARGO_TARGET_DIR/$T/release/liblogos_blockchain.so"
if [ "$RC" -ne 0 ] || [ ! -f "$SO" ]; then
  echo "BUILD FAILED"
  grep -n -B5 -A40 '^error' "$OUT/cargo-build.txt" | head -250
  exit 1
fi

echo "== artifact"
cp "$SO" "$OUT/liblogos_blockchain.so"
"$TC/llvm-strip" --strip-all -o "$OUT/liblogos_blockchain.stripped.so" "$SO"
stat -c '%n %s' "$OUT/liblogos_blockchain.so" "$OUT/liblogos_blockchain.stripped.so"
cp "$SRC/c-bindings/logos_blockchain.h" "$OUT/"
sha256sum "$OUT/liblogos_blockchain.so" "$OUT/logos_blockchain.h"

echo "== header"
"$TC/llvm-readelf" -h "$OUT/liblogos_blockchain.so" | grep -E 'Class|Machine|Type'
echo "== dynamic section"
"$TC/llvm-readelf" -d "$OUT/liblogos_blockchain.so" | grep -E 'NEEDED|SONAME|RUNPATH|RPATH|FLAGS|TEXTREL'
echo "== program headers"
"$TC/llvm-readelf" -lW "$OUT/liblogos_blockchain.so" | grep -E 'Type|LOAD|GNU_RELRO|GNU_STACK|TLS'
echo "== sections"
"$TC/llvm-size" -A "$OUT/liblogos_blockchain.so" | grep -E '^\.(text|rodata|data\.rel\.ro|data|bss|eh_frame|gcc_except_table|dynsym)|Total'

echo "== exported symbols vs header"
"$TC/llvm-nm" -D --defined-only "$OUT/liblogos_blockchain.so" | awk '$2 ~ /^[TtWw]$/ {print $3}' | sort > "$OUT/exports-all.txt"
python3 - "$OUT/logos_blockchain.h" "$OUT/exports-all.txt" <<'PY' > "$OUT/header-vs-exports.txt"
import re, sys
hdr = open(sys.argv[1]).read()
hdr = re.sub(r'/\*.*?\*/', '', hdr, flags=re.S)
hdr = re.sub(r'//[^\n]*', '', hdr)
# function prototypes: identifier followed by '(' at top level ending with ');'
funcs = set(re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*)\s*\([^;{]*\)\s*;', hdr))
funcs -= {"if", "while", "for", "return", "sizeof"}
exp = set(open(sys.argv[2]).read().split())
print(f"header functions: {len(funcs)}; exported T/W symbols: {len(exp)}")
print(f"header functions exported: {len(funcs & exp)}")
print("header functions NOT exported:", sorted(funcs - exp))
extra = sorted(e for e in exp if e not in funcs)
print(f"exported but not in header: {len(extra)} (first 40): {extra[:40]}")
PY
cat "$OUT/header-vs-exports.txt"

echo "== undefined dynamic symbols vs NDK API ${API} stub libs"
"$TC/llvm-nm" -D --undefined-only "$OUT/liblogos_blockchain.so" | awk '{print $2}' | sed 's/@.*//' | sort -u > "$OUT/undefined.txt"
wc -l < "$OUT/undefined.txt"
L="$SYSROOT/usr/lib/$T"
: > "$OUT/provided.txt"
for lib in "$L/$API/libc.so" "$L/$API/libm.so" "$L/$API/libdl.so" "$L/$API/liblog.so" "$L/libc++_shared.so" "$L/$API/libstdc++.so"; do
  "$TC/llvm-nm" -D --defined-only "$lib" 2>/dev/null | awk '{print $3}' | sed 's/@.*//' >> "$OUT/provided.txt"
done
sort -u -o "$OUT/provided.txt" "$OUT/provided.txt"
echo "undefined not provided by libc/libm/libdl/liblog/libc++_shared/libstdc++ (API ${API}):"
comm -23 "$OUT/undefined.txt" "$OUT/provided.txt" | grep -v '^__cxa_finalize$\|^__cxa_atexit$\|^__register_atfork$\|^_ITM_\|^__gmon_start__$' | head -40

echo "== native-lib provenance (strings)"
"$TC/llvm-nm" -D "$OUT/liblogos_blockchain.so" | grep -c -E 'rocksdb' | sed 's/^/rocksdb dyn syms: /'
"$TC/llvm-strings" -n 8 "$OUT/liblogos_blockchain.so" > "$OUT/strings.txt"
echo "zkey magic 'zkey' count: $(grep -c -a '^zkey' "$OUT/liblogos_blockchain.so")"
echo "strings mentioning /nix/store: $(grep -c '/nix/store' "$OUT/strings.txt")"
echo "strings mentioning $EXP: $(grep -c "$EXP" "$OUT/strings.txt")"
echo "strings mentioning /home/: $(grep -c '/home/' "$OUT/strings.txt")"
echo "strings mentioning resolv.conf: $(grep -c 'resolv.conf' "$OUT/strings.txt")"
du -sh "$CARGO_TARGET_DIR"
echo DONE
