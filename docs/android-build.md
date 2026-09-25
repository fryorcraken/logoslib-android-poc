# Building and running the Android wrapper

How to go from an empty `build/` to the demo app running liblogos on the x86_64 API 34
emulator, with the plan's M4 acceptance check passing. Every step is a script in
[`scripts/android/`](../scripts/android). Each script starts with a comment block giving its
inputs, outputs and pinned versions (`bash <script> --help` prints it). Each one can be
re-run: a step whose outputs exist is skipped unless `FORCE=1`. Full logs go to
`build/logs/<script>-<abi>.log`. The terminal shows only progress lines, plus the last 40
log lines on failure.

What runs where (the reasons are in [`plan.md`](plan.md) and
[`investigation.md`](investigation.md)):

```
app process (com.fryorcraken.logoslib.demo, untrusted_app)
  Kotlin LogosCore  --JNI-->  liblogos_jni.so
                               |- thread "logos-qt": QCoreApplication + logos_core_start + exec()
                               |- liblogos_core.so, liblogos_protocol.so (lp_* calls, events)
                               '- Qt6Core/Network/RemoteObjects, OpenSSL, liblgx, ...
  |  posix_spawn(nativeLibraryDir/liblogos_host_qt.so), one child per module,
  |  QtRO over unix sockets in cacheDir
  |- liblogos_host_qt.so --name capability_module ...   (started by logos_core_start)
  '- liblogos_host_qt.so --name hello_module ...        (started by loadModule)
```

## Prerequisites

| What | Version used here | Where the scripts look |
| --- | --- | --- |
| Linux x86_64 host | Fedora 43, 16 cores | about 6 GB free disk for `build/` and Qt |
| Host tools | cmake 3.31 (3.21 or later), GNU make, perl, python3 with venv, curl, git, tar, bzip2, xz, sha256sum, unzip, a host C++17 compiler (gcc) | `PATH`. Ninja is not needed: CMake uses "Unix Makefiles" |
| Android NDK | r27c (27.2.12479018) | `ANDROID_NDK_HOME`, default `~/android-ndk/android-ndk-r27c` |
| Android SDK | platform-tools 37.0.1, emulator 37.1.11, build-tools 36/37, platform android-37 (compileSdk 37) | `ANDROID_SDK_ROOT`, default `~/android-sdk` |
| System image and AVD | `system-images;android-34;google_apis;x86_64`, AVD `delivery-demo` | `EMU_AVD`, default `delivery-demo` |
| JDK | 21 (17 or later works) | `JAVA_HOME`, default `/usr/lib/jvm/java-21-openjdk` |
| Qt | 6.11.1 official prebuilts: `android_x86_64`, `android_arm64_v8a`, `gcc_64` (installed by step 1) | `QT_ROOT`, default `.work/probe/qt/6.11.1` |
| Network | GitHub, archives.boost.io, download.libsodium.org, pypi.org and the Qt mirrors (first run only); Google Maven and Maven Central (Gradle) | |

Gradle 9.7.1 comes from the wrapper in `android/`, and AGP 9.4.0 and the AndroidX libraries
come from Maven. All other pins are in
[`scripts/android/versions.env`](../scripts/android/versions.env) and
[`android/gradle/libs.versions.toml`](../android/gradle/libs.versions.toml).

To create an AVD if you have none (standard SDK commands; not run here, because this host
already has `delivery-demo`):

```sh
sdkmanager "system-images;android-34;google_apis;x86_64" "emulator" "platform-tools"
avdmanager create avd -n logos-api34 -k "system-images;android-34;google_apis;x86_64" -d pixel_6
export EMU_AVD=logos-api34
```

## Build and run, in order

Run from the repository root. Times are from this host with sources not yet fetched.

