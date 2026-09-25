# Implementation plan

Target: an Android/Kotlin app that embeds `liblogos_core`, loads the **Logos blockchain
module** (`blockchain_module`, the L1 node) and drives it. A small core module then calls the
blockchain module to show inter-module communication over liblogos's own transport. The work
is staged in rising order of ambition, the way liblogos-electron-poc was, and each milestone
has an acceptance check that runs without a human watching. The evidence is in
[`investigation.md`](investigation.md).

An earlier revision of this plan targeted LEZ (`lez_core`). The user switched to the
blockchain module on 2026-09-25. The Kotlin wrapper milestones (M2-M4) do not depend on
which module is loaded.

## Decisions (settled by experiment unless marked)

- **One process per module, as upstream does it.** liblogos keeps its subprocess container.
  - `logos_host_qt` ships as `jniLibs/<abi>/liblogos_host_qt.so` with
    `useLegacyPackaging = true` and is exec'd from `nativeLibraryDir`.
  - It carries the no-JVM fix: QtCore's `JNI_OnLoad` is primed with a fake JavaVM
    (`patches/logos-module-loader-qt/*nojvm-shim.patch`).
  - It is found through `LOGOS_HOST_PATH` or patch C.

  All verified on the x86_64 API 34 emulator, from inside an APK.
- **minSdk 34.** At API 34 the runtime needs no source changes beyond the patches above.
  Lower API levels would need the whole prefix rebuilt, plus backtrace and
  `POSIX_SPAWN_CLOEXEC_DEFAULT` guards. liblgx's platform-ICU port needs API 31 or higher.
- **Build system for Android: plain NDK CMake, cargo and shell scripts, not Nix (for now).**
  - Qt is the official 6.11.1 Android prebuilt (x86_64 and arm64, with QtRO, 16 KB-aligned),
    installed with aqtinstall, plus the host `gcc_64` 6.11.1 for moc/repc.
  - Nothing Nix-built for Linux goes into the APK.
  - The plan is to converge with logos-nix's Android set once it has QtRO and x86_64.
- **ABI order:** x86_64 first (the API 34 emulator), arm64-v8a second. The arm64 AVD does not
  boot on this host.
- **App bootstrap:**
  - `Os.setenv` for `TMPDIR` (a short `cacheDir`, asserting the 108-byte `sun_path`
    budget), `HOME`, `LD_LIBRARY_PATH=nativeLibraryDir` and `LOGOS_HOST_PATH`;
  - `System.loadLibrary` in a fixed order;
  - the JNI bridge defines its own `JNI_OnLoad`, which calls QtCore's
    `JNI_OnLoad(realVM)` and ignores `JNI_ERR`, so `Qt6Android.jar` is not needed.
- **Host threading** (desktop experiment X7):
  - One Kotlin-created, JVM-attached `logos-qt` thread runs `QCoreApplication`,
    `logos_core_start()` and `exec()`, and nothing else.
  - Module calls use `lp_invoke_async`, with a `jlong` call id and a native id→pending map.
    The Kotlin side enforces the deadline with a coroutine timeout, and late callbacks are
    dropped.
  - One call in flight per module. Loads run on `Dispatchers.IO`.
  - The first call after a load retries until it gets a non-default answer, because of the
    first-call race. Subscriptions are made after the load and wait for `ARMED`.
- **Module plumbing:** modules are staged as directories (`manifest.json`, plugin, private
  deps) in `assets/`, extracted read-only to `filesDir/modules`. Manifests are keyed
  `linux-x86_64[-dev]`, which is what liblgx reports under bionic. The `android-*` variant
  patch is optional.
- **ICU:** use liblgx's platform-ICU port (`patches/logos-package/`), so no ICU ships in the
  APK.

## Milestones

### M0: desktop reference (done)

lez_core and `lez_probe` under logoscore, plus the in-process `lp_*` harness. See
[`experiments/`](../experiments).

### M1: gating experiments (done)

X1-X9 in `investigation.md` §8. They established that subprocess hosting works on Android
with the no-JVM fix, the Qt-free runtime cross-builds, ICU can be dropped, and the host call
policy above holds.

