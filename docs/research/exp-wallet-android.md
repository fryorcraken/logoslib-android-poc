# Experiment: wallet-android

> Gating experiment, 2026-09-25. Machine-written by the experiment agent; logs and scripts in
> [../../experiments/wallet-android](../../experiments/wallet-android); patches in [../../patches](../../patches).
> `.work/` paths refer to local scratch that is not committed.


### Summary
Yes, lez_core's native library (wallet-ffi) builds for Android. It needed three changes: a small source patch to lez/common, dropping the default `prove` feature, and a stub pcsclite. It builds cleanly for x86_64-linux-android and aarch64-linux-android with NDK r27c at API 34, with 16 KB LOAD alignment. It exports all 58 wallet_ffi_* functions. The stripped .so is 13.8-15.2 MB, against 104 MB for the desktop build, and the 60 MB RISC Zero recursion zip is gone. The patch makes the Bedrock dependency optional (or removes it). After it, no Bedrock circuits, rapidsnark or GMP crates are left, and no native build step downloads anything. The only native pieces left are pcsc-sys (handled by the stub, which can be linked statically so no extra .so ships) and ring's C/asm (NDK clang builds it without trouble). A test program with no JavaVM ran on the x86_64 API 34 emulator. With the default TLS setup (rustls-platform-verifier), creating a wallet fails because the verifier panics: "Expect rustls-platform-verifier to be initialized". With a small opt-in `webpki-roots` feature added to wallet and wallet-ffi, the same test created a wallet, created an account and read the block height over HTTPS from https://testnet.lez.logos.co/: height 24050 in 656 ms. The LEZ rev is d8596eb7 (tag v0.2.5-rc2).

### Results
- [pass|verified-from-source] Q1: Which logos-execution-zone rev does logos-execution-zone-module 825d2a4 lock? For reference, what does lez-programs pin for lez_core acf0cd50?
  825d2a4 locks logos-execution-zone d8596eb734bf9c9ce801afb92df06098a2eb098a, which is ref v0.2.5-rc2 (lastModified 1788941221, commit 'Merge pull request #837 ... erhant/handle-nonzero-exit', 2026-09-09). The local ~/src/logos-blockchain/logos-execution-zone did not have this commit, so it was fetched from GitHub; tag v0.2.5-rc2 resolves to the same commit. For reference, lez-programs flake.nix:59 pins lez_core acf0cd50, whose lock points to logos-execution-zone 9edf4a622fe966199beed71685c6f0b855db0784 (branch erhant/0.2.4-with-r0-fix, which is v0.2.4 plus one r0 fetch fix). That is an older wallet-ffi schema than d8596eb7.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/probe/logs/meta-github_logos-blockchain_logos-execution-zone-module_825d2a41262b9882aa0f9ca837cb03635f7980c2.json ('repo':'logos-execution-zone','rev':'d8596eb7...','original':{'ref':'v0.2.5-rc2'}); /home/fryorcraken/src/logos-blockchain/lez-programs/flake.lock:4613-4620 (rev 9edf4a62..., ref erhant/0.2.4-with-r0-fix); /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/logs/setup.log
- [pass|verified-by-experiment] Q2: Working copy at the locked rev, with its toolchain and the Android targets
  The working copy is `git clone --shared` into .work/experiments/wallet-android/lez, with d8596eb7 fetched from https://github.com/logos-blockchain/logos-execution-zone.git and checked out detached. rust-toolchain.toml pins channel 1.94.0 (profile default), which was already installed. I ran `rustup target add --toolchain 1.94.0 x86_64-linux-android aarch64-linux-android`. rustc 1.94.0 (4a4ef493e 2026-03-02), cargo 1.94.0.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/logs/setup.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/logs/x3-before.log
