# Experiment: bc-android-build

> Blockchain-module research, 2026-09-25. Machine-written by the experiment agent; scripts and
> small logs in [../../experiments/bc-android-build](../../experiments/bc-android-build); patches in [../../patches](../../patches);
> node config fixtures in [../../config/blockchain](../../config/blockchain). `.work/` paths are local scratch.


### Summary
I cross-compiled liblogos_blockchain.so for both x86_64-linux-android and aarch64-linux-android (API 34, NDK r27c, libc++_shared, 16 KB LOAD alignment). The source is logos-blockchain 35a4a666, the rev that logos-blockchain-module 4b07e58 pins. The Bedrock circuits were built properly for Android, not stubbed: circom 2.2.2 built from its v2.2.2 tag, the CI's flags and patches, GMP 6.2.1 built with the NDK through rapidsnark's own build_gmp.sh, and the witness libs compiled with NDK clang++ and libc++. The four .dat files circom produced are byte-identical to the v0.5.7 release ones, which shows the generated C++ matches the release circuits. The proving keys, verification keys and .dat files are taken unchanged from the release bundle; its checksum matches the one in circuits-nix-hashes.json. rapidsnark comes from the iden3 v0.0.8 Android prebuilts; they are position-independent and built against libc++. Each cargo release build (fat LTO) takes about 8.1 to 8.8 minutes. The .so is 87.2 MB on x86_64 and 82.2 MB on aarch64; 35.6 MB of that is embedded zkeys and circuit data. The profile already strips symbols, so running llvm-strip saves under 1 KB. All 54 header functions are exported, and blockchain_module calls 52 of them. openssl-sys, native-tls, bzip2-sys and libz-sys are not in the Android build at all. One source patch was needed (lbc-build emitting -lstdc++). librocksdb-sys also emits -lstdc++; a one-line linker-script shim redirects that to libc++_shared, so the recommended build links only libc++_shared, libc, libdl and libm. I did not dlopen the library or run it, because the emulator was off-limits.

### Results
- [answered|verified-from-source] Q1: which logos-blockchain rev does the module pin, and is the copy built from it?
  logos-blockchain-module 4b07e58 pins logos-blockchain 35a4a666e22a51eb98fe8a050854e57fe3420899 (flake ref master, commit dated 2026-09-22 16:07:54 UTC, 'chore(dependdencies): Update overwatch (#3622)'). I fetched it into a git clone --shared copy and checked it out. At that rev the pins are: lbc-* crates tag v0.5.7, rust-rapidsnark rev e91187f8, circuits flake input v0.5.7 (ebf7ddf5), toolchain 1.98.1. The fresh upstream HEAD c4c86be differs in c-bindings (pow.rs +181 lines, plus storage.rs, subscriptions.rs, option.rs, result.rs, lib.rs), so the build must stay on 35a4a666 to match the module's header. The logos-blockchain flake builds `-p logos-blockchain-c` with default features only, and the module consumes it as packages.default; I used the same.
  evidence: .work/upstream/logos-blockchain-module/flake.lock:186-207; src/logos-blockchain/Cargo.toml:174-178 (lbc tag v0.5.7), :269 (rust-rapidsnark e91187f8); src/logos-blockchain/flake.nix:16,21,78-79; src/logos-blockchain/rust-toolchain.toml:11; logs/setup.log lines 5-17
