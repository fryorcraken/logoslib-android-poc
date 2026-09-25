# Desktop probe: lez_core under liblogos

> Research track `desktop-probe`, 2026-09-25. Written by a research agent and then checked by a
> second, adversarial agent, whose non-confirmed verdicts are listed under "Verifier".
> Claims are tagged verified-from-source / verified-by-experiment / inferred / open.
> Absolute paths point at the author's local checkouts (`~/src/logos-co`,
> `~/src/logos-blockchain`) at the revisions in [../investigation.md](../investigation.md);
> `.work/` paths are local scratch, not committed. The synthesis is in
> [../investigation.md](../investigation.md).


### Summary
Desktop probe succeeded end to end on Linux x86_64. Nix built logoscore (logos-logoscore-cli 6a0a2f4), lgpm (logos-package-manager 2c56ec7) and the lez_core 0.4.2 .lgx (logos-execution-zone-module 825d2a4) in about 5 minutes. Only 57+4+3 derivations had to be built because the Rust deps were already in the local store; the Logos binary cache is not used because this user is not a trusted Nix user. The .lgx was installed with lgpm and loaded headless into a logoscore daemon. lez_core has no module dependencies. Only the built-in capability_module and modules_state start with core, and a load-module takes about 27-40 ms. Over the liblogos transport the probe did: 40-method introspection; offline calls (name, version, wallet_dir, base58 encode/decode round-trip); real wallet work (create_new, 2 local account derivations, list_accounts, get_public_account_key, save); and one read-only testnet call, get_current_block_height = 23791 from https://testnet.lez.logos.co/ in 671 ms. create_new takes about 35 s because it makes 100 sequential calibration requests to the sequencer. That is longer than the fixed 20 s core_service RPC deadline, so the client times out while the module finishes anyway. Reopening the wallet with calibration_limit=5 takes 1.08 s. The RLN module no longer calls lez_core, so inter-module calls were shown with a small universal module (lez_probe, built in 15 s, dependency lez_core) that uses the generated modules().lez_core client. Calls succeed in 0-2 ms. ss shows a direct unix-socket connection from the lez_probe host process to lez_core's host process, plus one to capability_module; if capability_module is missing, module-to-module calls are refused. Runtime model: one logos_host_qt subprocess per module; QtRO local sockets named logos_<module>_<instanceId> under QDir::tempPath() (/tmp, or TMPDIR, relocation verified); the 108-byte sun_path limit caused a capability_module crash when the path was too long; no QPA platform plugin is needed. Native payload: the lez_core host maps 58 .so files (188 MiB). The union across the daemon and all hosts is 72 files (201.9 MiB). libwallet_ffi.so alone is 108.6 MB raw, 104.1 MB stripped and 68.3 MB gzipped; it embeds a ~60 MB zip (RISC Zero recursion markers) plus about 18 embedded ELF images, and it needs libpcsclite. liblogos_core also pulls in liblgx, which brings ICU (~37.7 MiB mapped), libsodium and zlib.

