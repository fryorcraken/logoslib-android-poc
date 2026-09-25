# Patches to upstream repos

These are narrow patches, grouped by the repo they apply to. The Android build scripts apply
them to local copies. None has been upstreamed yet, and no fork exists: forks are created only
after the maintainer confirms. Each patch was produced by one of the experiments in
[`../experiments`](../experiments), and its write-up is in
[`../docs/research`](../docs/research).

| Repo | Patch | Why | Verified |
| --- | --- | --- | --- |
| boost 1.87 | `boost-1.87.0-process-shell-android.diff` | Boost.Process `shell.cpp` includes `<wordexp.h>`, which bionic lacks | NDK build (ndk-runtime) |
| logos-container, logos-container-subprocess, logos-module-loader | `*-test-gate.diff` | Tests and googletest `FetchContent` are added unconditionally; adds an off switch, following the process-stats pattern | NDK build |
| logos-module-loader-qt | `*-android-nojvm-shim.patch` | `logos_host_qt` runs with no JavaVM on Android, and stock Qt 6.11 crashes in the `QCoreApplication` constructor. Primes QtCore's `JNI_OnLoad` with a fake VM. | The same code ran on the emulator in a test host (qt-jvmless); not yet compiled into `logos_host_qt` |
| logos-module-loader-qt | `*-A-host-backtrace-api33.diff` | `backtrace()` exists only from API 33 | Compile-verified |
| logos-module-loader-qt | `*-B-host-android-name-rpath.diff` | Ship the host as `liblogos_host_qt.so` with an `$ORIGIN` runpath, so it can live in `nativeLibraryDir` | Stand-in host on the emulator |
| logos-module-loader-qt | `*-C-loader-android-host-discovery.diff` | Find the host next to the loaded library; `program_location()` is `app_process64` on Android | Runtime-verified on the emulator (stand-in host) |
| logos-package (liblgx) | `0001`, `0002` | Use the NDK's ICU C API (API 31 and above) instead of the ICU C++ API, so no ICU ships in the APK | 436/436 upstream tests pass; Android build |
| logos-package (liblgx) | `0003` | Proposed `__ANDROID__` branch for `lgx_host_variant()` (`android-x86_64` / `android-arm64`) | Proposal only |
| logos-execution-zone | `01`/`01b`, `02` | Drop the Bedrock HTTP-client edge from `lez/common`, and add an opt-in `webpki-roots` TLS feature. Together they let `wallet-ffi` build and run on Android with no JVM. | Emulator: wallet + testnet read over HTTPS (LEZ is no longer the target) |