- [answered|verified-by-experiment] Q2: dependency tree for the Android target; every -sys crate or build script that compiles or downloads native code
  There are 551 target-side crates in cargo metadata and 548 unique packages in `cargo tree -e normal,build` (548 compiled on x86_64). Build scripts that compile native code for the target: librocksdb-sys 0.17.3+10.4.2 (RocksDB C++ through the cc crate, bindgen-runtime so it needs libclang; it emits cargo:rustc-link-lib=stdc++ for *linux* triples, Android included); ring 0.17.14 (C and asm through cc); chkstk_stub (build-dependency of rust-rapidsnark). Prebuilt native link inputs: rust-rapidsnark 0.1.3@e91187f8 (feature static-rapidsnark; links static rapidsnark/fr/fq/gmp plus c++ and c on Android; downloads iden3 assets only when RAPIDSNARK_LIB_DIR is unset); logos-blockchain-circuits-{poc,pol,poq,signature}-sys 0.5.7 (feature prebuilt; lbc-build downloads a release tarball by target_os and target_arch unless LBC_ROOT_DIR is set, so on Android it would ask for an android-x86_64 asset that does not exist; these crates also embed the zkeys, vkeys and .dat files at compile time with include_bytes!). utoipa-swagger-ui uses its vendored copy and does not download. openssl-sys, native-tls, bzip2-sys and libz-sys appear in the unified cargo metadata but not in the Android target graph (`cargo tree -i` finds no match or prints nothing) and are never compiled.
  evidence: out/native-crates-x86_64-android.txt; out/cargo-tree-inverse.txt; out/cargo-tree-x86_64-android.txt / .unique.txt; target/x86_64-linux-android/release/build/librocksdb-sys-161f6fb01ba39a06/output:5215-5217; target/.../build/rust-rapidsnark-8838db44e36f8f9d/output:19-25; target/.../build/utoipa-swagger-ui-e144e76457b2a44f/output:3 ('using vendored Swagger UI'); out/x86_64-linux-android/cargo-build.txt (no openssl/native-tls/bzip2/libz Compiling lines)
- [pass|verified-by-experiment] Q3: build the Bedrock circuits (PoL, PoQ, PoC, Signature) and GMP for Android and assemble an Android LBC_ROOT_DIR
  This is a real build, not stubs, for both x86_64 and aarch64, and took 41 s. Steps: (1) Built circom v2.2.2 from its git tag with cargo in 45 s; nixpkgs has 2.2.3, which the CI does not pin. (2) Ran `circom --c --r1cs --no_asm --O2` per circuit, then applied the CI's main.cpp return-0 sed and fix_calcwit_leak.sh, and copied src/{<circuit>/, circom_adapter.*, circom_fwd.hpp, types.hpp, assert.h} and the witness Makefile, exactly as action.yml does. The generated <circuit>.dat files are byte-identical to the release witness_generator.dat files for all four circuits. (3) Built GMP 6.2.1 (tarball sha256 fd4829...b4f2) with the submodule's unmodified `rapidsnark/build_gmp.sh android_x86_64` and `android`. Upstream uses NDK API 21 with --with-pic --disable-fft; that is fine for a static library linked at API 34. (4) Compiled the witness libs with NDK clang++ at API 34 against libc++ through a new `android-lib` Makefile target (patch circuits-01), then ran ld.lld -r, llvm-objcopy --keep-global-symbol and llvm-ar. Each lib<circuit>.a exposes only <circuit>_generate_witness and <circuit>_generate_witness_from_files, has 52 std::__ndk1 references and no std::__cxx11 references. (5) Assembled lbc-android/<arch>: VERSION, lib/libgmp.a (ours) and the NDK libs, plus proving_key.zkey, verification_key.json, witness_generator.dat and include/ copied from the v0.5.7 linux-x86_64 release bundle, whose SRI matches circuits-nix-hashes.json. A sha256 check confirms the data files are identical to the release. lbc-build's -lstdc++ is fixed by patch circuits-02, wired in through [patch] (patch logos-blockchain-01).
  evidence: logs/circuits.log:43-78 (dat gen == release for poc/pol/poq/signature), :146-212 (Machine, global syms, __ndk1/__cxx11 counts, 'data files identical to release: yes'); logs/inputs.log (circuits SRI sha256-kqDGrYENSGYxUYt7myR6K2b2avb4+N3OOBrLvf7cD38= matches expected); src/logos-blockchain-circuits/.github/actions/compile-witness-generator/action.yml:72,97-115; .github/workflows/ci.yml:17 (CIRCOM v2.2.2); rust/logos-blockchain-circuits-build/src/lib.rs:187-191 (stdc++ on non-macOS); target/.../build/logos-blockchain-circuits-poc-sys-cca8a25b5bb69929/output:12 (now emits c++)
