# Blockchain circuits and ZK stacks

> Research track `circuits`, 2026-09-25. Written by a research agent and then checked by a
> second, adversarial agent, whose non-confirmed verdicts are listed under "Verifier".
> Claims are tagged verified-from-source / verified-by-experiment / inferred / open.
> Absolute paths point at the author's local checkouts (`~/src/logos-co`,
> `~/src/logos-blockchain`) at the revisions in [../investigation.md](../investigation.md);
> `.work/` paths are local scratch, not committed. The synthesis is in
> [../investigation.md](../investigation.md).


### Summary
"Building blockchain circuits" means two unrelated ZK stacks that the LEZ wallet library pulls in, not anything specific to LEZ. The library is lez/wallet-ffi → libwallet_ffi.so, which lez_core links.

(1) LEZ's own proofs use RISC Zero. The guest programs, including privacy_preserving_circuit.bin, come prebuilt and committed under artifacts/. build.rs only embeds them and computes image IDs, so no risc0 toolchain or Docker is needed to build lez_core. Proving happens only for private or shielded transactions, and only through wallet-ffi's default `prove` feature. That feature compiles in the C++ CPU prover kernels and embeds a 59.8 MB recursion zkr archive in the .so. Public transactions are executed by the sequencer with no proof.

(2) The wallet also depends on logos-blockchain-core, through lez/common → logos-blockchain-common-http-client. That core depends on the Bedrock circom circuits (PoL, PoQ, PoC, Signature) through the lbc-*-sys crates, and on rust-rapidsnark. Their build scripts need LBC_ROOT_DIR, or a prebuilt download chosen by target os/arch, and RAPIDSNARK_LIB_DIR. The Nix flakes supply these for host systems only.

No Android circuits bundle is published. The release matrix covers linux x86_64/aarch64, macos aarch64 and windows x86_64 only. rapidsnark does have iden3 Android prebuilts, and the fork's download script already maps aarch64/x86_64-linux-android to them.

RLN proving in liblogos_rln_module is pure-Rust zerokit (arkworks Groth16) with a depth-10 zkey embedded at build time. It compiles for Android, and a librln.so built for arm64/x86_64 already exists in logos-android-wrap-poc.

A minimal public-only LEZ demo on Android needs no circuit at runtime. It does need Android-targeted link inputs for the Bedrock circuit crates (NDK-built libs or stubs, plus data files copied from the host bundle), and should be built with wallet-ffi --no-default-features.

