# Existing mobile support in the Logos ecosystem

> Research track `mobile-search`, 2026-09-25. Written by a research agent and then checked by a
> second, adversarial agent, whose non-confirmed verdicts are listed under "Verifier".
> Claims are tagged verified-from-source / verified-by-experiment / inferred / open.
> Absolute paths point at the author's local checkouts (`~/src/logos-co`,
> `~/src/logos-blockchain`) at the revisions in [../investigation.md](../investigation.md);
> `.work/` paths are local scratch, not committed. The synthesis is in
> [../investigation.md](../investigation.md).


### Summary
No Logos repo builds liblogos_core, a Logos Core module (.lgx) or LEZ for Android today, and none has a working iOS build. The one real piece of Android build support for Logos Core is in logos-nix: an opt-in aarch64-android package set with Qt 6.11.1 cross-built from source and a mkQtAndroidApk APK packager, added 2026-09-07. Its limits: arm64-v8a only; CI evaluates it but never builds it; the Logos public cache does not hold it; nothing uses it; and QtRemoteObjects is not set up for it (no build-machine repc tools), even though LogosAPI needs QtRO. For iOS there is also a logos-nix Qt set (aarch64-darwin with Xcode 26.6, static only) and an old basecamp qt-ios demo from Nov–Dec 2025. That demo calls liblogos functions that no longer exist and does not build as written. On the LEZ side: lez_core wraps the Rust wallet_ffi library. wallet_ffi pulls in Logos Blockchain crates (lb-core, then lb-pol, then lbc-pol-sys). Those need the circuits' native libraries, which are published only for linux x86_64/aarch64, macos aarch64 and windows x86_64. The rapidsnark crate itself does map Android targets to iden3's prebuilt Android archives. The keycard wallet also needs pcsc, and it is not optional. There are no Kotlin, Swift, Gradle, UniFFI or JNI files in any Logos repo. The only real mobile precedent is logos-delivery (messaging): Makefile and nimble targets build liblogosdelivery.so for 4 Android ABIs plus librln via cross/Docker, and upstream CI builds arm64 only (amd64 is blocked). The sibling logos-android-wrap-poc wraps it through a hand-written JNI shim. Mobile Logos Core is on roadmaps: LogosCore Testnet v0.3 lists "Mobile iOS/Android support", messaging milestone pm#428 (dated 2026-02-21) includes "Logos Core on mobile", and the user's RFP appendix says testnet 0.4 with the architecture not yet defined. Logos Blockchain and LEZ have no mobile strategy.