- [pass|verified-by-experiment] Q4: where RAPIDSNARK_LIB_DIR comes from
  I used the iden3 prebuilts rapidsnark-android-x86_64-v0.0.8.zip (sha256 966d0e572963af1ff35faa56a5a16754a67000308d0cd89ed6c4d60a3080a2e0) and rapidsnark-android-arm64-v0.0.8.zip (sha256 2e306704fe1b900261006ec41a7bef92bb3f94839c9989eff5058b133f5dc642), downloaded in a script. RAPIDSNARK_LIB_DIR points at inputs/rapidsnark-android-<arch>-v0.0.8/lib. These are the same assets the fork's download_rapidsnark.sh maps Android targets to, and the same version (0.0.8) as the host Nix rapidsnark package. The archives have no absolute (non-PIC) relocations, reference std::__ndk1 (libc++), and were linked with LLD 18.0.4. I did not build rapidsnark from source.
  evidence: logs/rsinspect.log; /nix/store/h6iir14haf6gi3kznr24shrmgpb20vch-...-e91187f8.../rust-rapidsnark-0.1.3/download_rapidsnark.sh:39-40; build.rs:50-63; target/.../build/rust-rapidsnark-8838db44e36f8f9d/output:3 ('using pre-supplied libs')
- [pass|verified-by-experiment] Q5: cargo build -p logos-blockchain-c --release for x86_64-linux-android (and aarch64)
  Both targets built on the first attempt; the only source patch was the lbc-build one. Timings: x86_64 cold, including host build-deps (548 crates), 486 s; aarch64 with host deps warm (441 crates), 486 s; stdcxxshim variants 518 s (x86_64) and 525 s (aarch64). Most of the time is the final fat-LTO link with codegen-units=1 from the release profile. rocksdb (with bindgen, system libclang 21 and --sysroot for the NDK), ring and rapidsnark needed only environment variables. Environment: CC/CXX/AR/RANLIB_<triple>=NDK <triple>34-clang(++)/llvm-ar/llvm-ranlib; CARGO_TARGET_<T>_LINKER=<triple>34-clang; CARGO_TARGET_<T>_RUSTFLAGS='-C link-arg=-Wl,-z,max-page-size=16384' (the shim variant adds '-L native=<dir holding libstdc++.so = INPUT(-lc++_shared)>'); BINDGEN_EXTRA_CLANG_ARGS_<triple>=--sysroot=<NDK sysroot>; LIBCLANG_PATH=/usr/lib64; LBC_ROOT_DIR=lbc-android/<arch>; RAPIDSNARK_LIB_DIR as in Q4.
  evidence: logs/cargo-x86_64-linux-android.log:16-18; logs/cargo-aarch64-linux-android.log:17-19; logs/cargo-x86_64-linux-android-stdcxxshim.log:7,18; logs/cargo-aarch64-linux-android-stdcxxshim.log:18
- [pass|verified-by-experiment] Q6: the resulting .so files (size, NEEDED, LOAD alignment, exports, undefined symbols)
  Sizes (raw / after llvm-strip --strip-all; profile strip=true already removed symbols): x86_64 87,165,864 / 87,165,352 bytes; aarch64 82,198,120 / 82,197,424. .rodata is about 48.7 MB, including full copies of all 12 circuit data files (35.6 MB, mostly zkeys: PoL 12.7 MB, PoQ 12.6 MB, PoC 5.3 MB, Sig 4.5 MB). NEEDED for the default build: libstdc++.so, libc++_shared.so, libc.so, libdl.so, libm.so; libstdc++.so comes from librocksdb-sys. NEEDED for the stdcxxshim build: libc++_shared.so, libc.so, libdl.so, libm.so. Every LOAD segment has p_align 0x4000 on both architectures. FLAGS are BIND_NOW and NOW; there is no TEXTREL. Exports: the 54 functions in logos_blockchain.h (cbindgen) are all exported as T symbols, with nothing extra; blockchain_module's .cpp calls 52 of them, and all 52 are present. Undefined dynamic symbols: 381, all defined by the API 34 libc, libm, libdl and libc++_shared stubs, except 2 WEAK rocksdb TLS-init wrappers (_ZTHN7rocksdb10perf_levelE, _ZTHN7rocksdb15ConcurrentArena9tls_cpuidE), which may resolve to null. In the default build, operator new/delete and __cxa_guard_* are also defined by the minimal system libstdc++.so, which comes first in NEEDED; the shim build removes that overlap.
  evidence: logs/cargo-<T>[-stdcxxshim].log sections '== dynamic section', '== program headers', '== exported symbols vs header'; logs/verify-<T>.log (WEAK binding, embedded data full-copy-in-so=True x12); out/<T>/header-vs-exports.txt, out/<T>/exports-all.txt; bash .work/scripts/bc-android-build-modusage.sh output (52 used, 0 missing)
