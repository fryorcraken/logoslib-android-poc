# The blockchain node library on Android

> M5/M6. Status: `liblogos_blockchain.so`, `libfyaml.so`, the `blockchain_module` plugin
> and `bc_probe` build reproducibly for x86_64 with the scripts below and pass the prefix and
> staging checks. On the x86_64 API 34 emulator the demo app loads both modules, each in its
> own `liblogos_host_qt.so` child, and runs the node: it joins devnet 0.3.0-rc.4 as a follower
> and syncs to the tip in about 35 s, and bc_probe reads the live height from it. The node
> needed one upstream patch to start at all on Android (DNS, below). How to run it and the
> measurements: [`android-build.md`](android-build.md), "M5/M6".

`blockchain_module` is a thin Qt plugin around the Logos blockchain node. The node itself is
Rust: logos-blockchain's `logos-blockchain-c` crate, built as the C library
`liblogos_blockchain.so` with the cbindgen header `logos_blockchain.h` (54 functions, of which
the module calls 52). The plugin links it as its external library and also links libfyaml,
which it uses to read the user config. This page covers how both libraries are built for
Android, what they are pinned to, and what is known to go wrong at run time.

## Build

```sh
bash scripts/android/build-blockchain.sh [x86_64|arm64-v8a]   # node library, ~11 min cold
bash scripts/android/build-libfyaml.sh   [x86_64|arm64-v8a]   # libfyaml, seconds
bash scripts/android/check-prefix.sh     [x86_64|arm64-v8a]   # acceptance check of the prefix
bash scripts/android/build-blockchain-module.sh [x86_64|arm64-v8a]   # blockchain_module + bc_probe, ~25 s
bash scripts/android/stage.sh x86_64 capability_module hello_module blockchain_module bc_probe
```

`build-blockchain-module.sh` needs the M3 runtime (`build-runtime.sh`) as well. Its plugin
build is described in "The module plugin" below.

The scripts install into `build/android/<abi>/prefix` next to the M2 dependencies:

- `lib/liblogos_blockchain.so` and `include/logos_blockchain.h`
- `lib/libfyaml.so`, `include/libfyaml.h` and `lib/pkgconfig/libfyaml.pc`
- `share/logos-android/blockchain-manifest.txt`, which records what the library was built from

Both scripts can be re-run. Each step keeps a stamp and is skipped while its inputs are
unchanged; `FORCE=1` redoes everything. They use `JOBS=8` unless told otherwise. Logs go to
`build/logs/build-{blockchain,libfyaml}-<abi>.log`. The pins are in
`scripts/android/versions-blockchain.env`.

## Pins

| What | Pin | Why |
| --- | --- | --- |
| logos-blockchain | tag `0.3.0-rc.4` (`39916dc8`) | See "Node revision" below |
| Rust | 1.98.1 | The node's `rust-toolchain.toml` |
| Bedrock circuits | v0.5.7 (`ebf7ddf5`) | The lbc tag in the node's `Cargo.lock`; the script checks it |
| Circuit data (zkeys, vkeys, `.dat`) | v0.5.7 `linux-x86_64` release bundle, sha256 `92a0c6ad…` | Also checked against the SRI in the circuits repo's `circuits-nix-hashes.json` |
| circom | 2.2.2 (`e410b0d5`) | `CIRCOM_TAG` in the circuits CI |
| GMP | 6.2.1 | What rapidsnark's `build_gmp.sh` builds |
| rapidsnark | iden3 v0.0.8 Android prebuilts (sha256-pinned per ABI) | What rust-rapidsnark `e91187f8` maps Android targets to |
| libfyaml | 0.9, release tarball | The version nixpkgs 25.11 gives the desktop module |
| NDK / API | r27c / 34 | As the rest of the prefix (`versions.env`) |

### Node revision

logos-blockchain-module `4b07e58` pins logos-blockchain `35a4a666`. Tag `0.3.0-rc.4` is that
commit plus three more: the devnet genesis ceremony (`settings.yaml`, the deployment compiled
into the node), an `inscribe.yaml` update, and a Cargo version bump with a reformatted
`Cargo.toml`. `git diff 35a4a666 0.3.0-rc.4 -- c-bindings/` is empty. The header is generated
from `c-bindings/src` alone, so it is the same too; the build checks this by comparing the
header's sha256 with the one generated at the pin. The circuits, rust-rapidsnark and toolchain
pins are also the same at both revisions.