### M2: native prefix for `x86_64-linux-android34`

Script: `scripts/android/build-deps.sh`, output in `build/android/x86_64/prefix`.

Contents:
- Boost 1.87 (process, filesystem, system, context, atomic, date_time; patched)
- fmt 10.2.1, spdlog 1.15.2, nlohmann_json 3.11.3
- OpenSSL 3, 16 KB-aligned; one copy for liblogos and QtNetwork's `dlopen`
- libsodium 1.0.20
- liblgx, patched to the platform ICU
- package_manager_lib

Every artefact is linked with `-Wl,-z,max-page-size=16384`.

**Accept when** every `.so` has an unversioned `lib*.so` SONAME, only NDK/`libc++_shared` and
in-prefix NEEDED entries, and `LOAD p_align` 0x4000. A checker script enforces this.

### M3: the Logos runtime for Android

Script: `scripts/android/build-runtime.sh`. Revisions are pinned to the working desktop
closure (liblogos `db45024` and its flake.lock pins).

Components:
- logos-protocol
- logos-plugin-qt (qt_host), logos-cpp-sdk, logos-qt-sdk
- logos-module, process-stats
- logos-container, logos-container-subprocess
- logos-module-loader, logos-module-loader-qt (`liblogos_host_qt.so` with the no-JVM shim and
  patches B/C)
- liblogos_core, capability_module

The code generators run on the host against `gcc_64` Qt, or their Nix output is reused. The
patches in `patches/` are applied by the script.

**Accept when** a JNI harness APK on the emulator runs `logos_core_start()` and
`capability_module` comes up in a `liblogos_host_qt.so` child, checked with logcat and
`ps -A`.

### M4: Kotlin wrapper for liblogos

This is the user's first step.

- `android/logos-core`: an Android library (AAR) with the JNI shim `logos_jni.cpp` and a
  Kotlin API:

  ```kotlin
  class LogosCore(context: Context) {
      suspend fun start(modules: List<String>): Unit        // stage assets, start logos-qt thread
      fun knownModules(): List<String>
      suspend fun loadModule(name: String, deps: LoadDeps = LoadDeps.REQUIRED): Boolean
      suspend fun call(module: String, method: String, argsJson: String = "[]",
                       timeout: Duration = 20.seconds): String      // JSON result
      fun events(module: String, event: String): Flow<List<String>>
      suspend fun methods(module: String): String            // getPluginMethods
      fun stop()
  }
  ```
- `android/demo-app`: a single Activity that shows known and loaded modules and a call log.
- `scripts/android/stage.sh`: copies the prefix, runtime and modules into `jniLibs/<abi>` and
  `assets/`. It checks SONAME/NEEDED, 16 KB alignment, and that no `/nix/store` paths or
  glibc remain.
- The first module is a trivial core module built for Android (`hello_module`: `ping()`,
  `echo(s)`, one event), so the wrapper is proven before the heavy node arrives.

**Accept when**, on the emulator, `loadModule("hello_module")` returns `true`,
`call("hello_module","ping")` returns `"pong"`, and an event arrives through `events(...)`.
An instrumented test (`connectedAndroidTest`) asserts all of it.

### M5: blockchain_module on Android

Research is done ([`research/exp-bc-*.md`](research)). Every native piece is proven for
Android; the Android package itself has not yet been built or run.

- **Node library, `liblogos_blockchain.so`: already cross-built for x86_64 and arm64**
  (logos-blockchain `35a4a666`, the revision module `4b07e58` pins; Rust 1.98.1, NDK r27c,
  API 34, fat LTO, about 8.5 min).
  - The Bedrock circuits are built properly for Android. circom 2.2.2 generates the C++
    (its `.dat` output is byte-identical to the release), GMP 6.2.1 comes from rapidsnark's
    own `build_gmp.sh`, and the witness libraries are compiled with NDK clang++ against
    libc++. The zkeys, vkeys and `.dat` files come unchanged from the v0.5.7 release bundle.
  - rapidsnark uses the iden3 v0.0.8 Android prebuilts.
  - Two link fixes: `patches/logos-blockchain-circuits/` makes lbc-build emit libc++, and a
    one-line linker shim redirects librocksdb-sys's `-lstdc++` to `libc++_shared`.
  - Result: 87 MB (x86_64) / 82 MB (arm64), of which 35.6 MB is embedded circuit data. It
    needs only `libc++_shared`, libc, libdl and libm, and is 16 KB-aligned.
  - To do: turn the experiment into `scripts/android/build-blockchain.sh`.