- [answered|inferred] Is the lbc-build -lstdc++ patch strictly required?
  Probably not for the link to succeed. rust-rapidsnark already adds -lc++ (libc++_shared) on Android, and librocksdb-sys adds -lstdc++ anyway. With the stdcxxshim, an unpatched lbc-build's -lstdc++ would also resolve to libc++_shared. I kept the source patch because it is the correct upstream fix. I did not build without it.
  evidence: target/.../rust-rapidsnark-*/output:24 (rustc-link-lib=c++); librocksdb-sys output:5217 (rustc-link-lib=stdc++)
- [not-run|open] Does the .so dlopen on Android, and does start_lb_node work (including witness generation and rapidsnark proving on device)?
  Not tested: the emulator belongs to another concurrent experiment and was off-limits. Static checks pass (every non-weak import resolves against API 34 bionic and libc++_shared; 16 KB alignment; no text relocations). Runtime risks, all inferred: (a) hickory-resolver with the system-config feature reads /etc/resolv.conf, which does not exist on Android; the string is present in the .so; (b) standalone-node-config.yaml uses relative ./state and ./db, while an Android process's working directory is /, so absolute app-private paths are needed (nodes/node/standalone-node-config.yaml:172,237); (c) if-watch and libp2p netlink use may run into Android 11+ app restrictions; (d) proving performance and memory on device are unknown; (e) panic strings contain 1,671 host paths under ~/.cargo, which is cosmetic (use --remap-path-prefix).
  evidence: logs/verify-<T>.log '/etc paths referenced'; src/logos-blockchain/c-bindings/src/api/lifecycle.rs:42-129

### Patches
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-android-build/patches/circuits-01-witness-makefile-android-lib.diff: adds an android-lib target and makes the ld -r and ar steps overridable ($(LD)/$(AR)) in the CI witness-generator Makefile; the default linux/macos/windows behaviour is unchanged (circuits v0.5.7)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-android-build/patches/circuits-02-lbc-build-libcxx-on-android.diff: one line in lbc-build/src/lib.rs:189 so target_os=android emits -lc++ (to libc++_shared) instead of -lstdc++
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-android-build/patches/logos-blockchain-01-patch-lbc-build.diff: a [patch."https://github.com/logos-blockchain/logos-blockchain-circuits.git"] entry pointing logos-blockchain-circuits-build at the patched copy (experiment wiring only)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-android-build/patches/logos-blockchain-01b-Cargo.lock-consequence.diff: the automatic Cargo.lock change caused by patch 01 (lbc-build source becomes a path)
- Not a source patch (build environment only): /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-android-build/android-stdcxx-shim/libstdc++.so, containing 'INPUT(-lc++_shared)', added with RUSTFLAGS '-L native=<dir>' so the -lstdc++ from librocksdb-sys resolves to libc++_shared. The upstream alternative is a one-line librocksdb-sys build.rs change (android should not be treated as linux for the C++ stdlib).