### Claims
- [C1|critical|verified-from-source] LEZ's zero-knowledge stack is RISC Zero (risc0-zkvm 3.0.5). Public transactions are executed by the sequencer with no proof. Private (privacy-preserving) transactions are executed and proved locally by the user, and validators verify the proof.
- [C2|critical|verified-from-source] The RISC Zero guest ELFs are committed to git under artifacts/, and build.rs only embeds them. That covers privacy_preserving_circuit.bin and 17 program .bin files (16 at the rev lez_core pins). build_utils::include_artifacts reads the .bin files and computes image IDs with risc0_binfmt::compute_image_id. Building wallet_ffi or lez_core therefore needs no cargo-risczero, rzup, Docker or RISC0_SKIP_BUILD. Guests are only rebuilt by `just build-artifacts` (cargo risczero build with Docker tag r0.1.91.1).
- [C3|critical|verified-from-source] Local proving is enabled only by wallet-ffi's default feature prove = [lee/prove] -> risc0-zkvm/prove. It is used by the private-path FFI calls: transfer_shielded / deshielded / private / *_owned, register_private_account, vault_claim_private, claim_pinata_private*, send_generic_private_transaction. These go through wallet.send_privacy_preserving_tx -> execute_and_prove_with_padded_inputs -> default_prover().prove_with_opts(..., ProverOpts::succinct()). This is a succinct STARK receipt, with no Groth16 wrap.
- [C4|high|verified-from-source] Without the prove feature, risc0 default_prover() falls back to ExternalProver, which spawns an r0vm subprocess. No r0vm exists on Android, so private transactions would fail at runtime while public ones are unaffected. RISC0_DEV_MODE=1 (with prove) produces fake receipts through DevModeProver. Those receipts are accepted only by a verifier that is also in dev mode.
- [C5|high|verified-from-source] risc0-zkvm/prove adds, at build time, (a) C++ CPU prover kernels (risc0-circuit-rv32im-sys / recursion-sys / keccak-sys, plus risc0-sys headers) compiled through the cc crate, and (b) the risc0 recursion_zkr.zip. The zip is downloaded from S3 or taken from RECURSION_SRC_PATH and embedded. CUDA kernels are built only with feature cuda, Metal only when target_os is macos/ios. The CPU kernel sources contain no x86 or NEON intrinsics.
- [C6|high|verified-by-experiment] In the host-built libwallet_ffi.so (x86_64, 108,567,024 bytes, the same file shipped in lez_core 0.4.2), the 59.8 MB risc0 recursion_zkr.zip is embedded (5 of 5 non-trivial probes matched). The RISC Zero CPU prover is linked in (3,509 risc0 symbols, including CpuCircuitHal generate_witness). .rodata is about 72 MB. The lez_core 0.4.2 .lgx is 70 MB.
- [C7|critical|verified-from-source] The wallet depends transitively on the Bedrock circom circuits. The chain is wallet -> lez/common -> logos-blockchain-common-http-client -> logos-blockchain-core -> logos-blockchain-pol / poc / zksign / blend-proofs (-> poq) -> logos-blockchain-circuits-{pol,poc,signature,poq}-sys plus logos-blockchain-circuits-prover -> rust-rapidsnark. LEZ source itself never uses these proofs: there are no lb_poc / proof-of-claim references in lez/ or lee/.
- [C8|high|verified-from-source] logos-blockchain-circuits compiles four circom circuits (PoQ, PoL, PoC, Signature) to C++ witness generators with circom --c --r1cs --no_asm --O2. Each becomes lib{circuit}.a with symbol isolation, plus a bundled static libgmp.a. Groth16 proving keys (.zkey) and verification keys come from snarkjs with the Hermez ptau. The release bundle also contains rapidsnark prover/verifier CLI binaries. All of this is built in GitHub CI and published as release tarballs.
- [C9|critical|verified-from-source] Circuit release bundles, and the circuits flake, exist only for linux-x86_64, linux-aarch64, macos-aarch64 and windows-x86_64. None exists for Android. The flake is only a fetchurl of the GitHub release tarball, never a from-source build.
- [C10|critical|verified-from-source] The lbc-*-sys build scripts (lbc-build) need LBC_ROOT_DIR. If it is unset and the prebuilt feature is on, they download logos-blockchain-circuits-v<ver>-<CARGO_CFG_TARGET_OS>-<CARGO_CFG_TARGET_ARCH>.tar.gz. logos-blockchain enables prebuilt for pol and zksign. For an Android target that would request an android-aarch64 asset that is not published (C9), so the build fails unless LBC_ROOT_DIR points to a directory of Android-built libs. lbc-build also emits link directives for static {circuit}, static gmp and stdc++ (c++ only on macOS).
- [C11|high|verified-by-experiment] The lbc -sys crates embed proving_key.zkey, verification_key.json and witness_generator.dat from LBC_ROOT_DIR at compile time with include_bytes!, so the files must exist at build time. In the host-built libwallet_ffi.so none of the Bedrock zkeys or vkeys are present (0 hits), so they are dead-stripped. The PoC witness-generator code and GMP are linked in: local symbols poc_generate_witness and poc_generate_witness_from_files, and 182 GMP symbols. rapidsnark's groth16_prover entry points are not linked.
- [C12|high|inferred] The circuit C++ is portable: generated with --no_asm, FFI sources use only standard headers plus nlohmann/json and GMP, and there are no x86 intrinsics. An NDK build of lib{circuit}.a and libgmp.a is therefore feasible in principle. It would need the circom 2.2.2 host compiler, the repo's patches (main.cpp return, calcwit leak), NDK clang, and llvm-objcopy / ld -r for symbol isolation. No Android recipe exists upstream (Makefile targets: linux / macos / windows only).
- [C13|medium|inferred] Each circuit release's .zkey comes from a single-contributor snarkjs setup with a random (/dev/urandom) contribution. An Android build therefore must reuse the proving and verification keys (and .dat) from the matching release bundle and never regenerate them, or proofs would not match nodes' verification keys. These data files are architecture-independent.
- [C14|high|verified-from-source] rust-rapidsnark at the rev pinned by LEZ and logos-blockchain (e91187f8) takes libs from RAPIDSNARK_LIB_DIR or downloads them. The download script maps aarch64-linux-android and x86_64-linux-android to upstream iden3 prebuilt assets (rapidsnark-android-arm64-v<ver>, rapidsnark-android-x86_64-v<ver>). Mobile targets link static rapidsnark/fr/fq/gmp and use libc instead of pthread. The circuits-prover crate enables static-rapidsnark. The iden3 upstream Makefile also has android / android_x86_64 build targets.
- [C15|medium|verified-by-experiment] Under Nix vendoring (crane), the RAPIDSNARK_VERSION file that the download fallback reads (../RAPIDSNARK_VERSION) is absent. RAPIDSNARK_LIB_DIR is therefore effectively mandatory for Nix-style builds. The existing Nix rapidsnark package only fetches the linux-x86_64 PIC prebuilt zip.
- [C16|high|verified-from-source] The LEZ flake's wallet package (what lez_core uses as external lib wallet_ffi) automates all three prerequisites for host systems only: LBC_ROOT_DIR (circuits flake), RAPIDSNARK_LIB_DIR (rust-rapidsnark flake) and RECURSION_SRC_PATH (pre-fetched zkr). Its systems are x86_64-linux, aarch64-linux, aarch64-darwin and x86_64-windows, with no Android output. It builds -p wallet-ffi with default features, so prove is on. The lez-rln module source says the same thing in its own words.
- [C17|medium|verified-from-source] The pins have drifted. On LEZ dev HEAD, Cargo.lock uses lbc v0.5.6 crates but the flake still pins circuits commit 2846ee7a (v0.5.3). At the rev lez_core pins (87fca2a1) they match (lbc v0.5.3). logos-blockchain pins circuits v0.5.6.
- [C18|medium|verified-from-source] liblogos_rln_module proves RLN in process with zerokit rln 3.0.0, default-features=false, which uses the pure-Rust arkworks ArkGroth16Backend. It embeds a vendored depth-10 circuit: graph.bin (171 KB, circom-witnesscalc graph) and rln_final.arkzkey (1.9 MB), included at build time with include_bytes!. There is no C++, GMP or rapidsnark dependency.
- [C19|medium|verified-by-experiment] There is precedent for building zerokit for Android. logos-android-wrap-poc, through logos-delivery's make targets, cross-compiles zerokit librln (v2.0.2) with cross (Docker) for Android ABIs. librln.so is already built for arm64-v8a and x86_64.
- [C20|medium|verified-from-source] liblogos_lez_rln_module does not prove anything itself. It uses risc0-zkvm with std only, and rln is a dev-dependency only. It links wallet_ffi directly for registry transactions, so it inherits wallet_ffi's build prerequisites. The on-chain RLN registry guests in logos-lez-rln are built on the host with cargo risczero build plus Docker. They are not Nix-automated and not needed on the device.
- [C21|high|open] RISC Zero's docs say CPU proving runs on 'nearly any modern CPU (x86 or ARM)'. They do not mention Android. The Groth16 wrapper is x86-only (LEZ does not use it, per C3). Proving with less than 10 GB of memory may need a smaller segment size. On-device LEZ private-transaction proving on Android is therefore unverified and likely heavy.
- [C22|medium|verified-from-source] An adjacent non-circuit native prerequisite blocks an Android wallet_ffi build. wallet -> keycard_wallet -> pcsc, and pcsc-sys requires libpcsclite through pkg-config or PCSC_LIB_DIR/PCSC_LIB_NAME on any non-windows/macos target, Android included. The host .so has NEEDED libpcsclite.so.1. This is present at the rev lez_core pins.
- [C23|medium|inferred] The Android NDK r27c sysroot has libc++_static.a / libc++_shared.so and only the minimal system libstdc++ (libstdc++.a / per-API libstdc++.so). The circuit objects in the linux-aarch64 release bundle were built with g++/libstdc++ against glibc, so they cannot be reused on Android and must be rebuilt with NDK clang/libc++. lbc-build's hard-coded -lstdc++ on non-macOS targets would resolve to the minimal system lib and needs libc++ linked alongside.

