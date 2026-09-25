#!/usr/bin/env bash
# Inspect the iden3 rapidsnark v0.0.8 android prebuilts (PIC-ness, C++ ABI, gmp) and compare gmp builds.
set -u
EXP=${REPO_ROOT}/.work/experiments/bc-android-build
TC=${HOME}/android-ndk/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64/bin
exec > >(tee "$EXP/logs/rsinspect.log") 2>&1
for a in x86_64 arm64; do
  D="$EXP/inputs/rapidsnark-android-$a-v0.0.8/lib"
  echo "=== $a"
  for f in librapidsnark.a libfr.a libfq.a libgmp.a; do
    echo "-- $f members=$("$TC/llvm-ar" t "$D/$f" | wc -l)"
    "$TC/llvm-readelf" -h "$D/$f" 2>/dev/null | grep -m1 Machine
    echo "   non-PIC abs relocs (R_X86_64_32/32S/64 in text, R_AARCH64_ABS32/ADR_PREL_PG_HI21_NC): $("$TC/llvm-readelf" -rW "$D/$f" 2>/dev/null | grep -c -E 'R_X86_64_32S? |R_X86_64_32 |R_AARCH64_ABS32 ')"
    echo "   __ndk1 undefined: $("$TC/llvm-nm" -u -C "$D/$f" 2>/dev/null | grep -c __ndk1)  __cxx11: $("$TC/llvm-nm" -u -C "$D/$f" 2>/dev/null | grep -c __cxx11)"
  done
  echo "-- global Fr_/Fq_ defined in libfr.a: $("$TC/llvm-nm" -g --defined-only "$D/libfr.a" | grep -c ' Fr_')"
  echo "-- librapidsnark.so NEEDED:"; "$TC/llvm-readelf" -d "$D/librapidsnark.so" | grep NEEDED
  echo "-- build-id/comment:"; "$TC/llvm-readelf" -p .comment "$D/librapidsnark.so" 2>/dev/null | sed -n '3,6p'
done
echo "=== libgmp.a comparison (iden3 vs ours) member counts"
echo "iden3 x86_64 $("$TC/llvm-ar" t "$EXP/inputs/rapidsnark-android-x86_64-v0.0.8/lib/libgmp.a" | wc -l)  ours x86_64 $("$TC/llvm-ar" t "$EXP/lbc-android/x86_64/lib/libgmp.a" | wc -l)"
echo "iden3 arm64 $("$TC/llvm-ar" t "$EXP/inputs/rapidsnark-android-arm64-v0.0.8/lib/libgmp.a" | wc -l)  ours aarch64 $("$TC/llvm-ar" t "$EXP/lbc-android/aarch64/lib/libgmp.a" | wc -l)"