### Artifacts
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-android-build/out/x86_64-linux-android-stdcxxshim/liblogos_blockchain.so (recommended; sha256 b57936be...; NEEDED libc++_shared/libc/libdl/libm)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-android-build/out/aarch64-linux-android-stdcxxshim/liblogos_blockchain.so (recommended; sha256 96cb4e26...)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-android-build/out/x86_64-linux-android/liblogos_blockchain.so (without the shim; also NEEDED libstdc++.so; sha256 971ebb74...)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-android-build/out/aarch64-linux-android/liblogos_blockchain.so (without the shim; sha256 3a91d4aa...)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-android-build/out/x86_64-linux-android/logos_blockchain.h (cbindgen header at 35a4a666; sha256 b76d781a...)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-android-build/lbc-android/x86_64 and /aarch64 (Android LBC_ROOT_DIR: NDK-built lib{poc,pol,poq,signature}.a + lib/libgmp.a + v0.5.7 release zkey/vkey/.dat)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-android-build/src/logos-blockchain-circuits/rapidsnark/depends/gmp/package_android_x86_64 and package_android_arm64 (GMP 6.2.1 NDK builds with gmp.h)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-android-build/build/circuits-gen/<circuit>/<circuit>_cpp (patched circom C++ output, arch-independent)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-android-build/inputs/ (circuits v0.5.7 linux-x86_64 release bundle, iden3 rapidsnark v0.0.8 Android zips)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-android-build/tools/circom/bin/circom (2.2.2)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-android-build/src/logos-blockchain (copy at 35a4a666 with the [patch] applied)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-android-build/logs/ (setup, inputs, circuits, gmp-*, witness-*, cargo-<T>[-stdcxxshim], verify-<T>, rsinspect)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-android-build/out/native-crates-x86_64-android.txt, cargo-tree-*.txt, cargo-tree-inverse.txt, metadata-x86_64-android.json
- Scripts: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/bc-android-build-{setup,inputs,nativecrates,inverse,circuits,cargo-common,cargo-x86_64,cargo-aarch64,cargo-x86_64-shim,cargo-aarch64-shim,verify,modusage,rsinspect,patches,waitdone*,watch}.sh

### Repro
All steps run as `bash /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/<name>.sh`: (1) bc-android-build-setup.sh: git clone --shared the upstream logos-blockchain, fetch and check out 35a4a666, install toolchain 1.98.1 with the android targets, run cargo tree and cargo metadata (the --no-dedupe tree that took about 30 min has since been removed from the script). (2) bc-android-build-inputs.sh: circuits v0.5.7 linux-x86_64 tarball with SRI check, iden3 rapidsnark v0.0.8 Android zips, circuits repo copy at v0.5.7 plus submodules, circom v2.2.2 through cargo install (45 s). (3) Apply patches/circuits-01 and circuits-02 in src/logos-blockchain-circuits and patches/logos-blockchain-01 in src/logos-blockchain (git apply; the leading '# rationale' line is ignored). (4) bc-android-build-circuits.sh: GMP via build_gmp.sh android_x86_64 and android, circom C++ generation with the CI patches, NDK witness libs for both architectures, assembly of lbc-android/<arch> (41 s). (5) bc-android-build-cargo-x86_64-shim.sh and bc-android-build-cargo-aarch64-shim.sh, recommended, about 8.7 min each; bc-android-build-cargo-{x86_64,aarch64}.sh build without the shim, about 8.1 min each. (6) bc-android-build-verify.sh, bc-android-build-modusage.sh, bc-android-build-patches.sh. The disk used by the experiment is 7.3 GB, of which 5.5 GB is the target/ directory.