### Claims
- [C1|critical|verified-by-experiment] lez_core can be brought up headless under liblogos on Linux x86_64 using only published flakes: logoscore dev CLI + lgpm + the LEZ module's #lgx output. Daemon status is OK after ~232-236 ms. `load-module lez_core` returns ok in 27 ms (first run) and 38-40 ms (reload, or together with a dependent).
- [C2|high|verified-by-experiment] Build cost on this machine was small because the Rust dependency closure was already in the local store: 57 derivations for logoscore (liblogos, protocol, SDKs, capability and modules_state modules), 4 for the lez_core lgx (including the wallet-ffi crate itself), 3 for lgpm; wall time about 5 min in total. The Logos Attic cache in the flake nixConfig is ignored ('ignoring untrusted flake configuration setting extra-substituters') because trusted-users=root. Free space on / was 70-71G before and after. Closure sizes: logoscore 827.5 MiB, lez_core lib 735.1 MiB, lgx 66.8 MiB, lgpm 81.8 MiB.
- [C3|critical|verified-by-experiment] lez_core 0.4.2 declares no module dependencies and loads alone. The only other modules running are the two built into logoscore (capability_module, started and granted token_registry,token_delivery host services; modules_state). The Electron POC chain (delivery_module -> liblogos_rln_module -> liblogos_lez_rln_module -> lez_core) no longer applies: liblogos_lez_rln_module 4.0.3 declares dependencies [] and links wallet_ffi itself instead of calling lez_core.
- [C4|high|verified-by-experiment] The real API surface of the built lez_core (0.4.2, from `logoscore module-info`) has 40 methods and 0 events. It differs from the local checkout's header (0.4.0): send_generic_public_transaction takes an extra payer_account_id_hex, and send_program_deployment_transaction is (QString,QStringList,QByteArray,bool,QString). Use module-info or the generated lez_core.lidl as the contract, not the local source. `version()` returns a hardcoded "0.3.0".
- [C5|critical|verified-by-experiment] Offline calls through the daemon, about 15-17 ms each including the CLI process start: name -> "lez_core"; version -> "0.3.0"; wallet_dir -> <persistence-path>/lez_core/<instanceId>; account_id_to_base58(64x 'a') -> CVDFLCAjXhVWiPXH9nTCTpCgVzmDVoiPzNJYuccr1dqB; account_id_from_base58 of that value round-trips to the input; invalid base58 -> "" (logged as wallet FFI error 10). With no wallet open, get_sequencer_addr returns "" and list_accounts returns [] (logged 'Null wallet handle').
- [C6|high|verified-by-experiment] Real work with a wallet: create_new(<wdir>/wallet_config.json, storage.json, statistics.json, password) writes a default config pointing at https://testnet.lez.logos.co/ and takes about 35 s, because WalletCore::new runs 100 sequential calibration requests (calibration_limit 100) against the sequencer. core_service forwards `call` with the default 20 s Timeout(), so the CLI gets METHOD_FAILED/timeout even though the module completes. lez_core dispatches calls one at a time, so the next call (get_sequencer_addr) waited 14.9 s. After that: 2x create_account_public (16-20 ms each), list_accounts (4 accounts: the 2 new ones plus 1 public and 1 private created by create_new), get_public_account_key and save (1.0 s) all succeeded.
- [C7|high|verified-by-experiment] One read-only network call worked: get_current_block_height -> 23791 from the public LEZ testnet sequencer (https://testnet.lez.logos.co/) in 671 ms. get_last_synced_block -> 0. No transaction was submitted.
- [C8|medium|verified-by-experiment] App-restart path: after unload-module/load-module (66 ms / 38 ms) the module keeps the same persistence instance id and wallet files. open() on the existing files, after lowering calibration_limit from 100 to 5 in wallet_config.json, finished in 1.08 s, within the 20 s deadline, and list_accounts returned the 4 persisted accounts.
- [C9|high|verified-by-experiment] The wallet's storage.json is plaintext JSON containing secret key material (secret_spending_key, viewing_secret_key, sk, authorization_secret_key, ...). The password passed to create_new is ignored upstream.
- [C10|critical|verified-by-experiment] Inter-module calls through liblogos' own transport work with no hand-written IPC. A 5-file universal module (lez_probe; metadata dependencies ["lez_core"]; flake input named lez_core; calls modules().lez_core.*) built in 15 s. `load-module lez_probe` auto-loaded lez_core first (dependencies_loaded:["lez_core"]). Calls lez_probe.lez_version / to_base58_via_lez / roundtrip_via_lez returned lez_core's results ("0.3.0", CVDFL..., a 2-call round-trip in 0-2 ms). ss shows the lez_probe host process with a direct unix-stream connection to /tmp/logos_lez_core_<inst>, owned by lez_core's logos_host, and one to capability_module's socket. The same edge is allowed under --access-policy enforce ('Registered access restriction for target: lez_core (3 allowed callers)').
- [C11|high|verified-by-experiment] capability_module is required for module-to-module calls. In run3, capability_module failed to listen and crashed; lez_probe -> lez_core then failed after 20 s ('Timeout waiting for replica: capability_module'; lez_core: 'rejecting unauthorized call ... auth token not recognized'). core_service -> lez_core, the CLI's direct call, still worked.
- [C12|critical|verified-by-experiment] Process model: each module runs in its own logos_host_qt subprocess spawned by the daemon, including capability_module and modules_state. Arguments: --name, --path <plugin.so>, --instance-persistence-path, --transport-set <base64 JSON> (capability_module), --host-services (capability_module only), --token-source stdin. The host is located via LOGOS_HOST_PATH (set by the logoscore wrapper). The subprocess container is chosen at build time (default logos-container-subprocess); no in-process container implementation exists in the local sources.
- [C13|critical|verified-by-experiment] Transport sockets are QtRO local servers named logos_<module>_<instanceId>. The relative name is resolved under QDir::tempPath(), which is /tmp by default. Setting TMPDIR relocated all 5 sockets (core_service, capability_module, modules_state, lez_core, lez_probe), and they were removed on clean stop. A socket path of 108 bytes (the sun_path limit) made capability_module fail to listen (HostNotFoundError) and crash with SIGSEGV; a 104-byte path worked.
- [C14|medium|verified-by-experiment] No Qt platform plugin or display is needed. With QT_QPA_PLATFORM, DISPLAY and WAYLAND_DISPLAY all unset, the daemon plus 4 module hosts ran and served calls. No qt-6/plugins .so was mapped by any process. The host environment carried LOGOS_HOST_PATH, QT_PLUGIN_PATH, TMPDIR and LOGOS_INSTANCE_ID.
- [C15|critical|verified-by-experiment] lez_core's native payload is dominated by libwallet_ffi.so (Rust): 108,567,024 B raw, 104,096,488 B stripped, 68,259,299 B gzip -9. Sections: .rodata 72.4 MB, .text 27.4 MB. The .rodata holds an embedded zip spanning about 12.4-72 MB (34 PK headers, ~1.3-2.8 MB members); risc0/recursion/zkr markers suggest RISC Zero recursion circuits (inferred). It also holds 18 embedded ELF images. lez_core_plugin.so is 2,426,624 B raw / 1,983,344 B stripped / 726,469 B gzip. wallet_ffi exports 58 wallet_ffi_* functions.
- [C16|critical|verified-by-experiment] Measured loaded closure from /proc/<pid>/maps: the lez_core host maps 58 .so files (188 MiB). Daemon: 67 files (90 MiB). Each built-in module host: 56 files (85 MiB). Union across daemon + 4 hosts: 72 files, 211,683,608 B (201.9 MiB), grouped as wallet_ffi 103.5 MiB, ICU 37.7 MiB, other desktop system libs (glib, systemd, krb5, curl, libproxy, ...) 17.8, Qt6 Core/Network/RemoteObjects 12.7, logos runtime 11.9, openssl 8.4, glibc 3.6, libstdc++/libgcc 3.6, lez_core plugin 2.3, boost 0.4. Much of the 'other' and ICU weight comes from nixpkgs' desktop Qt build and will not carry over to Android as-is (inferred).
- [C17|high|verified-by-experiment] Stripped sizes of the Logos runtime pieces (x86_64): liblogos_core 0.93 MB, liblogos_protocol 2.44 MB (36 lp_* exports), liblogos_qt_host 0.33 MB, liblgx 0.88 MB, libpackage_manager_lib 0.64 MB, logos_host_qt 2.05 MB, capability_module_plugin 2.43 MB, modules_state_plugin 2.54 MB, lez_probe_plugin 1.92 MB. For scale, desktop Qt: Core 7.1 MB, Network 2.2 MB, RemoteObjects 1.3 MB; openssl libcrypto 6.7 MB + libssl 1.1 MB. Universal module plugins and logos_host_qt statically embed the SDK: none of them NEED any liblogos_*.so; they need only Qt6 Core/Network/RemoteObjects, boost_system, ssl/crypto (+ spdlog/fmt for the host).
- [C18|high|verified-by-experiment] liblogos_core.so has a hard link-time dependency on libpackage_manager_lib and liblgx. liblgx in turn NEEDS ICU (libicuuc, libicui18n; icudata 31.9 MB mapped), libsodium and zlib. In liblogos, liblgx is used for semver range checks in the dependency gate. liblogos_core also NEEDS boost_process/context/filesystem/date_time/atomic/system, spdlog, fmt and Qt RemoteObjects/Network/Core. The exported C API is exactly 20 logos_core_* functions.
- [C19|high|verified-by-experiment] libwallet_ffi.so NEEDS libpcsclite.so.1 because the LEZ wallet crate unconditionally depends on keycard_wallet (pcsc = "2") for smart-card support. There is no Android pcsclite, so an Android build needs this feature-gated out or stubbed (inferred).
- [C20|high|verified-by-experiment] A lez_core plugin built against an older SDK stack (module-builder 6ef42ea 2026-07-01, logos-protocol 976bc7a 2026-06-30) loads and serves calls, including module-to-module calls, in a host from liblogos db45024 (2026-09-22, logos-protocol 8bbc027 2026-09-17). Both stacks use Qt 6.9.2 from nixpkgs e9f00bd; plugin RUNPATHs point at qtbase-6.9.2 and qtremoteobjects-6.9.2.
- [C21|medium|verified-by-experiment] An .lgx is a tar.gz containing manifest.json and variants/<variant>/{plugin.so, bundled libs}. lgpm install copies a variant's files into <modules-dir>/<name>/ with a manifest.json whose 'main' maps variant -> file, plus a 'variant' file. Nix dev builds use the variant 'linux-amd64-dev'. liblgx owns the variant vocabulary (lgx_host_variant) and lgpm appends '-dev' for non-portable builds. No Android variant name was found in the local package-manager, liblogos, module-builder or nix-bundle-lgx sources.
- [C22|medium|verified-by-experiment] A running logoscore daemon does not rescan its modules dir. After `lgpm install` of lez_probe, load-module failed ('Module not found in known modules: lez_probe') until the daemon was restarted. liblogos exposes logos_core_refresh_modules() for this, but the logoscore CLI has no command that calls it.
- [C23|medium|verified-by-experiment] Resource and latency figures on this machine: idle host RSS about 24 MB (capability_module, modules_state), lez_core host 26.8 MB loaded and 34.5 MB with a wallet open, daemon about 30 MB. Cold start to lez_probe + lez_core loaded: 297 ms. 20 sequential CLI round trips (40 lez_core calls, each CLI a new process) took 330 ms. In-module cross-module latency is 0-2 ms per 2 calls.
- [C24|medium|verified-by-experiment] State written at runtime when --config-dir and --persistence-path are given: the config dir holds client/{auto.json,config.json}, daemon/{tokens.json,tokens/auto.json} and daemon/state.json (removed on stop). Each module gets <persistence>/<module>/<12-hex instanceId>/, the same id across unload/reload. lez_core's wallet files go wherever the caller points them (here its wallet_dir). The only /tmp use is the sockets. Rust println! from wallet_ffi reaches the daemon log as '[out] [lez_core] ...' (captured host stdout, appeared buffered).
- [C25|low|verified-by-experiment] The ready-made alternative caller of lez_core, token_module from lez-programs (dependencies ["lez_core"]; calls modules().lez_core.account_id_to_base58/from_base58/get_account_public/list_accounts), would need 1035 derivations built plus 167 paths fetched (826.4 MiB download, 2.8 GiB unpacked), and it pins its own lez_core rev acf0cd5. It was skipped as a large extra build.
- [C26|medium|open] On Android, QDir::tempPath() (and so the socket directory) is reportedly not /tmp. A search result says QtLoader sets TMPDIR to the app cache dir, while QTBUG-98502 reports tempPath() returning the app files dir. Neither was verified here: the Jira page could not be fetched.

### Open questions
- Does logos-execution-zone's wallet crate (risc0-zkvm, rapidsnark/circuits, keycard/pcsc) cross-compile for aarch64-linux-android, and can pcsc and the RISC Zero recursion-circuit payload (~60 MB zip in .rodata) be feature-gated out without losing needed functionality (e.g. private/shielded transfers that prove locally)?
- What variant name would an Android .lgx use? liblgx's lgx_host_variant() owns the vocabulary, and no 'android' spelling appears in the local package-manager, liblogos, module-builder or nix-bundle-lgx sources (logos-package source not inspected).
- Is there any in-process ModuleContainer implementation, or must Android exec a logos_host_qt binary shipped in nativeLibraryDir? liblogos picks the container at build time (default logos-container-subprocess), and module_container.h only mentions in-process as a possibility.
- What exactly does QDir::tempPath() return in a Qt 6.9 Android app (cache dir via TMPDIR set by QtLoader vs files dir per QTBUG-98502)? Is the resulting logos_<module>_<12-hex> socket path safely under 108 bytes for long package names?
- How long do create_new/open calibration and the first sync take on a phone over mobile data? The fixed 20 s core_service Timeout() is already exceeded on desktop with the default calibration_limit=100.
- Can liblgx be built without ICU for Android? liblogos only uses it for semver (dependency_gate.cpp); ICU was 37.7 MiB of the desktop mapped set.
- Wallet-ffi from-scratch build time was not measured: its cargo deps derivation was already in the local store. A clean machine, or a cross build, will pay the full Rust + risc0 dependency compile.

### Recommendations
- Use the reproduction below (all state kept in .work/probe) as the reference 'known good' desktop baseline for the Android port: logoscore 6a0a2f4 + lgpm 2c56ec7 + lez_core lgx 825d2a4. Use `logoscore module-info lez_core` (or the generated lez_core.lidl) as the API contract; the local checkout's header is stale.
- For the Android 'real work' demo, use offline calls first (account_id_to_base58/from_base58, then create_new + create_account_public + list_accounts), then get_current_block_height against https://testnet.lez.logos.co/ as the single network call.
- Before create_new/open on Android, pre-write wallet_config.json with a small multi_sequencer_client_config.calibration_limit (5 worked: open in 1.08 s). Call through an in-process LogosAPIClient with an explicit Timeout well above 20 s, because lez_core runs one call at a time and a long call blocks every later call.
- For inter-module communication on Android, reuse the lez_probe pattern (.work/probe/src/lez_probe: universal module, dependencies ["lez_core"], flake input named lez_core, modules().lez_core.*). It builds in 15 s with the same module-builder rev as lez_core. Do not plan on RLN calling lez_core: it no longer does. token_module is a real consumer but costs 1035 derivations.
- Ship capability_module alongside any user modules. Without it every module-to-module call is refused ('auth token not recognized'); only the core_service path keeps working.
- Point TMPDIR (or the Android equivalent QDir::tempPath) at a SHORT app-private directory. Keep dir length at or below about 70 bytes so 'logos_capability_module_<12hex>' fits in the 108-byte sun_path; a too-long path crashes capability_module.
- Plan the APK native budget around libwallet_ffi (104 MB stripped, ~68 MB compressed for x86_64). Investigate feature-gating the keycard/pcsc dependency and the embedded RISC Zero zkr archive. Keep the Logos runtime itself small: runtime + host + 2 built-in modules ≈ 12 MB stripped, plus Android Qt Core/Network/RemoteObjects and OpenSSL.
- Budget for removing or rebuilding liblgx without ICU (used only for semver in liblogos' dependency gate), and for boost_process being linked into liblogos_core. Both come from the subprocess/package-manager design and are desktop-weighted.
- Treat the lez_core wallet dir as secret storage: storage.json holds plaintext spending/viewing keys and the password is ignored upstream. On Android keep it in app-private storage and consider Keystore-backed encryption at the app layer.
- If modules are installed at runtime on Android, call logos_core_refresh_modules() after installing. The logoscore CLI has no rescan command, and a daemon that is not refreshed does not see newly installed modules.

### Verifier (non-confirmed only)
(no verifier)

---

## Full report

## desktop-probe: lez_core under liblogos_core on Linux x86_64 (via Nix)

### TL;DR

lez_core runs headless under liblogos on this machine using only published flakes. The steps were: build the logoscore dev CLI, lgpm and the LEZ module's `#lgx`; install the .lgx with lgpm; start a logoscore daemon; `load-module lez_core`; call its methods.

- **Offline calls work:** base58 codec, name, version, wallet_dir.
- **Real wallet work:** create_new, local key derivation, list_accounts, get_public_account_key, save.
- **One read-only testnet call:** `get_current_block_height` returned 23791 from `https://testnet.lez.logos.co/` in 671 ms.
- **Inter-module calls through liblogos' own transport:** shown with a 5-file universal module (`lez_probe`) that calls `modules().lez_core.*`. RLN no longer calls lez_core, so it could not be used.
- **Payload:** dominated by `libwallet_ffi.so` (Rust): 108.6 MB raw, 104.1 MB stripped.

Everything below was observed running unless marked otherwise. All artifacts are under `/home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/probe`; scripts are under `.work/scripts/probe-*.sh`.

### 1. Flakes inspected (no build)

`nix flake show` results:

| Flake | Resolved rev | Relevant outputs |
|---|---|---|
| `github:logos-blockchain/logos-execution-zone-module` | `825d2a41` | `lgx`, `lgx-portable`, `lib`, `lez_core-lidl`, `headers-*` (package version 0.4.2) |
| `github:logos-co/logos-logoscore-cli` | `6a0a2f4e` | `cli` (logoscore), `ctl` (logosctl), `*-bundle-dir`, `*-appimage`; also has `x86_64-windows` |
| `github:logos-co/logos-liblogos` | `db45024f` | `logos-liblogos{,-bin,-lib,-include,-modules}`, `portable` |
| `github:logos-co/logos-package-manager` | `2c56ec7b` | `cli`, `cli-portable`, `cli-bundle-dir`, `lib` |

The local checkouts are behind GitHub:
- LEZ module: local `b2201442` (metadata 0.4.0) vs GitHub `825d2a4` (0.4.2).
- logoscore-cli: local `4e8c739` vs GitHub `6a0a2f4`.
- liblogos: local `7fee75b` vs GitHub `db45024`.

### 2. Build cost and caches

- The LEZ flake's `nixConfig.extra-substituters = https://cache.nix.logos.co/public` is ignored. The user is not a trusted Nix user (`nix config show trusted-users` → `root`; substituters → only cache.nixos.org), and nix warns `ignoring untrusted flake configuration setting 'extra-substituters'`.
- Even so, dry runs showed small builds because the heavy Rust dependency closure was already in the local store:
  - logoscore `#cli`: 57 derivations (liblogos, logos-protocol, cpp/qt SDKs, module-loader-qt, container, capability and modules_state modules, …).
  - LEZ `#lgx`: 4 derivations, including `logos-execution-zone-wallet-ffi-0.1.0` itself. Its `…-wallet-ffi-deps` crane derivation, `rapidsnark-0.0.8`, `logos-blockchain-circuits-0.5.3` and a pre-fetched zip were already present.
  - lgpm `#cli`: 3 derivations.
- Actual builds: lgpm under 1 min, lez lgx about 2 min, logoscore about 5 min, run in parallel.
- Free space on `/` was 70G before and 71G after. Closure sizes (`nix path-info -Sh`): logoscore 827.5 MiB, lez_core lib 735.1 MiB, lgx 66.8 MiB, lgpm 81.8 MiB.
- Caveat: a clean machine, or a cross build, pays the full wallet-ffi dependency compile. That was not measured here.

### 3. Bring-up: exact reproduction

```
nix build github:logos-co/logos-logoscore-cli/6a0a2f4e96aa078a0a30080595075bcf46fb9a5d#cli -o .work/probe/logos
nix build github:logos-co/logos-package-manager/2c56ec7bf1e187523d6ed0cb2abde04737c24414#cli -o .work/probe/lgpm
nix build github:logos-blockchain/logos-execution-zone-module/825d2a41262b9882aa0f9ca837cb03635f7980c2#lgx -o .work/probe/lez-lgx
bash .work/scripts/probe-install-lez.sh     # lgpm --modules-dir modules --allow-unsigned install --file lez-lgx/*.lgx
bash .work/scripts/probe-daemon-start.sh    # seeds capability_module+modules_state, starts daemon, loads lez_core
bash .work/scripts/probe-calls-offline.sh
bash .work/scripts/probe-calls-wallet.sh
bash .work/scripts/probe-reopen.sh
bash .work/scripts/probe-daemon-stop.sh
bash .work/scripts/probe-build-lezprobe.sh  # builds the inter-module caller
bash .work/scripts/probe-intermodule2.sh    # fresh daemon, load lez_probe (auto-loads lez_core), cross-module calls
bash .work/scripts/probe-run3-tmpdir.sh     # TMPDIR-relocated sockets, no QPA, --access-policy enforce
```

The daemon is started as `logoscore --config-dir .work/probe/cfg -D -m .work/probe/modules --persistence-path .work/probe/persist`, so nothing is written to `~/.logoscore`. It follows the recipe in the module's own doctest (`/home/fryorcraken/src/logos-blockchain/logos-execution-zone-module/doctests/logos-execution-zone-runtime.test.yaml`), including seeding the modules dir with logoscore's built-in modules (`cp -RL ./logos/modules/. ./modules/`).

**What loads, and in what order:**
- `lez_core` manifest: `"dependencies": []`, version 0.4.2, `main: {"linux-amd64-dev": "lez_core_plugin.so"}`.
- At daemon start: `Granting host services to 'capability_module': token_registry,token_delivery` → `Module loaded: capability_module` → `Module loaded: modules_state`.
- Then `load-module lez_core` → `{"dependencies_loaded":[],"status":"ok","version":"0.4.2"}` in **27 ms** (38 ms on reload).
- Daemon status was OK after about 235 ms.
- There is no deeper chain. The Electron POC's `delivery → rln → lez_rln → lez_core` chain is gone upstream: `liblogos_lez_rln_module` 4.0.3 declares `"dependencies": []`, with the comment "No module-level dependencies since 3.0.0: this module links wallet_ffi and holds its own wallet handle rather than calling the lez_core module" (`logos-rln-modules/logos-lez-rln-module/flake.nix:13-15`).

### 4. API surface (as built)

`logoscore module-info lez_core --json` lists **40 methods and no events**:
- name, version, wallet_dir;
- create_new, open, save, restore_storage;
- create_account_public/private, list_accounts;
- get_balance, get_account_public/private, get_public_account_key, get_private_account_keys;
- account_id_to/from_base58;
- sync_to_block, get_last_synced_block, get_current_block_height;
- six transfer_* variants;
- authenticated_transfer_elf, token_elf, amm_elf, ata_elf (QByteArray);
- send_generic_public_transaction(QStringList,QVariantList,QByteArray,QString,**QString**), send_generic_private_transaction, send_program_deployment_transaction(QString,QStringList,QByteArray,bool,QString);
- poll_transaction_status, bridge_withdraw, get_sequencer_addr;
- 4 label methods.

The signatures differ from the local 0.4.0 header, so treat module-info or the generated `lez_core.lidl` as the contract. `version()` is hardcoded to "0.3.0" (`lez_core_module.cpp:282-283`).

### 5. A working "real work" call sequence

**Offline** (each about 15-17 ms including the CLI process spawn):

| Call | Result |
|---|---|
| `name` | "lez_core" |
| `version` | "0.3.0" |
| `wallet_dir` | `…/persist/lez_core/89bde9c7c80f` (the module's persistence dir) |
| `account_id_to_base58 aaaa…(64)` | `CVDFLCAjXhVWiPXH9nTCTpCgVzmDVoiPzNJYuccr1dqB` |
| `account_id_from_base58` of that | the original 64-hex value (round trip OK) |
| `account_id_from_base58 '!!!not-base58!!!'` | `""` (log: `wallet FFI error 10`) |

**Wallet** (paths inside wallet_dir):
- `create_new <wdir>/wallet_config.json <wdir>/storage.json <wdir>/statistics.json str:<pw>` writes a default config: sequencer `https://testnet.lez.logos.co/`, `calibration_limit: 100`.
- The call takes about **35 s**: `WalletCore::new` → `MultiSequencerClient::new` runs 100 sequential calibration requests (`multi_client.rs:491`).
- core_service forwards `call` with the transport default `Timeout()` of 20 s (`logos-logoscore-cli/src/core_service/core_service_impl.cpp:544`). The CLI therefore gets `METHOD_FAILED … timed out after 20000ms`, but the module finishes the work.
- lez_core dispatches one call at a time, so the next call (`get_sequencer_addr`) waited 14.9 s before answering `https://testnet.lez.logos.co/`.
- After that:
  - `create_account_public` ×2: 16-20 ms each, returns a 64-hex id.
  - `list_accounts`: 4 accounts (2 new, plus 1 public and 1 private created at create_new).
  - `get_public_account_key <id>` → a 64-hex key.
  - `save` → 0, in 1.0 s.
- **Network (one read-only call):** `get_current_block_height` → **23791** in **671 ms**. No transaction was submitted.
- **Restart path:**
  - `unload-module` / `load-module` keep the same instance id and files.
  - With `calibration_limit` lowered to 5, `open(...)` → 0 in **1.08 s**, and `list_accounts` returns the 4 persisted accounts.
- **Security note:** `storage.json` (35 KB) is plaintext JSON with `secret_spending_key`, `viewing_secret_key`, `sk`, `authorization_secret_key`, and so on. The password is ignored upstream (`lez/wallet/src/storage.rs:33-35`, "TODO: Use password for storage encryption").

### 6. Inter-module communication

**Why lez_probe:** RLN no longer calls lez_core. The existing consumer, `token_module` (lez-programs), would cost 1035 derivations plus 826 MiB of downloads (dry run), so it was skipped.

**What lez_probe is:** a minimal universal module in `.work/probe/src/lez_probe`:
- `metadata.json` with `"dependencies":["lez_core"]`;
- a flake input named `lez_core` pinned to the same LEZ rev;
- `logos-module-builder` pinned to lez_core's own builder rev `6ef42ea`;
- an impl calling `modules().lez_core.version()`, `.account_id_to_base58()` and `.account_id_from_base58()`.

The builder generated `lez_core.lidl` (40 methods) and a typed wrapper `lez_core_api.h (class LezCore)`. The build took **15 s**. No IPC code was hand-written.

**Results on a fresh daemon:**
- `load-module lez_probe` → `{"dependencies_loaded":["lez_core"]}`, so lez_core came up first. Cold start to both loaded: 297 ms.
- `lez_probe.lez_version` → "0.3.0" (lez_core's string).
- `to_base58_via_lez` → `CVDFL…`.
- `roundtrip_via_lez` → `CqMHX… -> afd35f…`, 2 cross-module calls in 0-2 ms.
- 20 CLI round trips (40 lez_core calls) took 330 ms including 20 CLI spawns.
- Daemon log shows both sides: `[lez_probe] -> lez_core.version()` / `<- lez_core.version() = 0.3.0`.

**Process-level proof** (`probe-peers.sh`, matching ss inodes): the lez_probe host (pid 3098318) holds a unix-stream connection whose peer is `/tmp/logos_lez_core_<inst>`, owned by lez_core's `logos_host` (pid 3098316). It holds another to `/tmp/logos_capability_module_<inst>` for the token handshake. The daemon's core_service connects to lez_probe's socket to forward CLI calls.

**Access policy:** under `--access-policy enforce`, the declared edge is allowed (`Registered access restriction for target: lez_core (3 allowed callers)`).

**capability_module is mandatory for module-to-module calls.** When it crashed (section 8):
- lez_probe → lez_core failed after 20 s, with `Timeout waiting for replica: capability_module` and lez_core logging `rejecting unauthorized call … auth token not recognized`.
- core_service → lez_core, the CLI's direct call, still worked.

### 7. Native payload

**lez_core package:**

| File | Raw | Stripped | gzip -9 |
|---|---|---|---|
| libwallet_ffi.so | 108,567,024 | 104,096,488 | 68,259,299 |
| lez_core_plugin.so | 2,426,624 | 1,983,344 | 726,469 |

**What is inside libwallet_ffi.so:**
- `.rodata` 72.4 MB, `.text` 27.4 MB.
- An embedded zip spans roughly bytes 12.4 MB to 72 MB: 34 PK headers, members of 1.3-2.8 MB each.
- Markers `risc0` ×137 and `zkr` ×116 suggest the RISC Zero recursion circuits (inferred). There are also 18 embedded ELF images, which look like guest programs.
- It exports 58 `wallet_ffi_*` functions.
- It NEEDS `libpcsclite.so.1`: keycard smart-card support via `pcsc = "2"` (`logos-execution-zone/Cargo.toml:234`). This has no Android equivalent.
- lez_core_plugin.so NEEDS libwallet_ffi, Qt6 RemoteObjects/Network/Core, boost_system, ssl, crypto and the C/C++ runtime. The Logos SDK is statically linked into the plugin.

**Measured mapped closure** (`/proc/<pid>/maps`, `probe-payload.sh`):
- lez_core host: 58 .so files, 188 MiB.
- daemon: 67 files, 90 MiB.
- each built-in module host: 56 files, 85 MiB.
- **Union of all processes: 72 files, 201.9 MiB.**

| Group | Size |
|---|---|
| wallet_ffi | 103.5 MiB |
| ICU (via liblgx and QtCore) | 37.7 MiB |
| other desktop libs (glib, systemd, krb5, curl, libproxy, pcre2, …) | 17.8 MiB |
| Qt6 Core/Network/RemoteObjects | 12.7 MiB |
| logos runtime | 11.9 MiB |
| openssl | 8.4 MiB |
| glibc | 3.6 MiB |
| libstdc++/libgcc | 3.6 MiB |
| lez_core plugin | 2.3 MiB |
| boost | 0.4 MiB |

No Qt platform plugins are mapped.

**Logos runtime pieces, stripped (x86_64):**
- liblogos_core 0.93 MB. It exports the 20-function `logos_core_*` C API. It NEEDS package_manager_lib, liblgx, boost_process/context/filesystem/date_time/atomic/system, spdlog, fmt, Qt RO/Network/Core, ssl, crypto.
- liblogos_protocol 2.44 MB (36 `lp_*` exports).
- liblogos_qt_host 0.33 MB.
- liblgx 0.88 MB. It NEEDS ICU uc/i18n, libsodium and zlib, and is used by liblogos only for semver in `dependency_gate.cpp`.
- libpackage_manager_lib 0.64 MB.
- logos_host_qt 2.05 MB.
- capability_module_plugin 2.43 MB.
- modules_state_plugin 2.54 MB.

**For scale (desktop builds, stripped):** Qt Core 7.1 MB, Network 2.2 MB, RemoteObjects 1.3 MB; libcrypto 6.7 MB + libssl 1.1 MB.

**Pre-Android estimate (inferred):**
- Logos runtime + host + 2 built-in modules ≈ 12 MB stripped.
- Plus Android Qt Core/Network/RemoteObjects and OpenSSL, roughly 15-20 MB.
- Plus lez_core ≈ 106 MB stripped (about 69 MB compressed), unless the wallet's embedded proving data and pcsc can be trimmed.

### 8. Runtime behaviour that matters for Android

1. **One subprocess per module.** Every module, including capability_module and modules_state, runs in its own `logos_host_qt` process. The binary is found via `LOGOS_HOST_PATH`, which the logoscore wrapper sets (`qt_plugin_format_loader.cpp:121`).
   - Arguments: `--name --path --instance-persistence-path [--transport-set <base64>] [--host-services] --token-source stdin`.
   - The container is chosen at build time (default logos-container-subprocess, `logos-liblogos/src/CMakeLists.txt:140`). No in-process container exists in the local sources.
   - Idle RSS: about 24 MB per host; lez_core 27 MB, rising to 34.5 MB with a wallet open.
2. **Sockets.**
   - QtRO local servers are named `logos_<module>_<12-hex instanceId>` (`logos-protocol/cpp/logos_instance.h:28`) and resolved under `QDir::tempPath()` (`qt_socket_path.h:13-21`), which is `/tmp` by default.
   - Setting `TMPDIR` relocated all sockets. They are removed on clean stop.
   - The **108-byte sun_path limit** is real: with a 108-byte path, capability_module failed to listen (`HostNotFoundError`) and then SIGSEGV'd, and module-to-module auth broke. A 104-byte path worked.
   - What `QDir::tempPath()` returns on Android is open: see QTBUG-98502 and the note that QtLoader sets TMPDIR.
3. **No display needed.** Everything ran with `QT_QPA_PLATFORM`, `DISPLAY` and `WAYLAND_DISPLAY` all unset.
4. **Environment seen in the hosts:** `LOGOS_HOST_PATH`, `QT_PLUGIN_PATH`, `TMPDIR`, `LOGOS_INSTANCE_ID`. The wrapper unsets `LD_LIBRARY_PATH`. Optional: `LOGOS_LOG_LEVEL`, `LOGOS_SOCKET_GROUP`/`LOGOS_SOCKET_MODE`.
5. **Files written:**
   - `<config-dir>/client/{config.json,auto.json}`, `daemon/tokens.json`, `daemon/tokens/auto.json`, and `daemon/state.json` (removed on stop).
   - `<persistence>/<module>/<instanceId>/`, which is stable across reload.
   - The wallet files wherever the caller points them.
   - Wallet `println!` output is captured as `[out] [lez_core]` lines and arrives buffered.
6. **Deadlines and concurrency.** The fixed 20 s RPC deadline, combined with lez_core's one-call-at-a-time dispatch, means slow calls (create_new or open with default calibration, and later syncs or proofs) must be given an explicit longer `Timeout`, or calibration must be reduced.
7. **No rescan.** A running daemon does not see newly installed modules. After installing, call `logos_core_refresh_modules()`.
8. **Version compatibility.** A plugin built with the July SDK stack (module-builder 6ef42ea, logos-protocol 976bc7a) works in a September host (liblogos db45024, logos-protocol 8bbc027). Both use Qt 6.9.2 (nixpkgs e9f00bd).

### 9. What did not work or was skipped

- **create_new via the CLI:** exceeded the 20 s deadline (the work itself completed).
- **token_module as the inter-module consumer:** skipped (1035-derivation build).
- **First TMPDIR run:** a too-long socket dir crashed capability_module.
- **Loading a newly installed module into a running daemon:** failed until the daemon was restarted.
- **The QTBUG-98502 page:** could not be fetched.