Building the tag means `start(cfg, "")` joins devnet 0.3.0-rc.4 with no deployment file. A
build of the pin would need `config/blockchain/deployment-devnet-0.3.0-rc.4.yaml` passed to
`start()`. Devnet protocol names change with every RC, so the next devnet RC will leave this
build behind.

## How the node library is built

The recipe is the bc-android-build experiment ([research/exp-bc-android-build.md](research/exp-bc-android-build.md)),
turned into script steps:

1. **Sources.** logos-blockchain at the tag, plus `patches/logos-blockchain/`: a `[patch]` entry
   that points lbc-build at the patched circuits copy, and the matching one-line `Cargo.lock`
   change. The patch applies to both the tag and `35a4a666`. Since M5 also
   `logos-blockchain-02-android-dns-resolver-fallback.diff`, without which the node cannot
   start on Android (see "Runtime caveats"). The circuits repo at v0.5.7, plus
   `patches/logos-blockchain-circuits/`: an `android-lib` target in the witness Makefile, and
   lbc-build emitting `-lc++` rather than `-lstdc++` on Android. The circuits submodules
   circomlib, rapidsnark and `rapidsnark/depends/json` are fetched too.
2. **Circuits, built for real.**
   - circom 2.2.2 generates the C++ for PoC, PoL, PoQ and Signature. The CI's `main.cpp`
     return-0 sed and `fix_calcwit_leak.sh` are applied.
   - Every generated `.dat` must be byte-identical to the release's `witness_generator.dat`, or
     the build stops.
   - GMP comes from rapidsnark's own `build_gmp.sh`, run unmodified.
   - The four witness libraries are compiled with NDK clang++ against libc++. Each exports only
     its two `<circuit>_generate_witness*` functions.
3. **Android `LBC_ROOT_DIR`** (`build/android/<abi>/lbc`). It holds the NDK-built libraries and
   GMP. The proving keys, verification keys and `.dat` files are taken unchanged from the
   release bundle, and the build checks that they match it byte for byte. The keys are never
   regenerated, because each release's zkeys contain a random trusted-setup contribution.
4. **rapidsnark.** The iden3 v0.0.8 Android zip is used as `RAPIDSNARK_LIB_DIR`.
5. **cargo.** The build runs
   `cargo build -p logos-blockchain-c --release --locked --target <triple>`, using the
   release profile: fat LTO, `codegen-units=1` and strip.
   - `CC`, `CXX`, `AR`, `RANLIB` and the linker are the NDK tools at API 34.
   - `BINDGEN_EXTRA_CLANG_ARGS` points at the NDK sysroot, for librocksdb-sys.
   - `RUSTFLAGS` adds:
     - `-Wl,-z,max-page-size=16384` and `--build-id`;
     - `-Wl,-soname,liblogos_blockchain.so`. rustc gives a cdylib no SONAME, and without one
       the plugin, linked by path, would NEED an absolute build path;
     - `-L native=<shim>`, where the shim holds a one-line `libstdc++.so` linker script,
       `INPUT(-lc++_shared)`. librocksdb-sys links `-lstdc++` on every `*linux*` triple,
       Android included, and the shim sends that to libc++_shared;
     - `--remap-path-prefix`, which keeps host paths out of panic strings.

   Nothing is downloaded at build time. `LBC_ROOT_DIR` and `RAPIDSNARK_LIB_DIR` are both set,
   so lbc-build and rust-rapidsnark skip their release downloads.
6. **Checks.** The build fails unless all of the following hold:
   - NEEDED is exactly `libc++_shared.so libc.so libdl.so libm.so`;
   - the SONAME is `liblogos_blockchain.so`;
   - every `PT_LOAD` has `p_align` 0x4000 (16 KB pages);
   - there are no text relocations;
   - all header functions are exported;
   - the header matches the pinned sha256.

Result for x86_64, built 2026-09-25 (with the DNS patch: 87,148,920 bytes):