### Claims
- [C1|critical|verified-by-experiment] logos-nix (upstream master 7c1eb8bc, equal to the local HEAD) has an opt-in `aarch64-android` target. It provides Qt 6.11.1 (qtbase, qtdeclarative, qtshadertools, qtsvg) cross-built from the nixpkgs-windows pin for arm64-v8a, plus `pkgsAndroid`, `androidPkgs` (composed SDK/NDK 27.0.12077973), `logosQtHost`, `logosQtCrossCmakeFlags`/`logosQtCrossToolchainFile` and `mkQtAndroidApk`. It was added in commit 5378de5 on 2026-09-07.
- [C2|high|verified-by-experiment] The logos-nix Android Qt has never been built in CI and is not in the Logos public cache (or the local store). CI runs only `nix flake check --no-build`, and the android-apk check is excluded from that. Using it means building Qt for Android from source (the README measured 5m28s on 32 cores with dependencies already present, a 4.6 GiB closure of which 4.2 GiB is the SDK+NDK).
- [C3|critical|verified-by-experiment] QtRemoteObjects is not set up in the logos-nix Android set. The Windows overlay adds `-DQt6RemoteObjectsTools_DIR` and lists qtremoteobjects among the build-machine packages. The Android overlay does neither: its QT_ADDITIONAL_HOST_PACKAGES_PREFIX_PATH lists only qtbase/qtdeclarative/qtshadertools/qtsvg. Evaluating pkgsAndroid.qt6.qtremoteobjects.cmakeFlags shows no repc/host-tools flag. The same file's Windows comments say that without those flags `find_package(Qt6 COMPONENTS RemoteObjects)` fails.
- [C4|high|verified-from-source] No Logos repo uses the logos-nix mobile targets yet. The only hits for forAllMobileTargets, mobileTargets, pkgsAndroid, aarch64-android, pkgsIos, mkQtAndroidApk and mkIosCmakeStage are inside logos-nix itself.
- [C5|critical|verified-by-experiment] logos-liblogos has no Android or iOS build support. Its flake targets aarch64/x86_64-darwin, aarch64/x86_64-linux and an x86_64-windows pseudo-system; there are no Q_OS_ANDROID/Q_OS_IOS branches. The latest upstream HEAD db45024f (about 2026-09-22) is the same.
- [C6|high|verified-from-source] liblogos only ships a subprocess container. An in-process loader, which the user's appendix calls mobile 'Local mode', is possible only as a C++ extension point that nobody has implemented. ModuleManager::loaders() lets a frontend register custom loaders/containers ('Docker, WASM, in-process') before logos_core_start(). logos-container-subprocess says any other isolation mechanism means writing a sibling repo. Only logos-container and logos-container-subprocess exist locally.
- [C7|high|verified-from-source] The basecamp iOS demo (logos-basecamp/qt-ios, written 2025-11-28 to 2025-12-10) is stale and would not build or run against current liblogos. It calls logos_core_set_mode, logos_core_register_plugin_by_name, logos_core_process_events and logos_core_async_operation, none of which exist in the current logos_core.h. It expects LOGOS_PACKAGE_MANAGER_SRC while the flake exports LOGOS_PACKAGE_MANAGER_MODULE_SRC. It uses Qt 6.8.2 from ~/Qt6 (not Nix) and is not built in CI. It is still the only precedent for statically linking modules (Q_IMPORT_PLUGIN) into a mobile Logos app.
- [C8|medium|verified-from-source] logos-module has LogosModule::getStaticModules() (it wraps QPluginLoader::staticInstances()), but nothing in liblogos, the module loaders or the containers calls it. There is no static-plugin registration path in current liblogos, which is what iOS would need.
- [C9|medium|verified-from-source] The module toolchain cannot produce mobile modules. LogosModule.cmake builds plugins only as SHARED libraries. logos-module-builder's platform table lists only linux, darwin and windows triples, and its latest upstream HEAD 4b799827 (about 2026-09-23) has no Android references. logos-package-manager-module/scripts/build-ios.sh is stale: the module's CMakeLists hits FATAL_ERROR without LOGOS_MODULE_BUILDER_ROOT, which the script never sets.
- [C10|critical|verified-by-experiment] LEZ has no Android build. The logos-execution-zone flake targets x86_64-linux, aarch64-linux, aarch64-darwin and x86_64-windows. wallet-ffi is a cbindgen C ABI built as rlib/cdylib/staticlib with default feature `prove` (which turns on risc0-zkvm/prove). The lez_core module (logos-execution-zone-module) is a Qt plugin that wraps that wallet_ffi through logos-module-builder externalLibInputs. The latest LEZ upstream (3454abed, about 2026-09-25) has no Android references either.
- [C11|critical|verified-from-source] LEZ wallet_ffi, and so lez_core, depends on Logos Blockchain circuit artefacts that exist only for desktop platforms. The chain is lez/common, then logos-blockchain-common-http-client, then lb-core, then lb-pol/lb-poc, then lbc-pol-sys with the `prebuilt` feature. lbc-build downloads `logos-blockchain-circuits-v{ver}-{os}-{arch}.tar.gz` unless LBC_ROOT_DIR is set. Those bundles contain native static witness generators and libgmp, and the release matrix is linux x86_64/aarch64, macos aarch64 and windows x86_64 only. An Android build would therefore fail at download unless the circuits are cross-built for Android.
- [C12|high|verified-by-experiment] The rapidsnark crate pinned by LEZ and logos-blockchain (logos-blockchain-rust-rapidsnark rev e91187f8, 'feat/nixify') handles Android. Its download script maps aarch64-linux-android and x86_64-linux-android to upstream iden3 prebuilt archives, and its build.rs links static rapidsnark/fr/fq/gmp and uses libc instead of pthread on Android. Its Nix flake, however, only provides linux and darwin archives. The local repo checkout is the zkmopro upstream (last commit 2025-08-19), whose CI builds Android through cargo-ndk.
- [C13|medium|inferred] There are more Android obstacles inside the LEZ wallet. The wallet crate depends on keycard_wallet, which depends on keycard-rs and pcsc with no optional gating, and the Nix build adds pcsclite as a buildInput. Android has no system PC/SC library, so this dependency would need to be feature-gated or ported. The pcsc part is inferred.
- [C14|high|verified-from-source] Logos Blockchain has no mobile build and no mobile or light-client code. Its flake lists only desktop systems; c-bindings produce a cdylib, liblogos_blockchain. A grep for light node/light client/mobile finds nothing in logos-blockchain, logos-blockchain-module or logos-execution-zone-wallet-ui. Roadmap mentions of 'light nodes' are whitepaper and tutorial items from 2023–2025. The user's RFP appendix says no protocol has defined a mobile strategy.
- [C15|high|verified-by-experiment] No Logos repo contains mobile binding code. A search for *.kt, *.kts, *.swift, *.udl, uniffi.toml, AndroidManifest.xml, *.gradle, Package.swift, *.podspec, Info.plist, *.xcodeproj and pubspec.yaml found nothing, and no Cargo.toml depends on uniffi, jni, swift-bridge or flutter_rust_bridge.
- [C16|high|verified-from-source] The upstream logos-delivery precedent (at 05600659, 2026-09-18, the sibling repo's submodule) does build for Android. Makefile targets liblogosdelivery-android-{arm64,amd64,x86,arm} need ANDROID_NDK_HOME (ANDROID_TARGET defaults to 30) and call the nimble task libLogosDeliveryAndroid, which runs `nim c --app:lib --os:android -d:androidNDK` to produce build/android/<abi>/liblogosdelivery.so linked with -lrln -llog. librln (zerokit v2.0.2) is cross-compiled with `cross rustc --crate-type=cdylib` in Docker. iOS targets also exist. Upstream CI builds android arm64 only: amd64 is blocked by a nim-lsquic Android type mismatch and 32-bit ABIs by integer overflows.
- [C17|medium|verified-from-source] The sibling logos-android-wrap-poc works without liblogos_core. It uses upstream logos-delivery's Android targets plus a hand-written JNI shim (delivery_jni.c) and Kotlin AARs. Its README reports arm64-v8a and x86_64 working (x86_64 with a scripted Leopard-RS patch), an 85.7 MB universal APK that is ~76% liblogosdelivery.so, and storage coming from a fryorcraken fork adding `make libstorage-android`, which is not upstream.
- [C18|high|verified-from-source] Mobile support is planned but has no delivered Logos Core work. LogosCore roadmap Testnet v0.3 lists 'Mobile iOS support' and 'Mobile Android support'. The combined Gantt marks 'Mobile App for iOS and Android' active from 2025-06-01 to 2026-06-30, an end date already past. Messaging milestone 'Support Mobile Platforms' (logos-messaging/pm#428, dated 2026-02-21) has deliverables pm#457, #458 and #459, including 'Verify Chat and Delivery modules on Logos Core mobile' and 'Logos Core team for mobile runtime support'. The user's RFP appendix (last edited 2026-09-21) says mobile Basecamp is 'planned for testnet 0.4. Architecture is not defined'. This conflicts with the roadmap's v0.3.
- [C19|medium|verified-from-source] The logos-nix iOS target (b8f10e8, 2026-09-07) builds static Qt 6.11.1 for the iOS simulator and devices. It can only be built on aarch64-darwin with Xcode 26.6 (17F113), and its derivations are __noChroot. mkIosCmakeStage fails the build if any dynamic image is produced. So iOS needs statically linked modules, which current liblogos cannot register (see C8).
- [C20|medium|verified-from-source] The Android Qt from logos-nix has known limits. It is arm64-v8a only (adding an ABI means a new pseudo-system). The API floor is 28, with compileSdk 36 and build-tools 36.0.0. It uses NDK 27.0.12077973, which differs from the local NDK r27c (27.2.12479018). Qt uses its bundled 3rdparty libraries. OpenSSL is dlopened at runtime and not bundled, so TLS needs a per-ABI libssl/libcrypto via QT_ANDROID_EXTRA_LIBS. The APK DT_NEEDED check only sees link-time dependencies, not libraries loaded with dlopen.
- [C21|low|verified-from-source] Most grep hits are incidental. Transitive crates in Cargo.lock (android_system_properties, rustls-platform-verifier-android) appear in LEZ, logos-blockchain, lez-programs, spel, lez-multisig and logos-lez-rln. The circuits prover Makefile's android/ios targets come from iden3 rapidsnark and are never invoked by CI (CI runs only host_linux_*/host_windows_*/macos_arm64). logos-storage-module mentions Android only in a content:// comment. crossdeployqt and nix-bundle-dir are Linux/macOS/Windows (mingw) only. Lambda Prize LP-0010 puts 'mobile-native apps' out of scope. ecosystem-bravo's logos_wallet.md is an LLM-generated wishlist.
- [C22|low|verified-from-source] RLN modules in the Logos Core module ecosystem (logos-rln-modules, logos-lez-rln) build zerokit only for desktop. The only Android zerokit build path in the ecosystem is logos-delivery's build_rln_android.sh, which uses cross.

### Open questions
- Does `legacyPackages.x86_64-linux.pkgsAndroid.qt6.qtremoteobjects` from logos-nix actually build, and can a consumer's find_package(Qt6 RemoteObjects) work with the Android logosQtCrossCmakeFlags? The eval shows no repc/host-tools flag, but no build was attempted because it needs Android Qt built from source.
- What LGX variant name does liblgx produce on Android? lgx_host_variant() is compile-time and returns 'unknown' on a target with no rule (/nix/store/1l85mlja0rggx4y917whnh8c45jc1ms0-lgx-lib-0.1.0/include/lgx.h:193-200). The logos-package source is not cloned locally, so its rule table (and whether it has android-arm64) is unverified. logos_core_add_modules_dir and the module directory's main resolution depend on it.
- Does risc0-zkvm build for aarch64-linux-android with the `client` feature and with `prove` (the wallet-ffi default)? Not checked; the rules restrict web lookups to platform docs.
- Can the pcsc crate (a non-optional dependency of lez/keycard_wallet) cross-compile to Android, or does it need a feature gate in LEZ?
- What are the status and dates of logos-co/ecosystem#238 (Logos Core language bindings incl. Android/iOS, 'mobile Local mode'), #214/#219/#220/#222, and logos-messaging/pm#428/#457/#458/#459? They are cited only from local docs; gh was not allowed.
- Does anyone on the Logos Core team plan to consume logos-nix `pkgsAndroid` for liblogos? The two mobile commits carry 'slice' language (README: 'slice 09, not this one'), suggesting a multi-slice plan, but no consumer or issue link was found locally.
- Upstream logos-delivery CI now builds Android arm64 only (amd64 blocked by nim-lsquic). The sibling repo's x86_64 build predates this. Does x86_64 still build at current upstream? This matters for x86_64 emulator images.

### Recommendations
- Base the POC's Qt on logos-nix `legacyPackages.x86_64-linux.pkgsAndroid` (Qt 6.11.1, NDK 27.0, API 28, arm64-v8a) rather than a separate aqt/Qt online-installer toolchain, so it matches what the Logos team is building toward. Expect to build Qt from source: it is not in cache.nix.logos.co/public.
- In a POC-local overlay, add the missing QtRemoteObjects cross wiring, copying the Windows overlay: `-DQt6RemoteObjectsTools_DIR=<build-platform qtremoteobjects>/lib/cmake/Qt6RemoteObjectsTools` on qtremoteobjects, plus qtremoteobjects in QT_ADDITIONAL_HOST_PACKAGES_PREFIX_PATH (logos-nix/nix/windows/cross-overlay.nix:70-83,364-368). Consider sending this upstream to logos-nix.
- Target the arm64 AVD (delivery-demo-arm64), or accept adding an x86_64 Android pseudo-system to logos-nix (README 'Adding an ABI'), because the logos-nix Android set is arm64-v8a only.
- Do not reuse logos-basecamp/qt-ios code directly: its liblogos API calls are gone. Treat it only as a pattern for statically linking modules, which current liblogos cannot register anyway (LogosModule::getStaticModules is unused).
- Budget separately for getting LEZ onto Android. wallet_ffi needs Android builds of the logos-blockchain-circuits witness-generator static libraries and libgmp, supplied through LBC_ROOT_DIR, because no android bundle is published. It also needs RAPIDSNARK_LIB_DIR pointed at iden3's android-arm64 archive (the pinned crate already maps it), a feature gate or port for pcsc/keycard, and probably building wallet-ffi with default-features off to drop risc0 `prove`. A simpler test module might be better for the first end-to-end run.
- For inter-module QtRO on Android, plan for an in-process ModuleContainer/loader registered through ModuleManager::loaders() (none exists), or confirm that the subprocess container's logos_host can be exec'd from the APK's native library directory. Only the subprocess container exists today.
- Reuse the logos-delivery and sibling-repo cross-compilation patterns (NDK clang via ANDROID_NDK_HOME, `cross` for Rust cdylibs, llvm-strip, DT_NEEDED auditing) for any Nim or Rust native module dependencies.

### Verifier (non-confirmed only)
- [C2] partially-correct: The main point holds and I reproduced it: CI never builds the Android Qt, it is not in the Logos public cache, and it is not in the local store. One detail is wrong. The android-apk check is not excluded from CI. It is defined under checks.x86_64-linux (flake.nix:738-740), so `nix flake check --no-build --all-systems` evaluates it on both runners. Like every other check, it is just never built. The flake.nix comment only keeps it off a plain `nix flake check` run on a Mac. The Android eval-time drift assertions (android-overlay gate, flake.nix:633-733) are checked in CI. The README's 5m28s/4.6 GiB figures were measured on WSL x86_64 with dependencies and the SDK already present. Its DT_NEEDED note was 'measured on a physical arm64 device', so the author has built and run it outside CI.
- [C6] partially-correct: It is true that liblogos ships only the subprocess container and that no in-process container exists: the only ModuleContainer implementations are SubprocessContainer and a test NullContainer. But 'in-process is possible only as an extension point nobody has implemented' leaves out three things. (1) logos-protocol already has an in-process transport meant for mobile: LogosMode::Local ('Uses in-process PluginRegistry (mobile apps, single process)'), a PluginRegistry keyed on QCoreApplication properties, and a qt_local LocalTransportHost/LocalTransportConnection, with tests in logos-qt-sdk. logos_caller_scope.h says it 'has no in-tree producer today', that local calls bypass the meta-object so the caller is UNKNOWN, and that there is a cross-image hazard. The RFP appendix itself (lines 431-433) says 'the runtime supports Local mode, registering modules in-process through a PluginRegistry'. Line 561 ('undelivered') refers to the full mobile path, not the transport. (2) There are two extension seams, not one. The runtime one is ModuleManager::loaders().registerLoader(), but module_manager.h is not installed by nix/include.nix (only logos_core.h and the SDK headers are), so it works only from a source build. The link-time one is LogosCore::makeContainer() in logos-container's container_factory.h, defined by logos-container-subprocess, with the default chosen by containerImpl in liblogos flake.nix. (3) Module plugins deliberately link static copies of the protocol and qt-host libraries, because each runs in its own process (src/CMakeLists.txt:252-255). Loading several of them into one process would give each its own TokenManager singleton, the same failure described at :225-228. An in-process container would also need that linkage changed.
- [C16] partially-correct: Every quoted fact checks out, but calling amd64 'blocked' overstates it. That is only the comment in upstream CI. The sibling repo pins exactly 05600659 (submodule added 2026-09-21, never bumped) and its own CI builds x86_64 liblogosdelivery.so and librln.so from that commit. It applies a scripted Leopard-RS CMake patch first. The v0.1.0-poc APK ships lib/x86_64/liblogosdelivery.so (33.5 MB). So x86_64 builds from this commit; upstream CI simply doesn't build it. The quoted 32-bit reason is 'int overflows in nim-brokers and waku_store_sync'. Two more details: the aggregate `liblogosdelivery-android` target builds amd64, arm64 and x86 but not arm, and upstream CI also builds iOS device and simulator (ci.yml:243-272).

Confirmed: C1, C3, C4, C5, C7, C10, C11, C12, C14, C15, C18

### Verifier missed findings
- logos-protocol already has an in-process transport intended for mobile, but nothing produces it today. LogosMode::Local is documented as 'Uses in-process PluginRegistry (mobile apps, single process)' (/home/fryorcraken/src/logos-co/logos-protocol/cpp/logos_mode.h:10-16, :40). It is backed by PluginRegistry, which stores QObject* in QCoreApplication properties (cpp/plugin_registry.h:14-18, 47-61), and by the qt_local LocalTransportHost/Connection (cpp/implementations/qt_local/local_transport.h:9-21), selected in logos_transport_factory.cpp:16-19. There is a test: logos-qt-sdk/tests/qt-sdk/test_local_transport_integration.cpp. Known gaps: logos_caller_scope.h:70-75 says 'LogosMode::Local has no in-tree producer today', calls bypass the meta-object (caller identity UNKNOWN), and there is a cross-image hazard. This makes it the most direct building block for an in-process Android host and should be evaluated before writing a container from scratch.
- liblogos's own linkage model conflicts with loading modules in-process. Module plugins deliberately link STATIC copies of logos-protocol and qt-host 'because each runs in its own process where its own copy is the CORRECT per-process singleton' (/home/fryorcraken/src/logos-co/logos-liblogos/src/CMakeLists.txt:252-255). When static copies were loaded into one process before, each image got its own TokenManager singleton and 'every cross-module call was refused' (:225-228). So an in-process or mobile mode needs module plugins rebuilt against the shared liblogos_protocol and liblogos_qt_host, not just a new container.
- The packaged liblogos does not install module_manager.h or module_loader_registry.h. nix/include.nix:40-87 copies only logos_core.h and the SDK/protocol/qt-sdk/qt-host headers. So the 'frontends can register their own loaders' seam (ModuleManager::loaders()) is usable only from a source build. The seam a package can actually use is the link-time factory LogosCore::makeContainer(): declared in /home/fryorcraken/src/logos-co/logos-container/src/logos_container/container_factory.h:18, defined in logos-container-subprocess/src/subprocess_container_factory.cpp:14, and selected by containerImpl in logos-liblogos/flake.nix:103-109. docs/spec.md:12 says: 'a different container (Docker, in-process) ... is added by writing a new package that defines the same factory symbol — chosen at link time'.
- logos-module-builder has no static or mobile module output. It always runs add_library(${MODULE_NAME}_module_plugin SHARED ...) (/home/fryorcraken/src/logos-co/logos-module-builder/cmake/LogosModule.cmake:452). Its platformTriples table, which validates .lgx/metadata platform selectors, has rows only for x86_64/aarch64-linux, x86_64/aarch64-darwin and x86_64-windows (lib/resolvePlatforms.nix:91-99), and common.nix:89-90 lists only desktop systems plus x86_64-windows. No Logos module (.lgx) can be built for Android or iOS today, and iOS would need static plugins that the builder cannot produce.
- logos-module already has library-level support for statically linked modules, but nothing uses it. LogosModule::getStaticModules() wraps Q_IMPORT_PLUGIN plugins from QPluginLoader::staticInstances(), and wrapExisting() wraps an existing QObject (/home/fryorcraken/src/logos-co/logos-module/src/logos_module.h:102-118; logos_module.cpp:128). A grep for getStaticModules across both orgs finds only logos-module itself.
- logos-basecamp has a documented mobile bring-up approach that the researcher missed. shell-preview/README.md:15-24, 74-81 calls itself 'the mobile starting point', reducing 'port Basecamp' to 'cross-compile Qt, the QML modules, and one small host you own'. A mobile variant would be 'a second IShellHost implementation over QGuiApplication + QQuickWindow'. mock/README.md:180-184 says 'ui-host is a subprocess and plugins are dlopened, neither of which survives on iOS'. Both files, and README.md:92, point to MOBILE-HANDOFF.md, which exists neither in the local checkout (master 8f31582, 2026-08-31) nor upstream at 2c2022762b (nix flake prefetch -> /nix/store/jr0m9rm7nnb3ly2jjh6xpimrk9ps2rf2-source, no such file at top level). It is a dangling reference.
- There is a second stale iOS build script: /home/fryorcraken/src/logos-co/logos-package-manager-module/scripts/build-ios.sh. It uses Qt 6.8.2 from ~/Qt6/6.8.2/ios, the Xcode generator and qt-cmake, and at :186 expects 'Static library: ${build_dir}/modules/libpackage_manager_plugin.a'. But the module now builds through logos-module-builder's LogosModule.cmake (CMakeLists.txt:5-12), which only produces SHARED plugins, so the script's premise is out of date. Its history is not recoverable here because the clone is shallow (rev-parse --is-shallow-repository -> true).
- Logos Storage has no upstream Android build either. The sibling repo relies on a fork: docs/adr/0002-fork-storage-nim-for-android.md:9-13 says 'The upstream logos-storage/logos-storage-nim repo has no Android build support: its build.nims only defines host-target ... tasks, and its Makefile has no android targets at all', and the fork fryorcraken/logos-storage-nim adds libstorage-android-{arm64,amd64,x86,arm} (:29-42). The sibling README.md:35-37 says the storage JNI shim 'does not exist yet'. scripts/build-nim-android.sh:63-76 skips storage when the fork is not cloned.
- The sibling repo builds x86_64 delivery from the same upstream commit whose CI calls amd64 blocked. It pins nim-src/logos-delivery at 05600659 (git ls-tree), and its CI matrix builds arm64-v8a and x86_64 (/home/fryorcraken/src/fryorcraken/logos-android-wrap-poc/.github/workflows/ci-nim-android.yml:41-42) after scripts/patch-leopard-android-x86.sh patches Leopard-RS. The v0.1.0-poc APK ships lib/x86_64/liblogosdelivery.so (README.md:51-67). So an x86_64 emulator (e.g. the delivery-demo AVD) is feasible for delivery-based pieces.
- Android permits running child processes from the app's nativeLibraryDir, which is an exception to W^X. So the subprocess container (logos_host_qt spawned per module) is not ruled out on Android the way it is on iOS, provided the host binary ships as lib*.so in jniLibs. Status: inferred; Boost.Process on bionic is untested. Source: https://developer.android.com/about/versions/10/behavior-changes-10 ('untrusted apps that target Android 10 cannot invoke execve() directly on files within the app's home directory'); nativeLibraryDir exception described at https://dev.to/ai2th/pockr-part-2-executing-binaries-on-android-3b4k. This contrasts with the roadmap's 'Mobile platforms require a single process' (roadmap/content/messaging/roadmap/milestones/2026-support-mobile-platforms.md:34), which is really an iOS constraint.
- The logos-blockchain-circuits CI copies in a vendored rapidsnark prover Makefile with android, android_x86_64, ios and ios_simulator targets (/home/fryorcraken/src/logos-blockchain/logos-blockchain-circuits/.github/resources/prover/Makefile:57-93). The circuits CI runs only host targets: ci.yml:240 'make host_linux_x86_64_static', :511 aarch64, :817 windows, :1090 macos_arm64. So the prover and gmp half of the circuit bundle has a known upstream Android build path. The circom witness-generator archives (libpol.a, libpoq.a, libsignature.a, libpoc.a) have none. The circuits flake is only a fetchurl of release tarballs and throws on unsupported systems (flake.nix:13-18, 52-56).
- Two more mobile milestones sit in the roadmap. 'Messaging and Chat on Mobile' is dated 2025-12-11, needs '1 Logos Core Engineer', has completion TBC and all deliverables TODO (/home/fryorcraken/src/logos-co/roadmap/content/messaging/roadmap/milestones/2025-messaging-chat-on-mobile.md:5-37). 'Enable easy C-Bindings for Mobile' is dated 2025-12-19 (2025-enable-easy-c-bindings-for-mobile.md:5-37). Both appear in combined_roadmap.md:134-137 running to 2026-06-30, a date that has passed.
- logos-nix exposes Android through lib.mkAndroidCrossOverlay, which is a function of the build system, and not through lib.overlays. The overlays set is windows, windowsNative, windowsNim, ios plus the native ones (/home/fryorcraken/src/logos-co/logos-nix/flake.nix:286-305). A consumer doing its own `import nixpkgs` must call mkAndroidCrossOverlay <buildSystem> or use lib.mkAndroidPkgs.
- In the ecosystem-bravo content snapshot (not a git repo), a 'Mobile Wallet (iOS/Android)' and a 'Mobile App' deployment model are listed as aspirations only. There is no engineering plan behind them (/home/fryorcraken/src/logos-co/ecosystem-bravo/content/integration/infrastructure_essentials/logos_wallet.md:89-94, 182-186). This is consistent with C14/C18: no Logos Blockchain or LEZ mobile work exists.

---

## Full report

## Do any Logos components already build for Android or iOS?

### Bottom line

**No Logos component the POC needs builds for Android today.** That covers liblogos_core, the logos_host/module-loader stack, Logos Core modules (.lgx), the LEZ wallet (`lez_core`) and the Logos Blockchain node.

What does exist:

1. **logos-nix: an Android Qt toolchain and APK packager.** Qt 6.11.1 is cross-built for arm64-v8a, with an APK packager. It landed on master on 2026-09-07. Its limits:
   - CI evaluates it but never builds it.
   - It is not in the Logos public cache.
   - No Logos repo uses it.
   - It does not set up QtRemoteObjects, which LogosAPI transport needs.
2. **logos-nix: an iOS Qt toolchain.** Static Qt, built only on an Apple-silicon Mac (`aarch64-darwin`) with Xcode 26.6.
3. **An old iOS demo in logos-basecamp (`qt-ios`).** It statically links modules into the app, but it no longer builds or runs against current liblogos.
4. **The logos-delivery precedent (messaging).** Upstream builds `liblogosdelivery.so` and zerokit `librln.so` for Android. The sibling `logos-android-wrap-poc` wraps these through JNI without liblogos_core.
5. **Android-aware Rust crates.** The pinned `rust-rapidsnark` fork maps Android targets to iden3's prebuilt archives.

The main blockers for this POC:

- **LEZ needs desktop-only circuit libraries.** LEZ `wallet_ffi` transitively links Logos Blockchain circuit native libraries. Those are published only for linux x86_64/aarch64, macos aarch64 and windows x86_64.
- **No in-process module container.** liblogos ships only a subprocess container. An in-process ("Local mode") container is an extension point nobody has implemented.
- **No mobile module output.** The module builder produces only SHARED plugins for linux, darwin and windows.

Mobile support is on the LogosCore and messaging roadmaps. Logos Blockchain and LEZ have no defined mobile strategy.

### Method

I first ran `grep -rliIE 'android|ANDROID_NDK|aarch64-linux-android|x86_64-linux-android|armv7a-linux-androideabi|cargo-ndk|pkgsCross|iphoneos|xcframework|ios-arm64'` over:
- every repo in the task's mapping, plus liblogos, logos-core-poc, logos-waku-module, logos-docs, logos-lips, roadmap, the UI repos and the package-downloader repos;
- `.git`, `node_modules`, `target`, `vendor`, `nimbledeps`, `build` and lock files were excluded in the first pass;
- a second count including vendored and lock files flagged transitive-only repos.

The script is `/home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/mobile-search-grep.sh`.

A second script (`mobile-search-grep2.sh`) swept every other directory under `/home/fryorcraken/src/logos-co` and `/home/fryorcraken/src/logos-blockchain`. It listed, but I did not open, one file under a repo-level `.claude/` directory in `logos-co/rfp`.

A third script (`mobile-search-find.sh`) searched for Kotlin, Swift, Gradle, UniFFI and Xcode artefacts.

Because local checkouts can lag upstream, I checked current upstream heads with `nix flake metadata` and `nix flake prefetch`, then grepped the store sources:

| Repo | Upstream HEAD | Date |
|---|---|---|
| logos-nix | 7c1eb8bc | same as local |
| logos-liblogos | db45024f | about 2026-09-22 |
| logos-module-builder | 4b799827 | about 2026-09-23 |
| logos-basecamp | 2c202276 | about 2026-09-22 |
| logos-execution-zone | 3454abed | about 2026-09-25 |

### Hits and what they are

| Repo | Hits | Classification |
|---|---|---|
| **logos-nix** | `nix/android/*`, `nix/ios/*`, flake, README | **Real build support** (Qt only) |
| **logos-basecamp** | `qt-ios/build.sh` (plus CMakeLists, main.cpp) | **Real but stale** iOS demo |
| **logos-package-manager-module** | `scripts/build-ios.sh` | **Real but stale** |
| **logos-blockchain-rust-rapidsnark** | README, CI, build.rs, lib.rs | **Real** (upstream zkmopro crate; Android via cargo-ndk) |
| logos-blockchain-circuits | `.github/resources/prover/Makefile` android/ios targets | Vendored iden3 Makefile; CI never runs those targets |
| logos-storage-module | `storage_module_plugin.cpp:853` | Incidental (a `content://` comment) |
| crossdeployqt, nix-bundle-dir | `pkgsCross.mingwW64` | Windows-only cross; no mobile |
| roadmap, rfp-blockchain-api, logos-api-sdk-research | Docs | Plans and research, not builds |
| LEZ, logos-blockchain, lez-programs, spel, lez-multisig, logos-lez-rln | Cargo.lock only | Transitive crates (`android_system_properties`, `rustls-platform-verifier-android`) |
| lambda-prize LP-0010, ecosystem-bravo | Docs | Incidental: LP-0010 puts "mobile-native apps" out of scope; `logos_wallet.md` is an unreviewed LLM wishlist |

All other repos had zero first-party hits. That includes logos-liblogos, logos-cpp-sdk, logos-protocol, logos-qt-sdk, logos-plugin-qt, logos-module, the containers and loaders, logos-module-builder, logos-execution-zone, logos-execution-zone-module, logos-blockchain, logos-blockchain-module and the RLN modules. No Kotlin, Swift, Gradle, UniFFI or JNI file or dependency exists anywhere (`mobile-search-find.sh` output is empty).

### 1. logos-nix: the only Android build support for Logos Core

#### What the Android target provides

`logos-nix` has an opt-in `aarch64-android` target, added in commit `5378de5` on 2026-09-07 ("feat(android): Qt 6.11.1 for aarch64-android from source, APK packaging").

Configuration (`flake.nix:104-138`):
- ABI: `arm64-v8a` only.
- `androidApiLevel = "28"` ("Qt 6.11 defaults to and requires API 28").
- Compile SDK 36 and build-tools 36.0.0 (floors required by AGP 9).
- `androidNdkVersion = "27.0.12077973"`.
- `crossSystem.config = "aarch64-unknown-linux-android"`, `rust.rustcTarget = "aarch64-linux-android"`.
- Built from the separate `nixpkgs-windows` pin (Qt 6.11.1). Linux and macOS stay on Qt 6.9.2 (`flake.nix:32-36`).

Exposed outputs:
- `packages.aarch64-android.{qtbase,qtdeclarative,qtshadertools,qtsvg}` (`flake.nix:324-326`).
- The full cross set as `legacyPackages.<build>.pkgsAndroid`.
- On that set: `androidPkgs`, `logosQtHost`, `logosQtCrossCmakeFlags`, `logosQtCrossToolchainFile` and `mkQtAndroidApk` (`README.md:109-141`, `nix/android/cross-overlay.nix`).

`mkQtAndroidApk` (`nix/android/mk-apk.nix`):
- Runs a `qt_add_executable` CMake project through `androiddeployqt --aux-mode` and gradle, replaying the committed `deps.json` lock with no network.
- Signs with a committed debug keystore.
- Fails the build if any packaged `.so` has a DT_NEEDED that is neither packaged nor an NDK stub library. That check sees link-time dependencies only, never `dlopen` (`README.md:156-162`).

The smallest consumer is `nix/android/check-apk`: a QML window linking Gui and Quick only.

#### Other limits

- Qt uses its bundled 3rdparty libraries. OpenSSL is `openssl_runtime` and not bundled, so TLS needs a per-ABI libssl/libcrypto via `QT_ANDROID_EXTRA_LIBS` (`README.md:188-199`).
- Adding x86_64 or armeabi-v7a means a new pseudo-system ("slice 09, not this one", `README.md:164-171`).
- The logos-nix NDK is 27.0; this machine has r27c (27.2.12479018).

#### Status checks

- **Upstream is current.** `nix flake metadata github:logos-co/logos-nix` gives rev `7c1eb8bc…`, identical to the local HEAD.
- **Not built in CI.** CI runs only `nix flake check --no-build --all-systems` (`.github/workflows/ci.yml:34-35`). The `android-apk` check exists only for x86_64-linux and is never built by CI (`flake.nix:735-740`).
- **Not cached.** The qtbase output path evaluates to `/nix/store/5nxcfyhvzxbf0vhrkqcajbg57apf83ii-qtbase-aarch64-unknown-linux-android-6.11.1`. `nix path-info --store https://cache.nix.logos.co/public <that path>` returns "is not valid". It is not in the local store either.
- **Build cost.** The README's measurement is 5m28s for the four Qt modules on 32 cores with dependencies already present. The closure is 4.6 GiB, of which 4.2 GiB is the SDK+NDK (`README.md:220-224`).
- **No consumer.** A grep for `forAllMobileTargets|mobileTargets|pkgsAndroid|aarch64-android|pkgsIos|mkQtAndroidApk|mkIosCmakeStage` over both source trees hits only logos-nix.

#### QtRemoteObjects is not set up for Android

This matters directly for the POC's LogosAPI transport.

On Windows, the overlay:
- adds `-DQt6RemoteObjectsTools_DIR=<build-platform qtremoteobjects>` to qtremoteobjects (`nix/windows/cross-overlay.nix:361-368`);
- lists `qtremoteobjects` in `QT_ADDITIONAL_HOST_PACKAGES_PREFIX_PATH`;
- explains why: repc must run on the build machine, and "Without these flags find_package(Qt6 COMPONENTS RemoteObjects) fails" (`:54-83`).

The Android overlay's host-prefix list is only qtbase, qtdeclarative, qtshadertools and qtsvg (`nix/android/cross-overlay.nix:357-375`). It has no qtremoteobjects override.

Experiment: `nix eval --json 'path:/home/fryorcraken/src/logos-co/logos-nix#legacyPackages.x86_64-linux.pkgsAndroid.qt6.qtremoteobjects.cmakeFlags'` returns only toolchain, ABI, EGL and `CMAKE_SYSTEM_*` flags. There is no `Qt6RemoteObjectsTools_DIR` and no `QT_HOST_PATH`.

The package evaluates, but whether it builds or is findable by a consumer is untested. By analogy with the Windows notes it will likely need the same fix.

#### iOS side

Commit `b8f10e8` (2026-09-07) builds static Qt 6.11.1 for `aarch64-ios-simulator` and `aarch64-ios`:
- only on aarch64-darwin with Xcode 26.6 (17F113), as `__noChroot` derivations (`flake.nix:74-91`, `README.md:68-107`);
- `mkIosCmakeStage` fails on any dynamic image (`nix/ios/cmake-stage.nix:40-54`).

So iOS modules would have to be statically linked.

### 2. liblogos and the module toolchain: desktop and Windows only

- **liblogos targets.** `logos-liblogos/flake.nix:42` lists `aarch64-darwin x86_64-darwin aarch64-linux x86_64-linux`, and `forAllTargets` adds only `x86_64-windows` (`:62-82`). There are no `Q_OS_ANDROID`/`Q_OS_IOS` branches. Upstream HEAD `db45024f` has no mobile references (prefetched to `/nix/store/na8w49czlrhdi0hqy562zl09kywg8yvs-source`).
- **Loader and container.** `ModuleManager::loaders()` lets frontends "register their own loaders / containers (Docker, WASM, in-process, ...) before logos_core_start()" (`src/logos_core/module_manager.h:17-23`). The only implementation is `logos-container-subprocess`, whose README says another isolation mechanism "means writing a sibling repo" (`README.md:8-12`). The user's RFP appendix likewise says "mobile Local mode is undelivered" (`rfp-blockchain-api/appendix/integrating-logos-technology-stack.md:561`).
- **Static plugins.** `logos-module` has `LogosModule::getStaticModules()` over `QPluginLoader::staticInstances()` (`src/logos_module.cpp:125-144`). Nothing in liblogos, the loaders or the containers calls it, and the old `logos_core_register_plugin_by_name` API is gone.
- **Module builder.**
  - `LogosModule.cmake:452` always builds `add_library(... SHARED ...)`.
  - `lib/resolvePlatforms.nix:92-98` knows only linux, darwin and windows triples.
  - Upstream HEAD `4b799827` has no Android references.
- **LGX variants.** The variant vocabulary lives in liblgx (logos-package, not cloned locally). `lgx_host_variant()` is "compile-time … 'unknown' on a target with no rule" (`lgx.h:193-200` in `/nix/store/1l85mlja0rggx4y917whnh8c45jc1ms0-lgx-lib-0.1.0`). Whether an Android variant exists is open.

### 3. logos-basecamp and crossdeployqt

**`logos-basecamp/qt-ios`** is an iOS demo, commits `c68171f` (2025-11-28, "wip") through `f714bf6` (2025-12-10). How it works:
- It builds liblogos, package_manager and capability_module as static archives with the Xcode generator.
- It links them into a QML app using `Q_IMPORT_PLUGIN(PackageManagerPlugin)` (`main.cpp:15-16`).
- It calls a module through generated `LogosModules` / `LogosAPI` (`main.cpp:195-196`).

It is stale:
- It calls `logos_core_set_mode`, `logos_core_register_plugin_by_name`, `logos_core_process_events` and `logos_core_async_operation`. None of these exist in the current `logos_core.h`.
- `build.sh:38-42` requires `LOGOS_PACKAGE_MANAGER_SRC`, but `flake.nix:653` exports `LOGOS_PACKAGE_MANAGER_MODULE_SRC`.
- It uses Qt 6.8.2 from `~/Qt6` (`README.md:6`), and the device build is "untested" (`:18`).
- The simulator build targets x86_64 (`build.sh:119-120`).
- It is not in CI.

`logos-package-manager-module/scripts/build-ios.sh` is stale in the same way. The module's `CMakeLists.txt:5-9` hits FATAL_ERROR without `LOGOS_MODULE_BUILDER_ROOT`, which the script never sets.

The basecamp app itself has no Android code.

**crossdeployqt** is described as "Collect dependencies and assets for Qt 6 apps (Linux/macOS/Windows)" (`flake.nix:136`). Its only cross target is `pkgsCross.mingwW64`, so there is no mobile target.

### 4. LEZ, Logos Blockchain, circuits and RLN

#### LEZ

- **Flake targets.** `logos-execution-zone/flake.nix:38-43` targets x86_64-linux, aarch64-linux, aarch64-darwin and x86_64-windows. The builds set `LBC_ROOT_DIR` (circuits) and `RAPIDSNARK_LIB_DIR` from flake inputs, and add `openssl` and `pcsclite` (`:125-153`).
- **wallet-ffi.**
  - Built as a C ABI via cbindgen, with `crate-type = ["rlib","cdylib","staticlib"]` (`lez/wallet-ffi/Cargo.toml:10-11`).
  - Default feature `prove`, which chains `lee/prove` to `risc0-zkvm/prove` (`:29-31`, `lee/state_machine/Cargo.toml:37`).
- **`lez_core` module.** `logos-execution-zone-module` (metadata name `lez_core`) is a C++ Qt plugin wrapping that `wallet_ffi` through `externalLibInputs` (`flake.nix:13,21-26`, `metadata.json:24-28`).
- **No mobile code.** There is no Android or iOS code, feature or CI in LEZ; upstream `3454abed` is the same. No mobile wallet or SDK (Kotlin, Swift, UniFFI) exists.

#### Why LEZ cannot build for Android as-is

`wallet_ffi` depends on `lez/common`, which uses `logos-blockchain-common-http-client` (`lez/common/Cargo.toml:27`). The chain continues:
- that client depends on `lb-core`, `lb-groth16` and others (`logos-blockchain/nodes/node/http-client/Cargo.toml:18-23`);
- `lb-core` depends on `lb-pol` and `lb-poc` (`core/Cargo.toml:25,29-30`);
- `lb-pol` depends on `lbc-pol-sys` with `features = ["prebuilt"]` and on `lb-circuits-prover` (`zk/proofs/pol/Cargo.toml:14,18`).

`lbc-build` downloads `logos-blockchain-circuits-v{ver}-{os}-{arch}.tar.gz` from GitHub Releases unless `LBC_ROOT_DIR` is set (`logos-blockchain-circuits/rust/logos-blockchain-circuits-build/src/lib.rs:13-37`). Those bundles contain native `libpol.a`, `libpoq.a`, `libsignature.a`, `libpoc.a` and `libgmp.a` (`.github/workflows/ci.yml:386-412`). They are published only for linux x86_64/aarch64, macos aarch64 and windows x86_64 (`ci.yml:1417-1426`).

So an Android build of `wallet_ffi`, and therefore of `lez_core`, fails at the circuits download unless someone cross-builds the circuits with the NDK. The user's RFP appendix states the same (`integrating-logos-technology-stack.md:359-376, 839-841, 908-912`).

A second obstacle: `lez/keycard_wallet` depends on `keycard-rs` and `pcsc` unconditionally (`Cargo.toml:12,16`), and the wallet always pulls it in (`lez/wallet/Cargo.toml:22`). Android has no system PC/SC library; that part is inferred.

#### rapidsnark

The crate pinned by both LEZ and logos-blockchain is `logos-blockchain-rust-rapidsnark` rev `e91187f8` ("feat/nixify", `logos-blockchain/Cargo.toml:263-264`). It handles Android:
- `download_rapidsnark.sh:36-44` maps `aarch64-linux-android` and `x86_64-linux-android` to iden3's `rapidsnark-android-{arm64,x86_64}` archives;
- `build.rs:50-63,116-123` links static `rapidsnark`/`fr`/`fq`/`gmp` for mobile targets and `libc` instead of pthread on Android.

Its Nix flake, though, supplies only linux and darwin archives (`flake.nix:21-26`).

The local repo checkout is the zkmopro upstream (last commit 2025-08-19). Its CI builds `x86_64/aarch64-linux-android` with `cargo ndk` and iOS targets with `cargo build --target` (`.github/workflows/build-and-test.yml:33-71`). This is the only first-party-hosted Rust CI with Android targets in `logos-blockchain`.

#### Logos Blockchain node

- The flake targets only desktop systems (`flake.nix:35-39`).
- `c-bindings` is a `cdylib` named `logos_blockchain` (`Cargo.toml:42-43`).
- There is no light-client or mobile code anywhere in the repo.
- The roadmap mentions "Light Nodes" only as whitepaper and tutorial items (2023–2025).
- The user's RFP appendix says: "None of the protocols has defined its mobile strategy" (`:916-925`).

#### RLN

The zerokit-based `logos-rln-modules` and `logos-lez-rln` are desktop Qt modules with no mobile references. The ecosystem's only Android zerokit build is in logos-delivery (section 5).

### 5. The logos-delivery precedent

The sibling repo's submodule `nim-src/logos-delivery` is at upstream `05600659` (2026-09-18).

What upstream provides:
- **Makefile targets.** `liblogosdelivery-android-{arm64,amd64,x86,arm}` (`Makefile:613-668`):
  - require `ANDROID_NDK_HOME`; `ANDROID_TARGET` defaults to 30;
  - use the NDK `<triple><api>-clang` from `toolchains/llvm/prebuilt/linux-x86_64`;
  - rebuild the NAT libraries with that compiler.
- **Nimble task.** `libLogosDeliveryAndroid` runs `nim c --app:lib --os:android -d:androidNDK --cpu:<cpu> --passL:-lrln --passL:-llog` to produce `build/android/<abi>/liblogosdelivery.so` (`logos_delivery.nimble:207-222`).
- **zerokit.** `librln.so` (v2.0.2) is cross-compiled with `cross rustc --release --lib --target=<triple> --crate-type=cdylib` in Docker (`scripts/build_rln_android.sh:21-29`).
- **iOS.** Static-library targets `liblogosdelivery-ios-{device,simulator}` (`Makefile:673-708`).
- **Nix.** A `nix/pkgs/android-sdk` composition (NDK 27.2.12479018, platform 34) exists for dev shells.
- **CI.** `build-android` runs arm64 only: "amd64 is blocked by a nim-lsquic android type mismatch, 32-bit ABIs by int overflows in nim-brokers and waku_store_sync" (`.github/workflows/ci.yml:183-240`).

The sibling `logos-android-wrap-poc` builds on this without liblogos_core:
- a hand-written JNI shim plus independent Kotlin AARs per native library;
- its README reports arm64-v8a and x86_64 working (x86_64 via a scripted Leopard-RS patch) and an 85.7 MB universal APK, ~76% of it `liblogosdelivery.so`;
- storage comes from a fryorcraken fork adding `make libstorage-android`, which is not upstream (`README.md:26-47, 49-70, 271-282`).

There is one more precedent in the wider family, reported only in docs and not verified here:
- a Status Android APK built with `libsds.so` (`roadmap/content/messaging/updates/2025-09-01.md:13,20`);
- the user's `wallet-tech-stacks.md:254-264` reports that Status ships a Nim + Qt/QML app to both app stores.

### 6. Planned or in-progress work

- **LogosCore roadmap.**
  - Testnet v0.3 "Support Other Platforms: Windows Support, Mobile iOS support, Mobile Android support" (`roadmap/content/logoscore/roadmap/index.md:45-48`).
  - The combined Gantt has "Mobile App for iOS and Android :active, 2025-06-01, 2026-06-30" (`combined_roadmap.md:32`); that end date has passed.
  - The logos-app FURPS targets "Linux, Windows, macOS, Android, iOS, potentially WASM" (`logoscore/furps/logos-app.md:3`).
  - The roadmap repo's last commit is 2026-08-03.
- **Messaging.**
  - "Support Mobile Platforms", https://github.com/logos-messaging/pm/issues/428, dated 2026-02-21. It asks for "Logos Core team for mobile runtime support". Its deliverables are nim-ffi on mobile (pm#457), edge mode on mobile (pm#458) and "Verify Chat and Delivery modules on Logos Core mobile" (pm#459). It names single-process and multi-runtime (Chronos + Tokio) risks (`2026-support-mobile-platforms.md`).
  - Earlier: "Enable easy C-Bindings for Mobile", dated 2025-12-19.
- **The user's RFP appendix** (`rfp-blockchain-api/appendix/integrating-logos-technology-stack.md`, last edited 2026-09-21):
  - Mobile Basecamp is "planned for testnet 0.4. Architecture is not defined" (`:88-91`). This conflicts with the roadmap's v0.3.
  - It proposes Logos Core language bindings with "Android and iOS in scope" and says mobile Local mode, the Qt runtime inside the artefact, and ZK circuits for mobile are part of that deliverable. This is tracked as https://github.com/logos-co/ecosystem/issues/238, alongside #214, #219, #220 and #222; their dates were not checked (`:831-841`).
- **logos-nix.** The Android and iOS commits are the only merged Logos Core platform work. Their "slice" language suggests a staged plan.

### 7. Explicitly unsupported or blocked today

- logos-nix Android: arm64-v8a only; OpenSSL not bundled; QtRemoteObjects not set up; built only on x86_64-linux or aarch64-darwin.
- logos-nix iOS: aarch64-darwin with Xcode only; static only.
- Logos Blockchain circuit artefacts: no Android or iOS release, so any crate using lbc-*-sys (including LEZ `wallet_ffi`) cannot build for mobile as-is.
- LEZ, logos-blockchain, logos-liblogos and logos-module-builder: desktop plus Windows only.
- Upstream logos-delivery CI: Android amd64 and 32-bit are blocked.
- crossdeployqt and nix-bundle-dir: no mobile.

### Implications for this POC

1. The Android Qt base to align with is `logos-nix` `pkgsAndroid`. The POC must add the QtRemoteObjects cross flags itself, copying the Windows overlay.
2. liblogos, the module stack and every `.lgx` module would be the first Android builds of those components in the ecosystem. Nothing upstream can be reused beyond the Qt set and the APK packager.
3. Loading real LEZ (`lez_core`) on Android needs an Android circuits bundle first (witness generators plus gmp, via `LBC_ROOT_DIR`). rapidsnark's iden3 android-arm64 archive is already mapped by the crate. pcsc/keycard needs handling, and ideally `prove` is dropped. The rest of the pipeline could first be proven with a lighter module.
4. For in-process QtRO between modules, an in-process `ModuleContainer` is new work. The alternative is to make the subprocess `logos_host` exec-able from the APK's native library directory.