```sh
bash scripts/android/install-qt.sh x86_64        # 1. Qt 6.11.1 android_x86_64 + gcc_64 (aqtinstall 3.3.0)
bash scripts/android/build-deps.sh x86_64        # 2. M2 prefix: Boost, OpenSSL, libsodium, liblgx, ...  ~2-3 min
bash scripts/android/build-runtime.sh x86_64     # 3. M3 runtime: liblogos, host, capability_module, hello_module  ~1.5 min
bash scripts/android/build-jni.sh x86_64         # 4. liblogos_jni.so (the JNI shim)  ~1 s
bash scripts/android/stage.sh x86_64 capability_module hello_module   # 5. into :logos-core, then checked  ~3 s
bash scripts/android/build-apk.sh x86_64 --unit-tests                 # 6. Gradle: APKs + JVM tests  ~20 s clean
bash scripts/android/emulator.sh start           # 7. boot emulator-5570  ~20-60 s
bash scripts/android/run-m4.sh x86_64            # 8. M4 acceptance  ~30 s
bash scripts/android/emulator.sh stop            # 9.
```

### What each step prints when it works

1. **`install-qt.sh`** creates `.work/probe/qt-venv` with aqtinstall 3.3.0. It then runs
   `aqt install-qt all_os android 6.11.1 android_x86_64 --archives qtbase -m qtremoteobjects`
   and `aqt install-qt linux desktop 6.11.1 linux_gcc_64 --archives qtbase icu -m qtremoteobjects`.
   `all` also installs `android_arm64_v8a`. Last lines:
   ```
   -- android_x86_64: OK (96M)
   -- gcc_64: OK (176M)
   install-qt: OK (.../.work/probe/qt/6.11.1: android_x86_64 gcc_64)
   ```
2. **`build-deps.sh`** builds ten steps: boost, fmt, spdlog, json, cli11, semver, openssl,
   sodium, lgx and lpm. Then `check-prefix.sh` checks the prefix: `lib*.so` SONAMEs, NEEDED,
   16 KB LOAD alignment, undefined symbols, no glibc and no `/nix/store`.
   ```
   check-prefix: OK -- 14 files checked, no violations
   build-deps: OK (x86_64) ...
   ```
3. **`build-runtime.sh`** builds fifteen steps: gen (the host code generators), cppsdk,
   protocol, qthost, qtsdk, module, modulehost, procstats, container, subprocess, loader,
   loaderqt, liblogos, capability and hello. The upstream repos are checked out at the
   `db45024` closure under `build/src/`, with `patches/` applied.
   ```
   check-prefix: OK -- 20 files and 2 module manifests checked, no violations
   build-runtime: OK (x86_64) ...
   ```
4. **`build-jni.sh`**:
   ```
   -- .../build/android/x86_64/jni/liblogos_jni.so: 1096104 bytes, SONAME liblogos_jni.so, LOAD align 0x4000
   -- NEEDED: liblogos_core.so liblogos_protocol.so libQt6Core_x86_64.so liblog.so libdl.so libm.so libc++_shared.so libc.so
   -- exports: JNI_OnLoad + 17 LogosNative entry points
   build-jni: OK (...)
   ```
5. **`stage.sh`** copies and strips the DT_NEEDED closure into
   `android/logos-core/src/main/jniLibs/x86_64/`, and the module directories into
   `android/logos-core/src/main/modules-staged/x86_64/`. Both are gitignored. It then runs
   `check-prefix.sh` on exactly that set. Name the modules: without arguments it stages every
   module under `build/android/x86_64/modules/`, which would include `blockchain_module` once
   M5 puts it there.
   ```
   -- staged 15 libraries into android/logos-core/src/main/jniLibs/x86_64 (24416512 bytes, strip=1)
   -- staged modules capability_module hello_module into ... (stamp d1b29f001d22c5aa)
   stage: OK -- 15 libraries (24416512 bytes) + 2 modules; list in build/android/x86_64/staged.txt
   ```