### Open questions
- Does risc0-zkvm 3.0.5 with the prove feature actually cross-compile and run for aarch64-linux-android? The C++ kernels are portable and use the cc crate, but no build has been attempted, and peak memory for a succinct proof of privacy_preserving_circuit on a phone or emulator is unknown.
- When an unreferenced -sys static lib (pol/poq/signature) is built for the wrong architecture, does rustc/lld fail when bundling or linking for Android, or skip it? This decides whether only libpoc.a (which is actually linked) needs a real Android build, or all four.
- Why are poc_generate_witness and GMP linked into libwallet_ffi.so at all, and can a logos-blockchain-core feature or dependency trim remove them? Presumably something reaches lb_poc through leader_claim_proof or mantle types. LEZ only needs the http client types.
- Do the circuits' libgmp.a (lib/) and the iden3 rapidsnark libgmp.a conflict or duplicate when both are linked statically into one Android .so? On host both are linked, and no issue was observed.
- Which iden3 rapidsnark version do RAPIDSNARK_VERSION and the Nix package name point to (0.0.8)? Does the rapidsnark-android-arm64-v0.0.8 asset exist? The asset name comes from download_rapidsnark.sh; the GitHub release page was not checked, to respect the no-GitHub rule.
- Is a stub-library approach acceptable to the project? That means stub lib{pol,poq,poc,signature}.a exporting the two FFI symbols that return an error, an empty or stub libgmp.a, and zkey/vkey/.dat copied from the matching host bundle so include_bytes! resolves. It would be functionally safe for the wallet (never called), but it is a hack.
- Does the target sequencer for the demo (public testnet vs local standalone) run with RISC0_DEV_MODE? That decides whether dev-mode fake receipts could stand in for private-transaction proving in a demo.

### Recommendations
- Keep the minimal LEZ-on-Android demo to public-state operations: wallet_ffi_create_new/open, create_account_public, get_balance, sync_to_block, transfer_public / send_generic_public_transaction, vault_claim (public). These trigger no proving, so no circuit is needed at runtime.
- Cross-compile wallet_ffi for aarch64-linux-android (and x86_64-linux-android for the emulator) with cargo-ndk and `-p wallet-ffi --no-default-features`. This drops risc0 prove: no C++ prover kernels and no 59.8 MB recursion_zkr.zip. Private-path FFI calls will then return a proving error, because they would try r0vm.
- Set RAPIDSNARK_LIB_DIR to the iden3 Android prebuilt libs (librapidsnark.a, libfr.a, libfq.a, libgmp.a from rapidsnark-android-arm64-v0.0.8 / -x86_64). Do not rely on the build.rs download, which is unavailable under vendoring and needs network access.
- Assemble an Android LBC_ROOT_DIR. Copy {pol,poq,poc,signature}/{proving_key.zkey,verification_key.json,witness_generator.dat} and VERSION from the host release bundle whose version exactly matches the lbc tag in the Cargo.lock being built (v0.5.3 at lez_core's pinned LEZ rev 87fca2a1). Add Android-built lib{circuit}.a and lib/libgmp.a.
- Produce those Android circuit libs one of two ways. (a) Real: run circom 2.2.2 --c --no_asm on the host, apply the repo's two patches, compile with NDK clang++ against an NDK-built GMP (iden3's build_gmp.sh android or the rapidsnark Android libgmp.a), then do ld -r plus llvm-objcopy --keep-global-symbol for the two public symbols. (b) Quick: stub archives exporting {circuit}_generate_witness and _from_files that return an error, since the wallet never calls them. Script either option under .work and wrap it in a Nix derivation later.
- Provide a stub libpcsclite for Android through PCSC_LIB_DIR/PCSC_LIB_NAME (keycard is unused in the demo), or feature-gate keycard upstream. This is not a circuit, but it is the same class of native link blocker.
- Do not build RISC Zero guests or Bedrock circuits from source. The guest ELFs are committed in LEZ artifacts/, the circom zkeys are release-specific and must be reused, and circom, snarkjs, cargo-risczero and Docker are host-only tools that the demo does not need.
- Treat RLN (liblogos_rln_module) as a separate follow-up. zerokit rln 3.0.0 is pure Rust and embeds its depth-10 graph and zkey, so plain cargo-ndk should work; the wrap-poc cross-built zerokit librln is the precedent.
- Treat on-device private transactions as a later experiment. Enable prove, point RECURSION_SRC_PATH at the Nix-fetched zkr zip, cross-compile, and measure memory and time on arm64 hardware; check whether RISC0_DEV_MODE is available against a dev-mode sequencer first.
- Upstream suggestions for the LEZ team: feature-gate the Bedrock proving crates out of logos-blockchain-common-http-client / logos-blockchain-core for clients, publish android-{aarch64,x86_64} circuit bundles from the CI matrix, and fix the LEZ dev flake circuits pin (v0.5.3) versus Cargo.lock (v0.5.6) drift.

