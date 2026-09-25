# android/: Kotlin wrapper for liblogos

A Gradle project with two modules:

| Module | What it is |
| --- | --- |
| `:logos-core` | Android library (`com.fryorcraken.logoslib.core`). It holds the Kotlin API `LogosCore`, the JNI shim `src/main/cpp/logos_jni.cpp` (prebuilt, not built by Gradle) and the staged liblogos runtime. |
| `:demo-app` | Single-Activity demo (`com.fryorcraken.logoslib.demo`) and the M4 acceptance test (`src/androidTest`). |

`liblogos_core` and `liblogos_protocol` run inside the app process. Each module runs in its
own child process, `liblogos_host_qt.so`, which is exec'd from `nativeLibraryDir` and
reached over QtRO unix sockets in the app's `cacheDir`. The reasons are in
[`../docs/plan.md`](../docs/plan.md) and [`../docs/investigation.md`](../docs/investigation.md).

## Build

Gradle does not compile native code. The scripts in `scripts/android/` build it and stage
it into `:logos-core`. Both staging directories are gitignored.

The full walk-through, with expected outputs and troubleshooting, is
[`../docs/android-build.md`](../docs/android-build.md). In short:

```sh
bash scripts/android/install-qt.sh x86_64      # Qt 6.11.1 android_x86_64 + gcc_64 (aqt)
bash scripts/android/build-deps.sh x86_64      # M2: Boost, OpenSSL, liblgx, ... -> build/android/x86_64/prefix
bash scripts/android/build-runtime.sh x86_64   # M3: liblogos + host + capability_module, hello_module
bash scripts/android/build-jni.sh x86_64       # liblogos_jni.so -> build/android/x86_64/jni/
bash scripts/android/stage.sh x86_64 capability_module hello_module   # -> logos-core/src/main/{jniLibs,modules-staged}/x86_64 + checks
bash scripts/android/build-apk.sh x86_64 --unit-tests   # Gradle: demo + test APKs, JVM unit tests, size report
bash scripts/android/emulator.sh start         # x86_64 API 34 AVD on emulator-5570
bash scripts/android/run-m4.sh x86_64          # M4 acceptance: connectedDebugAndroidTest + demo autorun + force-stop
bash scripts/android/emulator.sh stop
```

By hand (from `android/`, with `JAVA_HOME=/usr/lib/jvm/java-21-openjdk`):
`./gradlew :demo-app:assembleDebug`, `./gradlew :logos-core:testDebugUnitTest`,
`ANDROID_SERIAL=emulator-5570 ./gradlew :demo-app:connectedDebugAndroidTest`, and the
unattended demo run (start -> load hello_module -> ping -> fire; ends with `AUTORUN OK`
under tag `LogosDemo`):
`adb shell am start -n com.fryorcraken.logoslib.demo/.MainActivity --ez autorun true`.

`stage.sh` copies:

- `liblogos_jni.so` and `liblogos_host_qt.so`;
- the DT_NEEDED closure of those two and of every module plugin (Qt Core, Network and
  RemoteObjects, OpenSSL `libssl_3`/`libcrypto_3`, `libc++_shared`, and the liblogos
  libraries);
- the module directories. They go to `modules-staged/<abi>/`, which is packaged as
  `assets/modules/<abi>/`. Gradle adds only the roots of the ABIs in `logos.abis`, because
  `abiFilters` filters jniLibs but not assets.

It then runs `check-prefix.sh` on exactly what was staged: names, SONAMEs, NEEDED, symbols,
16 KB alignment and manifests. The project also compiles with nothing staged. In that
case `LogosCore.start()` fails with "native runtime not packaged".

The versions and style follow `logos-android-wrap-poc/android`: AGP 9.4.0 with built-in
Kotlin 2.4.20, Gradle 9.7.1, Compose BOM 2026.09.00. The build uses minSdk 34, targetSdk 36
and compileSdk 37. ABIs come from `logos.abis` in `gradle.properties` (`x86_64`; arm64-v8a
is ready). `packaging.jniLibs.useLegacyPackaging = true` is required, because the module
host must be extracted to be exec'able.

## API

```kotlin
val core = LogosCore(context)                       // cheap; all instances share one runtime
core.start()                                        // env, assets, libs, logos-qt thread, logos_core_start
core.knownModules()                                 // [capability_module, hello_module]
core.loadModule("hello_module")                     // true; spawns a liblogos_host_qt.so child
core.callWithRetry("hello_module", "ping")          // "\"pong\"" (JSON); retries the first-call race
core.call("hello_module", "echo", LogosJson.array("hi"))
core.methods("hello_module")                        // getPluginMethods JSON
val sub = core.subscribe("hello_module", "hello")   // lp_subscribe
sub.awaitArmed(); sub.events.collect { println(it.argAsString(0)) }
core.events("hello_module", "hello")                // cold Flow alternative
core.stop(); core.awaitStopped()                    // teardown; no restart in this process
```

