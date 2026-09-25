# Investigation: liblogos_core + LEZ modules on Android

Date: 2026-09-25. This is the source-grounded research that has to come before any Android
build work. It answers the questions in the task brief, and each answer says how it was
established:

- **source**: read in the code or build files at the revision listed below
- **experiment**: observed running, on the desktop unless marked "emulator"
- **inferred**: reasoned from source or docs, but not observed

The per-track research notes behind this summary are in [`research/`](research/). Each one
lists its claims with file:line evidence, and each was adversarially re-checked by a second
agent. Paths in those notes point at the author's local checkouts, at the revisions below.

## Revisions examined

| Repo | Read (source) | Built / run (experiment) |
| --- | --- | --- |
| logos-blockchain/logos-execution-zone-module | `b220144` (2026-08-27, metadata 0.4.0) | `825d2a4` (lez_core 0.4.2) |
| logos-blockchain/logos-execution-zone | `87fca2a` (pinned by `b220144`), dev HEAD | as locked by `825d2a4` |
| logos-co/logos-liblogos | `7fee75b` (2026-09-14) | `db45024` (2026-09-22), via logoscore |
| logos-co/logos-protocol | `8bbc027` (0.9.0) | 0.9.0 |
| logos-co/logos-logoscore-cli | `6a0a2f4` | `6a0a2f4` |
| logos-co/logos-package-manager | `2c56ec7` | `2c56ec7` (lgpm) |
| logos-co/logos-rln-modules | `8bc94f0` (lez-rln 4.0.3, rln 0.8.2) | not built |
| logos-co/logos-nix | liblogos pins `f55bf91`; master `7c1eb8b` | not built |
| Qt | 6.9.2 (nixpkgs `e9f00bd`, desktop) | 6.11.1 official Android prebuilt (downloaded, inspected) |

Several local checkouts were behind upstream. Wherever the published build differs from the
local source, the published build wins (for example, the lez_core 0.4.2 API differs from the
local 0.4.0 header).

---

## 1. The module graph, and the "lez_core uses blockchain module" framing

### What has to be loaded

Only **`lez_core`**, plus `capability_module`, which liblogos loads itself at
`logos_core_start()`.

- `lez_core` declares `"dependencies": []`, defines no events, and wraps exactly one native
  library, `libwallet_ffi.so`
  (`logos-execution-zone-module/metadata.json:2,15,24-27`) — **source**.
- `libwallet_ffi.so` is the Rust crate `wallet-ffi` in logos-execution-zone
  (`lez/wallet-ffi`, cdylib), i.e. the LEZ light wallet — **source**.
- Loaded on its own under logoscore, `load-module lez_core` returns
  `{"dependencies_loaded":[],"status":"ok","version":"0.4.2"}` in 27 ms — **experiment**.
- `capability_module` is required for any module-to-module call. It mints the per-target
  tokens that `LogosAPIClient` presents, and without it cross-module calls are refused with
  "auth token not recognized" — **experiment** (desktop run with capability_module crashed).

### The framing was wrong at the module level

"lez_core uses the blockchain module" needs correcting:

- **No Logos Core module dependency exists in either direction.** `lez_core`,
  `blockchain_module` (logos-blockchain-module) and `lez_indexer_module` all declare
  `dependencies: []` — **source**.
- **The L1 relationship is at the protocol level, and it is server-side.** The sequencer
  publishes each L2 block as an inscription on a Bedrock (L1) channel. The L1 gives LEZ data
  availability, ordering and finality, and carries the deposit/withdraw bridge. The LEZ
  indexer rebuilds L2 state by reading that channel from an L1 node. "The L2 uses the L1 for
  indexing" is therefore imprecise: the L1 is the L2's DA/ordering/finality layer, and the
  *indexer* reads it — **source** (`logos-execution-zone` sequencer and indexer code).
- **The wallet uses neither the L1 nor the indexer.** `lez_core` talks only to an LEZ
  sequencer, over HTTPS JSON-RPC, default `https://testnet.lez.logos.co` — **source**.
- **The only other L1 link is at build time.** `wallet_ffi` statically links
  logos-blockchain Rust crates, and through them the Bedrock circuit code (see §3) —
  **source**.