### Verifier (non-confirmed only)
- [C10] partially-correct: All FOUR logos-blockchain proof crates enable prebuilt, not just pol and zksign: poc/Cargo.toml:16, pol:18, poq:17, zksign:17, both at da7bd379 (the rev LEZ pins) and at local HEAD. The lbc-*-sys crates also declare default = ["prebuilt"]. For an Android target the build still fails as described. It would request logos-blockchain-circuits-v0.5.6-android-aarch64.tar.gz, get a 404, and panic, unless LBC_ROOT_DIR is set. Separately, lbc-build emits cargo:rustc-link-lib=stdc++ for every non-macOS target including Android. NDK's libstdc++ is only the minimal system runtime, so NDK-built circuit libs (std::__ndk1) would additionally need libc++ (c++_shared or c++_static) linked, or that line patched.

Confirmed: C1, C2, C3, C4, C5, C6, C7, C8, C9, C11, C12, C14, C16, C21

### Verifier missed findings
- BIGGEST MISS: the whole Bedrock-circuit, rapidsnark and GMP stack enters wallet-ffi only because of one type conversion. In lez/common/src/config.rs:5,51-55, `use logos_blockchain_common_http_client::BasicAuthCredentials; impl From<BasicAuth> for BasicAuthCredentials`. A Cargo.lock BFS from wallet-ffi shows common -> logos-blockchain-common-http-client is the only LEZ-to-logos-blockchain edge (bash /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/verify-circuits-lockgraph.sh, for both HEAD and the shipped build-src lock). No other logos_blockchain use exists in lez/common, lez/wallet or lez/wallet-ffi sources, at HEAD, at 87fca2a1 or in /nix/store/jl63nj...-source. A few-line patch to lez/common (feature-gate that impl and dependency) removes logos-blockchain-core, lbc-{pol,poq,poc,signature}-sys, circuits-prover, rust-rapidsnark and libgmp from an Android wallet-ffi build. That makes 'NDK-built circuit libs or stubs' unnecessary for the minimal demo.
- Non-circuit native blocker in the same graph: wallet -> keycard_wallet -> pcsc -> pcsc-sys. It is unconditional: /home/fryorcraken/src/logos-blockchain/logos-execution-zone/lez/wallet/Cargo.toml:22 and lez/keycard_wallet/Cargo.toml:12,16. For target_os=android, pcsc-sys build.rs needs PCSC_LIB_DIR/PCSC_LIB_NAME or finds libpcsclite through pkg-config, and otherwise exits 1 (/nix/store/7w4cby2m...-cargo-package-pcsc-sys-1.3.0/build.rs:43-61). The shipped libwallet_ffi.so has NEEDED libpcsclite.so.1 and imports SCardEstablishContext/SCardTransmit/... (verify-circuits-elf.sh), and the LEZ flake adds pkgs.pcsclite (flake.nix:127). Android has no pcsclite, so an Android wallet-ffi needs a stub libpcsclite or has to patch keycard support out.
- The shipped lez_core 0.4.2 libwallet_ffi.so (sha256 191d16e1...) was NOT built from 87fca2a1. Its drv src is /nix/store/jl63njxvhab911gzs1g52b6wbvkspz88-f6m04y303z8y4xj174cw2qfv6ngm06p6-source. That source contains artifacts/lez/programs/fee.bin, has no pinata, pinata_token or vault, and its ppc.bin sha256 f2d9e655... matches no local commit. The embedded ppc guest from that source probes 15/15, while 87fca2a1's ppc probes only 3/14. The local logos-execution-zone-module is v0.4.0 (metadata.json:4); blockchain-modules-release pins module commit 0ea57f8a, which is absent locally. This matters because the wallet's program IDs and PRIVACY_PRESERVING_CIRCUIT_ID are image IDs computed from the embedded ELFs and must equal the sequencer's (lez/wallet/src/cli/mod.rs:243-264 asserts local == remote). An Android build must pin the LEZ rev that matches the target sequencer, even for public-only transfers.
- Circuits version drift: the LEZ flake pins the circuits flake at 2846ee7a (= v0.5.3), and the real build drv used LBC_ROOT_DIR=/nix/store/ai2mn1mc...-logos-blockchain-circuits-0.5.3. The lbc-*-sys crates in Cargo.lock, however, are tag v0.5.6 (Cargo.lock:6720-6790), contradicting the flake comment at flake.nix:16. Any Android circuit bundle (if the C7 patch is not applied) should use the v0.5.6 release zkeys and .dat files.
- Bedrock zkeys cannot be regenerated from source. ci.yml:147 adds a random /dev/urandom contribution to every release's zkey, and every platform bundle copies the same proving-keys artifact (ci.yml:401-407, 672-678, 980-986, 1252-1258). The data files for an Android bundle must therefore come from the matching release tarball. Only lib{circuit}.a and libgmp.a would be rebuilt with the NDK.
- Host circuit bundles cannot be relinked into Android. /nix/store/ai2mn1mc...-circuits-0.5.3/poc/libpoc.a has 20 undefined std::__cxx11 (GNU libstdc++) references and lib/libgmp.a is x86-64 (verify-circuits-embed.sh). The linux-aarch64 bundle is built the same way with glibc/libstdc++. lbc-build emits cargo:rustc-link-lib=stdc++ for every non-macOS target (logos-blockchain-circuits-build/src/lib.rs:187-191), which is wrong for NDK libc++.
- lez_rln module RLN story. liblogos_lez_rln_module (>= 3.0.0) links wallet_ffi from a LEZ FORK, github:adklempner/logos-execution-zone?rev=8e2b119e (logos-rln-modules/logos-lez-rln-module/flake.nix:13,26-27,45-53; metadata.json:24,35). Its shipped staticlib does NOT link zerokit: rln is a dev-dependency only (rust-lib/Cargo.toml:36-40), and it depends directly on risc0-zkvm 3.0 (Cargo.toml:26). Porting LEZ-RLN to Android therefore inherits every wallet_ffi issue (risc0, pcsc, the Bedrock edge) for the fork's rev. The existing Nix-store 2.1.0 plugin shows 704 risc0 symbols and no libwallet_ffi NEEDED, so it predates that change.
- The RLN zerokit precedent is weaker than the summary implies. logos-rln-module uses rln = 3.0.0 statically, with the depth-10 rln_final.arkzkey and graph.bin vendored in the module repo (rust-lib/src/proof.rs:52,58-59). The librln.so in logos-android-wrap-poc is zerokit 2.0.x (vendor/zerokit rln/Cargo.toml version 2.0.2, git tag v2.0.3), built as a cdylib through `cross` Docker (nim-src/logos-delivery/scripts/build_rln_android.sh:21-29). It is evidence that zerokit's Rust cross-compiles for Android, but it is not a reusable artefact for rln_module.
- The LEZ workspace declares wallet-ffi with default-features = false (Cargo.toml:102), but that only affects workspace dependents. The flake's crane build is `cargo build -p wallet-ffi` (drv buildPhase), so the crate's own default ["prove"] applies. --no-default-features has to be passed explicitly in an Android build.