### Next steps
- Run a smoke test on an Android emulator or device once it is free: push the shim build together with the NDK's libc++_shared.so, dlopen it from a small JNI or Kotlin harness (or an NDK test executable run through adb shell), call start_lb_node with standalone-node-config.yaml and standalone-deployment-config.yaml rewritten to absolute app-private paths (state.base_folder, storage folder_name, api listen_address 127.0.0.1:0), then get_cryptarchia_info / get_peer_id and shutdown_node. Watch for DNS problems (/etc/resolv.conf is missing) and netlink/if-watch errors.
- Check the witness generators and rapidsnark on device: run a PoL, PoQ or Signature proof with the circuits' sample.input.json through the node's prover path, and compare against a host run for the same inputs, or verify with the release verification_key.json.
- Kotlin wrapper next: a thin JNI layer over the 54 C functions in out/<T>/logos_blockchain.h. The module uses 52 of them; callbacks are used by the subscribe_* functions. Ship liblogos_blockchain.so with libc++_shared.so and extractNativeLibs=false; the library is already 16 KB aligned.
- To build blockchain_module itself for Android (the Qt plugin), it also needs libfyaml, nlohmann_json and boost built with the NDK (see module CMakeLists.txt:18-21 and metadata.json nix.runtime); this library is already its external lib.
- Upstream candidates: lbc-build should emit c++ on Android (patch circuits-02); an android-lib Makefile target plus android-{x86_64,aarch64} rows in the circuits release CI matrix (the build is reproducible and the .dat files are byte-identical); librocksdb-sys should not emit stdc++ for android triples; consider --remap-path-prefix to drop the ~1.7k host paths from panic strings.
- Optional size work: the zkeys are embedded with include_bytes! (35.6 MB). Loading them from files through PROVING_KEY_PATH, or feature-gating the unused circuits, would shrink the .so for mobile. This needs upstream changes.

---

## Full report

## bc-android-build: liblogos_blockchain.so for Android

liblogos_blockchain.so now builds for both `x86_64-linux-android` and `aarch64-linux-android` (API 34, NDK r27c, libc++_shared, `-z max-page-size=16384`). The circuits are a real NDK build, not stubs. I have not run the library: the emulator was in use by another experiment, so only static checks were done.

### Source and pins
- **Rev:** blockchain-module 4b07e58 pins logos-blockchain `35a4a666e22a51eb98fe8a050854e57fe3420899` (flake.lock:186-207, commit from 2026-09-22). I built that rev in a `git clone --shared` copy.
- **Why not HEAD:** fresh HEAD c4c86be changes c-bindings (pow.rs +181 lines and others), so it would not match the module's header.
- **Pins at 35a4a666:**
  - circuits v0.5.7 (ebf7ddf5)
  - rust-rapidsnark e91187f8
  - toolchain 1.98.1
- **Features:** defaults only; the flake builds just `-p logos-blockchain-c`.

### Native dependencies in the Android target graph (verified by experiment)
- **Compiled from C/C++ for the target:**
  - librocksdb-sys 0.17.3+10.4.2: RocksDB C++ through the cc crate, with bindgen. It emits `-lstdc++` for any `*linux*` triple, Android included.
  - ring 0.17.14: C and asm.
  - chkstk_stub.
- **Prebuilt static libraries:**
  - rust-rapidsnark with static-rapidsnark: links static rapidsnark, fr, fq and gmp, plus c++ and c.
  - lbc-{poc,pol,poq,signature}-sys with `prebuilt`: static circuit libs, gmp and stdc++ (patched to c++, see below). They also embed the zkeys, vkeys and .dat files with `include_bytes!`.
- **Would download at build time:** lbc-build downloads a release tarball when `LBC_ROOT_DIR` is unset; rust-rapidsnark downloads when `RAPIDSNARK_LIB_DIR` is unset.
- **Not built:** openssl-sys, native-tls, bzip2-sys, libz-sys and zstd/lz4 are never compiled for Android. They appear only in the unified cargo metadata.

### Circuits for Android (real build, 41 s for both architectures)
1. **circom:** v2.2.2 built from its git tag with cargo in 45 s. The CI pins 2.2.2; nixpkgs has 2.2.3.
2. **C++ generation:** `circom --c --r1cs --no_asm --O2`, then the CI's main.cpp return-0 sed and `fix_calcwit_leak.sh`, then the CI's source copies.
   - **All four generated `.dat` files are byte-identical to the v0.5.7 release.** That shows the generated C++ matches the released circuits.
