#!/usr/bin/env bash
# qt-jvmless X2.4: stage jniLibs (helper exe renamed lib*.so, Qt libs, plugin, JNI
# bridges, libc++_shared) and build both APK variants (withjar = A, nojar = B).
set -u
EXP=${REPO_ROOT}/.work/experiments/qt-jvmless
LOG="$EXP/logs/app-build.log"
exec 3>&1 > "$LOG" 2>&1
trap 'grep -E "JAVA_HOME|BUILD SUCCESSFUL|BUILD FAILED|FAILURE|error:|e: |What went wrong|lib/x86_64|extractNativeLibs|classes.dex|org/qtproject|APK_OK|^==" "$LOG" | head -80 >&3' EXIT
WRAP=${HOME}/src/fryorcraken/logos-android-wrap-poc/android
APP="$EXP/app"
QT=${REPO_ROOT}/.work/probe/qt/6.11.1/android_x86_64
NDK=${HOME}/android-ndk/android-ndk-r27c
SDK=${HOME}/android-sdk
B="$EXP/build/x86_64"
J="$APP/app/src/main/jniLibs/x86_64"
date -Is
# /usr/bin/java is a JRE-only java-25 (no javac); use the JDK that provides javac.
JAVAC=$(readlink -f /usr/bin/javac)
export JAVA_HOME=$(dirname "$(dirname "$JAVAC")")
echo "JAVA_HOME=$JAVA_HOME"
"$JAVA_HOME/bin/java" -version
echo "== copy gradle wrapper from wrap-poc =="
mkdir -p "$APP/gradle/wrapper"
cp -v "$WRAP/gradlew" "$APP/gradlew"
cp -v "$WRAP/gradle/wrapper/gradle-wrapper.jar" "$WRAP/gradle/wrapper/gradle-wrapper.properties" "$APP/gradle/wrapper/"
chmod +x "$APP/gradlew"
echo "== stage jniLibs =="
rm -rf "$J"; mkdir -p "$J"
cp -v "$B/qro_server" "$J/libqro_server.so"
cp -v "$B/libechoplugin.so" "$B/libqrotest_jni.so" "$B/libqrotest_jni_noonload.so" "$J/"
cp -v "$QT/lib/libQt6Core_x86_64.so" "$QT/lib/libQt6Network_x86_64.so" "$QT/lib/libQt6RemoteObjects_x86_64.so" "$J/"
cp -v "$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/x86_64-linux-android/libc++_shared.so" "$J/"
ls -la "$J"
echo "== gradle build =="
cd "$APP" || exit 1
./gradlew --no-daemon --console=plain assembleWithjarDebug assembleNojarDebug
rc=$?
echo "gradle rc=$rc"
[ $rc -eq 0 ] || exit $rc
AAPT2=$(ls -d "$SDK"/build-tools/*/aapt2 | tail -1)
for v in withjar nojar; do
  APK="$APP/app/build/outputs/apk/$v/debug/app-$v-debug.apk"
  echo "== $v: $APK =="
  ls -la "$APK"
  unzip -l "$APK" | grep -E 'lib/x86_64|classes.*dex'
  "$AAPT2" dump xmltree --file AndroidManifest.xml "$APK" | grep -E 'extractNativeLibs|package=|minSdk|targetSdk'
  unzip -p "$APK" 'classes*.dex' | strings | grep -c 'org/qtproject/qt/android/QtNative' | sed "s/^/QtNative refs in dex: /"
done
echo APK_OK