---

## Full report

## Blockchain circuits for lez_core and the LEZ/RLN modules, and whether they run on Android

### TL;DR

"Building blockchain circuits" covers two ZK stacks that lez_core's native library, libwallet_ffi.so (crate lez/wallet-ffi), pulls in.

1. **RISC Zero, LEZ's own ZK stack.** The guest programs, including the privacy-preserving circuit, are **prebuilt and committed** in `logos-execution-zone/artifacts/`. Nothing has to be built for them. Local proving happens only for private or shielded transactions, and only when wallet-ffi's default `prove` feature is on.
2. **The Bedrock circom circuits (PoL, PoQ, PoC, Signature) and rapidsnark.** The LEZ wallet uses none of them. They arrive through a transitive dependency: `lez/common → logos-blockchain-common-http-client → logos-blockchain-core → pol/poc/zksign/poq`. Their Rust `-sys` crates need a platform-specific directory of prebuilt static libs (`LBC_ROOT_DIR`) at build time, and **no Android build of these libs exists**.

A minimal public-only LEZ demo on Android needs **no circuit at runtime**. It does need Android-targeted link inputs for the Bedrock circuit crates: real NDK builds or stubs, plus data files copied from the host bundle. It also needs iden3's Android rapidsnark prebuilt, and a build with `--no-default-features`.

### 1. LEZ / LEE zero-knowledge stack (RISC Zero)

**What proves what.** LEZ runs everything on the RISC Zero zkVM (risc0-zkvm 3.0.5, `logos-execution-zone/Cargo.toml:144-145`). The README (`/home/fryorcraken/src/logos-blockchain/logos-execution-zone/README.md:68`) says: "Public transactions are executed directly on-chain like any standard RISC-V VM call, without proof generation. Private transactions are executed locally by users, who generate Risc0 proofs that validators verify". So the client proves only the privacy-preserving (shielded, deshielded, private) path. The sequencer executes public transactions and verifies private proofs.

**Guest programs are committed data, not something the build compiles.** `artifacts/lee/privacy_preserving_circuit/privacy_preserving_circuit.bin` (582 KB) and 17 program ELFs in `artifacts/lez/programs/*.bin` (token, amm, vault, pinata, bridge, …, 340–570 KB each) are in git (`git ls-files artifacts`; 16 program ELFs at the rev lez_core pins, 87fca2a1).

- `lee/state_machine/build.rs:2` and `lez/programs/build.rs:3` call `build_utils::include_artifacts`.
- That function (`build_utils/src/lib.rs:36-70`) reads the `.bin` files, computes image IDs with `risc0_binfmt::compute_image_id`, and emits `pub const X_ELF: &[u8] = include_bytes!(...)` and `X_ID: [u32; 8]`.
- Guests are regenerated only by `just build-artifacts`, which runs `cargo risczero build` in the Docker image `r0.1.91.1` (`Justfile:15-38`).
- `risc0-build` (the guest builder) appears only in test_methods, test_programs and examples, which are outside the wallet-ffi dependency graph.

**Conclusion:** building lez_core or wallet_ffi needs no rzup, cargo-risczero, Docker or `RISC0_SKIP_BUILD`. The guests are embedded at build time and executed or proved at runtime.

**Local prover (runtime, client side, optional).**

- `lez/wallet-ffi/Cargo.toml` has `default = ["prove"]`, `prove = ["lee/prove"]`; `lee/state_machine/Cargo.toml:37` has `prove = ["risc0-zkvm/prove"]`. Nothing else in lez/ or lee/ enables prove.
- The private FFI calls end in `lee::…::circuit::execute_and_prove_with_padded_inputs` (`lez/wallet/src/lib.rs:781`). That function calls `default_prover().prove_with_opts(env, PRIVACY_PRESERVING_CIRCUIT_ELF, &ProverOpts::succinct())` (`lee/state_machine/src/privacy_preserving_transaction/circuit/mod.rs:309-312`). The private calls are:
  - `wallet_ffi_transfer_shielded`, `transfer_deshielded`, `transfer_private`, `*_owned`
  - `register_private_account`, `vault_claim_private`, `claim_pinata_private_*`
  - `send_generic_private_transaction`
- The result is a **succinct STARK receipt**. There is no Groth16/"stark-to-snark" step, so risc0's x86-only Groth16 prover is never involved.
- Public calls (`transfer_public`, `create_account_public`, `get_balance`, `sync_to_block`, `vault_claim`, `send_generic_public_transaction`) never prove.

**How the prover is selected.** `risc0-zkvm-3.0.5/src/host/client/prove/mod.rs:183-212` picks the prover as follows:

- `RISC0_PROVER` if set;
- else Bonsai, if the Bonsai env vars are set and dev mode is off;
- else `LocalProver` if the `prove` feature is on;
- otherwise `ExternalProver`, which spawns an `r0vm` subprocess.