6. **`build-apk.sh`** runs `gradlew :demo-app:assembleDebug :demo-app:assembleDebugAndroidTest`
   with `-Plogos.abis=x86_64`, plus `:logos-core:testDebugUnitTest` with `--unit-tests`. It
   refuses an APK that lacks the runtime or the modules, and writes
   `build/android/x86_64/apk-sizes.txt`.
   ```
   -- name="com.fryorcraken.logoslib.core.FirstCallRetryTest" tests="7" ... failures="0" errors="0"
   -- name="com.fryorcraken.logoslib.core.LogosJsonTest" tests="10" ...
   -- name="com.fryorcraken.logoslib.core.internal.RuntimeEnvTest" tests="8" ...
      native libraries lib/                        24427272      9787610  (16 files)
      module assets assets/modules/                 4830874      1750612  (7 files)
   -- demo-app-debug.apk: 41033524 bytes; test APK 867443 bytes; ...
   build-apk: OK (.../demo-app-debug.apk)
   ```
7. **`emulator.sh start`** starts
   `emulator -avd delivery-demo -read-only -port 5570 -no-audio -no-boot-anim -no-snapshot-save -qt-hide-window`
   detached, waits for `sys.boot_completed`, and turns the screen on and unlocks it. It
   refuses to start a second emulator.
   ```
   -- emulator-5570 booted in 22 s
   -- emulator-5570: API 34, ABIs x86_64,arm64-v8a, page size 4096, SELinux Enforcing
   emulator: OK (emulator-5570)
   ```
8. **`run-m4.sh`** runs four phases; name some to run only those:
   `install`, `test` (`connectedDebugAndroidTest`), `demo` (autorun, `ps`, UI dump,
   screenshot, a "Methods" tap and a "Stop" tap) and `kill` (autorun, then `am force-stop`).
   It prints one PASS/FAIL line per check and exits non-zero if any fails.
   ```
   [PASS] instrumented test -- LogosCoreAcceptanceTest: 7 tests, 0 failures, 0 errors (Gradle rc=0)
   ...
   [PASS] 7b no child survives am force-stop -- before: 2 children of pid 8386; after: no liblogos_host_qt.so and no com.fryorcraken.logoslib.demo process
   run-m4: OK (18 checks passed)
   ```
   The evidence goes to `build/android/x86_64/m4/`: `summary.txt`, full and excerpted
   logcat per phase, `ps-*.txt`, `ui-*.xml`, `gfxinfo.txt`, the JUnit XML and
   `timings.txt`. Screenshots go to `build/screenshots/m4.png` (after autorun) and
   `m4-stopped.png` (after Stop).
9. **`emulator.sh stop`** runs `adb -s emulator-5570 emu kill` and waits until no qemu
   process is left for port 5570.

The steps for arm64-v8a are the same with `arm64-v8a` in place of `x86_64`. For an APK
carrying both ABIs, stage both and pass `GRADLE_ARGS=-Plogos.abis=x86_64,arm64-v8a`. arm64
builds and passes every static check, but it has not run on a device: the arm64 AVD does not
boot on this host.

### By hand

```sh
cd android
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk ANDROID_HOME=$HOME/android-sdk
./gradlew :demo-app:assembleDebug :demo-app:assembleDebugAndroidTest
ANDROID_SERIAL=emulator-5570 ./gradlew :demo-app:connectedDebugAndroidTest   # uninstalls the app afterwards
adb -s emulator-5570 install -r -t demo-app/build/outputs/apk/debug/demo-app-debug.apk
adb -s emulator-5570 shell am start -n com.fryorcraken.logoslib.demo/.MainActivity --ez autorun true
adb -s emulator-5570 logcat -s LogosDemo LogosCore logos-jni logos-qtloop logos-stdio
adb -s emulator-5570 shell ps -A -o PID,PPID,USER,NAME,ARGS | grep -E 'logoslib|liblogos_host_qt'
adb -s emulator-5570 exec-out screencap -p > build/screenshots/m4.png
```

Autorun runs start, load hello_module, subscribe, ping and fire, then waits for the event,
and ends with `AUTORUN OK (ping=pong, event=tag-1)` under tag `LogosDemo`. Without the
extra, the same sequence is driven by the Start, Load hello, Ping and Fire buttons.

