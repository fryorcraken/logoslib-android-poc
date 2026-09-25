# Implementation plan

The work is staged in rising order of ambition, the way liblogos-electron-poc was. Each
milestone has an acceptance check that can run without a human watching. Background and
evidence are in [`investigation.md`](investigation.md).

## Decisions taken

- **Build system for Android: plain NDK CMake, cargo, and scripts, not Nix (for now).**
  - logos-nix's Android Qt set is arm64-only.
  - It lacks QtRemoteObjects.
  - It has never been built by CI.

  The official Qt 6.11.1 prebuilts cover x86_64 and arm64 with QtRO, and are 16 KB-aligned.
  The plan is to converge on logos-nix once its Android set grows QtRO and x86_64.
- **One Qt: 6.11.1 official Android prebuilts,** with the host `gcc_64` 6.11.1 for moc/repc.
  - Every Logos component is compiled against it.
  - No desktop/Nix binary goes into the APK.
- **ABI order: x86_64 first** (the API 34 emulator on this host), **arm64-v8a second**. The
  arm64 AVD does not boot on this x86_64 host.
- **Calling route: `lp_*` C ABI in-process.** Verified on desktop. The JNI shim is C++ with
  `extern "C"` entry points, so it can free liblogos' `new[]` strings. Qt headers are limited
  to one small Qt-loop file.
- **Threading.**
  - One Kotlin-created thread (`logos-qt`) creates `QCoreApplication`, calls
    `logos_core_start()`, and blocks in `exec()`.
  - Every other JNI entry point is called from `Dispatchers.IO`, never from the Android main
    thread.
  - `lp_invoke_async` / event callbacks land on `logos-qt` and are handed straight to a
    `CompletableDeferred` / `SharedFlow`.
- **Module set on device:** `capability_module` (from the liblogos build), `lez_core`, and
  `lez_probe` (this repo). No RLN or delivery modules.
- **Where modules run:** decided by gating experiment X1/X2:
  - **(A) subprocess container**, `logos_host_qt` shipped as `liblogos_host_qt.so`: minSdk 33
    and `useLegacyPackaging`.
  - **(B) a new in-process container.**

## Milestones

### M0: desktop reference (done)

- logoscore + lgpm + lez_core 0.4.2 `.lgx` built from published flakes and run headless.
- `lez_probe` → `lez_core` inter-module calls work.
- A pure-C `lp_*` caller works in-process.

Reproduce with [`experiments/desktop-probe`](../experiments/desktop-probe) and
[`experiments/lp-inprocess`](../experiments/lp-inprocess).

### M1: Qt on the emulator (gate)

X1 and X2 from the investigation.

**Accept when:**
- A no-JVM `qro_server`/`qro_client` pair round-trips over `local:` on the x86_64 AVD.
- An APK runs an executable from `nativeLibraryDir` that talks QtRO to the app process.
- We know whether `Qt6Android.jar` is required.

**Outcome:** fix route (A) or (B) and the minSdk (33 for A).

### M2: native dependency prefix for `x86_64-linux-android`

A script that installs into `build/android/x86_64/prefix`:

- Boost 1.87: process, filesystem, system, context, atomic, date_time
- OpenSSL 3, built 16 KB-aligned; one copy for liblogos and QtNetwork's `dlopen`
- spdlog 1.15.2, fmt, nlohmann_json, CLI11 if needed, libsodium
- liblgx:
  - zlib from the NDK;
  - ICU through the NDK's ICU C API if X8 passes, else cross-built ICU.

Every artefact is linked with `-Wl,-z,max-page-size=16384`.

**Accept when** every `.so` has an unversioned `lib*.so` SONAME, only NDK/`libc++_shared` and
in-prefix NEEDED entries, and `LOAD p_align` 0x4000.

### M3: the Logos runtime for Android

Cross-build, pinned to the revisions in the working desktop closure (liblogos `db45024`,
logos-protocol 0.9.0, …):

- logos-protocol
- logos-plugin-qt (qt_host), logos-cpp-sdk, logos-qt-sdk
- logos-module, process-stats
- logos-container and the container chosen in M1
- logos-module-loader and logos-module-loader-qt (`logos_host_qt` for route A)
- liblogos_core, capability_module

The code generators run on the host, or their desktop output is reused. Patches live in
`patches/<repo>/`, one narrow diff per issue, applied by the build script. This follows the
sibling repo's scripted leopard patch. Known candidates:

- guard `backtrace()` and `POSIX_SPAWN_CLOEXEC_DEFAULT`;
- a tests off-switch.

