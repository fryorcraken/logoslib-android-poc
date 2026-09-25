# RLN modules and inter-module calls

> Research track `rln-intermodule`, 2026-09-25. Written by a research agent and then checked by a
> second, adversarial agent, whose non-confirmed verdicts are listed under "Verifier".
> Claims are tagged verified-from-source / verified-by-experiment / inferred / open.
> Absolute paths point at the author's local checkouts (`~/src/logos-co`,
> `~/src/logos-blockchain`) at the revisions in [../investigation.md](../investigation.md);
> `.work/` paths are local scratch, not committed. The synthesis is in
> [../investigation.md](../investigation.md).


### Summary
The logos-modules-dev README line "lez_core is here as a dependency of liblogos_lez_rln_module" is out of date. It was true up to lez-rln 2.x, which is the version the catalog's submodule pointer and the Electron POC use. Since 3.0.0 (commit 46caed6, 2026-09-14), liblogos_lez_rln_module declares no module dependencies. It calls the prebuilt LEZ libwallet_ffi C API itself, from Rust in-process, instead of calling lez_core. Current main is 4.0.3. liblogos_rln_module (zerokit proofs and membership) calls liblogos_lez_rln_module through the Rust SDK's typed async client. Neither module calls lez_core any more.

In the Electron POC, delivery_module pulled in liblogos_rln_module only because its lgx was built from the delivery-module branch impl-plugable-rln-api-module (RlnBridge). Delivery master and the modules-dev catalog pointer both declare dependencies []. lez_core was only ever a transitive dependency (rln 0.7.0 -> lez_rln 2.1.0 -> lez_core 0.4.1). None of the RLN or delivery stack is needed for a LEZ demo.

The modules that call lez_core today are:
- core modules in lez-programs: token_module, amm_module, stablecoin_module. They are universal C++ modules and call it through modules().lez_core.
- UI modules: lez_wallet_ui, the lez-programs amm/token apps and rln_membership_ui.

Every inter-module call path ends in logos-protocol's lp_* C API, then LogosAPIClient, then QtRO over LocalSocket, directly between the two modules' logos_host_qt child processes. This covers generated C++ wrappers, Rust SDK clients and LogosAPI::getClient. Before the first call to a target, the caller gets a per-target token from capability_module. So the only host requirements are these:
- capability_module must be in a modules dir; liblogos loads it at start.
- The thread that called logos_core_start must run a Qt event loop.
- No "enforce" access policy may be set. Declared dependencies only matter under enforce, for auto-loading and for generating the typed wrappers at build time.

Recommendation: ship capability_module, lez_core and a tiny purpose-built universal C++ probe module. It would be about 80-120 lines, modeled on test_ipc_new_api_module. The probe calls lez_core.version(), account_id_to_base58 and account_id_from_base58. Upstream docs say these need no open wallet and no network. The result is a deterministic, offline cross-module round-trip. As a stretch, run the unmodified upstream token_module.programInfo() against lez_core; it needs no glue code, but it costs an Android build of the Rust token_ffi crate (risc0).