## M4 result (2026-09-25, x86_64 API 34 emulator)

`run-m4.sh`: 18/18 checks passed. It was run four times in full, the last on a freshly booted
emulator; five more runs of the test phase and three more of the force-stop phase also
passed.

| # | Acceptance item | Evidence |
| --- | --- | --- |
| 1 | liblogos_core starts in the app process; capability_module comes up in a `liblogos_host_qt.so` child | `logos-qtloop: logos_core_start() returned` from the app pid; `logos-stdio: [info] [logos] Module loaded: capability_module`; `ps`: `liblogos_host_qt.so --name capability_module ... --host-services token_registry,token_delivery --token-source stdin`, PPID = the app, `untrusted_app` |
| 2 | `knownModules()` lists hello_module | `known modules: [hello_module, capability_module]` |
| 3 | `loadModule("hello_module")` is true and a second child appears | `loadModule(hello_module) -> true`; `ps` shows the second child `--name hello_module`; the instrumented test finds both in `/proc` |
| 4 | `call("hello_module","ping")` returns `"pong"` | `ping -> "pong"`, on the first attempt in every run |
| 5 | An event reaches Kotlin | `event hello_module.hello ["tag-1"]`; the test checks its own tag within 5 s |
| 6 | The UI stays responsive | no ANR; no Choreographer "Skipped frames" on the main thread; a Methods tap is answered in 20-25 ms (in-app); the UI dump shows `Runtime: RUNNING`, `Ping: pong`, `Last event: tag-1` |
| 7 | `stop()` tears down cleanly; nothing survives `am force-stop` | Stop tap: `stopped: true`, the app pid is unchanged and 0 children remain (the test also asserts 0 children after `stop()`); `am force-stop` with 2 children: app and hosts gone within 50-106 ms |

`ps -A` while the demo runs (RSS in KB):

```
  PID  PPID USER     LABEL                                      RSS NAME
 4516   364 u0_a193  u:r:untrusted_app:s0:c193,c256,c512,c768 163972 com.fryorcraken.logoslib.demo
 4547  4516 u0_a193  u:r:untrusted_app:s0:c193,c256,c512,c768  13200 liblogos_host_qt.so --name capability_module --path .../files/modules/capability_module/capability_module_plugin.so ...
 4555  4516 u0_a193  u:r:untrusted_app:s0:c193,c256,c512,c768  14400 liblogos_host_qt.so --name hello_module --path .../files/modules/hello_module/hello_module_plugin.so ...
```

Timings, in-app, device clock:

| Operation | Time |
| --- | --- |
| `start()`: env, module extraction, `loadLibrary`, QCoreApplication, `logos_core_start` including the capability_module child | 46-88 ms (342 ms on the first launch after emulator boot) |
| `loadModule(hello_module)` (spawns the host) | 15-21 ms (`logos_core_load_module` alone: 38-39 ms in the demo) |
| First `ping` after load | 3-5 ms, 1 attempt; the first-call race never showed |
| Warm `ping` | 1-2 ms |
| subscribe to `ARMED` | 1 ms |
| `fire` to event in Kotlin | 2-4 ms |
| `stop()` (loop quit, lp teardown, `logos_core_cleanup`, children gone) | 101-109 ms |
| APK install (both) / activity launch (`am start -W`) | 0.4-2.5 s / 0.5-1.2 s |
| `connectedDebugAndroidTest` wall time (Gradle) | 11-14 s |

APK size (x86_64 debug, `unzip -v`; full list in `build/android/x86_64/apk-sizes.txt`):

