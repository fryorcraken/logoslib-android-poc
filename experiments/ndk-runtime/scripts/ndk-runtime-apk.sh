#!/usr/bin/env bash
# ndk-runtime: package the smoke test as a Java-free NativeActivity APK
# (legacy/extracted native libs, host executable shipped as lib*.so) with the
# SDK build-tools directly (aapt2 + zipalign + apksigner, no Gradle).
set -u
W=${REPO_ROOT}/.work/experiments/ndk-runtime
SDK=${HOME}/android-sdk
BT=$SDK/build-tools/36.0.0
JAR=$SDK/platforms/android-36/android.jar
A=$W/apk
LOG=$W/logs/apk.log
export TMPDIR=$W/tmp
mkdir -p "$W/logs" "$TMPDIR"
exec 3>&1 >"$LOG" 2>&1
trap 'grep -E "^(APK|ERROR|error)" "$LOG" >&3' EXIT
date -Is
rm -rf "$A"; mkdir -p "$A/stage/lib/x86_64"

cat > "$A/AndroidManifest.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="dev.ndkruntime.smoke" android:versionCode="1" android:versionName="1">
  <application android:label="ndkrt" android:hasCode="false"
      android:debuggable="true" android:extractNativeLibs="true">
    <activity android:name="android.app.NativeActivity" android:exported="true">
      <meta-data android:name="android.app.lib_name" android:value="ndkrt_activity"/>
      <intent-filter>
        <action android:name="android.intent.action.MAIN"/>
        <category android:name="android.intent.category.LAUNCHER"/>
      </intent-filter>
    </activity>
  </application>
</manifest>
EOF

"$BT/aapt2" link -o "$A/base.apk" --manifest "$A/AndroidManifest.xml" -I "$JAR" \
  --min-sdk-version 34 --target-sdk-version 34 --debug-mode || { echo "APK aapt2 link FAILED"; exit 1; }
for f in libndkrt_activity.so liblogos_host_probe.so liblogos_host_qt.so libspdlog.so libfmt.so libc++_shared.so; do
  cp "$W/out/x86_64/$f" "$A/stage/lib/x86_64/$f"
done
(cd "$A/stage" && zip -r -0 "$A/base.apk" lib) || { echo "APK zip FAILED"; exit 1; }
"$BT/zipalign" -f -P 16 4 "$A/base.apk" "$A/aligned.apk" || { echo "APK zipalign FAILED"; exit 1; }
[ -f "$A/../debug.keystore" ] || keytool -genkeypair -keystore "$A/../debug.keystore" -storepass android \
  -keypass android -alias debug -keyalg RSA -keysize 2048 -validity 3650 -dname "CN=ndkrt debug"
"$BT/apksigner" sign --ks "$A/../debug.keystore" --ks-pass pass:android --key-pass pass:android \
  --out "$A/ndkrt-smoke.apk" "$A/aligned.apk" || { echo "APK sign FAILED"; exit 1; }
"$BT/zipalign" -c -P 16 -v 4 "$A/ndkrt-smoke.apk" | tail -8
unzip -lv "$A/ndkrt-smoke.apk"
echo "APK built $A/ndkrt-smoke.apk $(stat -c %s "$A/ndkrt-smoke.apk") bytes"
date -Is
