#!/usr/bin/env bash
# bc-android-build step 3: build the Bedrock circuit witness-generator libs + GMP for Android
# (x86_64 and aarch64) the way the circuits CI does it, and assemble an Android LBC_ROOT_DIR
# whose data files (zkey / vkey / .dat) come from the v0.5.7 linux-x86_64 release bundle.
set -u
EXP=${REPO_ROOT}/.work/experiments/bc-android-build
CS="$EXP/src/logos-blockchain-circuits"
CIRCOM="$EXP/tools/circom/bin/circom"
NDK=${HOME}/android-ndk/android-ndk-r27c
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
API=34
REL="$EXP/inputs/logos-blockchain-circuits-v0.5.7-linux-x86_64"
GEN="$EXP/build/circuits-gen"
BLD="$EXP/build/circuits"
LBC="$EXP/lbc-android"
JSON_INC="$CS/rapidsnark/depends/json/single_include"
mkdir -p "$EXP/logs" "$GEN" "$BLD" "$LBC" "$EXP/patches"
exec > >(tee "$EXP/logs/circuits.log") 2>&1
echo "== $(date -Is) circuits"
T0=$(date +%s)
"$CIRCOM" --version
git -C "$CS" log -1 --format='circuits %H %d'
git -C "$CS" diff > "$EXP/patches/circuits-01-witness-makefile-android-lib.diff"
cat "$EXP/patches/circuits-01-witness-makefile-android-lib.diff"

echo "== GMP 6.2.1 for Android (rapidsnark/build_gmp.sh android_x86_64 + android)"
cd "$CS/rapidsnark/depends" || exit 1
if [ ! -f gmp-6.2.1.tar.xz ]; then
  for u in https://ftp.gnu.org/gnu/gmp/gmp-6.2.1.tar.xz https://gmplib.org/download/gmp/gmp-6.2.1.tar.xz https://ftpmirror.gnu.org/gmp/gmp-6.2.1.tar.xz; do
    curl -fsSL --retry 3 --connect-timeout 20 -o gmp-6.2.1.tar.xz "$u" && break
  done
fi
sha256sum gmp-6.2.1.tar.xz
# pre-extract once so the two concurrent build_gmp.sh runs do not race in get_gmp()
if [ ! -d gmp ]; then tar -xf gmp-6.2.1.tar.xz && mv gmp-6.2.1 gmp; fi
cd "$CS/rapidsnark" || exit 1
export ANDROID_NDK="$NDK"
G0=$(date +%s)
( ./build_gmp.sh android_x86_64 > "$EXP/logs/gmp-android_x86_64.log" 2>&1; echo "gmp android_x86_64 exit=$?" ) &
( sleep 2; ./build_gmp.sh android > "$EXP/logs/gmp-android_arm64.log" 2>&1; echo "gmp android(arm64) exit=$?" ) &

echo "== circom C++ generation (host, arch independent)"
CALCFIX="$CS/.github/resources/witness-generator/fix_calcwit_leak.sh"
gen() {
  local name=$1 dir=$2 file=$3 stem=${3%.circom}
  local out="$GEN/$name"
  rm -rf "$out"; mkdir -p "$out"
  ( cd "$CS/$dir" && "$CIRCOM" --c --r1cs --no_asm --O2 "$file" --output "$out" ) > "$EXP/logs/circom-$name.log" 2>&1
  echo "circom $name exit=$? ($(grep -E 'non-linear|linear constraints|wires' "$EXP/logs/circom-$name.log" | tr '\n' ' '))"
  local cpp="$out/${stem}_cpp"
  sed -i ':a;N;$!ba;s/\n}\n\n*$/\n  return 0;\n}/' "$cpp/main.cpp"
  sh "$CALCFIX" "$cpp"
  cp -r "$CS/src/$name" "$cpp/$name"
  cp "$CS/src/circom_adapter.cpp" "$CS/src/circom_adapter.hpp" "$CS/src/circom_fwd.hpp" "$CS/src/types.hpp" "$CS/src/assert.h" "$cpp/"
  cp "$CS/.github/resources/witness-generator/Makefile" "$cpp/Makefile"
  echo "dat $name: gen=$(sha256sum < "$cpp/$stem.dat" | cut -c1-16) release=$(sha256sum < "$REL/$name/witness_generator.dat" | cut -c1-16)"
  ls -la "$cpp" | awk '{print "   ", $5, $9}' | grep -E '\.(cpp|dat)$'
}
gen poc mantle poc.circom
gen pol mantle pol.circom
gen poq blend poq.circom
gen signature mantle signature.circom
wait
echo "gmp seconds=$(( $(date +%s) - G0 ))"
for p in package_android_x86_64 package_android_arm64; do
  ls -la "$CS/rapidsnark/depends/gmp/$p/lib/libgmp.a" "$CS/rapidsnark/depends/gmp/$p/include/gmp.h"
  grep -E 'define GMP_LIMB_BITS|define __GMP_CFLAGS|define __GMP_CC ' "$CS/rapidsnark/depends/gmp/$p/include/gmp.h"