| Entry | Uncompressed | Stored in APK |
| --- | ---: | ---: |
| `libQt6Core_x86_64.so` | 6,420,704 | 2,630,441 |
| `libcrypto_3.so` | 5,970,552 | 2,312,506 |
| `liblogos_protocol.so` | 2,146,880 | 781,257 |
| `libQt6Network_x86_64.so` | 1,820,568 | 749,330 |
| `liblogos_host_qt.so` (the host executable) | 1,401,120 | 603,803 |
| `libc++_shared.so` | 1,252,080 | 459,698 |
| `libssl_3.so` | 1,036,552 | 475,461 |
| `libQt6RemoteObjects_x86_64.so` | 963,888 | 356,035 |
| `liblgx.so` | 963,176 | 465,548 |
| `liblogos_core.so` | 890,160 | 353,122 |
| `libpackage_manager_lib.so` | 535,584 | 220,947 |
| `libspdlog.so` | 472,272 | 146,101 |
| `liblogos_qt_host.so` | 312,000 | 117,239 |
| `libfmt.so` | 161,208 | 77,241 |
| `liblogos_jni.so` | 69,768 | 34,004 |
| `libandroidx.graphics.path.so` (Compose) | 10,760 | 4,877 |
| **all of `lib/x86_64/`** | **24,427,272** | **9,787,610** |
| `assets/modules/`: capability_module_plugin.so 2,421,624 + hello_module_plugin.so 2,408,624 + manifests | 4,830,874 | 1,750,612 |
| `classes*.dex` (debug build, stored uncompressed) | 28,949,072 | 28,949,072 |
| **demo-app-debug.apk** | | **41,033,524** |

On the device the runtime is extracted to `nativeLibraryDir` (24.4 MB) and the modules to
`filesDir/modules` (4.8 MB). The Logos part of the APK is 11.5 MB compressed. Most of the
41 MB is the debug build's uncompressed dex.

## Troubleshooting

**The emulator crashes at boot with `-no-window`.** On this host
`emulator -no-window` (with or without `-gpu swiftshader_indirect`) SIGSEGVs during cold boot,
right after "Failed to load snapshot default_boot". `emulator.sh` uses the windowed binary
with its window hidden (`-qt-hide-window`). Screenshots still work. `-read-only` lets the
instance share the AVD with another session without writing to it, and the fixed
`-port 5570` keeps it off the default `emulator-5554`. See
[`research/exp-qt-jvmless.md`](research/exp-qt-jvmless.md) ("Emulator").

**`emulator.sh start` says another emulator is running.** Only one emulator may run on this
host. Stop the other one, or use it through `ANDROID_SERIAL=<serial> bash scripts/android/run-m4.sh`.

**`emulator.sh start` times out.** Look at `build/logs/emulator-console.log`. The script
gives up after `EMU_BOOT_TIMEOUT` (300 s); a loaded host can need more. After a failed start,
run `emulator.sh stop` so no half-started qemu is left behind.

**Gradle: "JAVA_HOME ... is not a JDK" or "Unsupported class file".** `/usr/bin/java` on this
host is a JRE-only JDK 25. The scripts default to `JAVA_HOME=/usr/lib/jvm/java-21-openjdk`.

**`build-apk.sh`: "nothing staged for x86_64".** Run `build-jni.sh` and `stage.sh` first.
Gradle does not build native code. Without staging it still builds an APK, whose
`LogosCore.start()` then fails with `IllegalStateException: native runtime not packaged
for x86_64: missing [...]`.

**The app is gone after `connectedDebugAndroidTest`.** AGP uninstalls the app and the test
APK after the run. `run-m4.sh` passes
`-Pandroid.injected.androidTest.leaveApksInstalledAfterRun=true`, and its demo and kill phases
reinstall the app if it is missing.

**`UnsatisfiedLinkError: JNI_ERR returned from JNI_OnLoad`.** A library that links QtCore was
`System.loadLibrary`'d directly, so ART found QtCore's own `JNI_OnLoad`. That call fails
without `Qt6Android.jar`. Load only `c++_shared`, `crypto_3`, `ssl_3` and `logos_jni` (see
`NativeLibs.kt`). `liblogos_jni.so` has its own `JNI_OnLoad`, which primes QtCore with the
real JavaVM.

