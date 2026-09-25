# Patches to upstream repos

These are narrow patches, grouped by the repo they apply to. The Android build scripts apply
them to local copies. None has been upstreamed yet, and no fork exists: forks are created only
after the maintainer confirms. Each patch was produced by one of the experiments in
[`../experiments`](../experiments), and its write-up is in
[`../docs/research`](../docs/research).

| Repo | Patch | Why | Verified |
| --- | --- | --- | --- |
| boost 1.87 | `boost-1.87.0-process-shell-android.diff` | Boost.Process `shell.cpp` includes `<wordexp.h>`, which bionic lacks | NDK build (ndk-runtime) |
| logos-container, logos-container-subprocess, logos-module-loader | `*-test-gate.diff` | Tests and googletest `FetchContent` are added unconditionally; adds an off switch, following the process-stats pattern | NDK build (M3 `build-runtime.sh`) |
| logos-module-loader-qt | `*-test-gate.diff` | The same for logos-module-loader-qt 888da92 (`LOGOS_MODULE_LOADER_QT_BUILD_TESTS`); needed to build the whole repo (loader library and `logos_host_qt`) with the NDK | NDK build (M3) |
| logos-module-loader-qt | `*-android-nojvm-shim.patch` | `logos_host_qt` runs with no JavaVM on Android, and stock Qt 6.11 crashes in the `QCoreApplication` constructor. Primes QtCore's `JNI_OnLoad` with a fake VM. | Emulator (M4): the real `liblogos_host_qt.so` hosts `capability_module` and `hello_module` as children of the demo app (`scripts/android/run-m4.sh`) |
| logos-module-loader-qt | `*-A-host-backtrace-api33.diff` | `backtrace()` exists only from API 33 | Compiled into `liblogos_host_qt.so` (M3; inert at minSdk 34) |
| logos-module-loader-qt | `*-B-host-android-name-rpath.diff` | Ship the host as `liblogos_host_qt.so` with an `$ORIGIN` runpath, so it can live in `nativeLibraryDir` | Emulator (M4): the real host runs from `nativeLibraryDir` under this name |
| logos-module-loader-qt | `*-C-loader-android-host-discovery.diff` | Find the host next to the loaded library; `program_location()` is `app_process64` on Android | Runtime-verified on the emulator (stand-in host); compiled into `liblogos_core.so` by M3. M4 also sets `LOGOS_HOST_PATH`, so it does not exercise this path on its own |
| logos-package (liblgx) | `0001`, `0002` | Use the NDK's ICU C API (API 31 and above) instead of the ICU C++ API, so no ICU ships in the APK | 436/436 upstream tests pass; Android build |
| logos-package (liblgx) | `0003` | Proposed `__ANDROID__` branch for `lgx_host_variant()` (`android-x86_64` / `android-arm64`) | Proposal only |
| logos-blockchain-circuits | `circuits-01-witness-makefile-android-lib.diff` | Adds an `android-lib` target to the CI witness-generator Makefile and makes `ld -r`/`ar` overridable | NDK build of all 4 witness libs; `.dat` output byte-identical to v0.5.7 |
| logos-blockchain-circuits | `circuits-02-lbc-build-libcxx-on-android.diff` | lbc-build hard-codes `-lstdc++` on non-macOS; on Android it must link libc++ | Android cargo build |
| logos-blockchain | `logos-blockchain-01*.diff` | Build wiring: `[patch]` points lbc-build at the patched copy (applies to both `35a4a666` and tag `0.3.0-rc.4`; used by `scripts/android/build-blockchain.sh`) | Android cargo build (x86_64 + arm64) |
| logos-blockchain | `logos-blockchain-02-android-dns-resolver-fallback.diff` | **Runtime blocker on Android.** libp2p's `with_dns()` reads `/etc/resolv.conf` (hickory system config), which Android lacks; `Swarm::build` is unwrapped, so the node panics in `start_lb_node` and the panic hook `exit(1)`s the module host. On Android only, the DNS transport uses hickory's default upstream resolvers instead (`/ip4` peers never reach it). Upstream would rather read Android's resolvers or make the resolver configurable | Emulator (M5): without it, `A panic occurred: called Result::unwrap() on an Err value: ... ResolveError ... NotFound ... at services/network/src/backends/libp2p/swarm/mod.rs:86:78`; with it, the node joins devnet and syncs to the tip |
| logos-blockchain-module | `module-quiet-newblock-log.diff` | Stops the plugin printing every full block JSON to stderr (12 MB in 6.5 min on devnet), which would flood logcat | Applied to `4b07e58` by `scripts/android/build-blockchain-module.sh`. Emulator (M5): a devnet sync of 5,260 blocks produced no per-block stderr line |
| process-stats | `process-stats-linux-cpu-fields.diff` | Proposal, not applied: `getProcessStats()` reads `/proc/<pid>/stat` fields 15 and 16 (stime, cutime) as utime and stime, so `logos_core_get_module_stats()` reports kernel time only (4-9 % for a host `top` shows at 105-121 %). `LogosCore.moduleStats()` corrects it in Kotlin | `git apply --check` on `6e0aade`; the Kotlin correction matches `top` on the emulator |
| logos-execution-zone | `01`/`01b`, `02` | Drop the Bedrock HTTP-client edge from `lez/common`, and add an opt-in `webpki-roots` TLS feature. Together they let `wallet-ffi` build and run on Android with no JVM. | Emulator: wallet + testnet read over HTTPS (LEZ is no longer the target) |