done
tail -3 "$EXP/logs/gmp-android_x86_64.log" "$EXP/logs/gmp-android_arm64.log"

echo "== witness libs (NDK clang++ ${API}, libc++)"
build_arch() {
  local arch=$1 triple=$2 gmppkg=$3
  local gmp="$CS/rapidsnark/depends/gmp/$gmppkg"
  for spec in poc:poc pol:pol poq:poq signature:signature; do
    local name=${spec%%:*}
    local src="$GEN/$name/${name}_cpp"
    local dst="$BLD/$arch/$name"
    rm -rf "$dst"; mkdir -p "$dst"; cp -r "$src/." "$dst/"
    ( make -C "$dst" -j4 PROJECT="$name" android-lib \
        CXX="$TC/${triple}${API}-clang++" LD="$TC/ld.lld" AR="$TC/llvm-ar" OBJCOPY="$TC/llvm-objcopy" \
        PRIORITY_FLAGS="-I$gmp/include -I$JSON_INC" > "$EXP/logs/witness-$arch-$name.log" 2>&1
      echo "make $arch $name exit=$?" ) &
  done
  wait
}
W0=$(date +%s)
build_arch x86_64 x86_64-linux-android package_android_x86_64 &
build_arch aarch64 aarch64-linux-android package_android_arm64 &
wait
echo "witness seconds=$(( $(date +%s) - W0 ))"
grep -h -i -E 'error|warning: .*(implicit|incompatible)' "$EXP"/logs/witness-*.log | sort | uniq -c | sort -rn | head -20

echo "== assemble Android LBC_ROOT_DIR (data files from release v0.5.7)"
for arch in x86_64 aarch64; do
  case $arch in x86_64) gmppkg=package_android_x86_64;; aarch64) gmppkg=package_android_arm64;; esac
  R="$LBC/$arch"
  rm -rf "$R"; mkdir -p "$R/lib"
  cp "$REL/VERSION" "$R/VERSION"
  cp "$CS/rapidsnark/depends/gmp/$gmppkg/lib/libgmp.a" "$R/lib/libgmp.a"
  for name in poc pol poq signature; do
    mkdir -p "$R/$name/include"
    cp "$BLD/$arch/$name/lib$name.a" "$R/$name/" || echo "MISSING lib$name.a for $arch"
    cp "$REL/$name/proving_key.zkey" "$REL/$name/verification_key.json" "$REL/$name/witness_generator.dat" "$R/$name/"
    cp "$REL/$name/include/"* "$R/$name/include/"
  done
  echo "-- $R"
  find "$R" -type f -printf '%P %s\n' | sort
  echo "-- file / symbols ($arch)"
  for name in poc pol poq signature; do
    A="$R/$name/lib$name.a"
    [ -f "$A" ] || continue
    "$TC/llvm-readelf" -h "$A" 2>/dev/null | grep -m1 Machine
    echo "global defined in lib$name.a: $("$TC/llvm-nm" --defined-only -g "$A" 2>/dev/null | grep -v ':$' | awk '{print $3}' | tr '\n' ' ')"
    echo "undefined __ndk1 refs: $("$TC/llvm-nm" -u -C "$A" | grep -c '__ndk1')  __cxx11 refs: $("$TC/llvm-nm" -u -C "$A" | grep -c '__cxx11')  __gmp refs: $("$TC/llvm-nm" -u "$A" | grep -c '__gmp')"
  done
  "$TC/llvm-readelf" -h "$R/lib/libgmp.a" 2>/dev/null | grep -m1 Machine
done
echo "-- data files identical to release: $(cd "$REL" && find poc pol poq signature -type f ! -name '*.a' ! -path '*/include/*' -exec sha256sum {} + | (cd "$LBC/x86_64" && sha256sum -c --quiet - && echo yes))"
echo "total seconds=$(( $(date +%s) - T0 ))"
du -sh "$EXP/build" "$LBC" "$CS/rapidsnark/depends/gmp"
echo DONE