| | |
| --- | --- |
| `liblogos_blockchain.so` | 87,147,640 bytes before the DNS patch. The release profile already strips it; `llvm-strip --strip-all` saves 512 bytes more. About 48.8 MB of it is `.rodata`, 35.6 MB of which is embedded circuit data. |
| Dynamic section | NEEDED `libc++_shared.so libc.so libdl.so libm.so`; SONAME `liblogos_blockchain.so`; `BIND_NOW`; a build id; no RUNPATH |
| Alignment | 4 `PT_LOAD` segments, all `p_align` 0x4000 |
| C API | 54 of 54 header functions exported, nothing extra; `blockchain_module` 4b07e58 calls 52, and all are present; header byte-identical to the one at `35a4a666` |
| `check-prefix.sh x86_64` | OK: every one of the 381 undefined dynamic symbols resolves within the NEEDED closure |
| Cold build | About 10.5 min with `JOBS=8`, while another build shared the machine: cargo 558 s, circom 27 s, GMP 20 s, witness libraries 7 s, the rest under 20 s |
| Re-run | A no-op re-run takes under 1 s. Adding a patch re-prepares the source; the rebuild then took 341 s + 317 s here: `git clean` had deleted the cbindgen header, which the c-bindings build script only regenerates when `c-bindings/src` changes. The script now touches `c-bindings/build.rs` when the header is missing |
| Disk | 1.8 GB of cargo target, about 0.5 GB of sources |

Host paths are down from about 850 to 2, both from C/C++ inputs that `--remap-path-prefix` does
not cover. They are cosmetic.

The app must ship `libc++_shared.so` from the NDK alongside the library.

For arm64-v8a the whole script has run (2026-09-26, with the DNS patch): cargo 338 s with
`JOBS=8`, `liblogos_blockchain.so` 82,186,680 bytes, AArch64, the same NEEDED, SONAME, 16 KB
alignment and 54 of 54 header functions, and the header identical to the pin's. It ships in
the arm64-v8a release APK (`scripts/android/build-release.sh`).

## libfyaml

The desktop module's `.lgx` ships `libfyaml.so.0`, which is nixpkgs' libfyaml 0.9 built with
autotools and linked shared. `build-libfyaml.sh` builds the same 0.9 release with the NDK, with
these differences:

- **SONAME:** it is unversioned, `libfyaml.so` (libtool `-avoid-version`). An APK only packages
  `lib*.so`, so a NEEDED entry for `libfyaml.so.0` could never be satisfied.
- **pthread:** bionic has pthreads in libc and has no libpthread, but libfyaml's configure
  forces `-lpthread`. An empty `libpthread.a` stub satisfies it, and the script removes
  `-lpthread` from the installed `libfyaml.pc`.
- **qsort_r:** bionic lacks it; configure notices, and libfyaml falls back to `qsort()`.
- **Host tools kept out:** pkg-config points at an empty directory, and the build uses
  `--without-libclang`.

The result, for x86_64, is 693,928 bytes, with SONAME `libfyaml.so`, NEEDED `libc.so libdl.so`,
and 16 KB alignment. It exports the same 400 functions as the desktop `libfyaml.so.0` from
nixpkgs. Two of the functions the module calls, `fy_node_is_scalar` and `fy_node_is_mapping`,
are `static inline` wrappers of `fy_node_get_type` in the header. The script checks that
`fy_node_get_type` and the module's eight other calls are exported.

The module's other native dependencies are header-only
(nlohmann_json, and boost `algorithm/hex` and `algorithm/string/trim`) and already come from
`build-deps.sh`; the script checks that they are present.

## The module plugin

`build-blockchain-module.sh` builds logos-blockchain-module `4b07e58`, with
`patches/logos-blockchain-module/module-quiet-newblock-log.diff`, and `modules/bc_probe`. It
builds them the way `build-runtime.sh` builds hello_module: the code generators run on the
host, then logos-module-builder's `LogosModule.cmake` runs with the Qt/NDK toolchain. Both
scripts share that recipe, `scripts/android/module-build.sh`.