- [pass|verified-by-experiment] X3: After patching lez/common, are any lbc-* / logos-blockchain-circuits* / rust-rapidsnark / gmp crates left in wallet-ffi's graph (--no-default-features, x86_64-linux-android, -e normal,build)?
  Confirmed: none are left. Before the patch the graph had 680 unique crates, 63 of them with a build script, `links` or a -sys name. Those included logos-blockchain-circuits-{poc,pol,poq,signature}-sys 0.5.6, circuits-build, circuits-common, circuits-types, circuits-prover, rust-rapidsnark 0.1.3 (fork e91187f8), about 40 logos-blockchain-* crates, netlink-sys and quinn. The only path to them was logos-blockchain-common-http-client, pulled in by `common`. After patch 01 (or 01b) the graph has 430 crates, 44 of them native or with a build script: 250 removed, 0 added. The only crate with a logos-blockchain URL left is keccak v0.2.0 from github.com/logos-blockchain/sponges, a pure-Rust [patch.crates-io] fork, not Bedrock. The aarch64 graph is the same except for curve25519-dalek-derive, which only the x86_64 graph has. Native or linking crates left: pcsc-sys 1.3.0 (links=pcsc; its build.rs reads PCSC_LIB_DIR/PCSC_LIB_NAME, otherwise uses pkg-config for libpcsclite), ring 0.17.14 (builds C/asm with cc), jni-sys 0.3.1/0.4.1 (declarations only, no link; pulled in by jni <- rustls-platform-verifier <- jsonrpsee), dirs-sys and linux-raw-sys (pure Rust). The build scripts of risc0-circuit-keccak, risc0-circuit-recursion and risc0-zkp compile no native code. risc0-circuit-recursion's build.rs downloads recursion_zkr.zip only under its `prove` feature, and that feature is not enabled in the no-prove graph (checked with cargo tree -e features). No build script in the patched no-prove graph downloads anything. For reference, the default `prove` graph adds about 85 crates: risc0-sys, risc0-circuit-{keccak,recursion,rv32im}-sys, risc0-build-kernel, downloader, reqwest, liblzma-sys and others.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/out/tree-before.txt; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/out/tree-after.txt; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/out/tree-diff.txt; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/out/native-before.txt; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/out/native-after.txt; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/out/tree-after-aarch64.txt; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/logs/x3-before.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/logs/x3-after.log; /nix/store/50mgx3611i7hj9rch5m1aw2y1ipy2lk5-cargo-package-risc0-circuit-recursion-4.0.4/build.rs:15-18
- [partial|verified-by-experiment] X3 side effect: does the minimal patch 01 break other workspace crates?
  Yes. sequencer_core (block_publisher.rs:304,823,883; gossip/accreditation/mod.rs:38; cross_zone_watcher.rs:222) and indexer_core (lib.rs:112; cross_zone_verifier.rs:693) call `auth.clone().map(Into::into)`, which needs the removed From impl. So I made patch 01b instead: `logos-blockchain-common-http-client` becomes optional in common behind feature `bedrock-auth` (the use and the impl are cfg-gated), and sequencer_core and indexer_core enable it. With 01b, wallet-ffi's Android graph is identical to the one with 01 (diff exit 0). The Android .so is byte-identical to the 01+02 build (cmp). Host `cargo check -p sequencer_core -p indexer_core` passes in 149 s. The working copy is left at 01b + 02.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/logs/p01b.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/out/host-check.txt; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/patches/01b-common-bedrock-auth-feature.diff
- [pass|verified-by-experiment] X4: Does `cargo build -p wallet-ffi --release --no-default-features --target x86_64-linux-android` (NDK r27c, API 34, 16 KB pages, pcsc stub) succeed? Size, NEEDED, exports, recursion zip, p_align
  It succeeded on the first try. The only patch needed was 01; the workspace lint `warnings = deny` was not triggered. Build time: 74 s wall for 428 units with a cold target dir (sources already downloaded by cargo tree, 16 cores). Output: libwallet_ffi.so is 18,146,144 B raw and 14,999,376 B after llvm-strip. It is an ELF64 x86-64 'for Android 34, built by NDK r27c'. NEEDED: libpcsclite.so, libdl.so, libm.so, libc.so, with BIND_NOW. It exports 58 wallet_ffi_* functions (T), the same number as the desktop 825d2a4 .so. All 4 LOAD segments have p_align 0x4000 (16 KB). .rodata is 5,163,844 B, against 72,365,900 B on the desktop .so. Zip local-file headers: 0 (desktop has 34). 'zkr' strings: 0. recursion_zkr: 0. 'recursion' strings: 26, which are risc0-circuit-recursion verifier code and paths, not the zip. So the 60 MB recursion zip is gone. Undefined SCard*/g_rgSCard* symbols are resolved by the stub. The 16 prebuilt guest ELFs in artifacts/ (about 6.5 MB of .bin in total) are still embedded, as on desktop. There are no GMP symbols.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/logs/x4-x86_64.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/out/x86_64-linux-android/libwallet_ffi.so; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/out/x86_64-linux-android/libwallet_ffi.stripped.so; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/out/x86_64-linux-android/exports.txt; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/out/x86_64-linux-android/wallet_ffi.h; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/logs/final.log
