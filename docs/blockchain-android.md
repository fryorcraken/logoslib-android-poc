# The blockchain node library on Android

> Draft (M5). Status: `liblogos_blockchain.so` and `libfyaml.so` build reproducibly for
> x86_64 with the scripts below and pass the prefix checks. Nothing here has run on a device
> or emulator yet.

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
```

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
   change. The patch applies to both the tag and `35a4a666`. The circuits repo at v0.5.7, plus
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

Result for x86_64, built 2026-09-25:

| | |
| --- | --- |
| `liblogos_blockchain.so` | 87,147,640 bytes. The release profile already strips it; `llvm-strip --strip-all` saves 512 bytes more. About 48.8 MB of it is `.rodata`, 35.6 MB of which is embedded circuit data. |
| Dynamic section | NEEDED `libc++_shared.so libc.so libdl.so libm.so`; SONAME `liblogos_blockchain.so`; `BIND_NOW`; a build id; no RUNPATH |
| Alignment | 4 `PT_LOAD` segments, all `p_align` 0x4000 |
| C API | 54 of 54 header functions exported, nothing extra; `blockchain_module` 4b07e58 calls 52, and all are present; header byte-identical to the one at `35a4a666` |
| `check-prefix.sh x86_64` | OK: every one of the 381 undefined dynamic symbols resolves within the NEEDED closure |
| Cold build | About 10.5 min with `JOBS=8`, while another build shared the machine: cargo 558 s, circom 27 s, GMP 20 s, witness libraries 7 s, the rest under 20 s |
| Re-run | A no-op re-run takes under 1 s |
| Disk | 1.8 GB of cargo target, about 0.5 GB of sources |

Host paths are down from about 850 to 2, both from C/C++ inputs that `--remap-path-prefix` does
not cover. They are cosmetic.

The app must ship `libc++_shared.so` from the NDK alongside the library.

For arm64-v8a, the script's circuit steps have run: GMP, the witness libraries (AArch64,
libc++), the LBC directory and rapidsnark. Its cargo step has not run yet. The experiment
built the arm64 library with the same recipe (82 MB).

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

## Known runtime caveats (from the research, not yet seen on Android)

All of these come from desktop runs and source reading
([exp-bc-desktop](research/exp-bc-desktop.md), [exp-bc-surface](research/exp-bc-surface.md)).

- **rapidsnark writes `MyLogFile.log` to the current working directory** on every Groth16
  proof, about 1.4 KB each. An Android process's cwd is `/`, which is read-only; nobody knows
  yet what rapidsnark does when the open fails. The module's host process should `chdir` to an
  app-private writable directory before `start()`. In follower mode the node never proves, so
  the file is never written.
- **There is no `/etc/resolv.conf` on Android.** The node uses hickory-resolver with the system
  config, which reads that file. The node resolves names for NTP (`pool.ntp.org`) and for any
  DNS multiaddr. The devnet bootstrap peers are plain IPs, so peering itself does not need
  DNS. This is the first thing to watch in logcat.
- **netlink is restricted for apps on Android 11 and later.** The NAT gateway monitor (netdev,
  netlink) and if-watch use it. If it fails, the mitigation the research suggests is to set
  `external_address` in the config, which switches the NAT config from its dynamic default
  (autonat, UPnP, NAT-PMP, gateway monitor) to `static`.
- **The panic hook calls `exit(1)`.** After `start_lb_node`, any panic on any thread ends the
  process. With liblogos's one-process-per-module model, that is the `blockchain_module` host
  child, not the app. The app must detect that the module died and reload it. Separately, if
  initial block download fails, the chain-network service shuts the node down by itself. The
  module does not notice, and later calls fail.
- **Stopping within about 250 ms of `start()` deadlocks** in Overwatch. Upstream's own test
  waits 2 s. The wrapper should enforce a minimum run time of about 2 s before `stop()`.
- **`start()` can block for more than 20 s on a restart.** It returns only when every service
  is up, and a restart replays every block since LIB. On devnet, LIB stays at genesis while
  the generated config holds the node in Bootstrapping, so on desktop a restart took 26.5 s
  for about 5k blocks. That is longer than the 20 s default call timeout of
  `LogosCore.call`. Use a long timeout for `start` (minutes), and consider a shorter
  `prolonged_bootstrap_period`.

## Size

About 35.6 MB of the library is embedded circuit data: the zkeys, vkeys and `.dat` files for
all four circuits, compiled in with `include_bytes!`. Loading the keys from files instead, or
dropping circuits a follower never uses, would need upstream changes.