### Claims
- [C1|critical|verified-from-source] The logos-modules-dev README statement 'lez_core is here as a dependency of liblogos_lez_rln_module' is stale. It was true for lez-rln <=2.x, including the catalog's recorded submodule pointer f8ab37c (version 2.0.0, dependencies ["lez_core"]). Commit 46caed6 (2026-09-14, 3.1.0) changed dependencies to [] and removed the lez_core dependency_override. Current main (60ac0a5, 4.0.3) has no module dependencies. The catalog builds from the branch tip, so new catalog builds of liblogos_lez_rln_module no longer need lez_core.
- [C2|high|verified-from-source] liblogos_lez_rln_module and liblogos_rln_module are both defined in logos-co/logos-rln-modules. They live in the directories logos-lez-rln-module/ and logos-rln-module/, each with its own flake; the root flake aggregates them. Both are Rust cdylib modules built by logos-module-builder. logos-lez-rln is not a Logos module: it holds the on-chain LEZ programs (a RISC Zero registration program plus an incremental Merkle tree program).
- [C3|high|verified-from-source] liblogos_lez_rln_module 4.x is the RLN registry provider. It has 7 methods: get_valid_roots, get_merkle_proofs, register_member, get_native_balance, get_membership, get_registry_bounds, wallet_status. It reads the on-chain membership registry (Merkle roots, proofs, membership PDA state, config bounds) and submits Register transactions. It uses its own in-process wallet: wallet.rs declares the prebuilt LEZ libwallet_ffi C API (wallet_ffi_open, wallet_ffi_get_account_public, wallet_ffi_send_generic_public_transaction...), which the flake wires in as externalLibInputs.wallet_ffi from the logos-execution-zone flake. It needs a sequencer (LEZ_RLN_SEQUENCER) and a funded payer for writes.
- [C4|high|verified-from-source] Before 3.0.0, liblogos_lez_rln_module used lez_core only through inter-module calls. From Rust it called the raw logos-protocol lp_* C API: lp_client_create(target "lez_core", origin "core"), then lp_invoke / lp_invoke_async for exactly three methods: account_id_from_base58, get_account_public and send_generic_public_transaction. It did not link LEZ native code.
- [C5|high|verified-from-source] liblogos_rln_module (0.8.2) manages RLN membership: it generates credentials, keeps an encrypted keystore, runs the registration lifecycle, and generates and verifies zerokit proofs. It declares dependencies ["liblogos_lez_rln_module"], using a hand-maintained dependency_overrides LIDL. It calls that module through the Rust SDK's generated LiblogosLezRlnModuleClient *_async_with_timeout methods (get_membership, register_member, get_merkle_proofs, get_valid_roots, get_registry_bounds, wallet_status, get_native_balance). It also calls rln_gifter_module through an untyped PluginProxy, although that module is not in its dependencies. It links zerokit (rln = 3.0.0) and ships the tree_depth_10 arkzkey/graph resources.
- [C6|critical|verified-from-source] The Electron POC's delivery_module pulled in the RLN chain only because its delivery lgx declared dependencies ["liblogos_rln_module"]. That declaration exists only on the logos-delivery-module branch impl-plugable-rln-api-module, where RlnBridge calls modules().liblogos_rln_module when the node runs lez RLN. lez_core was purely transitive: rln 0.7.0 -> lez_rln 2.1.0 -> lez_core 0.4.1. Delivery master (origin/master 11243e2) and the modules-dev pointer 3770771 declare dependencies [] and bundle librln directly. git log --all -S liblogos_rln_module finds only branch commits.
- [C7|medium|inferred] The Electron POC README tells you to build delivery from the default branch (github:logos-co/logos-delivery-module#lgx and #liblogos_rln_module-lgx). That does not match the lgx actually installed, whose dependencies match the RLN branch. So the POC's RLN chain came from a branch build, not from master.
- [C8|high|verified-from-source] None of delivery_module, liblogos_rln_module or liblogos_lez_rln_module is needed for a standalone LEZ demo. lez_core declares dependencies [] and only needs its own libwallet_ffi.
- [C9|high|verified-from-source] The modules that depend on or call lez_core today are listed below. UI-type consumers are unsuitable for a headless Android demo. No other code in /home/fryorcraken/src/logos-co or /home/fryorcraken/src/logos-blockchain references lez_core.
- token_module, amm_module and stablecoin_module (lez-programs/modules; logos-amm-module wraps amm). These are universal C++ core modules that call modules().lez_core.* (account_id_to_base58/from_base58, get_account_public, list_accounts, send_generic_public_transaction).
- lez_wallet_ui (ui_qml). It uses the typed m_logos->lez_core.* wrappers, plus raw getClient("lez_core")->invokeRemoteMethod for transfer_private/shielded/deshielded.
- rln_membership_ui (ui_qml). Its QML bridge calls lez_core open, create_new, save, sync_to_block, get_current_block_height and create_account_public.
- The lez-programs amm and token apps (ui_qml).
- [C10|critical|verified-from-source] lez_core has methods that run entirely locally: name(), version(), account_id_to_base58 and account_id_from_base58. None of them touch walletHandle. wallet_ffi_account_id_to_base58 is just AccountId::new(bytes).to_string(). The upstream doctest describes account_id_to_base58 as needing 'no open wallet and no network'. version() returns "0.3.0" even though metadata.json says 0.4.0.
- [C11|medium|verified-from-source] Upstream token_module, unmodified, makes purely local cross-module calls to lez_core from programInfo() when TOKEN_PROGRAM_ID is set. normalizeAccountId calls lez_core.account_id_from_base58 for input that is not hex, and account_id_to_base58 produces the base58 id. The cost is a second Rust cdylib, token_ffi (lee_core v0.2.4, token_core, risc0-zkvm =3.0.5), which would have to be cross-compiled for Android. lez-programs also pins lez_core to rev acf0cd50 (0.4.1-interim), not LEZ-module main.
- [C12|critical|verified-from-source] All module-to-module call styles end up in the same place. Generated universal C++ modules().dep wrappers (logos::LpClient), the Rust SDK typed clients and PluginProxy, and modules().dynamic(name) all use logos-protocol's lp_* C API. lp_client_create constructs a LogosAPIClient(target, origin, TokenManager::forIdentity(origin), transports) on the Qt main thread, and lp_invoke calls LogosAPIClient::invokeRemoteMethod. LogosAPI::getClient(name) returns the same LogosAPIClient class directly.
- [C13|critical|verified-from-source] Module A gets authorized to call B through a per-target token that capability_module issues. If A has no token for B, LogosAPIClient first waits until B is acquirable, then calls mintAndCacheToken. That calls capability_module.requestModule, which checks three things: that the caller is a named module or the host (taken from the RPC caller document, not the self-reported fromModuleName), that B is loaded (its token is in the host token registry), and the access policy (fail-open by default). It then mints a UUID token, pushes it to B with informModuleToken, and returns it to A, which caches it. ModuleProxy rejects empty or unknown tokens, so calls fail without capability_module.
- [C14|high|verified-from-source] B does not have to be listed in A's metadata dependencies for the call to be allowed at runtime, unless the host installs an access policy with mode "enforce". The default is 'any loaded module may call any other'. Declared dependencies are used in three places: to generate typed wrappers at build time (which needs the dependency's LIDL from a same-named flake input or a dependency_overrides file), for auto-loading with LOGOS_LOAD_REQUIRED_DEPS, and for the derived allow-list under enforce. A module can call undeclared targets by name through modules().dynamic("name"); rln_module does this with PluginProxy to rln_gifter_module.
- [C15|critical|verified-from-source] Each module runs in its own logos_host_qt child process. The subprocess container is the only ModuleContainer implementation. Each child publishes its provider over QtRO at local:logos_<module>_<LOGOS_INSTANCE_ID>, over a QLocalSocket, which is the default LogosTransportConfig. An A->B call therefore goes straight from A's child process to B's child process (plus A to capability_module's child for the token) and does not pass through the host process. LogosMode::Local (the in-process PluginRegistry, documented as being for 'mobile apps, single process') exists in logos-protocol, but no code in liblogos, the loader or the container sets it, and basecamp has it commented out.
- [C16|critical|verified-from-source] For A->B calls to work, the host has to do the following:
- Put capability_module in a modules dir (liblogos ships it under $out/modules). logos_core_start calls initializeCapabilityModule, which returns false with no warning if the module is unknown.
- Keep a Qt event loop running on the thread that called logos_core_start. Core's token notifications and restriction pushes are posted to that thread.
- Either set no enforce policy, or declare the dependencies.
- Set a persistence base path for any module that needs one.
The host carries none of the A->B traffic itself.
- [C17|medium|verified-from-source] Qt documents Qt Remote Objects over local: URLs as the way for two Qt processes on Android (for example a service process and the app) to talk. So the QtRO LocalSocket transport liblogos uses between modules is supported on Android. Whether liblogos can spawn logos_host children from an app is a separate question.
- [C18|high|inferred] The RLN pair is a poor Android demo of inter-module calls:
- liblogos_rln_module links zerokit and ships arkzkey resources; its plugin was 20 MB on x86_64 in the Electron POC.
- liblogos_lez_rln_module 4.x links libwallet_ffi, probably a second copy next to lez_core's 108 MB x86_64 one.
- It needs a sequencer and a funded payer.
- The only rln->lez_rln call that stays off the chain, wallet_status, happens inside a background worker that start() launches.
- [C19|high|verified-from-source] A purpose-built universal C++ probe module that calls lez_core would be small: roughly 80-120 lines across metadata.json, header, cpp, CMakeLists and flake. It would follow logos-module-builder/templates/minimal-module plus test_ipc_new_api_module, which calls its dependencies through modules().<dep>. Building it needs only lez_core's LIDL: either the lez_core flake input's cheap `lidl` output (header-to-lidl, no wallet build) or a hand-written dependency_overrides LIDL like lez-rln 2.x's deps/lez_core.lidl.
- [C20|medium|inferred] A known race: according to a comment in lez_wallet_ui, its first call to lez_core can arrive before the capability/token handshake settles and come back as a default value (0 or ""). The UI's workaround is to call version() first and retry until the answer is non-empty. The current protocol waits until the target is acquirable before minting a token, which may already fix this; that is not verified.

### Open questions
- Can an Android app spawn a logos_host_qt child process for each module (for example an executable packaged as lib*.so in nativeLibraryDir)? If it cannot, liblogos has no in-process ModuleContainer and LogosMode::Local is not wired into the runtime, so inter-module calls would need a new container implementation.
- On Android, where do the QtRO local socket files land? A relative 'logos_<mod>_<id>' name resolves under QDir::tempPath(). Is that path within the socket-name length limit and allowed by SELinux for the app's child processes?
- Does lez-rln at logos-rln-modules rev 0079db0 (feat/lip-alignment, which delivery's RLN branch pins) still depend on lez_core? That rev is not in the local clone.
- Do lez_core create_new and open need network access (sequencer calibration or sync)? That decides whether a wallet-backed demo call can run offline.
- Which default features of risc0-zkvm (=3.0.5) does token_ffi pull in, and do they cross-compile for aarch64-linux-android? This only matters for the token_module stretch demo.
- Do logos_host children inherit the parent's environment (for example TOKEN_PROGRAM_ID for token_module) under the subprocess container?
- Is the lez_wallet_ui warm-up race (first call returns a default value before the token handshake completes) still present with the current logos-protocol readiness-gated handshake?

### Recommendations
- Ship three modules on Android: capability_module (from the liblogos build, required for tokens), lez_core, and a new purpose-built universal C++ probe module. Do not ship delivery_module, liblogos_rln_module or liblogos_lez_rln_module.
- Probe module (for example lez_probe): metadata dependencies ["lez_core"], interface "universal", concurrency single, and a hand-written dependency_overrides LIDL listing only name/version/account_id_to_base58/account_id_from_base58, so the build never touches the LEZ flake. One method, roundTrip(hex64), calls modules().lez_core.version(), then account_id_to_base58(hex), then account_id_from_base58(b58), and returns {lezVersion, base58, hexBack, ok: hexBack==hex}. This is deterministic and offline, and the host and module processes' logs make the cross-module hop easy to see.
- App flow: logos_core_add_modules_dir(dir containing capability_module, lez_core, lez_probe), then logos_core_set_persistence_base_path, then logos_core_start() on a thread that runs a Qt event loop, then logos_core_load_module("lez_probe", LOGOS_LOAD_REQUIRED_DEPS), which brings up lez_core first. Then call lez_probe.roundTrip from the host through LogosAPIClient (in-process Qt C++, as in Electron 0.3.0). Do not set an access policy at first.
- As proof, show both processes' logs: the capability_module requestModule and token push, 'LogosAPIClient: invoking remote method lez_core account_id_to_base58' in lez_probe's host, and the encoded value in the UI. Add a retry or warm-up on the first call in case of the handshake race.
- Stretch 1, still no glue code: load the unmodified upstream token_module and call programInfo() with TOKEN_PROGRAM_ID set in the app environment. This costs an Android cross-build of the Rust token_ffi crate (risc0-zkvm), so attempt it only once lez_core's own wallet_ffi Android build works.
- Stretch 2, network: have the probe call lez_core open/get_current_block_height against the testnet sequencer, only after the offline round-trip works.
- Before the PoC commits to the subprocess model, check on Android that logos_host_qt children can be spawned and that QtRO local sockets work.
- Report upstream that the logos-modules-dev README line 29 is stale, and that the logos-lez-rln-module README still says '9 methods' and 'never the C ABI' although wallet.rs declares the wallet_ffi C API.

### Verifier (non-confirmed only)
- [C6] partially-correct: The historical part is right. The Electron POC's delivery lgx (0.2.1) declared the required dependency ["liblogos_rln_module"], lez_core was only transitive (rln 0.7.0 -> lez_rln 2.1.0 -> lez_core 0.4.1), and the RlnBridge code came from impl-plugable-rln-api-module. The claims about CURRENT master are wrong because the local delivery-module clone is stale: .git/FETCH_HEAD is dated 2026-09-08, before the Electron POC build on 2026-09-17. Upstream master today is 4eb3b5b (lastModified 2026-09-24). It is version 0.3.0 and has RlnBridge merged (rlnBridgeEnable, rlnRespond, rlnState, rln*Request events). It declares "dependencies": [] plus "optional_dependencies": ["liblogos_rln_module"], pinned to logos-rln-modules main@6569702. Its flake re-exports packages liblogos_rln_module-lgx and liblogos_lez_rln_module-lgx. So 'git log --all -S finds only branch commits' only reflects the stale clone, and the chain HAS changed: RLN is now an optional dependency on master. The Electron POC README and CI build '#liblogos_rln_module-lgx', '#liblogos_lez_rln_module-lgx' and '#lez_core-lgx' from the default branch with no ref, which suggests master exposed those outputs by 09-17. The exact intermediate history cannot be checked locally. lez_core is still not needed: current rln 0.8.x / lez_rln 4.x have no lez_core edge, and current master exports no lez_core-lgx.
- [C16] partially-correct: Two problems. (1) The event-loop requirement is conditional. runOnOwner and logos_core.h say core's outbound calls run INLINE when made from the thread that called logos_core_start (or when there is no QCoreApplication). They are posted to that thread only when loads come from another thread, and only then must the owner pump its event loop. The Electron POC 0.1.0 loaded modules without the loop ever running. A->B traffic is child-to-child, so a single-threaded host needs no persistent pump for it. (2) The list omits the hard host requirement that liblogos must find and exec the logos_host_qt binary. The lookup order is LOGOS_HOST_PATH, then next to boost::dll::program_location(), then <first modulesDir>/../bin, looking for the exact names logos_host_qt or logos_host. On Android, program_location is app_process and Android 10+ forbids execve() of files in the app's writable home directory. So the host must ship logos_host_qt inside the APK (e.g. nativeLibraryDir) and set LOGOS_HOST_PATH. The rest is confirmed: capability_module must be present (liblogos bundles it in $out/modules together with an optional modules_state), and initializeCapabilityModule returns false silently if it is unknown.
- [C19] partially-correct: The approach is right: a universal C++ module whose dependency is resolved from lez_core's cheap `lidl` output or from a dependency_overrides LIDL. The size estimate is low. The unmodified minimal-module template alone is already about 118 lines (impl.cpp 16, impl.h 35, CMakeLists 28, flake.nix 14, metadata.json 25). Adding three wrapper calls plus result formatting and retry handling gives roughly 150-200 lines. Also note test-ipc-module-new-api has no flake.nix of its own. Declaring lez_core as optional_dependencies instead of dependencies would also avoid bundling it.

Confirmed: C1, C2, C3, C4, C5, C8, C9, C10, C12, C13, C14, C15, C18

### Verifier missed findings
- Local clones of several repos are stale, and some conclusions depend on it. logos-delivery-module was last fetched on 2026-09-08 (.git/FETCH_HEAD). logos-execution-zone-module is at HEAD b220144 (2026-08-27, metadata 0.4.0) and lacks the modules-dev pointer 51eadfb and the rln pin 0ea57f8 ('bad object'). Upstream is newer: delivery 4eb3b5b (0.3.0, 2026-09-24), lez_core 825d2a4 (0.4.2, 2026-09-14), liblogos db45024 vs local 7fee75b. logos-rln-modules local matches upstream (8bc94f0). Evidence: nix flake prefetch outputs for each repo; git -C .../logos-execution-zone-module log -1 51eadfb -> unknown revision.
- Current logos-delivery-module master (0.3.0) treats RLN as an OPTIONAL dependency. It declares optional_dependencies ["liblogos_rln_module"], RlnBridge is merged, and the flake re-exports liblogos_rln_module-lgx and liblogos_lez_rln_module-lgx. Loading delivery with LOGOS_LOAD_REQUIRED_DEPS therefore does not pull RLN; LOGOS_LOAD_REQUIRED_AND_OPTIONAL does, if RLN is installed. Evidence: /nix/store/7xr7ryn9g8qarkz51kxbp378brm0knig-source/metadata.json:13-14 and flake.nix:145-154.
- logos_core_load_module now takes a LogosLoadDeps enum (LOGOS_LOAD_MODULE_ONLY=0, LOGOS_LOAD_REQUIRED_DEPS=1, LOGOS_LOAD_REQUIRED_AND_OPTIONAL=2) instead of a bool, and there is a new logos_core_optional_load_report(). The Android host binding must use this signature. Evidence: /home/fryorcraken/src/logos-co/logos-liblogos/src/logos_core/logos_core.h:72-94,140,157; logos_core.cpp:47-70.
- The metadata field optional_dependencies is a first-class mechanism. It generates a typed wrapper from the target's LIDL, the target is 'never loaded, never bundled, and never built', and it still counts in the enforce-mode allow-list. It is a clean way for a probe module to reference lez_core without bundling or building lez_core's 108 MB wallet_ffi. Evidence: /home/fryorcraken/src/logos-co/logos-module-builder/lib/common.nix:176,202-215; module_manager.cpp:468-474; logos-module-builder commit 6e46d91 (tests/fixtures/universal-optional-deps).
- First-call race: the first cross-module call to lez_core can go out before capability_module has told the target about the caller's token. The call then resolves to a default-constructed value, and for an int return that looks like success. The upstream wallet UI works around this by warming up with lez_core.version() and retrying until it is non-empty. A probe demo should do the same, or check the logos::CallError out-param, rather than trust the first reply. Evidence: /home/fryorcraken/src/logos-blockchain/logos-execution-zone-wallet-ui/src/LEZWalletBackend.cpp:257-271.
- lez_core builds are fragmented and not interchangeable. Upstream main 825d2a4 is 0.4.2 on LEZ v0.2.5-rc2. lez-programs pins lez_core acf0cd50 ('0.4.1-interim', wallet-ffi v0.2.4), with the comment that 'release v0.4.1/0.4.2 pin a much newer wallet-ffi that cannot' load a wallet written by the v0.2.4 CLI. logos-rln-modules shadow-publishes lez_core 0.4.1 (rev 0ea57f8) because 'the official catalog's lez_core ... 0.4.0 bundles a wallet-ffi that cannot parse the chain's privacy-preserving transactions — wallet sync wedges forever at the first one (testnet block 1078)'. This matters for the token_module stretch goal and for any wallet or network use, though not for the offline base58 methods. Evidence: /home/fryorcraken/src/logos-blockchain/lez-programs/flake.nix:34-59; /home/fryorcraken/src/logos-co/logos-rln-modules/.github/workflows/release.yml:44-54; /nix/store/8y6lph8knxjv64qm1ljd7cqy98wlcszc-source/flake.nix:13.
- The stretch demo token_module.programInfo() makes NO call to lez_core unless the token_module child process has the TOKEN_PROGRAM_ID or TOKEN_PROGRAM_BIN environment variable set. Without either it returns an empty object. With a hex TOKEN_PROGRAM_ID it calls lez_core.account_id_to_base58; with a base58 id it calls account_id_from_base58. On Android the variable must reach the spawned logos_host_qt child through the host's environment. Evidence: /home/fryorcraken/src/logos-blockchain/lez-programs/modules/token/src/token_module_impl.cpp:31-32,197-200,208-217,242,249-254,275-276,394-396.
- Host requirement for any load (and so for any inter-module demo): liblogos must exec a separate logos_host_qt binary per module. It is found via LOGOS_HOST_PATH, then next to boost::dll::program_location(), then <first modulesDir>/../bin, with exact names logos_host_qt or logos_host. On Android, program_location is app_process, and apps targeting API 29+ cannot execve files in their writable home directory. The binary must therefore ship in the APK (e.g. as lib*.so in nativeLibraryDir) with LOGOS_HOST_PATH pointing at it. Evidence: /home/fryorcraken/src/logos-co/logos-module-loader-qt/src/qt_plugin_format_loader.cpp:109-149; https://developer.android.com/about/versions/10/behavior-changes-10.
- capability_module's ability to mint and push tokens depends on the host granting it the token_registry and token_delivery services. logos-module-loader-qt grants them from a hardcoded table matched on the exact name 'capability_module', passed on the child's command line as --host-services. The module must keep that name, and a custom loader or container on Android would have to reproduce the grant. Evidence: /home/fryorcraken/src/logos-co/logos-module-loader-qt/src/qt_plugin_format_loader.cpp:24-62; /home/fryorcraken/src/logos-co/logos-capability-module/src/capability_module_impl.cpp:99-106,155-163; logos-capability-module/metadata.json:34-35.
- liblogos also bundles and auto-starts an optional modules_state module (the lifecycle feed) in logos_core_start after capability_module, but only if it is installed. An Android build can leave it out. Evidence: /home/fryorcraken/src/logos-co/logos-liblogos/src/logos_core/logos_core.cpp:29-32; module_manager.cpp:1279-1296; flake.nix:135-138.
- The pins in the logos-rln-modules flakes are inconsistent. The root flake uses adklempner/logos-execution-zone rev efad872, but logos-lez-rln-module/flake.nix uses rev 8e2b119, despite its comment 'Must match the root flake's pin'. The root flake also still builds lez_core (logos-wallet-module rev 0ea57f8) as its 'wallet-module' output, and logos-rln-module's liblogos_lez_rln_module input tracks main with no rev. Evidence: /home/fryorcraken/src/logos-co/logos-rln-modules/flake.nix:22-27,71; logos-lez-rln-module/flake.nix:23-27; logos-rln-module/flake.nix:16.

---

## Full report

## RLN modules, lez_core, and the Android inter-module demo

### 1. Is lez_core a dependency of liblogos_lez_rln_module? Only in older versions

`/home/fryorcraken/src/logos-co/logos-modules-dev/README.md:29` says: *"`lez_core` is here as a dependency of `liblogos_lez_rln_module`."* This is out of date.

- The catalog's recorded submodule pointer for logos-rln-modules is `f8ab37c` (`git -C logos-modules-dev ls-tree HEAD submodules/`). At that rev, `logos-lez-rln-module/metadata.json` is version 2.0.0 with `"dependencies": ["lez_core"]` and a `dependency_overrides` entry pointing at `rust-lib/deps/lez_core.lidl`. So the statement was true when it was written.
- Commit `46caed6` (2026-09-14, "feat!: liblogos_lez_rln_module on LEZ v0.2.5, owning its wallet in-process (3.1.0)") replaced `"dependencies": ["lez_core"]` with `"dependencies": []`, dropped the override, and added `external_libraries: wallet_ffi`. The commit message says: *"a consumer that used to open the wallet through lez_core must now wait on this module's own readiness instead. The lez_core dependency lidl is gone with it."*
- Current main (`60ac0a5`, 4.0.3): `/home/fryorcraken/src/logos-co/logos-rln-modules/logos-lez-rln-module/metadata.json:12` has `"dependencies": []`.
- Per its own README (lines 45-49), modules-dev builds from the branch tip. New catalog builds of `liblogos_lez_rln_module` therefore no longer need `lez_core`. The README line describes the recorded pointer, not what the catalog builds today.

### 2. Where the RLN modules live and what they do

Both modules are in **`/home/fryorcraken/src/logos-co/logos-rln-modules`**, each in its own flake, with the root flake aggregating them (`flake.nix:31-32`):

| Directory | Module | Kind |
|---|---|---|
| `logos-lez-rln-module/` | `liblogos_lez_rln_module` 4.0.3 | Rust cdylib, `concurrency: multi` |
| `logos-rln-module/` | `liblogos_rln_module` 0.8.2 | Rust cdylib |
| `logos-rln-membership-ui/` | `rln_membership_ui` | `ui_qml` |

`/home/fryorcraken/src/logos-co/logos-lez-rln` is **not a module**. It holds the on-chain LEZ programs (README:3): a RISC Zero *registration program* and an *incremental Merkle tree program* (depth 9, 512 leaves, split into a top tree plus 16 subtree PDAs, README:76-117). Registration debits native balance, creates a membership PDA and chain-calls the tree to insert `hash(id_commitment, rate_limit)` (README:148). `logos-delivery-module` master defines neither RLN module.

**What lez-rln actually does.** It keeps an RLN membership registry as an LEZ program. `liblogos_lez_rln_module` is the chain-access provider: it reads the tree's valid Merkle roots, Merkle proofs, membership PDA state and config bounds, and submits Register transactions (`rust-lib/liblogos_lez_rln_module.lidl:43-100`). Its 7 methods are `get_valid_roots`, `get_merkle_proofs`, `register_member`, `get_native_balance`, `get_membership`, `get_registry_bounds` and `wallet_status`. The module README still says "9 methods", which is stale after 4.0.0.

**How it uses lez_core.**
- **Today (3.x/4.x) it does not.** It links LEZ's prebuilt wallet library directly:
  - `flake.nix:45-56` wires in `wallet_ffi = { input = inputs.logos-execution-zone; packages.default = "wallet"; }`.
  - `rust-lib/src/wallet.rs:188-244` declares `extern "C" { fn wallet_ffi_open ...; fn wallet_ffi_get_account_public ...; fn wallet_ffi_send_generic_public_transaction ... }`.
  - The README (92-99) explains why: a host has only one `lez_core` wallet handle, it cannot be closed, and it cannot be given the ~9.1M-cycle gas limit that registration needs.
  - Configuration is through `LEZ_RLN_SEQUENCER`, `LEZ_RLN_PAYER`, `LEZ_RLN_PAYER_KEY` and `LEE_WALLET_HOME_DIR` (lidl:16-19).
- **Up to 2.x it used inter-module calls only.**
  - `git show 46caed6^:logos-lez-rln-module/rust-lib/deps/lez_core.lidl` lists the consumed subset: `account_id_from_base58`, `get_account_public` and `send_generic_public_transaction`.
  - The Rust code called the raw logos-protocol C API: `lp_client_create` (lib.rs:197, target `"lez_core"`, origin `"core"`), then `lp_invoke` / `lp_invoke_async` (lib.rs:284,318).

**liblogos_rln_module** is the "registry-agnostic RLN membership management" module:
- It generates credentials inside the module, keeps an Argon2id/XChaCha-sealed keystore, runs the registration lifecycle, and generates and verifies zerokit proofs (README).
- It links `rln = 3.0.0` (zerokit; Cargo.toml:37) and ships `resources/tree_depth_10/{graph.bin,rln_final.arkzkey}` (about 2.1 MB).
- `metadata.json:12-27` declares `"dependencies": ["liblogos_lez_rln_module"]`, with a hand-maintained override LIDL.
- It calls the sibling through the Rust SDK's generated typed client: `LiblogosLezRlnModuleClient::*_async_with_timeout` for `get_membership`, `register_member`, `get_merkle_proofs`, `get_valid_roots`, `get_registry_bounds`, `wallet_status` and `get_native_balance` (`rust-lib/src/provider.rs:36,415-569`).
- It also calls `rln_gifter_module.request` through an untyped `PluginProxy` (provider.rs:194-218), although that module is not in its metadata dependencies.
- It never calls `lez_core`.

### 3. Why the Electron POC's delivery_module pulled in the RLN chain

The POC's installed manifests show the chain:

- `modules/delivery_module/manifest.json`: 0.2.1, `"dependencies": ["liblogos_rln_module"]`
- `modules/liblogos_rln_module/manifest.json`: 0.7.0, depends on `liblogos_lez_rln_module`
- `modules/liblogos_lez_rln_module/manifest.json`: **2.1.0**, depends on `lez_core`
- `modules/lez_core/manifest.json`: 0.4.1, `[]`

The Makefile (54-58) records the same chain: `delivery_module -> liblogos_rln_module -> liblogos_lez_rln_module -> lez_core`. **lez_core was never a dependency of delivery itself.** It came in only through RLN relay: delivery → rln → lez_rln 2.x → lez_core.

In delivery-module, the RLN dependency exists **only on the branch `origin/impl-plugable-rln-api-module`**:
- There, metadata declares `"dependencies": ["liblogos_rln_module"]`.
- The flake pins `liblogos_rln_module.url = ".../logos-rln-modules?ref=feat/lip-alignment&rev=0079db05...&dir=logos-rln-module"`.
- `src/rln_bridge.{h,cpp}` serves the Nim library's rln* callbacks by calling `modules().liblogos_rln_module` (delivery_module_plugin.cpp:287), but only when the node runs lez RLN (`rln-lez`).

On `origin/master` (11243e2) and at the modules-dev pointer `3770771`, delivery has `"dependencies": []` and bundles `librln` directly (flake `externalLibInputs.rln`). `git log --all -S liblogos_rln_module` finds only branch commits (5738c5f…74b2e8e). So:
- The POC's delivery lgx was a branch build, even though its README (340-343) says to build from the default branch. This is inferred.
- In current delivery master the chain is gone.
- Even on the branch, it would no longer reach `lez_core` with current lez-rln (≥3.0.0). I could not check the branch's pinned rev `0079db0`, because it is not in the local clone.

**None of this is needed for a standalone LEZ demo.** `lez_core` declares `[]` (`logos-execution-zone-module/metadata.json:15`) and needs only its own `libwallet_ffi.so`. That library is 108,567,024 bytes in the POC's x86_64 dev bundle, next to a 2.4 MB plugin.

### 4. Every lez_core consumer, and how suitable each is as a demo

`grep -rl lez_core` across both roots, repo source files only, finds:

| Consumer | Type | lez_core calls | Extra native weight | Network | Local-only call? |
|---|---|---|---|---|---|
| `token_module` (lez-programs/modules/token) | core, universal C++ | `modules().lez_core.account_id_to_base58` (impl.cpp:254), `account_id_from_base58` (276), `get_account_public` (286), `list_accounts` (324), `send_generic_public_transaction` (512) | Rust `token_ffi` cdylib (lee_core v0.2.4, token_core, risc0-zkvm =3.0.5) | reads and txs need a sequencer | **Yes**: `programInfo()` with `TOKEN_PROGRAM_ID` set (impl.cpp:202-265, 394-404) |
| `amm_module` (lez-programs/modules/amm; `logos-amm-module` is a flake wrapper) | core, universal C++ | `account_id_from_base58` (295), `get_account_public`, `list_accounts`, many `send_generic_public_transaction` | Rust `amm_ffi` | yes | only the base58 normalisation inside other calls |
| `stablecoin_module` | core, universal C++ | `account_id_from_base58` (217), `get_account_public` (224), `send_generic_public_transaction` (309) | Rust `stablecoin_ffi` | yes | same as amm |
| `lez_wallet_ui` | ui_qml | typed `m_logos->lez_core.*` (open, list_accounts, sync…), plus raw `m_logosAPI->getClient("lez_core")->invokeRemoteMethod("lez_core","transfer_private",…)` (LEZWalletBackend.cpp:505-557) | QML UI stack | yes | `version()` warm-up |
| `rln_membership_ui` | ui_qml | QML `bridge.callModuleAsync` for `open`, `create_new`, `save`, `sync_to_block`, `get_current_block_height`, `create_account_public` (OnboardingFlow.qml:228-493) | QML plus the whole RLN stack | yes | no |
| lez-programs apps/amm, apps/token | ui_qml | through the shared `LogosWalletProvider.cpp` | QML | yes | no |
| `liblogos_lez_rln_module` ≤2.x (historical) | Rust cdylib | the 3 methods in §2 | wallet not linked; `lez_core` did chain access | yes | only `account_id_from_base58` |

`lez_core`'s local-only surface is verified. `name()`, `version()`, `account_id_to_base58` and `account_id_from_base58` never touch `walletHandle` (lez_core_module.cpp:278-284, 423-449), and `wallet_ffi_account_id_to_base58` is `AccountId::new(bytes).to_string()` (logos-execution-zone/lez/wallet-ffi/src/keys.rs:188-206). The module's own doctest (`doctests/logos-execution-zone-runtime.test.yaml:223-259`) calls it "a pure encoding helper … no open wallet and no network required, so it runs entirely offline", and uses the base58 round-trip as its IPC proof. Two small quirks: `version()` returns "0.3.0" while metadata says 0.4.0. And `lez_wallet_ui` has a comment (257-271) about the first call racing the capability handshake; it warms up with `version()` and retries.

**Assessment.**
- *RLN pair.* This is the worst candidate:
  - rln links zerokit and its plugin was 20 MB on x86_64.
  - lez_rln 4.x links libwallet_ffi again.
  - Both need a sequencer, a funded payer and a persistence path.
  - Their only cross-module call that stays off the chain (`wallet_status`) runs inside a background worker that `start()` launches (`ensure.rs`), so it cannot be observed or driven directly.
- *token_module.* The best **existing** module: it is unmodified upstream code, so it involves no glue at all. `programInfo()` with `TOKEN_PROGRAM_ID=<base58>` makes two local calls to `lez_core` (from_base58, then to_base58). The cost is an Android build of `token_ffi` (risc0-zkvm and friends). lez-programs also pins `lez_core` to rev `acf0cd50` (0.4.1-interim), not LEZ-module main. Those two methods are stable by name and arity, so it is inferred compatible.
- *Purpose-built probe.* The cleanest option. `test_ipc_new_api_module` (logos-test-modules) is the reference: metadata `dependencies: ["test_basic_module", "test_extlib_module"]`, and every method is one line such as `return modules().test_basic_module.echo(input);`. Its impl.cpp is 180 lines and impl.h 94, and it covers far more than we need. A `lez_probe` built from `templates/minimal-module` (flake of 14 lines, metadata of 25) plus a header of about 15 lines and a cpp of about 25 lines comes to **roughly 80-120 lines**.
  - Its only build input beyond the builder is `lez_core`'s LIDL. That can come from the `lez_core` flake input's `lidl` output, which is a cheap `--header-to-lidl` derivation with no wallet build (mkLogosModule.nix:950-969). It can also come from a 3-method hand-written `dependency_overrides` file, which has a direct precedent in lez-rln 2.x's `deps/lez_core.lidl`.
  - It adds no native libraries beyond what every module already needs.

### 5. How inter-module calls work today

**Every call style ends in the same place:** logos-protocol's `lp_*` C API, then `LogosAPIClient`.
- Universal C++ modules get generated `LogosModules` wrappers. The Lp style (`generator_lib.cpp:1877-1958`) builds one `logos::LpClient(target, origin)` per declared dependency, plus `dynamic(name)` for by-name calls. `LpClient` calls `lp_client_create` / `lp_invoke` (`logos-cpp-sdk/cpp/logos_lp_client.h:1-16,282,506`).
- Rust modules use the Rust SDK's typed clients or `PluginProxy`, which sit on the same C API (provider.rs:9-29).
- Qt code uses `LogosAPI::getClient(name)` (`logos-plugin-qt/cpp/logos_api.h:295`).
- `lp_client_create` constructs `new LogosAPIClient(target, origin, &TokenManager::forIdentity(origin), targetCfg, capabilityCfg)` on the Qt main thread, and `lp_invoke` calls `invokeRemoteMethod` (`logos-protocol/cpp/logos_protocol.cpp:245-317,357-394`).

**Authorization is a token handshake through capability_module** (`logos_api_client.cpp:114-239`):
1. If A has no token for B, A waits until B is acquirable (`ensureTargetAcquirable`).
2. A calls `mintAndCacheToken`, which invokes `capability_module.requestModule(capToken, A, B)`.
3. capability_module (`capability_module_impl.cpp:60-167`) checks:
   - who is calling, from the RPC caller document the host pushed in, not from the self-reported name;
   - that B is loaded (`logos::host::tokenFor(B)` is non-empty);
   - the access policy, which fails open.
4. It then mints a UUID token, pushes it to B with `informModuleTokenTo` (3 s timeout), and returns it to A.
5. A caches the token and calls B with it. A stale token gets one re-exchange.

`ModuleProxy` rejects empty or unknown tokens (`module_proxy.h:133-139`). **Without capability_module, module-to-module calls fail.**

**Does B have to be in A's metadata dependencies? Not at runtime, by default.**
- `ModuleManager::setAccessPolicy` logs *"Inter-module access enforcement is OFF (no access policy set): any loaded module may call any other"* (module_manager.cpp:1142-1145).
- Only `logos_core_set_access_policy({"mode":"enforce",…})` turns on deny-by-default, where *"a module may only call the modules it declares as dependencies"* (1162-1165, allow-lists derived at 439-478; `core` and `core_service` are always trusted).
- Declared dependencies matter for three things:
  - build-time typed wrappers: the builder resolves each name to the same-named flake input's `packages.<sys>.lidl`, or to a `dependency_overrides` file (`logos-module-builder/lib/common.nix:167-236`);
  - `LOGOS_LOAD_REQUIRED_DEPS` auto-loading (`logos_core.h:72-93`);
  - the enforce allow-list.
- A module can call an undeclared target through `modules().dynamic("name")`, or `PluginProxy` in Rust.

**Transport.** liblogos loads every module into its own `logos_host_qt` child process (`logos-module-loader-qt/README.md:15-31`). `logos-container-subprocess` is the only `ModuleContainer` implementation; in-process, Docker and WASM are only mentioned as possibilities (README:9-12). Each child publishes its provider over QtRO at `local:logos_<module>_<LOGOS_INSTANCE_ID>` (`logos_instance.h:27-29`), and the default `LogosTransportConfig` is `LocalSocket` (`logos_transport_config.h:18,30`). An A→B call therefore goes **directly from A's child process to B's over a QLocalSocket**, plus A to capability_module's child for the token. **The host process carries none of that traffic.**

`LogosMode::Local` (in-process `PluginRegistry`, "mobile apps, single process"; `logos_mode.h:7-18`, `plugin_registry.h`) exists, but nothing in liblogos, the loader or the container sets it, and basecamp has it commented out (`app/main.cpp:86`). It is not a supported runtime path today. On Android, Qt documents QtRO `local:` connections between processes, for example a service process and the app (https://doc.qt.io/qt-6/android-services.html). So the transport itself is supported there; spawning `logos_host_qt` children from an app is the open risk.

**What the host has to do:**
1. Put `capability_module` in a modules dir. liblogos bundles it under `$out/modules` (flake.nix:131-139, nix/modules.nix). `logos_core_start` → `initializeCapabilityModule` returns false with no warning if it is not known (module_manager.cpp:1298-1311).
2. Keep a Qt event loop running on the thread that called `logos_core_start`. Core's token notifications and restriction pushes are posted to that owner thread (`runOnOwner`, 335-366; `notifyCapabilityModule`, 508-527).
3. Set no enforce policy, or keep the dependencies declared.
4. Set `logos_core_set_persistence_base_path` for modules that need it.
5. Load both modules. `LOGOS_LOAD_REQUIRED_DEPS` on A brings B up first.

### 6. Recommended module set and demo

**Modules:** `capability_module` (from the liblogos build), `lez_core`, and a new `lez_probe` (universal C++; `dependencies: ["lez_core"]`; `dependency_overrides` with a local LIDL listing `name`, `version`, `account_id_to_base58` and `account_id_from_base58`). No delivery or RLN modules.

**Demo:** the app calls `lez_probe.roundTrip("aa…aa")` through the host's in-process LogosAPIClient, as in Electron 0.3.0. Inside `lez_probe`:
1. `modules().lez_core.version()` (warm-up, and it shows which LEZ version answered)
2. `modules().lez_core.account_id_to_base58(hex)`
3. `modules().lez_core.account_id_from_base58(b58)`
4. It returns `{lezVersion, base58, hexBack, ok}`.

This is deterministic and offline, and it needs no wallet. The hop is visible in three places: `lez_probe`'s host log, capability_module's `requestModule` / token-push logs, and `lez_core`'s dispatch. Only the app → probe call involves host code; probe → lez_core goes entirely through liblogos's own generated wrappers, lp_* and QtRO.

**Stretch:**
1. Unmodified upstream `token_module.programInfo()` with `TOKEN_PROGRAM_ID` set: no glue at all, but it needs an Android `token_ffi` build.
2. A network call (`lez_core.open` / `get_current_block_height`) against the testnet sequencer.

Sources: [Qt Android Services](https://doc.qt.io/qt-6/android-services.html), [QLocalSocket](https://doc.qt.io/qt-6/qlocalsocket.html), [Qt Remote Objects Nodes](https://doc.qt.io/qt-6/qtremoteobjects-node.html).