**SIGSEGV in `QCoreApplication::QCoreApplication` (app or host).**
- In the app, QtCore never got the JavaVM: `logos-qtloop: QtCore JNI_OnLoad(realVM) ... returned -1`
  must appear before `QCoreApplication created`.
- In a `liblogos_host_qt.so` child, the host was built without
  `patches/logos-module-loader-qt/*nojvm-shim.patch`. Check the `loaderqt` step of
  `build-runtime.sh`.

**A module never loads or QtRO cannot listen.**
- TMPDIR must be set and short. The socket is `$TMPDIR/logos_<module>_<12 chars>` and must fit
  the 108-byte `sun_path`. `LogosCore` sets TMPDIR to `cacheDir` and refuses a module name
  that would not fit.
- The host must be found: `LOGOS_HOST_PATH` is set to `nativeLibraryDir/liblogos_host_qt.so`,
  which only exists with `useLegacyPackaging = true` (`extractNativeLibs=true`; `build-apk.sh`
  checks it).

**`knownModules()` lacks a module.**
- The manifest's `main` must have a key liblgx accepts under bionic: `linux-x86_64-dev`,
  not `android-*`, unless `patches/logos-package/0003` is applied.
- The directory name must equal the manifest `name`, and must not start with `_` or `.`,
  because aapt drops those from the APK.
- `check-prefix.sh` checks all three.
- The extracted copy is refreshed when `modules.stamp`, the APK version or the module set
  changes. `adb shell pm clear com.fryorcraken.logoslib.demo` forces it.

**`stop()` then `start()` fails with "cannot be restarted in the same process".** This is
expected. Qt allows one QCoreApplication per process, and liblogos keeps global state. Restart
the app, as the demo says.

**Logcat noise that is expected:**
- `F QtCore: initJNI failed` in the app and in every host, and one
  `ClassNotFoundException ... QtNative` in the app. QtCore's `JNI_OnLoad` returns JNI_ERR
  without `Qt6Android.jar`, after storing the VM (the hosts get a fake one). The F-level line
  does not abort.
- `[critical] [capability_module] Critical: Failed to register natives methods for
  org/qtproject/qt/android/QtInputDelegate` in each host, from the same cause.
- `Warning: It is recommended to use 'localabstract' over 'local' on Android` (QtRO).
  `local:` sockets in `cacheDir` work.
- `avc: denied { search } for name="tests" ... shell_test_data_file` (4 per host). This is
  the dynamic linker probing a test directory, with no effect.
- `avc: granted { execute } ... files/modules/<m>/<m>_plugin.so`. This is an audit record,
  not a denial: dlopen of a module plugin from app data is allowed at targetSdk 36 but
  audited (see the limits below).
- `logos-stdio: s_glBindAttribLocation: ...`. The app's stdout is piped to logcat, and the
  emulator's GL driver prints there.

**adb server restarts.** `/usr/bin/adb` (37.0.0) and the SDK's `platform-tools/adb`
(37.0.1) speak the same protocol, but mixing clients of different versions can restart the
server under other sessions. The scripts use the SDK's adb; override with `ADB=...`.

**Two ABIs at once.** `build/src` is shared between ABIs: never run two `build-deps.sh` or
`build-runtime.sh` jobs at the same time.

## Known limits

- **Only x86_64 has run on a device.** arm64-v8a builds and passes the static checks.
  16 KB-page devices and API 35/36 are untested, although every LOAD segment is 16 KB-aligned.
- **Module plugins are `dlopen`ed from `filesDir`.** SELinux audits that as "granted execute
  on app_data_file". A future Android release could forbid it. The fallback is to ship
  plugins as `lib*.so` in `nativeLibraryDir` and point `main` there.
- **Patch C is not exercised on its own.** `LogosCore` always sets `LOGOS_HOST_PATH`, so M4
  does not show that host discovery (patch C) works without it.
- **The Android 12+ phantom-process limit** (32 children system-wide, background kills) is
  untested with long-lived module hosts.
- **The APK is a debug build.** R8 and resource shrinking are off. The size table above is
  dominated by debug dex.