- **Module plugin, `blockchain_module_plugin`:** built with logos-module-builder's CMake path
  from M3, plus an NDK build of libfyaml (and the boost/nlohmann headers).
  `patches/logos-blockchain-module/` silences the full-block-JSON-on-stderr log, which would
  flood logcat.
- **Node revision:** build the node at tag `0.3.0-rc.4`. It is the pin plus the devnet
  genesis, with identical C bindings, so `start(cfg, "")` joins devnet. The alternative is
  the pin plus `config/blockchain/deployment-devnet-0.3.0-rc.4.yaml` (with `tx_ttl`), which
  is what joined devnet on desktop.
- **Driving it:**
  1. `generate_user_config` with `config/blockchain/devnet-rc4-gen-args.json`, with absolute
     app-private paths and `http_addr` pinned to 127.0.0.1.
  2. `merge_user_config` with `follower-mode.extra.yaml`: `prolonged_bootstrap_period` of
     1 year, so the node syncs and follows the chain but never proves.
  3. `start` with a long timeout; `start()` blocks until the services are up.
  4. Poll `get_network_info` and `get_cryptarchia_info`, and subscribe to `newBlock`.

  On desktop this synced about 5k devnet blocks in about 40 s, then followed the head at
  about 0.1% CPU with 288 MB RSS.
- **Android runtime risks:**
  - rapidsnark writes `MyLogFile.log` into the working directory, so the host needs a
    writable cwd;
  - `/etc/resolv.conf` is missing (hickory DNS);
  - netlink (NAT gateway monitor) is restricted on Android 11+;
  - the node's panic hook calls `exit(1)`, which only kills the module's child process;
  - stopping within about 250 ms of start deadlocks.
- **Offline alternative:** a standalone single-node chain (`config/blockchain/02-*.diff`).
  It produces a block per slot and exercises the on-device PoL proving path (witness
  generator + rapidsnark).

**Accept when:**
- The app starts a devnet follower on the emulator, `n_peers` > 0, and the height climbs to
  the devnet tip, with `newBlock` events reaching Kotlin.
- Stretch: the standalone chain produces blocks with on-device proofs.

### M6: inter-module call

[`modules/bc_probe`](../modules/bc_probe), built and run on desktop, declares
`dependencies: ["blockchain_module"]`. It calls `get_cryptarchia_info`, `get_time_info` and
`get_network_info` through the generated `modules().blockchain_module.*` wrappers, in 0-1 ms
each, tracking the live height. On Android the app calls `bc_probe`, and liblogos's own QtRO
transport carries the hop, with no glue code.

**Accept when** the UI shows `bc_probe`'s live height and the logs show `capability_module`
issuing a token and the `bc_probe` → `blockchain_module` invocation.

### M7: size and packaging report, arm64-v8a, CI

- Per-ABI APK size table.
- An arm64 build.
- A release workflow if the build reproduces in CI.

## Risks, in order

1. The node's runtime behaviour on Android: DNS without `/etc/resolv.conf`, netlink, a
   writable cwd for rapidsnark, on-device proving time and memory. Its native build is
   proven.
2. The volume of native dependencies to cross-build (Boost, OpenSSL, libsodium, Qt glue):
   proven piece by piece, not yet end to end.
3. The Android 12+ phantom-process limit on long-lived module children. Untested.
4. The first-call race and nested-event-loop blocking in `lp_*`. Mitigated by the threading
   rules above.
5. arm64 and 16 KB devices are untested (no arm64 emulator on this host).

## Out of scope for this PoC

UI (QML) modules, which liblogos does not host (Basecamp's own plugin loader does); LEZ
wallet use; iOS; Play-store signing.