- [pass|verified-by-experiment] X4: The same build for aarch64-linux-android
  Build time: 50 s (353 units; host build scripts and proc-macros reused). libwallet_ffi.so is 18,167,464 B raw and 13,789,328 B stripped. NEEDED: libpcsclite.so, libdl.so, libm.so, libc.so. 58 wallet_ffi_* exports. LOAD p_align 0x4000 on all 4 segments. .rodata 5,096,696 B. zip headers 0, zkr 0. Not run on a device: the arm64 AVD does not boot on this host.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/logs/x4-aarch64.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/out/aarch64-linux-android/libwallet_ffi.stripped.so
- [pass|verified-by-experiment] X4 variant: pcsc stub linked statically plus the webpki-roots feature (the recommended Android artifact)
  PCSC_LIB_DIR=<dir with libpcsclite.a> PCSC_LIB_NAME=static=pcsclite. pcsc-sys build.rs prints `cargo:rustc-link-lib=<PCSC_LIB_NAME>` but has no rerun-if-env-changed, so `cargo clean -p pcsc-sys --release --target T` is needed when switching. With `--no-default-features --features webpki-roots`, NEEDED is only libdl.so, libm.so and libc.so (no libpcsclite.so), with no dynamic SCard* symbols. x86_64: 18,340,976 raw, 15,169,576 stripped, 5,766,612 gzip -9. aarch64: 18,371,576 raw, 13,945,544 stripped, 5,499,977 gzip -9. 58 exports, p_align 0x4000. Incremental rebuild takes 13-14 s. webpki-roots adds about 170 KB. The feature adds exactly one crate to the graph (webpki-roots 1.0.7, already in Cargo.lock) and no aws-lc crates. rustls features: ring, std, tls12, logging.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/logs/x5-webpki.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/out/x86_64-linux-android-webpki/libwallet_ffi.stripped.so; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/out/aarch64-linux-android-webpki/libwallet_ffi.stripped.so; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/out/tree-webpki.txt
- [pass|verified-from-source] TLS: How is the sequencer HTTP client built at d8596eb7, and what is the smallest change that makes HTTPS work without a JavaVM?
  All sequencer clients are built in one function, lez/wallet/src/multi_client.rs:459-478 make_subclient(). It calls `SequencerClientBuilder::default()` (a re-export of jsonrpsee::http_client::HttpClientBuilder; sequencer_service_rpc/src/lib.rs:6,33), optionally set_headers for basic auth, then `.build(url)`. jsonrpsee-http-client 0.26.0 has default feature `tls` = hyper-rustls + rustls + rustls-platform-verifier. For https with the default CertificateStore::Native it calls `rustls::ClientConfig::with_platform_verifier()` (transport.rs:255-264). On Android that verifier calls with_context() -> global() on every certificate check, which panics with 'Expect rustls-platform-verifier to be initialized' (rustls-platform-verifier 0.5.3 src/android.rs:84-87) unless init_with_env/init_with_refs was given a JavaVM and Context. Client construction itself does not panic; the TLS handshake does. The builder already has `with_custom_cert_store(rustls::ClientConfig)` (client.rs:188-192), which uses CertificateStore::Custom and skips the platform verifier entirely. Smallest change, implemented as patch 02 and compiled for both arches: an opt-in feature `webpki-roots` on wallet (optional deps rustls 0.23 with default-features=false and features [ring, std, tls12], plus webpki-roots 1), forwarded by wallet-ffi. make_subclient() then calls `builder.with_custom_cert_store(webpki_tls_config())`, where webpki_tls_config() is `ClientConfig::builder_with_provider(Arc::new(ring::default_provider())).with_safe_default_protocol_versions()?.with_root_certificates(RootCertStore{roots: webpki_roots::TLS_SERVER_ROOTS.to_vec()}).with_no_client_auth()`. The change is 20 lines of Rust and 5 of TOML. An alternative is to gate on cfg(target_os = "android") instead of a feature. The trade-off: the bundled Mozilla root set does not follow the device trust store or user-installed CAs.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/lez/lez/wallet/src/multi_client.rs; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/lez/lez/sequencer/service/rpc/src/lib.rs; /nix/store/vx2xv2jwb38a1knzrca2n5yqxmrkp91h-cargo-package-jsonrpsee-http-client-0.26.0/src/transport.rs:240-274; /nix/store/vx2xv2jwb38a1knzrca2n5yqxmrkp91h-cargo-package-jsonrpsee-http-client-0.26.0/src/client.rs:188-192; /nix/store/a43h4q08b8vjj4x0m27bidn6p9y5a43w-cargo-package-rustls-platform-verifier-0.5.3/src/android.rs:84-87; /nix/store/a43h4q08b8vjj4x0m27bidn6p9y5a43w-cargo-package-rustls-platform-verifier-0.5.3/src/verification/android.rs:95-115; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/patches/02-wallet-webpki-roots-feature.diff