- **The likely origin of the framing:** the `blockchain-modules-release` catalog publishes
  `lez_core` together with `blockchain_module`, `blockchain_ui`, `lez_indexer_module`,
  `lez_explorer_ui` and `lez_wallet_ui`. That is joint packaging, not a dependency
  (`blockchain-modules-release/.gitmodules`) — **source**.

### The RLN chain the Electron POC loaded does not apply here

The Electron POC loaded `liblogos_rln_module`, `lez_core` and `liblogos_lez_rln_module` to
bring up delivery. That was an artefact of a delivery build, not a LEZ requirement:

- The Electron POC's delivery `.lgx` (0.2.1) declared the dependency
  `["liblogos_rln_module"]`, which at the time existed only on the logos-delivery-module
  branch `impl-plugable-rln-api-module`. `lez_core` was purely transitive:
  rln 0.7.0 → lez_rln 2.1.0 → lez_core 0.4.1 — **source**.
- Current delivery master (0.3.0) declares RLN as an *optional* dependency
  (`optional_dependencies: ["liblogos_rln_module"]`) — **source** (upstream flake).
- **`liblogos_lez_rln_module` 3.0.0+ (2026-09-14) no longer depends on `lez_core`.** It links
  `wallet_ffi` itself and holds its own wallet handle
  (`logos-rln-modules/logos-lez-rln-module/flake.nix:13-15`: "No module-level dependencies
  since 3.0.0"). The logos-modules-dev README line "lez_core is here as a dependency of
  liblogos_lez_rln_module" is stale; it was true up to lez-rln 2.x — **source**.

None of delivery, `liblogos_rln_module` or `liblogos_lez_rln_module` is needed for a LEZ demo.

### Who actually calls lez_core (inter-module consumers)

Modules that declare `lez_core` and call it through generated `modules().lez_core.*`
wrappers:

- Core modules: `token_module`, `amm_module` and `stablecoin_module` (in lez-programs), and
  logos-amm-module.
- UI modules: `lez_wallet_ui`, `amm_ui`, `token_ui` and `rln_membership_ui`.

The read-only calls they use are `account_id_to_base58/from_base58`, `get_account_public`
and `list_accounts` — **source**.

For this PoC, the inter-module demo is a small purpose-built universal module,
[`modules/lez_probe`](../modules/lez_probe). It has `dependencies: ["lez_core"]` and calls
`modules().lez_core.version() / account_id_to_base58() / account_id_from_base58()`. On
desktop:

- It built in 15 s.
- `load-module lez_probe` auto-loaded `lez_core` first.
- Cross-module calls returned in 0-2 ms.
- `ss` showed the `lez_probe` host process connected directly to `lez_core`'s host socket,
  plus one connection to `capability_module`'s socket.

The same call edge also worked under `--access-policy enforce` — **experiment**. This is
liblogos's own transport doing the work, with no glue code written for it: the answer to "why
can't we reuse existing inter-module comms".

An unmodified upstream consumer, `token_module.programInfo()`, would also work without glue.
It costs an Android build of the Rust `token_ffi` crate (risc0), and on desktop it needed 1035
derivations, so it is a stretch goal.

---

## 2. What "real work" means for lez_core

`lez_core` 0.4.2 exposes 40 methods and 0 events (`logoscore module-info lez_core`). The
published 0.4.2 API differs from the local 0.4.0 header: pinata/register/vault were removed,
and payer arguments were added. By network need, the methods fall into four groups:

| Needs | Methods |
| --- | --- |
| Nothing (no wallet, no network) | `name`, `version` (hard-coded "0.3.0"), `account_id_to_base58/from_base58`, `*_elf` getters |
| An open wallet, local only | `create_account_public/private`, `list_accounts`, key getters, labels, `get_balance(private)` |
| Sequencer, read | `get_current_block_height`, `get_account_public`, `get_balance(public)`, `sync_to_block`, `poll_transaction_status` |
| Sequencer, write | `transfer_public`, `send_generic_public_transaction` (public, no proof); private/shielded variants (need a local RISC Zero proof) |

Nothing in `lez_core` calls the L1 or an indexer directly — **source**.

Gotchas found:

- **`create_new`/`open` are not purely local.** The first time a sequencer URL is used, the
  wallet calibrates by sending `calibration_limit` `getLastBlockId` requests (default 100,
  about 35 s against the testnet). That exceeds the 20 s default IPC timeout, so the caller
  sees a timeout while the module finishes — **experiment**. Writing `wallet_config.json` with
  `calibration_limit: 3-5` first brings `open` down to 1.08 s — **experiment**.
- **`save()` also uses the network.** It rotates the client, which sends `getLastBlockId` —
  **source**.
- **One wallet per host.** `lez_core` holds exactly one wallet handle and has no
  close/destroy method, and it executes calls one at a time. A 35 s `create_new` delayed the
  next call by 14.9 s — **experiment**.
- **The public testnet is live.** Measured 2026-09-25 by experiment:
  - `https://testnet.lez.logos.co`, block height ~23.8k
  - the pinata faucet account `EfQhKQAkX2FJiwNii2WFQsGndjvF1Mzd7RuVe7QdPLw7` holds 1,481,850
    (difficulty 3)
- **Writes are version-sensitive.** The testnet's program IDs do not match LEZ dev HEAD's
  image IDs — **experiment**. Opening a wallet and reading work across the version skew
  (0.4.2 against the testnet — **experiment**), but a write names program IDs, so the
  `lez_core`/LEZ revision must match the deployed sequencer — **inferred**. Which revision
  matches is still open.

Recommended demo sequence, in order of how little infrastructure it needs:

1. **Offline:** `name`, `version`, then an `account_id_to_base58` → `from_base58` round trip.
   Directly and through `lez_probe`.
2. **Testnet read** (outbound HTTPS only):
   1. Pre-write `wallet_config.json` with `calibration_limit` 3.
   2. `create_new`, then `create_account_public`, `list_accounts`, `save`.
   3. Poll `get_current_block_height`. A ticking block height is LEZ's equivalent of
      delivery's `connectionStateChanged`.
   4. Read the pinata account with `get_account_public`.
3. **Stretch:** a public write, only against a version-matched sequencer. Candidates are the
   testnet, if a matching revision is identified, or a local standalone LEZ sequencer
   (`cargo run --features standalone -p sequencer_service`).

The offline and testnet-read steps were run on desktop through liblogos (logoscore): offline
calls, `create_new`, account creation, `save`, and `get_current_block_height` = 23791 in
671 ms — **experiment**.

---

## 3. "Building blockchain circuits": what it actually is

It is two unrelated ZK stacks that the wallet library pulls in:

| Component | Needed by | Build vs runtime | Android status | Recommendation |
| --- | --- | --- | --- | --- |
| RISC Zero guest ELFs (17 programs + `privacy_preserving_circuit.bin`) | wallet-ffi (image IDs, `*_elf` getters) | Prebuilt, committed under `artifacts/`, embedded with `include_bytes!`. No risc0 toolchain or Docker needed. | Architecture-independent data | Keep as is |
| RISC Zero prover (C++ CPU kernels + 59.8 MB recursion zkr zip) | Private/shielded transactions only (`prove` feature, on by default) | Compiled and embedded in `libwallet_ffi.so` | Unverified on Android; heavy | Build with `--no-default-features` (public-only). Private transactions will then fail cleanly. |
| Bedrock circom circuits (PoL, PoQ, PoC, Signature witness libs) + GMP + rapidsnark | logos-blockchain-core, reached through **one** `BasicAuthCredentials` conversion in `lez/common/src/config.rs:5,51-55` | Static C++ libs (`LBC_ROOT_DIR`) and zkeys embedded at build time | **No Android bundle exists** (release matrix: linux x86_64/aarch64, macos aarch64, windows x86_64). Host bundles are glibc/libstdc++ and cannot be relinked. | **Patch the edge out** of `lez/common`, a few lines. The wallet never uses these proofs. Fallback: NDK-built or stub libs, reusing the release zkeys. |
| zerokit RLN (arkworks Groth16, depth-10 zkey embedded) | `liblogos_rln_module` only | Pure Rust | Cross-compiles; precedent in logos-android-wrap-poc | Not needed for LEZ |

- **source**, for every row: the verifier traced the Cargo lock graph and found
  `common → logos-blockchain-common-http-client` to be the *only* LEZ→logos-blockchain edge.
- **experiment**, for what the shipped `.so` embeds: zkr present, Bedrock zkeys dead-stripped,
  PoC witness code and GMP still linked.

**Plain answer:** a minimal public-only LEZ demo on Android needs **no circuit at runtime**,
and should not compile any circuit for Android. Nothing here is on-device circuit
compilation. circom, snarkjs, cargo-risczero and Docker are host tools only, and the demo
needs none of them.

What it does need is a wallet-ffi build that:
- skips the Bedrock crate edge (patch), and
- drops `prove` (feature flag), and
- replaces two non-circuit native blockers:
  - `pcsc-sys`, which the mandatory Keycard smart-card support pulls in and which needs
    libpcsclite (none on Android): a stub or a feature gate;
  - TLS verification: see §6.

---

## 4. liblogos_core and Qt: existing Android support upstream

### None in liblogos, logos-module-builder or LEZ

- The liblogos flake has no android/cross/mobile output. Its systems are
  aarch64/x86_64 darwin and linux, plus a Windows pseudo-system — **source**.
- logos-module-builder has no Android references. Published `.lgx` variants are
  darwin-arm64, linux-amd64, linux-arm64 and windows-x86_64 only — **source**.
- There are no Kotlin, Gradle, JNI or UniFFI files in any Logos repo. Mobile Logos Core is on
  roadmaps (Testnet v0.3 "Mobile iOS/Android support"), but nothing is built — **source**.
- An old iOS demo in logos-basecamp (`qt-ios`) calls liblogos functions that no longer exist
  — **source**.

### The one real piece: logos-nix master's Android Qt set

logos-nix master (added 2026-09-07, commit `5378de5`) has an opt-in `aarch64-android` set.
It cross-builds Qt 6.11.1 from source (API 28, NDK 27.0, arm64-v8a only) and adds a
`mkQtAndroidApk` packager. Its limits:

- **No QtRemoteObjects wiring**, although the whole stack needs QtRO.
- **Never built by CI** and not in the Logos cache.
- **arm64 only.** The arm64 AVD does not boot on this x86_64 host, so the first on-device
  target has to be x86_64.
- **Not the revision liblogos pins** (`f55bf91`).

All of the above — **source** (plus the verifier's eval).

### The practical route: official Qt 6.11.1 Android prebuilts

- Official prebuilts exist for arm64_v8a and x86_64, with the qtremoteobjects add-on,
  installable with aqtinstall — **experiment**, downloaded.
- The arm64 prebuilt was built with NDK r27c, the same NDK installed here. It is min API 28,
  and every `.so` is 16 KB page-aligned — **experiment**, measured.
- Qt 6.9.2, the desktop pin, is **not** 16 KB-ready on Android; 16 KB support arrived in
  6.9.3 — **source**.

### The "Qt version trap", re-derived

No Logos binary uses Qt private API: there are 0 `Qt_6_PRIVATE_API` imports in liblogos_core,
the protocol, qt_host, logos_host_qt and the module plugins — **experiment**, ELF check. Only
Qt's own libraries (QtRemoteObjects, QtNetwork) import QtCore private API.

So the Electron POC's "must match the exact nixpkgs Qt" becomes, on Android: *every Qt
library comes from one Qt build, host tools (moc/repc) are the same version, and every Logos
component is compiled against that Qt.* Building everything for Android ourselves makes that
automatic.

One real constraint remains: **the QtRO wire protocol is Qt-version-sensitive**, so every
QtRO peer must use the same Qt. An Android app on 6.11.1 must not talk QtRO to a desktop
6.9.2 daemon — **source** (logos-cpp-sdk flake comment).

### Embedding Qt in a plain Kotlin app

- **The Qt Java classes must be packaged.** `libQt6Core`'s `JNI_OnLoad` does
  `FindClass("org/qtproject/qt/android/QtNative")` and returns `JNI_ERR` if it is missing. So
  a plain Kotlin app that `System.loadLibrary`s Qt Core must package `Qt6Android.jar` — or
  load Qt Core only as a DT_NEEDED dependency, in which case `JNI_OnLoad` never runs.
  Whether that is enough is one of the gating experiments below — **source**.
- **Qt's Android context will be null.** Without `QtActivity`/`QtService` the context is
  null. Qt-free paths do not care. Nothing in the Logos runtime uses `QStandardPaths`,
  `QSysInfo`, `QTimeZone` or `QNetworkInformation` — **source**.
- **One thread for all Qt work.** Qt itself runs its loop on a dedicated thread
  (`qtMainLoopThread`). The app should do the same: create `QCoreApplication`, call
  `logos_core_start()` and run `exec()`, all on one dedicated thread. The Electron POC's
  "a dedicated Qt thread does not work" only applied when Qt objects were created on a
  different thread from the one running `exec()` — **experiment** (§5).
- **Set `TMPDIR`, and keep it short.** QtRO sockets are `$TMPDIR/logos_<module>_<12hex>` and
  must fit in `sun_path` (108 bytes). With an 82-character `TMPDIR`, `capability_module`
  failed to listen and crashed with SIGSEGV — **experiment**.

---

## 5. Loading and calling modules

### Loading: the `logos_core_*` C ABI

The C ABI is 20 functions — **source + experiment**, ELF exports:
init / add_modules_dir / start / cleanup, get_loaded/known_modules, load/unload_module,
optional_load_report, dependency queries, get_modules_info, process_module, get_token,
get_module_stats, set_persistence_base_path, set_module_transports, set_access_policy and
refresh_modules.

Changes since the Electron POC:

- `logos_core_load_module(name, LogosLoadDeps)` now takes an enum
  (`MODULE_ONLY` / `REQUIRED_DEPS` / `REQUIRED_AND_OPTIONAL`), not a bool.
- `logos_core_init` is a no-op. The embedder must create the `QCoreApplication`.
- Strings returned by `logos_core_*` are allocated with `new[]`, so the JNI shim must be C++
  to free them correctly. Strings returned by `lp_*` use `lp_string_free`.

**Every module runs in its own `logos_host_qt` subprocess.** This is the default and only
container:

- It is logos-container-subprocess: `posix_spawn`, with the token passed over stdin, and one
  QtRO LocalSocket per module.
- The container is chosen at **link time**. `registerLoader()` cannot override the default,
  because the default composite loader is registered first and accepts everything.
- No in-process container exists anywhere.

All of the above — **source**, spot-checked by the critic in
`module_manager.cpp:306-316` and `module_loader_registry.cpp:27-30`.

`logos-protocol` does have an in-process transport, `LogosMode::Local`, documented as "mobile
apps, single process". But no code in liblogos produces it, and it is a per-image static that
statically linked plugins don't share — **source**.

### Calling: the Qt-free `lp_*` route works in-process

**This corrects the Electron POC's central table.** Its README row "Call a module
in-process | LogosAPI / LogosAPIClient, C++ | no" is no longer true.
[`experiments/lp-inprocess`](../experiments/lp-inprocess) runs a **pure-C** caller with no Qt
headers:

1. It loads `lez_core` with `logos_core_load_module` from a non-Qt thread (23 ms).
2. It calls `version`, `name` and `account_id_to_base58` through `lp_client_create` +
   `lp_invoke`, each round trip taking 0-4 ms.
3. An `lp_invoke_async` callback arrives on the Qt thread.

The only Qt C++ is the ~60-line [`qt_loop.cpp`](../experiments/lp-inprocess/qt_loop.cpp),
which owns the `QCoreApplication`, calls `logos_core_start()` and runs `exec()` on one
dedicated thread. [Log](../experiments/lp-inprocess/run-2026-09-25.log) — **experiment**.

Why it works:

- `liblogos_core` uses the shared `liblogos_protocol.so`, so there is exactly one
  `TokenManager` per process.
- After each load, core stores the module's root token there.
- An `lp_*` client in the same process presents that token, with no handshake, no
  core_service, no daemon and no TCP.

Calls are marshalled onto the `QCoreApplication` thread with `BlockingQueuedConnection`.

Caveats — **experiment + source**:

| Caveat | Consequence |
| --- | --- |
| `lp_get_methods` returns `[]` (remote introspection is not implemented) | Method names come from the module's `.lidl`/`module-info`. `lp_invoke(target, "getPluginMethods")` is probably the runtime alternative; being checked. |
| An unknown method returns `LP_OK` + `null` | The JNI layer should validate method names. |
| `lp_subscribe` has no wildcard | Subscribe to named events. `lez_core` emits none anyway. |
| `BlockingQueuedConnection` has no timeout | A busy or wedged Qt thread blocks every caller. Never do slow work on the Qt thread. |
| `lp_provider_*` is a stub | The app can *consume* modules but cannot itself be a module through a C ABI. |

The alternative routes, ranked:

| Route | Qt C++ in the app | Second process | Verdict |
| --- | --- | --- | --- |
| **`lp_*` in-process** (above) | ~60 lines (QCoreApplication + exec) | No | **Recommended**; desktop-verified |
| `LogosAPIClient` JNI shim (Electron 0.3.0) | ~190 lines | No | Fallback, e.g. for wildcard events |
| In-process `core_service` + `lp_*` over TCP | ~1,100+ lines ported from logoscore-cli | No | Not worth it: core_service is not a library |
| `logosctl` daemon as a child process | none | Yes | Worst on Android: exec rules, phantom-process killer, lifecycle |

### Where the modules run on Android: the open decision

Because liblogos spawns a `logos_host_qt` child per module, Android needs one of these two:

**(A) Keep the subprocess container.**

What it requires:
- Ship `logos_host_qt` as `jniLibs/<abi>/liblogos_host_qt.so` with
  `useLegacyPackaging = true`, so it is extracted to `nativeLibraryDir`, the only place an
  app targeting SDK 29+ may exec from.
- Set `LOGOS_HOST_PATH` to point at it.
- Use **minSdk 33**: `logos_host` calls `backtrace()` (API 33), and
  `POSIX_SPAWN_CLOEXEC_DEFAULT` returns EINVAL below API 33 — **source**.

What it risks:
- Each child runs **without a JavaVM**, so any Qt path that reaches JNI would crash —
  *being tested on the emulator*.
- `wallet_ffi`'s TLS verifier (rustls-platform-verifier) *requires* a JavaVM on Android and
  panics without one. HTTPS from `lez_core` would therefore need a patch (webpki roots via
  jsonrpsee `with_custom_cert_store`) or a plain-HTTP sequencer — **source + inferred**.
- Android 12+ kills "phantom" child processes beyond 32 system-wide.

**(B) Write an in-process `ModuleContainer`**, an upstream-quality change. It needs:

- a new container, selected at build time;
- reimplementing `module_initializer`, which today is compiled only into the `logos_host_qt`
  executable;
- linking plugins against the shared `liblogos_protocol`/`qt_host`, so that there is a single
  `TokenManager`;
- reproducing `capability_module`'s host-services grant.

It removes the JVM-less-child, TLS and phantom-process problems.

The gating experiments decide between (A) and (B). The plan starts with (A) because it needs
no liblogos redesign, and keeps (B) as the escalation path.

---

## 6. Packaging: the Android analogue of `bundle-runtime.js`

The category of problem recurs, as predicted: Nix builds carry absolute `/nix/store`
RUNPATHs and glibc/libstdc++. On Android the fix is to rebuild, not relink:

- **Nothing from Nix Linux can be reused.** Rebuild everything with NDK r27c against
  `libc++_shared`. Qt's Android build refuses anything except `ANDROID_STL=c++_shared` —
  **source**. That includes the Qt stack, Boost 1.87, OpenSSL 3, spdlog/fmt, liblgx (ICU,
  libsodium, zlib), `package_manager_lib`, the Logos runtime, the module plugins and
  `wallet_ffi`.
- **Bionic honours `DT_RUNPATH`/`$ORIGIN`** (API ≥ 24) and resolves `DT_NEEDED` by file name
  in the app namespace — **source**.
- **Library naming.**
  - Only `lib*.so` entries are packaged and extracted, so versioned sonames
    (`libssl.so.3`, `libboost_*.so.1.87.0`, `libicuuc.so.76`) must be renamed, with
    `SONAME` and `DT_NEEDED` rewritten to match. It is better to fix the names at link time
    than with patchelf.
  - Qt's Android build already uses ABI-suffixed names (`libQt6Core_x86_64.so`).
  - Module plugins (`<name>_plugin.so`) either get renamed to `lib*.so` along with their
    manifest `main`, or ship as `.lgx` in assets, extracted read-only to `filesDir` and
    `dlopen`ed from there. `dlopen` from app data is allowed; `execve` is not.
  - All — **source**.
- **16 KB pages.** NDK r27c still defaults to 4 KB, as the sibling repo's libs are. Every
  non-Qt artefact needs `-Wl,-z,max-page-size=16384`, and patchelf needs
  `--page-size 16384` — **experiment**.
- **Variant names.** liblgx's `lgx_host_variant()` has no `__ANDROID__` branch, so an NDK
  build reports `linux-x86_64` / `linux-arm64` (plus `-dev` unless `LGPM_PORTABLE_BUILD`).
  Manifests must use that key until an `android-*` variant is added upstream — **source**.
- **Environment.** `TMPDIR` (short), `HOME`, `LOGOS_HOST_PATH` and
  `logos_core_set_persistence_base_path(filesDir/...)` must all be set before starting.

---

## 7. Native size (pre-Android estimate)

Measured on desktop x86_64 — **experiment**:

| Piece | Size |
| --- | --- |
| `libwallet_ffi.so` | 108.6 MB raw, 104.1 MB stripped, 68.3 MB gzip. `.rodata` is 72 MB, of which ~60 MB is the RISC Zero zkr, removed by `--no-default-features`. |
| lez_core plugin | 2.4 MB |
| Logos runtime (core, protocol, qt_host, lgx, package manager, logos_host_qt, 2 built-in modules) | ≈12 MB stripped |
| Qt Core + Network + RemoteObjects (desktop) | ≈10.6 MB |
| OpenSSL | ≈7.8 MB |
| ICU (via liblgx) | ≈37.7 MB mapped. Avoidable with a port to the platform ICU C API (API 31+); being tested. |

A no-prove, Bedrock-free `wallet_ffi` should be far smaller than 104 MB — **inferred**; the
Android build is being tested.

---

## 8. Gating experiments

Running now. Results will be recorded in [`experiments/`](../experiments):

| # | Question | Decides |
| --- | --- | --- |
| X1 | Do QCoreApplication, QtRO over a local socket, and QPluginLoader work in a native executable with **no JVM** on the x86_64 emulator? | Subprocess route (A) vs in-process container (B) |
| X2 | From a real APK: exec a helper from `nativeLibraryDir`, SELinux on the local socket, and whether `Qt6Android.jar` is needed | App bootstrap design |
| X3/X4 | Does `wallet-ffi` build for `x86_64-linux-android` with the `lez/common` patch, no `prove` and a pcsclite stub? Size, NEEDED libs | Whether lez_core can run on Android at all |
| X7 | `getPluginMethods` via `lp_invoke`, the first-call token race, blocking behaviour | JNI threading and timeout policy |
| X8 | Can liblgx use the NDK's ICU C API instead of bundling ICU? | ~30 MB of APK |
| X9 | Do Boost 1.87 and logos-container-subprocess compile with the NDK? | Remaining port effort for the runtime |

---

## 9. What would need changing upstream (all unforked for now)

Candidate patches, each narrow:

1. **logos-execution-zone:** feature-gate the `BasicAuthCredentials` conversion in
   `lez/common`, which drops the whole Bedrock circuit, rapidsnark and GMP tree from client
   builds. Also feature-gate Keycard/pcsc, and allow a webpki-roots TLS option for
   JVM-less/embedded use.
2. **logos-package (liblgx):** an `__ANDROID__` branch in `lgx_host_variant()`, and optionally
   the ICU C-API port of `path_normalizer`.
3. **logos-module-loader-qt / logos-container-subprocess:** guard `backtrace()` and
   `POSIX_SPAWN_CLOEXEC_DEFAULT` by API level; add a `BUILD_TESTING` switch for the
   unconditional googletest `FetchContent`.
4. **logos-nix:** add qtremoteobjects + repc to the Android overlay, and an x86_64-android
   target.
5. **Stale docs:**
   - logos-modules-dev README: the lez_rln → lez_core line.
   - liblogos README: the bool `load_module` signature.
   - liblogos spec.md: "init creates QCoreApplication".
   - liblogos `module_manager.h` / spec.md: says loaders compose additively; they don't.
   - `lez_core`: `version()` hard-codes "0.3.0".

Per the sibling project's convention, forks are created only after the user confirms. So far
all patches are applied only in local scratch copies.