Without `prove`, private transactions would fail on Android because there is no r0vm. Public transactions are unaffected.

`RISC0_DEV_MODE=1` makes `get_prover_server` return a `DevModeProver` (`server/prove/mod.rs:417-421`). Its `FakeReceipt` verifies only if the verifier is also in dev mode (`receipt.rs:594-606`). Dev mode is therefore a shortcut only against a sequencer running in dev mode.

**What `prove` costs at build time** (`risc0-zkvm Cargo.toml:72-99`):

- **C++ CPU kernels**, compiled through `risc0_build_kernel` / `cc`:
  - risc0-circuit-rv32im-sys (`build.rs:22-39`), recursion-sys, keccak-sys, plus risc0-sys headers.
  - CUDA kernels only with feature `cuda`; Metal kernels only for macos/ios (`risc0-sys build.rs:27-41`).
  - No x86 or NEON intrinsics in the CPU kernel sources (grep came back empty).
- **`recursion_zkr.zip` (59.8 MB)**. `risc0-circuit-recursion build.rs:16-17,42-71` downloads it from S3 (sha256 744b999f…), or takes it from `RECURSION_SRC_PATH`, under `cfg(feature="prove")`.

Experiment: the host-built `libwallet_ffi.so` (108,567,024 bytes) is the file that ships in the lez_core 0.4.2 module (`/nix/store/1kalh7g6…-logos-lez_core-module-lib-0.4.2/lib/`; the `.lgx` is 70 MB).

- The whole zkr zip is embedded: 5 of 5 probes hit.
- The risc0 CPU prover is linked: 3,509 risc0 symbols, including the `CpuCircuitHal` witness generators.
- `.rodata` is about 72 MB.

The scripts are `.work/scripts/circuits-symbols.sh`, `circuits-embed2.sh` and `circuits-rapidsnark-syms.sh`. So `prove` accounts for most of lez_core's size.

**Android verdict for RISC Zero proving: unknown.** The code is portable C++ and Rust built through `cc`, so it probably compiles for aarch64-linux-android. RISC Zero's docs say "RISC Zero proving will run on nearly any modern CPU (x86 or ARM)". They do not mention Android, and they warn that below 10 GB of memory the segment size may need changing (https://dev.risczero.com/api/generating-proofs/local-proving). Nobody has built or run it. It is not needed for a public-only demo.

### 2. logos-blockchain-circuits (Bedrock circom circuits) and rapidsnark

**What it is.** `/home/fryorcraken/src/logos-blockchain/logos-blockchain-circuits/README.md:6-13` lists four circom circuits:

| Circuit | Proves |
|---|---|
| PoQ (Proof of Quota) | Blend quota |
| PoL (Proof of Leadership) | Leadership lottery win |
| PoC (Proof of Claim) | Voucher ownership and nullifier |
| Signature | Knowledge of secret keys |

Pipeline (`docs/build-pipeline.md`, `.github/actions/compile-witness-generator/action.yml:72`):

- `circom --c --r1cs --no_asm --O2` produces a C++ witness generator, the `.r1cs` and the `.dat`.
- `snarkjs groth16 setup` with the vendored Hermez ptau produces `proving_key.zkey` and `verification_key.json`. The setup uses a **random single contribution** (`ci.yml:141-148`: `head -c 32 /dev/urandom | … snarkjs zkey contribute`).
- The C++ is patched (missing `return` in main.cpp, calcwit leak), compiled with `g++ -std=c++11 -O3`, merged with `ld -r`, and all symbols except `{circuit}_generate_witness[_from_files]` are localised with objcopy (`.github/resources/witness-generator/Makefile:9-11,74-79`).
- A static `libgmp.a` is built from source, and rapidsnark `prover`/`verifier` CLIs are bundled.

The release bundle (`/nix/store/ai2mn1mc…-logos-blockchain-circuits-0.5.3`, 46 MB) contains `{pol,poq,poc,signature}/{lib*.a, proving_key.zkey (4–13 MB), verification_key.json, witness_generator.dat, include/}`, `lib/libgmp.a`, `prover` and `verifier`.

**How it is built and distributed.** GitHub CI builds natively on four runners. The release upload matrix is linux x86_64, linux aarch64, macos aarch64 and windows x86_64 (`ci.yml:1417-1426`). The flake (`flake.nix:13-18,63-72`) is only a `fetchurl` of `…/releases/download/v<ver>/logos-blockchain-circuits-v<ver>-<os>-<arch>.tar.gz` for those systems, with hashes in `circuits-nix-hashes.json`. **There is no Android asset and no Android flake output.** The `justfile` has local `circom` + `make linux-lib` recipes that the rust/README calls "not yet an officially supported workflow". The Makefile has only linux, macos and windows targets.

**How Rust consumes it.** Each `-sys` crate's build.rs calls `lbc_build::build_circuit(name)` (`rust/logos-blockchain-circuits-build/src/lib.rs`):

- It resolves `LBC_ROOT_DIR`. If that is unset and the `prebuilt` feature is on, it downloads the release for `CARGO_CFG_TARGET_OS`/`CARGO_CFG_TARGET_ARCH` (lines 16-24, 83-86, 131-146).
- It emits `rustc-link-lib=static={circuit}`, `static=gmp`, and `stdc++` (or `c++` on macOS) (lines 184-192).
- `lbc-common`'s `circuit_artifacts!` macro `include_bytes!`es `proving_key.zkey`, `verification_key.json` and `witness_generator.dat` from `LBC_ROOT_DIR` (`artifacts.rs:24-45`), so those files must exist at compile time.
- logos-blockchain enables `prebuilt` for pol and zksign (`zk/proofs/pol/Cargo.toml:18`, `zk/proofs/zksign/Cargo.toml:17`).
- For an Android target, the build would try to fetch `…-android-aarch64.tar.gz`, which is not published, and panic unless `LBC_ROOT_DIR` is set.