- **Same generators as the desktop build.** The module's flake locks logos-module-builder
  `16e2f6b` (0.3.1). Its cpp-sdk, plugin-qt, protocol, qt-sdk and lidl revisions are exactly
  the Android runtime's, and `16e2f6b` differs from the builder revision used here (`de169fd`)
  only in `flake.lock`. The LIDL contracts it produces are byte-identical to the ones in the
  desktop `.lgx` files: 48 methods and 3 events for blockchain_module, 5 methods for bc_probe.
- **The external library and libfyaml.** `EXTERNAL_LIBS logos_blockchain` is pointed at the
  prefix with `LOGOS_EXT_ROOT_LOGOS_BLOCKCHAIN`, LogosModule.cmake's hook for a `lib/` +
  `include/` root. `LINK_LIBRARIES fyaml` gets `-L<prefix>/lib`. The plugin NEEDs both
  libraries by their bare SONAMEs.
- **bc_probe's dependency.** On desktop, bc_probe's flake has an input named
  `blockchain_module`. Here that becomes `logos-cpp-generator --dep=blockchain_module=<lidl>`,
  which is what mkLogosModule passes. The contract is the one the blockchain_module step
  publishes in `build/android/<abi>/lidl/`. bc_probe does not link the node library.

### Staging layout: private libraries in the module directory

The plugin's two private libraries ship inside `assets/modules/<abi>/blockchain_module/`, as
in the desktop `.lgx`, and are extracted with it to `filesDir/modules/blockchain_module/`.
They are not in `jniLibs`.

This needs one thing the builder does not do on Android. CMake's Android platform module
emits no RPATH at all, so the `INSTALL_RPATH $ORIGIN` that LogosModule.cmake sets never
reaches the ELF: hello_module's plugin has no RUNPATH. Bionic resolves the NEEDED entries of
a dlopen()ed library from `LD_LIBRARY_PATH` (the app sets it to `nativeLibraryDir`), then from
the library's own DT_RUNPATH, then from the system paths. It never looks in the directory the
library came from. So the plugin is linked with `-Wl,-rpath,$ORIGIN`, through a clang response
file, because a `$` in `CMAKE_SHARED_LINKER_FLAGS` does not survive the Makefile link step.
`check-prefix.sh` now fails a module file that NEEDs a sibling but has no DT_RUNPATH `$ORIGIN`.

Checked on the x86_64 API 34 emulator, as the app's uid through `run-as`, against the module
directory the installed demo APK had extracted:

- `linker64 --list` of the plugin, with `LD_LIBRARY_PATH=nativeLibraryDir`, resolves
  `liblogos_blockchain.so` and `libfyaml.so` to `files/modules/blockchain_module/`, and Qt,
  OpenSSL and libc++_shared to `nativeLibraryDir`.
- The real `liblogos_host_qt.so` from `nativeLibraryDir`, started with the environment the app
  gives its children, loads `blockchain_module_plugin.so` and prints `@logos-load-status ok`.
  Its `/proc/<pid>/maps` shows `liblogos_blockchain.so` and `libfyaml.so` mapped from the
  module directory. It loads `bc_probe_plugin.so` the same way.
- No SELinux denial was logged for any module file. In the same session, the app's own
  `untrusted_app` child that hosts capability_module got the usual audited "granted
  { execute }" on its `app_data_file` plugin, and `liblogos_blockchain.so` has the same label.

These checks used `run-as` (domain `runas_app`). Since M5 the demo app loads the module
itself through `LogosCore.loadModule`: the child runs as `untrusted_app` with the same
result, and the node runs from those libraries (`android-build.md`, "M5/M6").

The alternative was `jniLibs`. The package manager would extract the libraries at install
time and the host would find them through `LD_LIBRARY_PATH`, with no RUNPATH needed. That
remains the fallback if a future Android release forbids executable mappings from app data,
which is the same risk every module plugin carries (see [`android-build.md`](android-build.md),
"Known limits"). `stage.sh` already puts in jniLibs any NEEDED it finds in the prefix but not
in the module directory, so the switch would be a change to the module directory only.

### Sizes

From `build/android/x86_64/blockchain-module-summary.txt` and
`build/android/x86_64/apk-sizes.txt`:

| File | As built | Staged (stripped) | Stored in the APK (deflate) |
| --- | ---: | ---: | ---: |
| `blockchain_module_plugin.so` | 42,761,952 | 2,837,736 | 1,033,862 |
| `liblogos_blockchain.so` (with the DNS patch) | 87,148,920 | 87,148,912 | 48,491,506 |
| `libfyaml.so` | 693,928 | 627,528 | 290,049 |
| `bc_probe_plugin.so` | 51,208,864 | 2,885,232 | 969,949 |

NEEDED:

- `blockchain_module_plugin.so`: `liblogos_blockchain.so libfyaml.so libQt6RemoteObjects_x86_64.so
  libQt6Network_x86_64.so libQt6Core_x86_64.so liblog.so libssl_3.so libcrypto_3.so libm.so
  libc++_shared.so libdl.so libc.so`, RUNPATH `$ORIGIN`
- `liblogos_blockchain.so`: `libc++_shared.so libc.so libdl.so libm.so`
- `libfyaml.so`: `libdl.so libc.so`
- `bc_probe_plugin.so`: the same Qt, OpenSSL, libc++ and NDK set as hello_module's plugin

The jniLibs set does not change: 15 libraries, 24,416,512 bytes.

The x86_64 debug APK with capability_module, hello_module, blockchain_module and bc_probe is
91,818,822 bytes at M5-build and 91,960,288 bytes with the M5 demo code (clean build),
against 41,033,524 with the first two modules. Its module assets are 98,330,922 bytes
uncompressed and 52,536,288 stored. (An incremental Gradle build that replaces the 48 MB
entry can leave the old one as dead space: 140.5 MB once here. `FORCE=1 build-apk.sh`
cleans.) On the emulator:

| What | Measured |
| --- | --- |
| `adb install -r -t` | 1.3 s |
| First `LogosCore.start()` after install, which extracts all four module directories | 969 ms |
| The next `start()`, with nothing to extract | 101 ms |
| Extraction, the difference | about 0.9 s, once per install or update |
| `files/modules` on the device | 96,176 KB, of which blockchain_module is 88,532 KB |

A phone will be slower than this host's emulator. The extracted copy is on disk in addition
to the APK, as `nativeLibraryDir` is with `useLegacyPackaging`.

## Runtime caveats: what happened on Android

The list below started as predictions from desktop runs and source reading
([exp-bc-desktop](research/exp-bc-desktop.md), [exp-bc-surface](research/exp-bc-surface.md)).
Each item now says what the x86_64 API 34 emulator showed (M5, 2026-09-25; logs under
`build/android/x86_64/m5/` and `.work/logs/m5-run/`).

- **No `/etc/resolv.conf`: a blocker, fixed with an upstream patch.** It was not NTP that
  failed. libp2p's `SwarmBuilder::with_dns()` builds its DNS transport from hickory's system
  config, which reads `/etc/resolv.conf` (absent on the emulator, as on every Android). The
  network service unwraps `Swarm::build`, so the node panicked 15 ms into `start()`:
  ```
  [blockchain_module] A panic occurred: called `Result::unwrap()` on an `Err` value: Custom { kind: Other,
  error: ResolveError { kind: Proto(ProtoError { kind: Io(Os { code: 2, kind: NotFound, message: "No such
  file or directory" }) }) } } at services/network/src/backends/libp2p/swarm/mod.rs:86:78
  ```
  and the panic hook ended the host. `patches/logos-blockchain/logos-blockchain-02-android-dns-resolver-fallback.diff`
  builds the DNS transport from hickory's default upstream config on Android only (15 lines
  in `libp2p/src/swarm.rs`). The devnet peers are `/ip4` addresses, so they never reach that
  resolver. Upstream would rather read Android's resolvers or make them configurable.
- **NTP needs no fix.** The time service resolves `pool.ntp.org` with `tokio::net::lookup_host`,
  i.e. bionic's `getaddrinfo`, which asks netd. netd logged `GetAddrInfoHandler::run` for the
  app's uid every 15 s (the NTP `update_interval`), and the node logged no NTP error. The
  children inherit the app's network groups, so the app needs the `INTERNET` permission
  (`demo-app/src/main/AndroidManifest.xml`); `:logos-core` itself declares none.