Results and arguments are JSON strings, exactly as the `lp_*` C ABI defines them.
`LogosJson` builds argument arrays and parses results, and it is pure Kotlin. A failed call
throws `LogosCallException` with liblogos' `{code, message, origin}`. A Kotlin deadline
throws `LogosTimeoutException`.

## How the runtime is started

1. **Environment.** `Os.setenv` sets four variables:
   - `TMPDIR` = `cacheDir`, checked against the 108-byte `sun_path` budget of
     `$TMPDIR/logos_<module>_<12-char id>`;
   - `HOME` = `filesDir`;
   - `LD_LIBRARY_PATH` = `nativeLibraryDir`, for the children;
   - `LOGOS_HOST_PATH` = `nativeLibraryDir/liblogos_host_qt.so`.
2. **Modules.** `assets/modules/<abi>/<module>/` is extracted to `filesDir/modules`. The
   module directories are made read-only. The extraction is re-done when the staged
   `modules.stamp`, the APK version or the module set changes.
3. **Libraries.** `System.loadLibrary` is called for `c++_shared`, then `crypto_3` and
   `ssl_3`, then `logos_jni`. Nothing that links QtCore is loaded explicitly: ART would find
   QtCore's `JNI_OnLoad` through DT_NEEDED, which returns JNI_ERR without `Qt6Android.jar`
   (qt-jvmless run R4). The linker pulls in Qt and liblogos as DT_NEEDED of
   `liblogos_jni.so`. The shim's own `JNI_OnLoad` calls QtCore's `JNI_OnLoad(realVM)` and
   ignores the JNI_ERR, so `QCoreApplication` can be constructed. Logcat then shows a
   ClassNotFoundException for `QtNative` and an F-level `initJNI failed` line, both from tag
   `QtCore`. Both are expected: the F-level line is only a log entry, not an abort.
4. **The `logos-qt` thread.** It is a Kotlin thread with an 8 MB stack. It runs
   `nativeRun`, which creates the `QCoreApplication`, calls `logos_core_init`,
   `add_modules_dir`, `set_persistence_base_path(filesDir/persist)` and `start`, then runs
   `exec()`. Nothing else runs on it. Readiness is signalled from inside the running loop.

## Threading and calls

The rules come from the desktop experiment X7 (`docs/research/exp-desktop-harness.md`):

- **Calls.** Every call goes through `lp_invoke_async`, never through sync `lp_invoke`,
  which nests an event loop. The Kotlin call id is the `user_data`, and the shim keeps an
  id → pending map. The Kotlin `withTimeout` is the real deadline. On timeout the id is
  forgotten on both sides and a late callback is dropped.
- **Callbacks.** Result, event and subscription-status callbacks run on the Qt thread. They
  only hand off, through `CompletableDeferred.complete`, `Channel.trySend` or a StateFlow.
- **One call in flight per module**, enforced by a Kotlin `Mutex`. The deadline covers the
  wait for the mutex as well.
- **Blocking native calls** are the load, the first `lp_client_create` for a module, and
  subscribe. They run detached on `Dispatchers.IO`, so a caller's timeout returns
  immediately. Loads never run on the Qt thread.
- **First call after a load.** The capability registration completes asynchronously, and
  until then a module-to-module edge answers the wrapper default (`""`). `callWithRetry`
  retries an idempotent method every 25 ms, for up to 5 s, while the answer is `""` or
  `null`.
- **Events.** Subscribe after the load, then `awaitArmed()` before triggering an event. A
  pending subscription is polled on a 250 ms to 5 s backoff. An unknown event name is
  accepted silently.
- **Stop.** `stop()` posts a teardown to the loop: unsubscribe everything, destroy the
  `lp_client`s, quit. Then `logos_core_cleanup()` terminates the module hosts.

## Logs

| Logcat tag | Source |
| --- | --- |
| `LogosCore` | Kotlin |
| `logos-jni` | The JNI shim |
| `logos-qtloop` | The Qt loop, QtCore priming |
| `logos-stdio` | Process stdout/stderr: spdlog from liblogos, and the module hosts, which inherit the pipe |
| `LogosM4Test`, `LogosDemo` | The test and the demo; `TIMING ...` lines |

## Known limits

- **One runtime per process.** It cannot be restarted after `stop()`.
- **Unknown method names answer `null` with success.** This is upstream behaviour. Use
  `methods()` to validate names.
- **`lp_get_methods` returns `[]`** for QtRO, so `methods()` uses `getPluginMethods`
  instead.
- **Qt's TLS plugin is not staged.** It is not needed for local QtRO. Modules that do HTTPS
  through QtNetwork would need `plugins/tls` from the Qt prebuilt.
- **`TMPDIR` is `cacheDir`.** The system may trim it under storage pressure.