**Who consumes it:**

- **The Bedrock node / logos-blockchain-c**, for real. The logos-blockchain flake sets `LBC_ROOT_DIR` and `RAPIDSNARK_LIB_DIR` at lines 92-93. The logos-blockchain-module wraps logos-blockchain-c.
- **The LEZ wallet, incidentally.** The dependency chain is in `Cargo.lock:6820-6840, 6863-6894, 6502-6516, 6720-6790`. LEZ code never uses PoC/PoL (grep of lez/ and lee/ is empty).

The LEZ flake still has to provide `LBC_ROOT_DIR` and `RAPIDSNARK_LIB_DIR` for the wallet (`logos-execution-zone/flake.nix:137-141`). The lez-rln module's own source spells the same requirement out (`logos-lez-rln-module/rust-lib/src/wallet.rs:13-19`): "Compiling it needs a prebuilt rapidsnark, the circuits tree, a pre-fetched risc0 recursion archive and, on macOS, a Metal toolchain stub…".

**What actually lands in the wallet .so** (experiment on the host build):

- None of the Bedrock zkeys or vkeys (0 hits), so they are dead-stripped.
- PoC witness-generator code *is* linked (local symbols `poc_generate_witness`, `poc_generate_witness_from_files`), plus 182 GMP symbols.
- rapidsnark's `groth16_prover*` is not linked.

So the circuit libs are **link-time inputs** for the wallet, with at least libpoc.a and libgmp.a really linked. They are not runtime data.

**Pin drift (FYI).** LEZ dev HEAD's Cargo.lock uses lbc v0.5.6 crates, while its flake pins circuits commit `2846ee7a` = v0.5.3 (`flake.nix:16-19`). At the LEZ rev lez_core pins (87fca2a1) both are v0.5.3. logos-blockchain uses v0.5.6. Any hand-assembled `LBC_ROOT_DIR` must match the lbc tag in the Cargo.lock actually being built.

**rust-rapidsnark** (the fork at e91187f8, pinned by both LEZ and logos-blockchain):

- `build.rs` takes libs from `RAPIDSNARK_LIB_DIR`, or runs `download_rapidsnark.sh`.
- The script maps `aarch64-linux-android` → `rapidsnark-android-arm64-v$VER` and `x86_64-linux-android` → `rapidsnark-android-x86_64-v$VER` from **upstream iden3 releases**. Linux uses the fork's -fPIC rebuilds (`download_rapidsnark.sh:36-44`).
- Mobile targets link static rapidsnark/fr/fq/gmp and `c` instead of pthread (`build.rs:50-63`). `logos-blockchain-circuits-prover` sets `static-rapidsnark`.
- Upstream iden3 rapidsnark documents Android builds (`./build_gmp.sh android`, `TARGET_PLATFORM=ANDROID`; see also the copy of its Makefile in `.github/resources/prover/Makefile:57-75`). iden3/android-rapidsnark targets 64-bit Android, API 24+.
- Nix nuance: the crane-vendored crate lacks `../RAPIDSNARK_VERSION`, so the download fallback cannot work under Nix and `RAPIDSNARK_LIB_DIR` is required. The Nix `rapidsnark-0.0.8` package just unzips `rapidsnark-linux-x86_64-pic-v0.0.8.zip` (`nix derivation show`).

**Android verdict for the Bedrock circuits:**

- **rapidsnark: yes.** Use the iden3 Android prebuilts.
- **Witness-generator libs: feasible from source, not provided.** The code is portable C++11 with `--no_asm`, standard headers, nlohmann/json and GMP. A build needs circom 2.2.2 on the host, the two patches, NDK clang++/libc++, an NDK GMP, and `ld -r` + `llvm-objcopy`.
- **The linux-aarch64 bundle cannot be reused.** It was built with g++/libstdc++ against glibc. The NDK r27c sysroot has libc++ and only the minimal system libstdc++, and lbc-build hardcodes `-lstdc++`, so libc++ must also be linked.
- **Data files** (`.zkey`, `.json`, `.dat`) are architecture-independent. Copy them from the matching release; never regenerate them, because the random contribution makes each release's keys unique.

### 3. RLN circuits

**logos-rln-module (`liblogos_rln_module`)** does RLN proof generation and verification in process with **zerokit `rln` 3.0.0, `default-features=false`** (`rust-lib/Cargo.toml:37`). It uses the pure-Rust arkworks `ArkGroth16Backend` and embeds a vendored **depth-10** circuit (`proof.rs:52-59`): `graph.bin` (171 KB, witness-calculator graph) and `rln_final.arkzkey` (1.9 MB), both through `include_bytes!`. The lockfile (lines 1187-1212) shows only Rust dependencies (ark-*, sled, safer-ffi): no C++, GMP or rapidsnark. It is Android-compilable.

Precedent: logos-android-wrap-poc, through logos-delivery's `build_rln_android.sh:21-29`, cross-compiles zerokit librln v2.0.2 with `cross rustc --target=<android triple> --crate-type=cdylib`. `librln.so` exists for arm64-v8a and x86_64 under `nim-src/logos-delivery/build/android/`.

**logos-lez-rln-module (`liblogos_lez_rln_module`)** does no proving. It uses risc0-zkvm with `std` only, and rln is a dev-dependency only (`Cargo.toml:26,36-39`). It links `wallet_ffi` itself (`wallet.rs:13-19`), so it inherits all of wallet_ffi's build prerequisites. The on-chain RLN registry programs (`logos-lez-rln`: rln_registration, incremental_merkle_tree) are RISC Zero guests built on the host with `cargo risczero build` + Docker (README:15-37). They are deployed on chain and not Nix-automated (the flake exports only check-membership). The device does not need them.

### 4. Classification

