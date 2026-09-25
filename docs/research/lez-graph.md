# LEZ module graph and lez_core API

> Research track `lez-graph`, 2026-09-25. Written by a research agent and then checked by a
> second, adversarial agent, whose non-confirmed verdicts are listed under "Verifier".
> Claims are tagged verified-from-source / verified-by-experiment / inferred / open.
> Absolute paths point at the author's local checkouts (`~/src/logos-co`,
> `~/src/logos-blockchain`) at the revisions in [../investigation.md](../investigation.md);
> `.work/` paths are local scratch, not committed. The synthesis is in
> [../investigation.md](../investigation.md).


### Summary
The module is named `lez_core`, as expected. Its metadata declares no Logos Core module dependencies (`dependencies: []`), it defines no events, and it wraps exactly one native library, `libwallet_ffi.so`. That library is the Rust `wallet-ffi` crate in logos-execution-zone, the LEZ light wallet. At runtime the wallet talks only to an LEZ sequencer, over HTTPS JSON-RPC (default https://testnet.lez.logos.co). It never contacts the L1 or an indexer.

The user's framing "lez_core uses the blockchain module" is wrong at the module level. The L1 (Bedrock / logos-blockchain) matters in three other places:
- **Protocol level, server side:** the sequencer publishes L2 blocks as inscriptions in an L1 channel. This covers data availability, ordering and finality, plus the deposit/withdraw bridge. The indexer rebuilds L2 state by reading that channel from an L1 node.
- **Build level:** wallet_ffi statically links logos-blockchain Rust crates and circuit code.
- **Other modules:** `lez_indexer_module` needs an L1 node URL. `blockchain_module` runs a full L1 node. Neither is a dependency of `lez_core`, in either direction. `liblogos_lez_rln_module` v3+ no longer depends on `lez_core`; it links wallet_ffi itself.

Opening or creating a wallet (`create_new` / `open`) needs a reachable sequencer. On first open the wallet calibrates by sending up to 100 `getLastBlockId` requests. On an already-open wallet, key/account creation, listing and labels are local, and the base58 codec and ELF getters work without any wallet at all.

The public testnet is live (verified by experiment on 2026-09-25: block 23793, pinata faucet account holding 1,481,850, difficulty 3). Its program IDs do not match current LEZ dev HEAD. Whether they match the LEZ commit that `lez_core` main pins is unverified.

Three demo sequences, ranked by how little infrastructure they need:
- **A – offline codec:** no infrastructure at all.
- **B – testnet read path (recommended):** only outbound HTTPS. A real BIP39 wallet, public account creation, a live block height and a real on-chain account read.
- **C – register + pinata PoW claim + balance 150:** version-sensitive, no funds or proving needed. The published lez_core 0.4.1/0.4.2 builds (inspected in /nix/store) removed these methods.

Prebuilt `.lgx` files exist only for darwin-arm64, linux-amd64, linux-arm64 and windows-x86_64, not Android. The native payload is about 100 MB unstripped (70 MB `.lgx`). It needs `libpcsclite.so.1`. Its TLS (rustls-platform-verifier) needs JNI setup on Android.

### Claims
- [C1|critical|verified-from-source] The module's metadata name is `lez_core` (display name 'LEZ Core Module', version 0.4.0 in the local checkout, type core, interface universal, main lez_core_plugin). It declares NO Logos Core module dependencies. Its only external native library is wallet_ffi. name() returns "lez_core", but version() hard-codes "0.3.0", which does not match the metadata.
- [C2|critical|verified-from-source] lez_core wraps libwallet_ffi from the Rust crate `wallet-ffi` (logos-execution-zone/lez/wallet-ffi, crate-type cdylib+staticlib, cbindgen-generated wallet_ffi.h). The flake pins LEZ commit 87fca2a (2026-08-10, dev branch, `git describe` = v0.2.0-399). That commit is not a descendant of release tag v0.2.4. The LEZ flake builds it as packages.<system>.wallet with crane (`-p wallet-ffi`, default features incl. `prove` = risc0-zkvm/prove).
- [C3|critical|verified-from-source] Public API of lez_core (local main): name, version, wallet_dir, create_new, open, save, restore_storage, create_account_public/private, list_accounts, get_balance, get_account_public/private, get_public_account_key, get_private_account_keys, account_id_to_base58/from_base58, sync_to_block, get_last_synced_block, get_current_block_height, claim_pinata (+2 private variants), transfer_public/shielded/deshielded/private/shielded_owned/private_owned, register_public_account/private_account, authenticated_transfer_elf/token_elf/amm_elf/ata_elf, send_generic_public_transaction, send_generic_private_transaction, send_program_deployment_transaction, poll_transaction_status, bridge_withdraw, get_vault_balance, vault_claim, vault_claim_private, get_sequencer_addr, check_label_available, add_label, resolve_label, get_all_labels_for_account. It declares NO events and emits none.
- [C4|critical|verified-from-source] Methods fall into five groups. (a) Purely local, no wallet handle: name, version, account_id_to_base58/from_base58, *_elf (embedded RISC0 program bytes). (b) Local once a wallet is open: create_account_public/private, list_accounts, get_account_private, get_public_account_key, get_private_account_keys, get_last_synced_block, get_sequencer_addr, the label methods, and get_balance(is_public=false). (c) Sequencer reads: get_balance(public) via getAccountBalance, get_account_public (getAccount), get_current_block_height (getLastBlockId), sync_to_block (getBlockRange), poll_transaction_status (getTransaction), get_vault_balance. (d) Sequencer writes with public transactions and no proof: transfer_public, register_public_account, claim_pinata, bridge_withdraw, vault_claim, send_generic_public_transaction, program deployment. (e) Sequencer writes that need a local RISC0 proof: shielded/deshielded/private transfers, private pinata/vault variants, send_generic_private_transaction. No method calls the L1 or an indexer directly.
- [C5|critical|verified-from-source] create_new and open are NOT purely local. WalletCore::new always builds a MultiSequencerClient. For any sequencer URL not already in the statistics file, it calibrates by sending up to calibration_limit (default 100) getLastBlockId requests. If no sequencer answers, choose_leaders returns None ('Failed to find leader'): wallet_ffi_create_new returns a null handle and lez_core.create_new returns an empty string (open returns INTERNAL_ERROR).
- [C6|critical|verified-by-experiment] The default sequencer is https://testnet.lez.logos.co. If the config path does not exist, the wallet writes a default config pointing there. This public testnet is live: checkHealth ok, last block 23792-23793, channel 0101…01, and the pinata faucet account EfQhKQAkX2FJiwNii2WFQsGndjvF1Mzd7RuVe7QdPLw7 holds 1,481,850 with difficulty byte 3. One request takes about 0.34 s on a reused connection and about 1.0 s with a fresh TLS connection.
- [C7|high|inferred] With the default calibration_limit of 100, the first create_new/open against the testnet sends about 100 requests (~34 s at the measured 0.34 s/request). That exceeds the 20 s default Logos IPC call timeout, so a caller would likely see an empty or default reply while the module is still calibrating. Lower multi_sequencer_client_config.calibration_limit in the wallet config JSON (e.g. 3), or pass a longer or infinite Timeout, as the wallet UI does for proving.
- [C8|medium|inferred] Offline wallet creation is possible in principle. Pre-seed statistics.json with an entry for the configured sequencer URL ({latency_avg, latency_var, sample_size, latest_block_id, errors}). setup() then 'actualizes' instead of 'calibrates', and a failed update keeps the key, so choose_leaders still selects that sequencer. After that, create_new/open, create_account_public, list_accounts and labels would run without network.
- [C9|critical|verified-from-source] lez_core never needs an L1 (logos-blockchain) node at runtime, and it has no module-level dependency on blockchain_module. The L1 sits behind the sequencer. The sequencer publishes each L2 block as an inscription on a Bedrock Mantle channel (channel_id) and follows the L1 for adoption, reorgs and finality. It also mints finalized Bedrock deposits on L2 and reconciles withdrawals. bridge_withdraw is an ordinary public L2 transaction to the bridge program; the sequencer carries out the L1 side.
- [C10|high|verified-from-source] 'The L2 uses the L1 for indexing' is imprecise. The L1 is the L2's data-availability, ordering and finality layer, plus the bridge. The LEZ indexer rebuilds L2 state by reading the zone channel's inscriptions from an L1 node, independently of the sequencer. The wallet (lez_core) uses neither the indexer nor the L1: it reads chain state from the sequencer's RPC.
- [C11|critical|verified-from-source] Verdict on 'lez_core uses blockchain module': there is no module-level dependency in either direction. lez_core, blockchain_module and lez_indexer_module all declare dependencies []. lez_indexer_module needs an L1 HTTP endpoint at runtime, but not the blockchain_module. liblogos_lez_rln_module v3+ does NOT depend on lez_core: it links wallet_ffi itself. Modules that DO declare lez_core are lez_wallet_ui, amm_module, token_module, the stablecoin module and rln_membership_ui.
- [C12|high|verified-from-source] The L1 link is a build-time one. wallet_ffi statically links logos-blockchain Rust crates: common → logos-blockchain-common-http-client → logos-blockchain-core → poc/pol/groth16 → logos-blockchain-circuits-*-sys witness libs, plus circuits-prover → rust-rapidsnark. That is why the LEZ flake sets LBC_ROOT_DIR and RAPIDSNARK_LIB_DIR for the wallet build. The circuits-build crate otherwise downloads prebuilt libs named <os>-<arch> from GitHub releases, and the circuits flake only covers x86_64-linux, aarch64-linux, aarch64-darwin and x86_64-windows (no Android).
- [C13|medium|verified-from-source] RISC Zero guest programs are NOT compiled during the build. Prebuilt program ELFs (17 programs of about 0.35-0.52 MB each, plus privacy_preserving_circuit.bin at 0.63 MB, at the pinned commit) are committed under artifacts/ and embedded with include_bytes; their image IDs are computed at build time. risc0 recursion artefacts (zkr zip) are prefetched from S3 by the flake. The `prove` feature pulls in the risc0 prover.
- [C14|high|verified-by-experiment] Native payload of a released lez_core (0.4.2 build found in /nix/store, linux-amd64): libwallet_ffi.so is 108.6 MB, not stripped, with no debug sections (.text 27.4 MB, .rodata 72.4 MB). lez_core_plugin.so is 2.4 MB. The .lgx is 70 MB gzip (111 MB uncompressed) and contains only variants/linux-amd64-dev. libwallet_ffi.so's NEEDED list includes libpcsclite.so.1 (Keycard support is mandatory in the wallet crate). lez_core_plugin.so needs Qt6Core, Qt6RemoteObjects, Qt6Network, boost_system, libssl and libcrypto.
- [C15|high|verified-by-experiment] The upstream-published lez_core (0.4.1 and 0.4.2 builds in /nix/store) has a different API from the local 0.4.0 source. claim_pinata*, register_*_account and vault* are gone. send_generic_public_transaction takes a byte-string instruction plus payer_account_id_hex. send_program_deployment_transaction becomes a program-loader call with a payer. The bundled wallet_ffi.h likewise lacks wallet_ffi_claim_pinata/register/vault and adds program_loader_*. LEZ release v0.2.4 still has the pinata, register and vault FFI functions.
- [C16|critical|verified-by-experiment] The public testnet's program IDs (e.g. authenticated_transfer [583309054,…], pinata [2062635772,…]) do NOT match the image IDs computed for current LEZ dev HEAD (authenticated_transfer [1334061388,…], pinata [3883838627,…]). getProgramIds lists only amm, authenticated_transfer, pinata, privacy_preserving_circuit and token. The program artefacts also differ between v0.2.4, the module's pinned 87fca2a and HEAD, so each produces different program IDs. lez-programs states the deployed sequencer is on the v0.2.4 wallet-ffi line. Write transactions from a lez_core build whose LEZ version differs from the deployed one will probably be rejected.
- [C17|high|verified-from-source] The pinata faucet claim needs a client-side proof of work. The caller must find a u128 solution such that SHA-256(seed[32] || solution.to_le_bytes()) starts with `difficulty` zero bytes (difficulty 3 on testnet, so about 2^24 hashes). lez_core.claim_pinata takes the solution as a 32-hex LE16 string and does not compute it. The prize is 150 per claim, and the CLI first requires the recipient to be initialized (auth-transfer init = register_public_account). At the pinned commit fees are not implemented.
- [C18|high|verified-from-source] Real inter-module consumers of lez_core call it through the generated typed accessors, over Logos IPC (QtRO). amm_module (universal) calls modules().lez_core.account_id_from_base58, get_account_public, list_accounts and send_generic_public_transaction. token_module and stablecoin call account_id_to_base58/from_base58, get_account_public, list_accounts and send_generic_public_transaction. lez_wallet_ui (Qt) calls m_logos->lez_core.version/open/create_new/save/wallet_dir/list_accounts/get_account_public/private/get_all_labels_for_account/sync_to_block/get_last_synced_block/get_current_block_height/get_sequencer_addr/create_account_*/get_balance/get_*keys/transfer_public/bridge_withdraw/check_label_available/add_label, and uses invokeRemoteMethod with NO_TIMEOUT for private transfers. lez-multisig has no lez_core references.
- [C19|medium|verified-from-source] The wallet UI warms up with lez_core.version() before its first stateful call. Otherwise the first cross-process call can race the capability/auth-token handshake, and the rejected call returns a default value (0 for int64, the same as SUCCESS). Also, lez_core holds exactly one wallet handle per process and has no close method: a second create_new/open fails with 'wallet is already open'.
- [C20|medium|inferred] Some lez_core parameter types do not map cleanly onto the IPC wire format. Local main still declares send_generic_public_transaction(… const std::vector<uint32_t>& instruction …), send_generic_private_transaction(vector<uint32_t>) and restore_storage(uint32_t depth). The fix branch says vector<uint32_t> fell back to an opaque `any` and was silently dropped over QtRO. The current logos-cpp-sdk generator (fb88c7d, 2026-09-11) turns unmapped spellings such as uint32_t into a build error. Demo calls should stick to methods with only tstr/int/bool/bstr arguments.
- [C21|medium|verified-from-source] How lez_core is built and packaged: logos-module-builder mkLogosModule produces the plugin library, `lgx` (a dev variant with /nix/store RUNPATHs) and `lgx-portable`. Module CI builds on ubuntu-latest and macos-15. The blockchain-modules-release catalog publishes lez_core, the wallet UI, lez-indexer, blockchain module/UI and explorer UI unsigned for darwin-arm64, linux-amd64, linux-arm64 and windows-x86_64. There is no Android variant anywhere, and logos-module-builder has no Android references.
- [C22|high|inferred] On Android, wallet_ffi's HTTPS client needs JNI setup. jsonrpsee-http-client uses hyper-rustls with rustls-platform-verifier, which on Android must be initialized once (init_with_env(env, context) or similar) and needs the org.rustls:rustls-platform-verifier Maven component plus a ProGuard keep rule. Without this, HTTPS calls to https://testnet.lez.logos.co would fail certificate verification.
- [C23|low|verified-from-source] The module's config/testnet.config.yaml is an L1 node config (network/blend/da_network/cryptarchia sections, deployment: mainnet), not a wallet config. No code, build file or script in the module references it; it is dead weight for the LEZ demo.
- [C24|low|verified-from-source] ~/src/logos-co/nescience-testnet is an old checkout (last commit 2025-12-05) of logos-blockchain/lssa, the predecessor of logos-execution-zone ('Nescience State Separation Architecture'). It is not a testnet endpoint and is superseded by logos-execution-zone.

### Open questions
- Which LEZ version is https://testnet.lez.logos.co running? Its program IDs (authenticated_transfer [583309054,…]) match none of the image IDs computed locally for dev HEAD. lez-programs says the v0.2.4 wallet-ffi line. Settle it by computing risc0 image IDs of the artifacts at v0.2.4 and at 87fca2a (e.g. a tiny risc0_binfmt::compute_image_id tool) and comparing with getProgramIds.
- Does wallet-ffi cross-compile to aarch64-linux-android with its default `prove` feature (risc0-sys C++ kernels, recursion zkr), `ring`, `pcsc-sys` (libpcsclite has no Android build; is a stub .so enough?) and the logos-blockchain-circuits-*-sys libs (no android prebuilt, so LBC_ROOT_DIR must point to a cross-built root)? Is `--no-default-features` (no prove) viable for a demo that uses public transactions only?
- Upstream lez_core has moved past the local clone (release catalog gitlink 0ea57f8a; lez-programs pins acf0cd50 '0.4.1-interim'; published 0.4.1/0.4.2 dropped pinata/register/vault and added payer/fee args). Which lez_core commit and LEZ commit pair should the Android POC target, and does that header build with the current logos-cpp-sdk generator, which rejects uint32_t?
- Does the public testnet enforce transaction fees? The wallet UI and RLN module comments mention fees and payers, but the pinned commit says fees are not implemented. If fees apply, register_public_account and claim_pinata cannot succeed from an unfunded fresh account.
- Does restore_storage (execute_keys_restoration) make network calls? This was not traced.
- The Electron POC's delivery_module 0.2.1 loaded lez_core as a transitive dependency (README:60), but the local logos-delivery-module checkout (2026-04-22) has no lez_core reference. Which delivery/rln module version introduced that edge, and is it still there?
- The 20 s default IPC timeout versus calibration time was worked out on paper, not tested end-to-end through logoscore; confirm with `logoscore call lez_core create_new …` against the testnet.

### Recommendations
- Load only `lez_core` (plus the host's capability_module) for the base LEZ demo. Do not load blockchain_module or lez_indexer_module: lez_core needs neither, and both would add an L1 node or L1 endpoint to the demo.
- Use sequence B (testnet read path) as the main 'real work' demo. Before calling it, write a wallet config with sequencers=[{sequencer_addr:"https://testnet.lez.logos.co"}] and multi_sequencer_client_config {distribution_limit:1, calibration_limit:3}. Warm up with version() until it returns non-empty. Then call create_new (non-empty mnemonic), save (0), create_account_public (64-hex id), list_accounts, account_id_to_base58, then get_current_block_height polled every ~5 s (a ticking live block height stands in for delivery's connectionStateChanged). Finally call get_balance and get_account_public on the pinata account (hex from account_id_from_base58("EfQhKQAkX2FJiwNii2WFQsGndjvF1Mzd7RuVe7QdPLw7")), expecting about 1,481,850 and data[0]=3. On later launches call open() instead of create_new().
- Keep sequence A (offline: name, version, account_id_to_base58/from_base58 round trip, optionally authenticated_transfer_elf() for a ~0.39 MB bstr) as the first milestone and a CI smoke test. It mirrors the upstream doctest and needs no network.
- Treat sequence C (register_public_account, then client-side SHA-256 PoW with 3 leading zero bytes, claim_pinata, poll_transaction_status, get_balance == "150") as a stretch goal. Only attempt it after confirming the LEZ version of the lez_core build matches the deployed testnet (program IDs) and that no fees apply. Note that the published 0.4.1/0.4.2 builds no longer expose claim_pinata or register.
- For the inter-module part, write a tiny universal module (e.g. `lez_probe`, metadata dependencies ["lez_core"]) that calls modules().lez_core.get_current_block_height() / account_id_from_base58() / get_account_public(), following amm_module_impl.cpp's generated logos_sdk.h pattern. Avoid methods with uint32_t or vector<uint32_t> parameters (send_generic_*, restore_storage). If a real upstream consumer is wanted, token_module.inspectDefinition() is a read-only chain token_module → lez_core → sequencer, but it adds token_ffi to cross-compile.
- Budget for the Android native build: libwallet_ffi.so is about 100 MB per ABI unstripped (72 MB rodata). Build it for arm64-v8a only. Try --no-default-features (drops the risc0 prover) and stub or feature-gate pcsc/keycard. Point LBC_ROOT_DIR/RAPIDSNARK_LIB_DIR at cross-built circuit libs, or check whether the demo path pulls them in at all. Initialize rustls-platform-verifier through JNI at app start and bundle its Maven component.
- Pass a longer timeout for create_new/open and for any transaction call (the wallet UI uses Timeout(-1) for proof-generating calls). Never run privacy-preserving methods on-device in the POC: they need local RISC0 proving, which the wallet UI calls 'unbounded on commodity hardware'.

### Verifier (non-confirmed only)
- [C4] partially-correct: The groups are right for the methods listed, but the claim leaves out two methods that use the network and misses one cost. (1) save() is NOT local: wallet_ffi_save calls store_persistent_data() and then block_on(wallet.client_rotation()). client_rotation re-runs MultiSequencerClient::setup, which sends at least one getLastBlockId, and save returns STORAGE_ERROR if the rotation fails even though storage.json was already written. (2) restore_storage calls execute_keys_restoration, which runs sync_to_latest_block (a full chain sync from block 0 for a fresh wallet) and then one getAccount per derived account. (3) Every metered read (get_account_public, get_balance(public), get_current_block_height, poll_transaction_status) sends TWO HTTP requests: the call plus a concurrent getLastBlockId latency probe. Also, account/key creation changes only in-memory state; nothing persists until save(), which needs the network.
- [C5] partially-correct: This holds for a first-time create_new/open whose statistics file has no entry for the sequencer URL. It is wrong as a general statement about `open`. setup() calibrates only URLs missing from statistics. For a URL already there (after any earlier save(), or with a pre-seeded statistics.json) it sends ONE actualization getLastBlockId. If that request fails, the URL stays in statistics and choose_leaders still selects it (it filters only on statistics.contains_key), so open (and create_new with a pre-seeded statistics path) succeeds with the sequencer unreachable. Also: calibration always sends exactly calibration_limit requests (the loop does not stop early), and each one can wait up to jsonrpsee's default 60 s request timeout, because SequencerClientBuilder is built without a timeout. Against a blackholed host that means up to 100×60 s. create_new writes neither storage.json nor statistics.json; only save() persists them.
- [C11] partially-correct: The verdict (no module-level dependency between lez_core and blockchain_module in either direction; lez-rln v3+ does not depend on lez_core) is correct. The list of modules that declare lez_core is incomplete. It should also include amm_ui (lez-programs/apps/amm, deps [lez_core, amm_module]), token_ui (lez-programs/apps/token, deps [lez_core, token_module]) and logos-amm-module's own metadata.json (amm_module, deps [lez_core]). A likely source of the user's framing: the blockchain-modules-release catalog publishes lez_core together with blockchain_module, blockchain_ui, lez_indexer_module, lez_explorer_ui and lez_wallet_ui. That is joint packaging only, not a dependency.

Confirmed: C1, C2, C3, C6, C7, C9, C10, C12, C14, C15, C16, C17, C18, C22

### Verifier missed findings
- Calibration can be skipped and open() works offline. MultiSequencerClient::setup calibrates only sequencer URLs missing from statistics.json; a known URL gets one getLastBlockId, and choose_leaders keeps it even if that request fails. So the demo can (a) write wallet_config.json with multi_sequencer_client_config.calibration_limit 3 before create_new, as both RLN modules do, and/or (b) ship a pre-seeded statistics.json. Either removes the ~35 s first-create stall and lets a saved wallet reopen with no network. Evidence: .work/lez-graph/pinned/lez/wallet/src/multi_client.rs:136-140, :605-618 (line counts match git 87fca2a); /home/fryorcraken/src/logos-co/logos-rln-modules/logos-rln-module/rust-lib/src/wallet_home.rs:55-59; logos-lez-rln-module/rust-lib/src/wallet.rs:571-573. Status: verified-from-source.
- create_new persists nothing, and save() uses the network. new_init_storage builds the wallet in memory only. storage.json and statistics.json are written only by save(), which also runs client_rotation (setup -> getLastBlockId) and returns STORAGE_ERROR if that fails. The desktop probe matches this: statistics sample_size 101 = 100 calibration probes + 1 actualization during save. Evidence: pinned lez/wallet/src/lib.rs:137-155, :253-297; git show 87fca2a:lez/wallet-ffi/src/wallet.rs wallet_ffi_save; .work/probe/persist/lez_core/89bde9c7c80f/statistics.json {sample_size:101, latency_avg:352.47, latest_block_id:23791}; .work/probe/logs/run/daemon.log:17-22. Status: verified-from-source + experiment.
- lez_core holds exactly ONE wallet handle per host. open/create_new refuse while one is open, and there is no close/destroy method in the module API. Every consumer module (amm/token/wallet UI) therefore shares whatever wallet and config the first caller opened. That is why liblogos_lez_rln_module v3 dropped its lez_core dependency. For the Android demo, the app and any consumer module must agree on who opens the wallet, and a failed or timed-out create_new cannot be retried in the same process without unloading the module. Evidence: /home/fryorcraken/src/logos-co/logos-rln-modules/logos-lez-rln-module/rust-lib/src/wallet.rs:3-13; /home/fryorcraken/src/logos-blockchain/logos-execution-zone-module/src/lez_core_module.cpp:1190-1193, :1220-1223; lez_core_module.h (no close method). Status: verified-from-source.
- Avoid sync_to_block and restore_storage in the demo. A fresh wallet starts at last_synced_block 0 (storage.rs:44 at 87fca2a). sync_to_block(height) then polls every block from 1 to ~23.8k in 100-block getBlockRange batches and calls store_persistent_data() after EVERY block (pinned lib.rs:901-940). restore_storage runs sync_to_latest_block plus one getAccount per derived account (git grep 87fca2a lez/wallet/src/cli/mod.rs:407-438). Public-account reads (get_account_public, get_balance public) need no sync. Status: verified-from-source.
- Each metered read makes two HTTP requests. metered_get runs the call and a getLastBlockId latency probe concurrently (pinned multi_client.rs:241-249). The jsonrpsee client is built with its default 60 s request timeout (vendored jsonrpsee-http-client-0.26.0/src/client.rs:340; multi_client.rs:118-134 sets no timeout). With a blackholed network (e.g. an emulator with no route), first-time calibration could block for up to calibration_limit x 60 s instead of failing fast. Status: verified-from-source (blocking duration inferred).
- The published lez_core 0.4.x targets a fee-charging LEZ. Its bundled wallet_ffi.h adds PAYER_CANNOT_FUND = 18 ('Fee payer cannot fund the fee reserve'), and generic tx/deploy take payer_account_id_hex, so writes need a funded native-balance payer. The build that matches the deployed testnet (v0.2.4 wallet-ffi, 4-arg generic tx, pinata/register/vault still present) is logos-execution-zone-module rev acf0cd50 ('0.4.1-interim'), pinned by lez-programs; amm_module/token_module are built against that same lez_core. Evidence: /nix/store/bbyj265j6igp6ic8vkkcbghyj09qscn7-logos-execution-zone-wallet-ffi-0.1.0/include/wallet_ffi.h:111-113; /home/fryorcraken/src/logos-blockchain/lez-programs/flake.nix:34-59. Status: verified-from-source.
- The local lez module checkout (b220144, 0.4.0) is stale. The blockchain-modules-release catalog pins submodule logos-execution-zone-module at 0ea57f8, which does not exist locally (git log 0ea57f8 -> bad object), and the probe's nix metadata references 825d2a4. The published API is the 0.4.2 .lidl in /nix/store, not the local header. Evidence: git -C /home/fryorcraken/src/logos-blockchain/blockchain-modules-release submodule status; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/probe/logs/meta-github_logos-blockchain_logos-execution-zone-module_825d2a41262b9882aa0f9ca837cb03635f7980c2.json (filename). Status: verified-by-experiment.
- Blockers for an Android build of wallet_ffi beyond pcsc and TLS: (1) logos-blockchain-circuits-build links -lstdc++ for every non-macOS target, plus static gmp. (2) Without LBC_ROOT_DIR it downloads logos-blockchain-circuits-v<ver>-<target_os>-<target_arch>.tar.gz, and 'android' is not in the circuits flake/release matrix. (3) The released lib is NEEDED libstdc++.so.6 while the NDK ships libc++. So the circuits C++ witness libs, gmp and rapidsnark must be rebuilt for android-aarch64 with libc++, or the dependency cut. The only reason they are linked is lez/common's use of logos-blockchain-common-http-client for BasicAuthCredentials, so patching that to a local type would drop the whole L1 crate tree. Evidence: /home/fryorcraken/src/logos-blockchain/logos-blockchain-circuits/rust/logos-blockchain-circuits-build/src/lib.rs:16-24, :84-86, :187-192; git show 87fca2a:lez/common/src/config.rs:5; NDK r27c sysroot listing. Status: verified-from-source (build outcome inferred).
- libwallet_ffi.so exposes no way to initialize rustls-platform-verifier on Android. nm -D shows only wallet_ffi_* and risc0 sys_* symbols, and no JNI_OnLoad. An uninitialized verifier panics ('Expect rustls-platform-verifier to be initialized') at the first HTTPS handshake. The Android build must add an exported init (JNI) function to wallet-ffi or a wrapper crate, or talk to a plain-http sequencer (e.g. a local one at http://127.0.0.1:3040). Evidence: nm -D on /nix/store/1kalh7g6v47w0llgm8c1d4raxgc34g3z-logos-lez_core-module-lib-0.4.2/lib/libwallet_ffi.so; vendored jsonrpsee transport.rs:257-260; rustls-platform-verifier src/android.rs. Status: verified-from-source (runtime effect inferred).
- A read-only, fund-free inter-module call already exists upstream: token_module.inspectDefinition/inspectHolding/inspectMetadata -> readPublicAccount -> modules().lez_core.get_account_public (plus account_id_from_base58 / list_accounts). It is a real LogosAPI/QtRO inter-module call and needs only an open lez_core wallet and a reachable sequencer. Evidence: /home/fryorcraken/src/logos-blockchain/lez-programs/modules/token/src/token_module_impl.cpp:282-320, :406-447; lez-programs/modules/token/metadata.json:9. Status: verified-from-source (not executed).
- The lez module repo contains config/testnet.config.yaml, a full logos-blockchain (L1) node config (cryptarchia, blend, DA settings, devnet peers commented out). Nothing references it (grep -rn testnet.config -> no matches), and it dates from the 'Initialise.' commit 77c429f of 2026-02-03. It is a leftover that could mislead readers into thinking lez_core runs or needs an L1 node. Status: verified-from-source.
- The 'lez_core uses blockchain module' framing most likely comes from packaging. blockchain-modules-release publishes lez_core, lez_wallet_ui, lez_indexer_module, lez_explorer_ui, blockchain_module and blockchain_ui as one catalog, for darwin-arm64, linux-amd64, linux-arm64 and windows-x86_64 only. Evidence: /home/fryorcraken/src/logos-blockchain/blockchain-modules-release/.gitmodules:19-36; .github/workflows/_release-module.yml:70. Status: verified-from-source.
- Testnet chain progress is slow: 23793 (researcher) -> 23804 (my probe at 2026-09-25 03:09 UTC). A demo that waits for a transaction to be included (poll_transaction_status, which uses seq_poll_timeout 12 s and seq_tx_poll_max_blocks 5 by default) may need generous timeouts. The wallet UI raises them to 30 s / 15 blocks / 10 retries (LEZWalletBackend.cpp:575-578). The rate was measured over two points only. Status: verified-by-experiment (rate estimate rough).

---

## Full report

## LEZ modules for the Android POC: what to load and what "real work" means (task key: lez-graph)

### 1. The module: `lez_core`

**Identity.** The repo `/home/fryorcraken/src/logos-blockchain/logos-execution-zone-module` (local HEAD b220144, 2026-08-27) builds a Logos Core module:

- `metadata.json:2` sets `"name": "lez_core"`, display name "LEZ Core Module", version 0.4.0.
- `metadata.json:7-9` sets type `core`, interface `universal`, and `"main": "lez_core_plugin"`.
- `metadata.json:15` sets `"dependencies": []`.
- `metadata.json:24-27` lists one external native library: `wallet_ffi`.

`name()` returns `"lez_core"`, but `version()` is hard-coded to `"0.3.0"` (`src/lez_core_module.cpp:278-284`), which does not match the metadata. The upstream doctest expects `"result":"0.3.0"` (`doctests/logos-execution-zone-runtime.test.yaml:214-221`).

**What it wraps.** `LEZCoreModule` is a Qt-free "universal" class (`src/lez_core_module.h:24`, `: public LogosModuleContext`). It holds one `WalletHandle*` (`:107`). It calls the C ABI of **`libwallet_ffi`**, i.e. the Rust crate `wallet-ffi` at `logos-execution-zone/lez/wallet-ffi`:

- `Cargo.toml:11`: `crate-type = ["rlib","cdylib","staticlib"]`.
- The header `wallet_ffi.h` is generated by cbindgen (`build.rs`).
- `wallet-ffi` wraps the `wallet` crate (`WalletCore`), which is the LEZ light wallet / sequencer client.

`logos-module-builder`'s codegen generates the Qt/QtRO plugin glue from the header, and the header comment warns that multi-line signatures are silently dropped (`lez_core_module.h:16-23`).

**Native dependency pin.** `flake.nix:13` pins `github:logos-blockchain/logos-execution-zone?ref=87fca2a…` (2026-08-10, dev branch). `git describe` gives `v0.2.0-399-g87fca2a17`. It is **not** a descendant of the latest release tag v0.2.4 (`git merge-base --is-ancestor v0.2.4 87fca2a` returns false). `flake.nix:21-26` maps `wallet_ffi` to the LEZ flake's `packages.<system>.wallet`. That package is defined in `logos-execution-zone/flake.nix:155-169` as a crane build of `-p wallet-ffi` with default features, which include `prove = ["lee/prove"]`, i.e. the risc0-zkvm prover (`lez/wallet-ffi/Cargo.toml:29-31`).

**No events.** A grep for emit/signal/event over `src/` and `metadata.json` finds only an unrelated comment. There is no `logos_events:` section. Unlike delivery's `connectionStateChanged`, liveness must be observed through return values and polling.

### 2. Public API and what each call needs

Declarations are at `lez_core_module.h:32-104`. Classification was done by tracing into `wallet-ffi` and `wallet` at the pinned commit (files dumped to `.work/lez-graph/pinned/`).

| Class | Methods | What it touches |
|---|---|---|
| Purely local, no wallet handle | `name`, `version`, `account_id_to_base58(hex)`, `account_id_from_base58(b58)`, `authenticated_transfer_elf`, `token_elf`, `amm_elf`, `ata_elf` (return embedded RISC0 program bytes), `wallet_dir` (host persistence path, `"-"` if none) | nothing |
| Wallet lifecycle | `create_new(config, storage, statistics, password) -> mnemonic`, `open(config, storage, statistics) -> 0/err`, `save()`, `restore_storage(mnemonic, password, uint32 depth)` | **sequencer reachability on first use** (see §3) |
| Local once a wallet is open | `create_account_public/private -> 64-hex`, `list_accounts -> [{account_id,is_public}]`, `get_account_private`, `get_public_account_key`, `get_private_account_keys`, `get_last_synced_block`, `get_sequencer_addr`, `check_label_available`, `add_label`, `resolve_label`, `get_all_labels_for_account`, `get_balance(id, false)` | local storage (`account.rs:344`: private balance comes from the local cache) |
| Sequencer read (HTTPS JSON-RPC) | `get_balance(id,true)` → `getAccountBalance`; `get_account_public` → `getAccount`; `get_current_block_height` → `getLastBlockId`; `sync_to_block` → `getBlockRange`; `poll_transaction_status` → `getTransaction`; `get_vault_balance` | LEZ sequencer |
| Sequencer write, public transaction, no proof | `transfer_public`, `register_public_account`, `claim_pinata`, `bridge_withdraw`, `vault_claim`, `send_generic_public_transaction`, `send_program_deployment_transaction` | sequencer (`send_pub_tx`, `wallet/src/lib.rs:817-879`: nonces + signatures + `sendTransaction`) |
| Sequencer write + **local RISC0 proof** | `transfer_shielded/deshielded/private/shielded_owned/private_owned`, `register_private_account`, `claim_pinata_private_owned_*`, `vault_claim_private`, `send_generic_private_transaction` | sequencer + on-device proving (`pinata.rs:55`, `vault.rs:114` use `send_privacy_preserving_tx`) |
| L1 / indexer | none directly | — |

The sequencer RPC surface is `sendTransaction, checkHealth, getBlock, getBlockRange, getLastBlockId, getAccountBalance, getTransaction, getAccountsNonces, getProofsAndRoot, getAccount, getProgramIds, getChannelId` (pinned `lez/sequencer/service/rpc/src/lib.rs` method names). The wallet does not use the indexer yet: rpc `lib.rs:47-48` says "TODO: These functions should be removed after wallet starts using indexer"; a grep for "indexer" over `lez/wallet*` finds nothing.

`bridge_withdraw` is also just an L2 public transaction to the bridge program (`wallet/src/program_facades/bridge.rs:23-31`). The L1 side is executed by the sequencer.

**Endpoints.**
- The wallet default is `https://testnet.lez.logos.co` (`lez/wallet/src/config.rs:79-82`; also `cli/network.rs:5`).
- A missing config file is replaced by this default (`config.rs:99-124`).
- The local-dev sequencer is `http://127.0.0.1:3040` (`lez/wallet/configs/debug/wallet_config.json`; wallet UI `LOCALHOST_URL`).
- The wallet UI offers `TESTNET_URL = "https://testnet.lez.logos.co"` (`LEZWalletBackend.cpp:30`).

### 3. Opening a wallet is not offline

`wallet_ffi_create_new` and `wallet_ffi_open` both end up in `WalletCore::new` (pinned `lez/wallet/src/lib.rs:157-194`), which always does `MultiSequencerClient::new(...).await?`:

1. `setup()` (`multi_client.rs:96-179`) puts every configured URL that is **not** in the statistics file on a calibration list.
2. `calibrate_client` (`:477-516`) sends `calibration_limit` sequential `getLastBlockId` requests. The default is **100** (`config.rs:10`).
3. `choose_leaders` (`:605-618`) keeps only URLs that have statistics and returns `None` if there are none, which surfaces as "Failed to find leader".

Result: if the sequencer is unreachable, `create_new` returns `""` (`lez_core_module.cpp:1195-1199`) and `open` returns `INTERNAL_ERROR`.

Two practical consequences:

- **Timeout.** Measured from this host, each keep-alive request costs about 0.34 s and the first costs about 1.0 s including TLS (`.work/scripts/lez-graph-probe2.sh`). A default first open therefore takes about 35 s, above the 20 s default Logos IPC timeout (`logos-protocol/cpp/logos_mode.h:29-31`). Fix: set `"multi_sequencer_client_config": {"distribution_limit": 1, "calibration_limit": 3}` in the config JSON (`config.rs:40-56,72-73`), and/or call with a longer `Timeout`. (Inferred; not tested end-to-end.)
- **Offline trick (inferred).** Pre-seed `statistics.json` with `{"<url>": {latency_avg, latency_var, sample_size, latest_block_id, errors}}`. Known URLs are only "actualized", a failed update keeps the entry (`:136-165`), and `choose_leaders` then accepts it. That would allow `create_new`/`open`, account creation and listing with no network.

Also:
- The module keeps exactly one wallet handle per process and has no close method: `create_new`/`open` refuse if one is already open (`lez_core_module.cpp:1190,1220`). The RLN module's LIDL (`liblogos_lez_rln_module.lidl:13-14`) cites this as the reason it stopped using lez_core.
- The wallet UI warns that the first cross-process call can race the capability-token handshake and resolve to a default value. It warms up with `version()` until the result is non-empty (`LEZWalletBackend.cpp:257-271`).

### 4. L1/L2 relationship; does lez_core need the L1?

**At runtime lez_core never talks to the L1.** The L1 (Bedrock, the logos-blockchain node) sits behind the sequencer:

- **Sequencer side.** The debug config carries `bedrock_config {channel_id, node_url: http://localhost:18080, funding_key}` (`lez/sequencer/service/configs/debug/sequencer_config.json:8-16`). `block_publisher.rs` publishes each L2 block "as an inscription chained on parent" in a Mantle channel. The L1 "rejects it if the tip moved" (`:155-158`). The sequencer follows the L1 branch for adoption, reorgs and finality, and handles "Finalized Bedrock deposit events, to record and mint on L2" and withdraw events (`:65-79`).
- **Indexer side.** `IndexerCore` wraps `ZoneIndexer<NodeHttpClient>` (`lez/indexer/core/src/lib.rs:10,40-49`) and reads the zone channel from an L1 node (`indexer_config.json: bedrock_config.addr, channel_id`). The indexer therefore rebuilds L2 state from L1 data, independently of the sequencer.
- **Run order** in the LEZ README (`:143-162`): L1 node, then indexer, then sequencer.

**Correction to "the L2 uses the L1 for indexing".** The L1 is the L2's data-availability, ordering and finality layer, plus the deposit/withdraw bridge. Indexing is one consumer of that L1 data (the indexer service and `lez_indexer_module`). The wallet uses neither.

**Build-time coupling does exist.**
- `lez/common/Cargo.toml:27` depends on `logos-blockchain-common-http-client` (only for `BasicAuthCredentials`, `common/src/config.rs:5`).
- Transitively that pulls `logos-blockchain-core → logos-blockchain-poc/pol/groth16 → logos-blockchain-circuits-*-sys`, and `circuits-prover → rust-rapidsnark` (pinned `Cargo.lock:5976-5993, 6310-6311, 5926-5927`).
- That is why the LEZ flake sets `LBC_ROOT_DIR` and `RAPIDSNARK_LIB_DIR` for the wallet build (`flake.nix:136-141`).
- `nm` on the released `libwallet_ffi.so` finds circom/witness/groth16/poseidon symbols (259/43/63/104 matches).

### 5. Verdict on "lez_core uses blockchain module"

**No, at the module level, in either direction.** Evidence:

- `lez_core`: `dependencies: []`.
- `blockchain_module` (`logos-blockchain-module/metadata.json`): `dependencies: []`. It runs a full L1 node in-process via `liblogos_blockchain` and has start/stop, wallet, channel_deposit and explorer methods plus `newBlock`/`processedBlock`/`libBlock` events (`src/logos_blockchain_module.h:25-187`).
- `lez_indexer_module`: `dependencies: []`. It wraps `indexer_ffi` and needs a reachable L1 HTTP URL (README `:48,:116`). It does not declare `blockchain_module`, though a blockchain_module in the same host could serve that URL.

Checking the alternatives offered in the task:

- **(a) is correct:** LEZ uses the L1 at the protocol level, server-side (sequencer and indexer).
- **(b) is outdated:** `liblogos_lez_rln_module` (`logos-rln-modules/logos-lez-rln-module/metadata.json`) has `dependencies: []` and links `wallet_ffi` directly. Its LIDL says "v3.0.0 dropped the lez_core dependency" (`:12-19`). `liblogos_rln_module` depends on `liblogos_lez_rln_module`. `rln_membership_ui` declares `lez_core`.
- **(c) is false** at the metadata level: the indexer module does not declare the blockchain module.

In the Electron POC, `lez_core` was loaded transitively by `delivery_module` 0.2.1 (`liblogos-electron-poc/README.md:60`). The local `logos-delivery-module` checkout (2026-04-22) no longer shows that edge.

### 6. Build, packaging and payload

- **Flake outputs.** `mkLogosModule` produces the lib, `lgx` (dev variant, `/nix/store` RUNPATHs) and `lgx-portable` (`logos-module-builder/lib/mkLogosModule.nix:1172-1174`). Module CI builds on ubuntu-latest and macos-15. The LEZ flake's systems are x86_64-linux, aarch64-linux, aarch64-darwin and x86_64-windows (`flake.nix:38-43`).
- **Guest programs are prebuilt.** RISC0 guest ELFs are committed under `artifacts/` (17 program `.bin` files of 0.35-0.52 MB plus `privacy_preserving_circuit.bin` at 0.63 MB at 87fca2a). `build_utils::include_artifacts` embeds them with `include_bytes!` and computes image IDs (`build_utils/src/lib.rs:19-73`). No guest compilation happens.
- **Other downloaded or prebuilt inputs.** The risc0 recursion `.zkr` zip is prefetched from S3 (`flake.nix:65-100`). The logos-blockchain circuits come from the pinned circuits flake. Otherwise `circuits-build` downloads `<os>-<arch>` tarballs from GitHub releases (`logos-blockchain-circuits-build/src/lib.rs:16-23,85-86`), and the circuits flake has no Android system.
- **Measured payload** (released lez_core 0.4.2 build in `/nix/store`):
  - `libwallet_ffi.so`: 108,567,024 bytes, not stripped, no debug sections; `.rodata` 72.4 MB, `.text` 27.4 MB.
  - `lez_core_plugin.so`: 2.4 MB.
  - `.lgx`: 70 MB gzip, 111 MB uncompressed, containing only `variants/linux-amd64-dev`.
  - `libwallet_ffi.so` NEEDED includes **`libpcsclite.so.1`**, because Keycard support is mandatory (`keycard_wallet` → `pcsc`).
  - The plugin needs Qt6Core, Qt6RemoteObjects, Qt6Network, boost_system, ssl and crypto.
- **HTTPS on Android.** The client is jsonrpsee over hyper-rustls with `rustls-platform-verifier` (pinned `Cargo.lock:4690-4710`). On Android this needs `init_with_env(env, context)` and the `rustls:rustls-platform-verifier` Maven component with a ProGuard keep rule (https://github.com/rustls/rustls-platform-verifier).
- **Published catalog.** `blockchain-modules-release` publishes lez_core, the wallet UI, lez-indexer, the blockchain module/UI and the explorer UI, unsigned, for `darwin-arm64, linux-amd64, linux-arm64, windows-x86_64` (`.github/workflows/_release-module.yml:70,82`). There is no Android variant.
- **Upstream drift.** The catalog's gitlink 0ea57f8a and lez-programs' pin acf0cd50 are both absent from the local clone. The **published 0.4.1/0.4.2 contract** (`/nix/store/…-0.4.2/share/logos/lez_core.lidl`):
  - drops `claim_pinata*`, `register_*`, `vault*`;
  - makes `send_generic_public_transaction` take `instruction: bstr` plus `payer_account_id_hex`;
  - turns program deployment into a program-loader call with a payer.

### 7. Version and wire-type hazards

- **Testnet compatibility.** The public testnet is live: `checkHealth` ok, block ~23793, channel `0101…01`, and the pinata account `EfQhKQ…PLw7` holds 1,481,850 with difficulty byte 3 (probe on 2026-09-25). Its `getProgramIds` (only amm, authenticated_transfer, pinata, privacy_preserving_circuit, token; e.g. authenticated_transfer `[583309054,…]`) **do not match** the image IDs computed for current LEZ dev HEAD (`target/release/build/programs-*/out/lez/programs/mod.rs`: `[1334061388,…]`). Program artefact blobs also differ between v0.2.4, 87fca2a and HEAD. lez-programs says the deployed sequencer matches the v0.2.4 wallet-ffi line and that "wallet-ffi and sequencer must agree on the JSON-RPC API and wallet-config schema" (`lez-programs/flake.nix:48-58`). Reads that return plain JSON (`getLastBlockId`, `getAccountBalance`, `getAccount`) are probably robust across versions. Transactions and `getBlockRange` (borsh) are not.
- **Wire types.** Local main still declares `std::vector<uint32_t>` / `uint32_t` parameters (`send_generic_*`, `restore_storage`). The fix branch b60be46 says such arguments were "silently drop[ped] over QtRO". The current logos-cpp-sdk generator makes these spellings a **build error** (`impl_header_parser.cpp:145-161,1364-1396`). Demo calls should use only tstr/int/bool/bstr arguments.

### 8. Proposed "it's alive" sequences, ranked by infrastructure

**A. Offline codec (needs nothing).** This mirrors the upstream doctest.
1. `name()` → `"lez_core"`; `version()` → `"0.3.0"`.
2. `account_id_to_base58("aa…aa" [64 hex])` → base58 string B.
3. `account_id_from_base58(B)` → `"aa…aa"`.
4. `account_id_from_base58("!!!not-base58!!!")` → `""`.
5. Optionally `account_id_from_base58("EfQhKQAkX2FJiwNii2WFQsGndjvF1Mzd7RuVe7QdPLw7")` → pinata hex, and `authenticated_transfer_elf()` → a ~0.39 MB bstr crossing IPC.

No network, no L1, no proving, no funds. It proves the Rust library is loaded and callable, but the work is shallow.

**B. Testnet read path (recommended).** Needs outbound HTTPS to the LEZ sequencer only. No L1, no indexer, no proving, no funds.
1. Warm up: `version()` until non-empty.
2. Write `<wallet_dir()>/config.json`:
   ```json
   {"sequencers":[{"sequencer_addr":"https://testnet.lez.logos.co"}],
    "seq_poll_timeout":"30s","seq_tx_poll_max_blocks":15,"seq_poll_max_retries":10,
    "seq_block_poll_max_amount":100,
    "multi_sequencer_client_config":{"distribution_limit":1,"calibration_limit":3}}
   ```
3. `create_new(cfg, storage.json, statistics.json, pw)` → 24-word mnemonic, non-empty. On later launches use `open(...)` → 0.
4. `save()` → 0.
5. `create_account_public()` → 64-hex; `list_accounts()` → `[{account_id, is_public:true}]`; `account_id_to_base58(id)`.
6. `get_sequencer_addr()` → the testnet URL.
7. Poll `get_current_block_height()` every ~5 s; it ticks upward (~23.8k now). This stands in for `connectionStateChanged`.
8. `get_balance(pinata_hex, true)` → `"1481850"`-ish; `get_account_public(pinata_hex)` → JSON `{program_owner, balance (LE hex), nonce, data}` with `data[0]=03`.

This does real work: BIP39 wallet creation, key derivation, multi-sequencer calibration and live chain reads.

**C. Public write path (stretch).** Needs the sequencer, a lez_core/LEZ build that matches the deployed testnet, and CPU time for proof-of-work. No L1, no RISC0 proving, no funds (if fees are off).
1. Steps 1-5 from B.
2. `register_public_account(id)` → `{"success":true,"tx_hash":…}`.
3. `poll_transaction_status(tx)` until true.
4. Read the pinata account data and search, in the app, for a `u128 s` with `SHA-256(seed32 ‖ s_le16)[0..3] == 0` (~2^24 hashes; `wallet/src/cli/programs/pinata.rs:213-255`).
5. `claim_pinata(pinata_hex, id, s_le16_hex)`, then `poll_transaction_status`.
6. `get_balance(id, true)` → `"150"` (`programs/pinata/src/main.rs:4`).

This only works with the local 0.4.0-era API (the methods are absent in 0.4.1/0.4.2), and only if program IDs match the testnet. It is unverified.

**Inter-module variant.** A tiny universal module with `"dependencies": ["lez_core"]` calling `modules().lez_core.get_current_block_height()` / `account_id_from_base58()` / `get_account_public()`, exactly as `lez-programs/modules/amm/src/amm_module_impl.cpp:15-19,295,308,337` does. The token module's `inspectDefinition` is a real upstream alternative but needs `token_ffi`.

### 9. Consumers of lez_core (real inter-module calls)

- **`lez_wallet_ui`** (`ui_qml`, deps `["lez_core"]`) uses `m_logos->lez_core.` for: `version`, `open`, `create_new`, `save`, `wallet_dir`, `list_accounts`, `get_account_public/private`, `get_all_labels_for_account`, `sync_to_block`, `get_last_synced_block`, `get_current_block_height`, `get_sequencer_addr`, `create_account_public/private`, `get_balance`, `get_public_account_key`, `get_private_account_keys`, `transfer_public`, `bridge_withdraw`, `check_label_available`, `add_label`. Private and shielded transfers go through `invokeRemoteMethod(..., NO_TIMEOUT)` (`LEZWalletBackend.cpp:169-685`).
- **`amm_module`** is published via `logos-amm-module`, which just re-exports lez-programs `amm-module-lgx`. It uses `modules().lez_core.` for `account_id_from_base58`, `get_account_public`, `list_accounts`, `send_generic_public_transaction`.
- **`token_module` and the stablecoin module** use the same set plus `account_id_to_base58`.
- **lez-programs' shared `LogosWalletProvider`** uses `open`, `create_new`, `create_account_*`, `get_account_public`, `send_generic_public_transaction`, `get_sequencer_addr`, `list_accounts`, `get_current_block_height`, `sync_to_block`, `get_last_synced_block`, `get_balance`, `save`.
- **`lez-multisig`** has no lez_core references.
- **`~/src/logos-co/nescience-testnet`** is a stale (2025-12-05) checkout of `logos-blockchain/lssa`, the predecessor of logos-execution-zone. It is not a testnet endpoint.
- The module's `config/testnet.config.yaml` is an unreferenced L1 node config.

Evidence scripts and outputs are under `/home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/lez-graph-{pinned,probe,probe2}.sh` and `.work/lez-graph/`.