- [pass|verified-by-experiment] Extra runtime check: does the Android .so load and work in a process with no JavaVM (like a logos_host_qt child), with and without patch 02?
  The test is a C program (smoke/wallet_smoke.c) built with NDK clang for x86_64 API 34, run from adb shell in /data/local/tmp with LD_LIBRARY_PATH. It is a plain executable, so there is no JavaVM. Variant A (no-prove, default TLS, stub as a separate libpcsclite.so): the .so loads, and account_id_to_base58 works offline ('7Z8ftDAzMvoyXnGEJye8DurzgQQXLAbYCaeeesM7UKHa'). create_new then fails after 1503 ms: a tokio worker panics at rustls-platform-verifier-0.5.3/src/android.rs:87 'Expect rustls-platform-verifier to be initialized', and the wallet reports 'Failed to create wallet: Failed to find leader', returning handle NULL. The panic is inside a spawned calibration task, so it becomes an error and the process does not abort. Variant B (no-prove, webpki-roots, static stub): create_new succeeds in 1174 ms (calibration_limit 1, 24-word mnemonic), create_account_public returns err=0, get_sequencer_addr returns https://testnet.lez.logos.co/, and get_current_block_height returns height 24050 in 656 ms (err=0). EXIT=0. This confirms end to end that HTTPS without a JVM needs patch 02, and that the static pcsc stub works.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/logs/smoke.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/smoke/wallet_smoke.c; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/logs/emu-start.log