**Accept when** a small NDK-built test executable on the emulator runs
`logos_core_start()` and loads `capability_module` plus a trivial module.

### M4: Kotlin app, "load only" (the Electron 0.1.0 equivalent)

`android/`, a single-Activity Gradle project, reusing the sibling repo's Gradle/AGP setup
where it fits:

1. **Bootstrap:**
   - `Os.setenv("TMPDIR", cacheDir)` (asserting the `sun_path` budget), `HOME`, and
     `LOGOS_HOST_PATH` for route A;
   - `System.loadLibrary` in a fixed order;
   - start the `logos-qt` thread.
2. **Modules:** `.lgx` files or plain module dirs in `assets/`, extracted read-only to
   `filesDir/modules` on first run, with manifests keyed `linux-x86_64[-dev]`.
3. **JNI shim** (`logos_jni.cpp`): `nativeRun`, `loadModule`, `knownModules`,
   `loadedModules`, `invoke(module, method, argsJson, timeoutMs)`, `invokeAsync`, `stop`.
4. **Staging script** (`scripts/android/stage-jnilibs.sh`): copies the prefix into
   `jniLibs/<abi>`, renames and fixes SONAME/NEEDED, strips, and checks 16 KB alignment. It
   fails if any `/nix/store` path, glibc NEEDED or 4 KB LOAD slips through.

**Accept when** the app shows `known: capability_module, lez_probe, …` and
`loadModule(capability_module) -> true` on the emulator. An instrumented test or an
`adb logcat` grep asserts it.

### M5: lez_core for Android

1. **`wallet_ffi`** for `x86_64-linux-android`:
   - `--no-default-features` (no `prove`);
   - the `lez/common` patch that drops the Bedrock edge;
   - a pcsclite stub or feature gate;
   - a TLS fix for the chosen hosting route, e.g. webpki roots under route A;
   - linked against `libc++_shared` with 16 KB pages.
2. **Revision:** pin the LEZ/lez_core revision chosen for the demo. `825d2a4` is known to work
   on desktop for reads. A write-capable pairing needs the revision the sequencer runs.
3. **Plugin:** `lez_core_plugin` built with logos-module-builder's CMake and the NDK toolchain.

**Accept when** `loadModule(lez_core) -> true` on the emulator.

### M6: call lez_core (the Electron 0.2.0/0.3.0 "real work" bar)

**Offline:** `name`, `version`, then an `account_id_to_base58` ↔ `from_base58` round trip.

**Network:**
1. Pre-write `wallet_config.json` with `calibration_limit` 3.
2. `create_new`, `create_account_public`, `list_accounts`, `save`.
3. Poll `get_current_block_height` every 5 s.
4. Read the pinata account with `get_account_public`.

**Timeouts:** 60 s for `create_new`/`open`, and a warm-up call before the first real one.

**Accept when:**
- The app shows a live, increasing LEZ block height from `https://testnet.lez.logos.co`, or
  from a local standalone sequencer at `http://10.0.2.2:<port>` if TLS or version skew blocks
  the testnet.
- The UI stays responsive, checked by an instrumented test that asserts a UI action completes
  while a call is in flight.

### M7: inter-module on device

The app calls `lez_probe.roundtrip_via_lez(hex)`, and `lez_probe` calls `lez_core` through
generated `modules().lez_core.*` wrappers over liblogos' own QtRO transport. No glue code is
written for the hop.

**Accept when:**
- The UI shows the round-trip result.
- The logs show `capability_module` issuing a token and `lez_probe` → `lez_core` invocations
  (`adb logcat` / captured host stdout).

### M8: size and packaging report, arm64-v8a

- Per-ABI APK size table, like the sibling's.
- An arm64-v8a build, checked on a real device if one is available.
- A release workflow, if the build is reproducible in CI.

## Risks, in order

1. JVM-less Qt in module child processes (route A). X1 settles it.
2. TLS inside `wallet_ffi` without a JavaVM. Fixed by webpki roots, plain HTTP, or route B.
3. The size of the non-Qt native tree to cross-build: Boost, OpenSSL, ICU, libsodium.
4. `wallet-ffi` compiling for Android (risc0 client crates, ring, pcsc). X4 settles it.
5. Single-threaded `lez_core` plus `BlockingQueuedConnection` with no timeout, which can wedge
   callers. Mitigate with the threading rules above and long explicit timeouts.
6. Version skew between the `lez_core` build and the deployed testnet, for writes.

## Out of scope for this PoC

Private or shielded transactions (on-device RISC Zero proving), RLN, delivery, L1 or indexer
modules, iOS, and Play-store signing.
