#!/usr/bin/env bash
# qt-jvmless X1.2: cross-build qro_server, qro_client, libechoplugin.so and the JNI
# bridge libs for Android x86_64 (API 34, c++_shared) against Qt 6.11.1 prebuilts.
set -u
EXP=${REPO_ROOT}/.work/experiments/qt-jvmless
mkdir -p "$EXP/logs"
exec 3>&1 > "$EXP/logs/build.log" 2>&1
trap 'grep -E "error:|FAILED|BUILD_OK" "$EXP/logs/build.log" >&3' EXIT
QT=${REPO_ROOT}/.work/probe/qt/6.11.1
NDK=${HOME}/android-ndk/android-ndk-r27c
SDK=${HOME}/android-sdk
B="$EXP/build/x86_64"
RE="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"
which make cmake
cmake --version | head -1
rm -rf "$B"
set -x
cmake -S "$EXP/src" -B "$B" -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$QT/android_x86_64/lib/cmake/Qt6/qt.toolchain.cmake" \
  -DQT_HOST_PATH="$QT/gcc_64" \
  -DANDROID_NDK_ROOT="$NDK" \
  -DANDROID_SDK_ROOT="$SDK" \
  -DANDROID_ABI=x86_64 \
  -DANDROID_PLATFORM=android-34 \
  -DANDROID_STL=c++_shared
rc=$?
set +x
[ $rc -eq 0 ] || { echo "CONFIGURE FAILED rc=$rc"; exit $rc; }
cmake --build "$B" -j16 -- VERBOSE=1
rc=$?
[ $rc -eq 0 ] || { echo "BUILD FAILED rc=$rc"; exit $rc; }
echo "== outputs =="
ls -la "$B"
for f in qro_server qro_client libechoplugin.so libqrotest_jni.so libqrotest_jni_noonload.so; do
  echo "== $f =="
  file "$B/$f"
  "$RE" -hW "$B/$f" | grep -E 'Type:|Machine:'
  "$RE" -lW "$B/$f" | grep -E 'INTERP|interpreter|LOAD' | head -8
  "$RE" -dW "$B/$f" | grep -E 'NEEDED|RUNPATH|RPATH|FLAGS'
  "$RE" --dyn-syms -W "$B/$f" | grep -E ' JNI_OnLoad' || echo "(no JNI_OnLoad export)"
done
echo "== JNI_OnLoad in Qt libs =="
for l in Core Network RemoteObjects; do
  "$RE" --dyn-syms -W "$QT/android_x86_64/lib/libQt6${l}_x86_64.so" | grep -E ' JNI_OnLoad' || echo "libQt6${l}: none"
done
echo BUILD_OK