- [partial|inferred] What does dropping `prove` cost at runtime?
  Without `prove`, risc0-zkvm is built with only client+std. Two calls are affected. lee Program::execute_session uses default_executor() (lee/state_machine/src/program/mod.rs:120-121), and wallet private transactions (send_privacy_preserving_tx_with_pre_check -> circuit::execute_and_prove_with_padded_inputs -> default_prover(), lee/.../circuit/mod.rs:336-339,375-377) use default_prover(). Without `prove`, both fall back to ExternalProver('ipc', r0vm), which spawns an `r0vm` binary (or uses Bonsai via BONSAI_API_URL/KEY, but only if risc0's bonsai feature is on). No r0vm exists on Android, so shielded, deshielded and private transfers, plus any local guest execution, will fail at runtime. Public paths are fine: public account creation, the block-height read, and presumably transfer_public, which only signs and sends; transfer_public was not executed. Whether the failure is a clean error or a panic (get_r0vm_path().unwrap()) was not tested.
  evidence: /nix/store/wzlbxfrsppp2mn84isgk0flrns1zdi4c-cargo-package-risc0-zkvm-3.0.5/src/host/client/prove/mod.rs:183-247,255-281; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/lez/lez/wallet/src/lib.rs:788-814

### Patches
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/patches/01-common-drop-bedrock-http-client.diff -- Rationale: the minimal form asked for in X3. Removes logos-blockchain-common-http-client and the From<BasicAuth> for BasicAuthCredentials impl (lez/common/Cargo.toml, lez/common/src/config.rs, plus a one-line Cargo.lock change). This alone makes wallet-ffi build for Android, but it BREAKS sequencer_core and indexer_core. It is superseded by 01b.
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/patches/01b-common-bedrock-auth-feature.diff -- Rationale: non-breaking version of 01. The dependency becomes optional behind common feature `bedrock-auth` (the use and the impl are cfg-gated), and only lez/sequencer/core and lez/indexer/core enable it. wallet-ffi's graph and .so are identical to the 01 build, and host cargo check of sequencer_core and indexer_core passes.
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/patches/02-wallet-webpki-roots-feature.diff -- Rationale: opt-in `webpki-roots` feature (wallet and wallet-ffi). make_subclient() uses jsonrpsee with_custom_cert_store with a rustls ring ClientConfig and webpki_roots::TLS_SERVER_ROOTS, so HTTPS works without a JavaVM. Verified on the emulator.
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/patches/all-combined.diff -- the full working-copy diff on top of d8596eb7: 01b + 02 + Cargo.lock.
- Not a LEZ patch: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/pcsc-stub/pcsclite_stub.c. It exports the 16 SCard* functions and 3 g_rgSCard*Pci statics that pcsc-sys 1.3.0 imports (src/lib.rs:316-409). Every function returns SCARD_E_NO_SERVICE (0x8010001D). Built with NDK clang as libpcsclite.so (-shared, soname libpcsclite.so) or as libpcsclite.a for static linking.

### Artifacts
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/out/x86_64-linux-android-webpki/libwallet_ffi.stripped.so (recommended x86_64: no-prove, webpki-roots, static pcsc stub; 15,169,576 B)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/out/aarch64-linux-android-webpki/libwallet_ffi.stripped.so (recommended arm64; 13,945,544 B)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/out/x86_64-linux-android/libwallet_ffi.stripped.so (no-prove, default TLS, NEEDED libpcsclite.so)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/out/aarch64-linux-android/libwallet_ffi.stripped.so
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/out/x86_64-linux-android-webpki/wallet_ffi.h (cbindgen header)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/pcsc-stub/ (pcsclite_stub.c, <target>/libpcsclite.so, <target>-static/libpcsclite.a)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/smoke/ (wallet_smoke.c and the A/B device payloads)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/out/tree-before.txt, tree-after.txt, tree-diff.txt, native-before.txt, native-after.txt, tree-webpki.txt, tree-before-prove.txt, tree-after-prove.txt, tree-after-aarch64.txt
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/logs/ (setup, x3-before, x3-after, x4-x86_64, x4-aarch64, x5-webpki, emu-start, emulator.out, smoke, final, p01b, patches)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/lez (working copy at d8596eb7 with 01b + 02 applied)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/wallet-android/target (cargo target dir)
- Scripts: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/wallet-android-{setup,x3-before,x3-after,x4-common,x4-x86_64,x4-aarch64,x5-webpki,emu-start,smoke,final,p01b,watch-p01b,patches}.sh plus wallet-android-nativecrates.py

### Repro
Every step is a script under /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/, run as `bash <path>`, in this order:
1. wallet-android-setup.sh: `git clone --shared` of ~/src/logos-blockchain/logos-execution-zone, fetch d8596eb734bf9c9ce801afb92df06098a2eb098a from GitHub, check it out.
2. wallet-android-x3-before.sh: `rustup target add --toolchain 1.94.0 x86_64-linux-android aarch64-linux-android`, then `cargo tree --locked -p wallet-ffi --no-default-features --target x86_64-linux-android -e normal,build --prefix none`.
3. Apply patch 01b (or 01).
4. wallet-android-x3-after.sh: the same tree with --offline, plus inverse and feature trees.
5. wallet-android-x4-x86_64.sh and wallet-android-x4-aarch64.sh. The environment they set, per target T at API 34: CC_<t>/CXX_<t>=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/<T>34-clang(++); AR_<t>/RANLIB_<t>=llvm-ar/llvm-ranlib; CARGO_TARGET_<T>_LINKER=<T>34-clang; CARGO_TARGET_<T>_AR=llvm-ar; RUSTFLAGS='-C link-arg=-Wl,-z,max-page-size=16384'; CARGO_TARGET_DIR=.work/experiments/wallet-android/target. They build the stub with `<T>34-clang -shared -fPIC -O2 -fvisibility=hidden -Wl,-soname,libpcsclite.so -Wl,-z,max-page-size=16384 -o pcsc-stub/<T>/libpcsclite.so pcsc-stub/pcsclite_stub.c` and set PCSC_LIB_DIR=pcsc-stub/<T>, PCSC_LIB_NAME=pcsclite. Then `cargo build -p wallet-ffi --release --no-default-features --target <T>`.
6. Apply patch 02, then wallet-android-x5-webpki.sh: builds the static stub with `clang -c` and `llvm-ar rcs libpcsclite.a`, sets PCSC_LIB_NAME=static=pcsclite, runs `cargo clean -p pcsc-sys --release --target T`, then `cargo build -p wallet-ffi --release --no-default-features --features webpki-roots --target T`.
7. wallet-android-emu-start.sh: `emulator -avd delivery-demo -no-audio -no-boot-anim -no-snapshot-save`, WINDOWED. The -no-window/headless binary segfaulted twice on this host.
8. wallet-android-smoke.sh: builds smoke/wallet_smoke.c with x86_64-linux-android34-clang, pushes variants A and B to /data/local/tmp/wsmoke, runs `LD_LIBRARY_PATH=. ./wallet_smoke <dir> https://testnet.lez.logos.co/`.
9. wallet-android-final.sh: comparisons, then `adb emu kill`.
10. wallet-android-p01b.sh: verifies 01b and runs host `cargo check -p sequencer_core -p indexer_core`.

### Next steps
- Use the webpki + static-stub variant (out/<target>-webpki/libwallet_ffi.so) as lez_core's native lib in the Android packaging experiment. It only needs libc, libm and libdl, so it can go in nativeLibraryDir next to the lez_core Qt plugin.
- Upstream to logos-execution-zone: 01b (common `bedrock-auth` feature) and 02 (wallet/wallet-ffi `webpki-roots` feature). Both are small and additive. Optionally make webpki the default under cfg(target_os = "android").
- Decide on private transactions. Without `prove`, default_prover and default_executor fall back to an r0vm subprocess, which does not exist on Android, so shielded, deshielded and private transfers will fail. Options: public-only demo, Bonsai or remote proving, or an Android `prove` build. That build would need risc0-sys and circuit-*-sys C++ compiled with the NDK, plus the 60 MB zkr. Untested.
- Test a public write path on Android (transfer_public or send_generic_public_transaction) against testnet or a local plain-http sequencer (X5). Only read calls were run here.
- Check the lez_core Qt plugin (logos-execution-zone-module 825d2a4) against the wallet_ffi.h built here, which is the same rev d8596eb7. The ABI should match the desktop 0.4.2 build: 58 exports in both.
- Upstream bug to report (seen in source, not tested): multi_client.rs:465-470 sends `Authorization: Basic user:password` without base64, so basic_auth to a sequencer is probably broken on every platform.
- Emulator on this host: only the windowed binary boots. -no-window (qemu-system-x86_64-headless) SIGSEGVs at cold boot. Two coredumps from that (PIDs 3380720 and 3389763, about 340 MB) are in systemd-coredump.
- arm64 runtime check still open: needs a physical arm64 device, since the arm64 AVD does not boot here.

---

## Full report

## wallet-android: building lez_core's wallet-ffi for Android

**Result:** it builds for x86_64 and arm64, and the x86_64 build works on the emulator. HTTPS without a JavaVM needs patch 02 (webpki-roots). Details below.

### 1. LEZ rev (verified-from-source)
- **Locked rev:** logos-execution-zone-module 825d2a4 locks logos-execution-zone **d8596eb734bf9c9ce801afb92df06098a2eb098a**, ref `v0.2.5-rc2`, 2026-09-09, "Merge PR #837 erhant/handle-nonzero-exit".
  - Source: `.work/probe/logs/meta-...825d2a4....json`.
  - The local ~/src checkout does not have this commit, so it was fetched from GitHub.
- **Reference:** lez-programs pins lez_core acf0cd50, which locks LEZ **9edf4a622fe966199beed71685c6f0b855db0784**, branch `erhant/0.2.4-with-r0-fix` (v0.2.4 plus an r0 fetch fix).
- **Toolchain:** `rust-toolchain.toml` is 1.94.0. I added the android targets to it.

### 2. X3: dependency graph (verified-by-experiment)

Command: `cargo tree -p wallet-ffi --no-default-features --target x86_64-linux-android -e normal,build --prefix none`

| | crates | build.rs / links / -sys |
|---|---|---|
| before | 680 | 63 |
| after patch 01 or 01b | 430 | 44 (250 removed, 0 added) |

**Confirmed: no lbc / logos-blockchain-circuits* / rust-rapidsnark / gmp crates remain.**
- The only leftover with a logos-blockchain URL is `keccak` from logos-blockchain/sponges. It is a pure-Rust `[patch.crates-io]` fork, not Bedrock.
- The before graph had circuits-{poc,pol,poq,signature}-sys, circuits-build, rust-rapidsnark, about 40 logos-blockchain-* crates, netlink-sys and quinn. All of them came through the single edge `common -> logos-blockchain-common-http-client`.

Native crates left after the patch:
- `pcsc-sys` 1.3.0 (links=pcsc). Satisfied by the stub through PCSC_LIB_DIR/PCSC_LIB_NAME.
- `ring` 0.17.14. Builds C/asm with cc and NDK clang without trouble.
- `jni-sys` 0.3.1/0.4.1. Declarations only, pulled in by jni <- rustls-platform-verifier <- jsonrpsee.
- `dirs-sys` and `linux-raw-sys`. Pure Rust.

Build scripts:
- No build script in the no-prove graph downloads anything.
- `risc0-circuit-recursion`'s build.rs downloads `recursion_zkr.zip` only under its own `prove` feature, and that feature is off here (checked with `-e features`).
- The default `prove` graph adds about 85 crates: risc0-sys, risc0-circuit-*-sys, risc0-build-kernel, downloader, reqwest, liblzma-sys and others.

**Patch 01 breaks other crates.** The minimal patch as specified breaks `sequencer_core` and `indexer_core`, which call `auth.clone().map(Into::into)` and need the removed From impl. **Patch 01b** fixes this: an optional dependency behind a `common/bedrock-auth` feature, enabled only by those two crates.
- wallet-ffi's graph under 01b is identical to the 01 graph.
- The Android .so is byte-identical to the 01 build.
- Host `cargo check -p sequencer_core -p indexer_core` passes (149 s).

### 3. X4: build (verified-by-experiment)

Build setup:
- NDK r27c `<T>34-clang` set as CC/CXX/linker, with llvm-ar.
- `RUSTFLAGS=-C link-arg=-Wl,-z,max-page-size=16384`.
- A stub libpcsclite: 16 `SCard*` functions plus 3 `g_rgSCard*Pci` statics, each function returning `SCARD_E_NO_SERVICE`.
- **It succeeded on the first try. The only source patch needed was 01.**

| artifact | raw | stripped | gz -9 | NEEDED | build time |
|---|---|---|---|---|---|
| x86_64, no-prove, dynamic stub | 18,146,144 | 14,999,376 | - | libpcsclite.so, libdl, libm, libc | 74 s cold (428 units) |
| arm64, no-prove, dynamic stub | 18,167,464 | 13,789,328 | - | same | 50 s (353 units) |
| x86_64, no-prove + webpki + static stub | 18,340,976 | 15,169,576 | 5,766,612 | libdl, libm, libc | 13-21 s incremental |
| arm64, no-prove + webpki + static stub | 18,371,576 | 13,945,544 | 5,499,977 | libdl, libm, libc | 14 s |
| desktop 825d2a4 (prove) | 108,567,024 | about 104 MB | about 68 MB | libpcsclite.so.1, libstdc++, libgcc_s, libm, libc, ld-linux | - |

Other measurements on the Android builds:
- **Exports:** 58 `wallet_ffi_*` functions, the same as desktop.
- **Alignment:** every LOAD segment has **p_align 0x4000** (16 KB).
- **.rodata:** 5.16 MB on x86_64 and 5.10 MB on arm64, against **72.4 MB** on desktop.
- **Recursion zip:** zip local-file headers are 0 (desktop has 34), and `zkr` / `recursion_zkr` strings are 0. **The 60 MB recursion zip is gone.** The 26 `recursion` strings that remain are verifier code, not the zip.
- **Still embedded, as on desktop:** the 16 prebuilt guest ELFs, about 6.5 MB.

**Static stub.** Setting `PCSC_LIB_NAME=static=pcsclite` links the stub into the .so, which removes `libpcsclite.so` from NEEDED. pcsc-sys's build.rs has no rerun-if-env-changed, so run `cargo clean -p pcsc-sys` when switching between the two forms.

### 4. TLS (source read, then tested on the emulator)

**How the client is built:**
- `lez/wallet/src/multi_client.rs:459-478 make_subclient()` is the single place where sequencer clients are built.
- It calls `SequencerClientBuilder::default()`, which is jsonrpsee 0.26 `HttpClientBuilder`, with the default `tls` feature.
- For https, the builder uses `ClientConfig::with_platform_verifier()` (jsonrpsee-http-client transport.rs:255-264).
- On Android, the rustls-platform-verifier 0.5.3 verifier calls `global()` on every certificate check. That panics with *"Expect rustls-platform-verifier to be initialized"* unless the verifier was initialised with a JavaVM and Context (android.rs:84-87).

**Smallest fix (patch 02, implemented).** An opt-in feature `webpki-roots` on wallet and wallet-ffi:
- `builder.with_custom_cert_store(...)` is given a rustls `ClientConfig` built with the `ring` provider and `webpki_roots::TLS_SERVER_ROOTS`.
- Size of the change: 20 lines of Rust and 5 of TOML.
- New dependencies: `rustls 0.23` with default-features off (ring, std, tls12) and `webpki-roots 1`. Only webpki-roots 1.0.7 is new to the graph; there are no aws-lc crates.

**Emulator test** (x86_64 API 34, plain executable, no JavaVM):

| variant | create_new | create_account_public | get_current_block_height |
|---|---|---|---|
| A: default TLS | fails after 1.5 s: panic at `rustls-platform-verifier-0.5.3/src/android.rs:87`, then "Failed to find leader", handle NULL | not reached | not reached |
| B: webpki-roots | OK, 1.17 s | OK | **24050** in 656 ms over HTTPS to testnet.lez.logos.co |

- In variant A the panic happens inside a spawned tokio calibration task, so it becomes an error and the process does not abort.
- The offline `account_id_to_base58` call worked in both variants.

### 5. Caveats and open items
- **No `prove` means no private transactions.** risc0 `default_prover` and `default_executor` fall back to an `r0vm` IPC subprocess (risc0-zkvm 3.0.5, prove/mod.rs:183-247), and there is no r0vm on Android. Shielded, deshielded and private transfers will fail (inferred from source). Public paths work; only reads were exercised.
- **Emulator:** the `-no-window` (headless qemu) binary SIGSEGVs at cold boot on this host. The windowed binary booted in 25 s. It was stopped afterwards with `adb emu kill`.
- **arm64:** built but not run. The arm64 AVD does not boot here.
- **Upstream bug (source reading only):** `multi_client.rs:465-470` sends `Authorization: Basic user:password` without base64 encoding.

### Paths
- **Patches:** `.work/experiments/wallet-android/patches/` contains 01, 01b, 02 and all-combined. Each file starts with a one-line rationale.
- **Artifacts:**
  - `.work/experiments/wallet-android/out/<target>[-webpki]/`
  - `.work/experiments/wallet-android/pcsc-stub/`
  - `.work/experiments/wallet-android/smoke/`
- **Logs:** `.work/experiments/wallet-android/logs/`
- **Scripts:** `.work/scripts/wallet-android-*.sh`

