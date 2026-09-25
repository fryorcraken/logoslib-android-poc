#!/usr/bin/env bash
# ndk-runtime: artifact size + 16 KB alignment table for the report.
set -u
W=${REPO_ROOT}/.work/experiments/ndk-runtime
TC=${HOME}/android-ndk/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64
PREFIX=$W/prefix/x86_64
T=$W/tmp/strip
LOG=$W/logs/sizes.log
mkdir -p "$T"
exec > >(tee "$LOG") 2>&1
printf '%-40s %12s %12s %s\n' file bytes stripped max-LOAD-align
for f in "$PREFIX"/lib/*.a "$PREFIX"/lib/*.so "$W"/out/x86_64/*; do
  case "$f" in *.stripped) continue;; esac
  b=$(stat -c %s "$f")
  cp -f "$f" "$T/x"; "$TC/bin/llvm-strip" --strip-unneeded "$T/x" 2>/dev/null; s=$(stat -c %s "$T/x")
  al=$("$TC/bin/llvm-readelf" -l "$f" 2>/dev/null | awk '$1=="LOAD"{print $NF}' | sort -u | tr '\n' ',')
  printf '%-40s %12s %12s %s\n' "$(basename "$f")" "$b" "$s" "${al:--}"
done
echo "APK $(stat -c %s "$W/apk/ndkrt-smoke.apk") bytes (unstripped libs, stored)"
du -sh "$PREFIX" "$W/build" "$W/src" "$W/dl"