- **netlink: a warning, nothing more.** With the generated config's default NAT traversal
  (autonat, UPnP, NAT-PMP, gateway monitor), the gateway monitor logs once
  `WARN ... nat::gateway-monitor: Failed to detect gateway: Failed to get default gateway:
  Default Gateway not found` and the node carries on. An outbound-only follower needs no
  `external_address`; `BlockchainNode.prepareConfig(externalAddress = ...)` can still set one
  (untested).
- **The panic hook's `exit(1)` ends only the host, and LogosCore now reports it.** The DNS
  panic above is a real instance: the blockchain_module host exited, capability_module,
  bc_probe and the app stayed up, and the `start()` call in flight failed 0.8 s later with
  `LogosModuleDiedException: blockchain_module host process is gone ...; blockchain_module.start
  abandoned` instead of waiting out its 10 min deadline. A host killed with SIGKILL was
  reported 219-553 ms later, and the next call failed in 0 ms. See `android/README.md`, "Module
  host deaths". The app decides what to do (the demo offers Load BC again). An IBD failure,
  which makes the node shut itself down without the module noticing, was not seen.
- **Stopping too early: enforced, not seen.** `BlockchainNode.stop()` waits until 2 s after
  `start()` returned. `stop()` then took 53-76 ms and the host stayed loaded.
- **`start()` is fast on a fresh node and slow on a restart.** On an empty node directory it
  returned after 46-93 ms. On the synced one (about 5.26k blocks, LIB still at genesis because
  follower mode never leaves Bootstrapping) it replayed the chain and took 20.7-20.8 s, just
  over the 20 s default call timeout. The demo and the test call it with a 10 min timeout.
- **rapidsnark's `MyLogFile.log`: never written on Android.** In follower mode the node never
  proves. In the standalone chain (below) it proved a block per slot on the device, and the
  hosts' working directory stayed empty: the iden3 v0.0.8 `librapidsnark.a` contains the
  string, but `liblogos_blockchain.so` does not (the link does not pull the file logger in).
  `LogosCore` still `chdir()`s the app to `filesDir/work` before liblogos starts, so every host
  has a writable working directory (`/proc/<host pid>/cwd` = `files/work`, checked by the
  instrumented test).
- **Also seen:**
  - The udp/50001 bootstrap peer never completes a QUIC handshake from the emulator
    (`Handshake with the remote timed out`); the node still has 3-4 peers (the other bootstrap
    peers plus a discovered one) and syncs from them.
  - One `WARN quinn_udp: sendmsg error: Os { code: 5, ... }, segment_size: Some(1452)` per
    run: UDP segmentation offload fails on the emulator's interface, and quinn goes on
    without it.
  - The node's own log goes to stdout, with ANSI colour codes, and so to `logos-stdio`: about
    150 lines for a whole devnet sync at the generated config's filter. With the module patch
    there is no per-block line.
  - The `newBlock` payload has no height (the header has slot, parent, body root and the PoL
    proof); the demo takes the height from `get_cryptarchia_info`. All 5,260 events of a
    fresh sync reached Kotlin (event count = height).
  - `logos_core_get_module_stats()` under-reports CPU (process-stats reads the wrong
    `/proc/<pid>/stat` fields); `LogosCore.moduleStats()` corrects it.

### Standalone chain (stretch): on-device proving

The node repo's `standalone-node-config.yaml` + `standalone-deployment-config.yaml` (tag
0.3.0-rc.4; Android paths and API port as in `config/blockchain/02-*.diff`, log filter
`logos_blockchain: INFO`) started from the demo (`--es bc_config ... --es bc_deployment ...`)
go Online after the 5 s bootstrap and propose one block per 1 s slot, each with a PoL
Groth16 proof made on the device (witness generator + rapidsnark, x86_64 emulator; no
SIGILL). Height 11 after 22 s, host at 84-89 % of one core and 52-74 MB RSS. Script:
`.work/scripts/m5-run-standalone.sh`; screenshot `build/screenshots/m5-standalone.png`.

## Size

About 35.6 MB of the library is embedded circuit data: the zkeys, vkeys and `.dat` files for
all four circuits, compiled in with `include_bytes!`. Loading the keys from files instead, or
dropping circuits a follower never uses, would need upstream changes.