3. **GMP 6.2.1:** built with rapidsnark's own `build_gmp.sh android_x86_64` and `android`, unmodified.
4. **Witness libs:** NDK clang++ (API 34) with libc++, through a new `android-lib` Makefile target, then `ld.lld -r`, `llvm-objcopy --keep-global-symbol` and `llvm-ar`.
   - Each lib exports only its two `<c>_generate_witness*` symbols.
   - Each has 52 `std::__ndk1` references and no `__cxx11` references.
5. **Android LBC_ROOT_DIR** (`lbc-android/<arch>`):
   - The four NDK-built libs and our libgmp.a.
   - `zkey`, `vkey`, `.dat` and `VERSION` copied unchanged from the release bundle. The bundle's SRI matches `circuits-nix-hashes.json`, and a sha256 check confirms the copies are identical.

### rapidsnark
- **Source:** iden3 v0.0.8 Android prebuilts, downloaded in a script.
  - x86_64 zip sha256 `966d0e57…`
  - arm64 zip sha256 `2e306704…`
- **Properties:**
  - These are the exact assets the fork's `download_rapidsnark.sh` maps Android targets to.
  - Position-independent code (no absolute relocations).
  - Built against libc++ and linked with LLD 18.0.4.

### Build results

| | x86_64 | aarch64 |
|---|---|---|
| Build time (fat LTO, codegen-units=1) | 486 s (518 s with shim) | 486 s (525 s with shim) |
| .so size, raw | 87,165,864 B | 82,198,120 B |
| .so size after `llvm-strip` | 87,165,352 B | 82,197,424 B |
| LOAD p_align | 0x4000 on all 4 LOAD segments | 0x4000 on all 4 LOAD segments |
| NEEDED, default build | libstdc++, libc++_shared, libc, libdl, libm | same |
| NEEDED, shim build | libc++_shared, libc, libdl, libm | same |
| Exports | all 54 header functions, nothing extra | same |

- **Size:** the profile already strips symbols, which is why `llvm-strip` barely changes the size. About 35.6 MB of the `.so` is embedded circuit data (all 12 files, full copies).
- **Module coverage:** blockchain_module calls 52 of the 54 exported functions; all are present.
- **Link flags:** `BIND_NOW` is set and there are no text relocations.
- **Undefined symbols:** all 381 resolve against API 34 bionic and libc++_shared, except 2 WEAK rocksdb TLS-init wrappers, which may resolve to null.

### Patches (diffs in `patches/`, one-line rationale at the top of each)
1. **circuits-01:** adds an `android-lib` target and overridable `LD`/`AR` to the witness Makefile.
2. **circuits-02:** lbc-build emits `c++` instead of `stdc++` on Android (lib.rs:189).
3. **logos-blockchain-01 (+01b lock):** a `[patch]` entry pointing at the patched lbc-build.
4. **Build-environment shim, no source change:** `android-stdcxx-shim/libstdc++.so` containing `INPUT(-lc++_shared)`, added with `-L native=` in RUSTFLAGS.
   - librocksdb-sys's `-lstdc++` then resolves to libc++_shared.
   - This removes NEEDED libstdc++.so and the duplicate `operator new`/`delete` and `__cxa_guard` providers.
   - Upstream alternative: a one-line change in librocksdb-sys build.rs.
   - The lbc patch is probably redundant for a successful link, since rapidsnark already adds `-lc++`. I did not build without it.

### Still unknown
- Whether the `.so` loads and runs on Android: `dlopen`, `start_lb_node`, and on-device witness generation and proving (time and memory).
- Runtime risks (inferred):
  - `/etc/resolv.conf` does not exist on Android, but hickory-resolver's system-config reads it.
  - The standalone configs use relative `./state` and `./db`; an Android process's working directory is `/`.
  - Android 11+ restricts netlink sockets, which if-watch/libp2p use.
- Minor differences from CI:
  - nlohmann/json comes from the rapidsnark submodule rather than Ubuntu's 3.10.5.
  - GMP is compiled at API 21, as upstream's script does.