| Component | Needed by | Build-time vs runtime | Where it runs | Android-compilable? | Recommendation |
|---|---|---|---|---|---|
| LEZ RISC Zero guest ELFs (privacy_preserving_circuit.bin + program .bin) and image IDs | lee, programs → wallet_ffi (lez_core, lez_rln) | Embedded at build time from committed artifacts/; image IDs computed in build.rs | zkVM: on client for private transactions, on sequencer for public ones | N/A: riscv32im data, arch-independent, already prebuilt | Bundle automatically (no action); do not rebuild |
| RISC Zero local prover (rv32im/recursion/keccak C++ kernels + Rust) | wallet-ffi default feature `prove` (private/shielded transactions) | Compiled at build time; used at runtime only for private operations | On device | Unknown: portable C++ via cc, no intrinsics, but Android is not documented and memory use is heavy | Not needed for the minimal demo: build with `--no-default-features`; experiment later |
| risc0 recursion_zkr.zip (59.8 MB) | risc0-circuit-recursion (prove only) | Downloaded or `RECURSION_SRC_PATH` at build time; embedded | Data inside the .so | Yes (data) | Dropped with `--no-default-features`; otherwise pre-fetch via `RECURSION_SRC_PATH` (the LEZ flake does this) |
| Bedrock circom witness-generator libs lib{pol,poq,poc,signature}.a + libgmp.a | logos-blockchain-core (transitive via lez/common); Bedrock node | Link time (lbc-*-sys build.rs); libpoc and GMP actually linked | Would run on device but the wallet never calls them | No published Android bundle; source is portable C++11 + GMP (needs circom 2.2.2 + NDK); cannot reuse linux-aarch64 objects | Needed at link time: NDK-compile, or ship stub archives, into an Android `LBC_ROOT_DIR` |
| Bedrock zkeys / vkeys / .dat | Same crates, through `include_bytes!` | Must exist at build time; dead-stripped from the wallet .so | n/a | Yes (arch-independent data) | Copy from the host release bundle whose version matches Cargo.lock; never regenerate |
| rapidsnark (librapidsnark/fr/fq/gmp) | logos-blockchain-circuits-prover (static-rapidsnark) | Link time; not linked into the host wallet .so | n/a | Yes: iden3 android-arm64/x86_64 prebuilts, mapped in download_rapidsnark.sh | Bundle the prebuilt via `RAPIDSNARK_LIB_DIR` |
| rapidsnark prover/verifier CLIs in the circuits bundle | Node tooling | Not used | Host | n/a | Not needed |
| zerokit RLN (rln 3.0.0) + depth-10 graph.bin / arkzkey | liblogos_rln_module | Compiled; data embedded at build time; proves at runtime | On device | Yes: pure Rust; wrap-poc precedent (librln.so arm64/x86_64) | Compile for Android when RLN is in scope; not needed for the minimal LEZ demo |
| LEZ-RLN registry guests | logos-lez-rln deploy | Host build-time only (cargo risczero + Docker) | Sequencer / on chain | N/A | Not needed |
| circom, snarkjs, ptau, cargo-risczero/rzup, Docker | Producing the artifacts above | Host tools only | Host | N/A | Not needed unless regenerating circuits (don't) |
| (Adjacent, not a circuit) pcsc / libpcsclite via keycard_wallet | wallet | Link time; host .so NEEDED libpcsclite.so.1 | Device | No pcsclite on Android; pcsc-sys needs `PCSC_LIB_DIR` / `PCSC_LIB_NAME` | Provide a stub lib |

### 5. Existing Nix automation (host systems only)

- **wallet_ffi:** `nix build github:logos-blockchain/logos-execution-zone/<rev>#wallet`. It is a crane build of `-p wallet-ffi` with default features, setting `LBC_ROOT_DIR`, `RAPIDSNARK_LIB_DIR` and `RECURSION_SRC_PATH` for x86_64-linux, aarch64-linux, aarch64-darwin and x86_64-windows (`flake.nix:38-43,137-160`).
- **lez_core:** `nix build` in logos-execution-zone-module (mkLogosModule, `externalLibInputs.wallet_ffi`, LEZ rev 87fca2a1).
- **Circuits:** `nix build github:logos-blockchain/logos-blockchain-circuits/<rev>` = GitHub release fetch.
- **rapidsnark:** `rust-rapidsnark#rapidsnark` = PIC linux prebuilt zip.
- **RLN modules:** `nix build .#logos-rln-module-lgx` and `.#logos-lez-rln-module-lgx` (logos-rln-modules).

None of these has an Android system or cross output. RISC Zero guests are built with `just build-artifacts` (not Nix) and committed.

### 6. Plain answer

A minimal LEZ-on-Android demo needs **none** of the blockchain circuits at runtime. That demo loads lez_core, opens or creates a wallet, creates a public account, syncs, reads a balance and sends a public transfer. None of these operations proves anything, because the sequencer executes public transactions.

The circuits matter only as **build and link prerequisites** of `wallet_ffi` for `aarch64-linux-android` / `x86_64-linux-android`:

1. The Bedrock circom witness-generator libraries (pol, poq, poc, signature) + libgmp for Android in an `LBC_ROOT_DIR`, alongside their zkey/vkey/.dat copied from the matching host release. They can be real NDK builds or stubs, since the wallet never calls them.
2. iden3's Android rapidsnark prebuilt via `RAPIDSNARK_LIB_DIR`.
3. Build with `--no-default-features` to skip the RISC Zero prover and its 60 MB recursion archive.

The LEZ "circuit" in the RISC Zero sense (privacy_preserving_circuit.bin) is already prebuilt and just gets embedded. RISC Zero on-device proving (private/shielded transactions) and zerokit RLN proving are later, optional steps. RLN is known to cross-compile; RISC Zero on Android is unverified.

Sources: https://dev.risczero.com/api/generating-proofs/local-proving ; https://github.com/iden3/rapidsnark ; https://github.com/iden3/android-rapidsnark
