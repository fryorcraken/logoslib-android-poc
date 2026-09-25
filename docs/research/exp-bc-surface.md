# Experiment: bc-surface

> Blockchain-module research, 2026-09-25. Machine-written by the experiment agent; scripts and
> small logs in [../../experiments/bc-surface](../../experiments/bc-surface); patches in [../../patches](../../patches);
> node config fixtures in [../../config/blockchain](../../config/blockchain). `.work/` paths are local scratch.


### Summary
Source investigation of blockchain_module and liblogos_blockchain (task key bc-surface); nothing was built. The module's flake pins logos-blockchain master at 35a4a666. That commit is exactly where the devnet tag 0.3.0-rc.4 forks from master: rc.4 is the pin plus 3 commits (the genesis ceremony and a version bump), the C-bindings are the same, and the only node file that changes is settings.yaml. That file is the deployment compiled into the node. At the pin (and on master) it describes a placeholder chain called 'standalone-local', so a pin build started with an empty deployment joins no public network.

To join a public network, either build logos-blockchain at tag 0.3.0-rc.4 (devnet), or build the pin and pass the rc.4 settings.yaml as start()'s deployment argument. The devnet bootstrap peers are 65.108.203.235 udp/3000, 3001, 3002 and 50001, with the peer IDs listed in .github/release/devnet-peers.txt. Joining needs no registration, stake or tokens.

A syncing node only verifies proofs: Groth16 in pure-Rust arkworks, with the verification keys embedded via include_bytes. Once the node switches to Online, it starts proving:
- Blend edge mode eagerly mines 2 proof-of-work solutions and builds 2 PoQ proofs every epoch, using the witness generator plus rapidsnark.
- PoL proofs are made when the node wins a slot as leader, which needs stake.
- Any wallet transaction needs a zksign proof, and leader_claim needs a PoC proof.

Neither blend nor the leader can be switched off by config. Both wait for Online, though, so setting prolonged_bootstrap_period to 1 year gives a follower mode: the node syncs and follows the chain but never proves anything.

For aarch64-linux-android the dependency tree (normal and build edges) contains no openssl, aws-lc, zstd/lz4/bz2/libz, jemalloc, KZG or DA code. The native parts are: librocksdb-sys (C++ source build plus bindgen), ring, the four lbc circuit -sys crates, rust-rapidsnark (prebuilt static libs), and netlink-sys via netdev.

Things that can kill the host process:
- The node installs a global panic hook that calls exit(1) on any panic.
- If initial block download fails, the node shuts itself down, and the module is not told.
- Stopping the node within about 250 ms of start deadlocks Overwatch.

An upstream example consumer exists (blockchain_client_example, which polls chain height every 5 s). It is a Rust module that pulls in the whole of logos-blockchain-core, so a small universal C++ probe module is the cheaper inter-module demo.

### Results
- [answered|verified-from-source] Q1a. blockchain_module identity, build inputs, and which logos-blockchain rev / cargo package it builds
  - Identity (metadata.json): name blockchain_module, version 0.0.999, type core, interface universal, codegen impl_header logos_blockchain_module.h / class LogosBlockchainModule, main blockchain_module_plugin, no module dependencies.
- Bundled libs: liblogos_blockchain.{so,dylib,dll} and libfyaml.so.0. Runtime nix packages: nlohmann_json, boost, libfyaml.
- Build inputs (flake.nix): logos-module-builder 0.3.1, and logos-blockchain from github:logos-blockchain/logos-blockchain?ref=master, locked to 35a4a666e22a51eb98fe8a050854e57fe3420899 (2026-09-22).
- How the lib is built: externalLibInputs.logos_blockchain points at the node flake, whose default package is crane `cargo build -p logos-blockchain-c`. That crate is a cdylib named logos_blockchain and defines no cargo features. Toolchain is Rust 1.98.1, with LBC_ROOT_DIR from the circuits v0.5.7 flake and RAPIDSNARK_LIB_DIR from the rust-rapidsnark e91187f8 flake. cbindgen writes c-bindings/logos_blockchain.h, which postInstall copies to include/.
- Module-side native deps: libfyaml (used by user_config_reader.cpp), boost header-only algorithm/hex and string trim, and nlohmann_json.
- Release pairing: module tag 0.3.0-rc.4 (fcc93e48) pins node tag 0.3.0-rc.4 (39916dc8) with builder 0.2.6. Module tag 0.2.4 pins node 0.2.4 (adc72a45). The release workflow publishes the module under the same version as the node.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain-module/metadata.json:2-40; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain-module/flake.nix:10-13,26-28; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain-module/flake.lock:186-200 (rev 35a4a666); /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain-module/CMakeLists.txt:11-22; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/flake.nix:14-22,52,77-121; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/c-bindings/Cargo.toml:12-47; build.rs:3-12; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain-module/src/user_config_reader.cpp:5,29-69; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/logs/rel.log (module tags' flake pins); /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/.github/workflows/prepare-release.yml:133-139
- [answered|verified-from-source] Q1b. Exposed methods (signatures) and events/payloads
  Every method returns StdLogosResult ({success, value, error}). Values are strings or JSON strings. u64 amounts are sent as decimal strings.

Node methods (logos_blockchain_module.h):
- Lifecycle, :26-27: start(config_path, deployment), where an empty deployment means use the compiled-in default. If config_path is empty it falls back to the LB_CONFIG_PATH env var (.cpp:640-649). start() subscribes all 3 block streams (.cpp:668-675). stop().
- Stream re-subscribe, :36-38: subscribe_to_new_blocks, subscribe_to_processed_blocks, subscribe_to_lib_blocks.
- State, :48 and :54: does_state_exist() and purge_state(). Both need instancePersistencePath.
- Config, :65-95: generate_user_config(json_args). JSON keys: initial_peers[], output, net_port, blend_port, http_addr, external_address, state_path, storage_path, logs_path, skip_ibd, log_filter, kms_file, use_persistence_paths. It returns the absolute config path (.cpp:545-630). Also: static update_user_config, migrate_user_config, migrate_user_config_0_1_2, merge_user_config(src, dst, extra_yaml, bool, bool), participate.
- Keys, :99-116: generate_key, add_key, remove_key.
- Identity, :119: static get_peer_id(config_path).
- Wallet, :122-159: wallet_get_balance(addr), wallet_transfer_funds(change, senders[], recipient, amount, tip), wallet_get_known_addresses(), wallet_get_notes(addr, tip), wallet_get_leader_aged_notes(tip), leader_claim(), wallet_get_claimable_vouchers(), wallet_fund_tx(json).
- Transactions, :165: submit_signed_transaction(json).
- Channels, :173-198: channel_deposit, channel_deposit_with_notes, get_channel_state.
- Blend, :201-205: blend_join_as_core_node(locator, note), blend_info().
- Chain and network, :210 and :217: get_chain_id(); get_network_info() returning {n_peers, n_connections, n_pending_connections, n_discovered_peers}.
- Explorer, :220-222: get_block(header_hex), get_blocks(from_slot u64, to_slot u64), get_transaction(tx_hex).
- Cryptarchia, :225-227: get_cryptarchia_info() returning {lib, lib_slot, tip, slot, height, mode: Online|NotStarted|Bootstrapping} (.cpp:1825-1858); get_block_events(header_hex).
- Time, :232: get_time_info() returning {slot_duration_ms, genesis_time_unix_ms, current_slot, current_epoch}.
- PoW, :237-278: pow_start_mining, pow_stop_mining, pow_start_auto_claim, pow_stop_auto_claim, pow_claim(addr), pow_claimable_rewards(), static pow_configure(cfg, json), read_accounts(cfg), read_pow_config(cfg).

Events (:283-299):
- newBlock(blockJson): wrapped as {"block":"<block JSON as an escaped string>"} (.cpp:490-493).
- processedBlock(eventJson): the /cryptarchia/blocks/stream schema, i.e. the block plus tip, tip_slot, lib and lib_slot.
- libBlock(blockInfoJson): the /cryptarchia/lib/stream schema.
- Every stream sends the JSON literal null once when it ends.

Drift: blockchain_module.lidl is stale. It lacks pow_configure, read_accounts and read_pow_config, which the header has.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain-module/src/logos_blockchain_module.h:18-319; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain-module/src/logos_blockchain_module.cpp:480-528,545-723,1739-1908; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain-module/blockchain_module.lidl:1-52
- [answered|verified-from-source] Q1c. Shipped configs (config/) and the network they target
  config/node_config.yaml is dead weight:
- It is the Devnet 0.2.0-rc.1 config (commit 7415183, 2026-06-26). Its peers are 209.38.241.182 on udp/3000-3003, with /logos-blockchain-devnet/*/1.0.0 protocol names.
- It uses the old schema (http:, testing_http:, key_management:, an embedded deployment:), which today's parser rejects because it runs with OnUnknownKeys::Fail.
- Nothing references it: no hit in nix, cmake, json, yml or cpp files.

The real config comes from generate_user_config, which calls lb_node init. It generates a new keystore.yaml with 7 keys: network, blend signing, blend zk, leader funding, sdp funding, voucher master and pow claim. It refuses if a keystore already exists ('Keystore file exists. Use `update` command.').

The network is decided by the deployment compiled into the node, which is settings.yaml included via include_bytes:
- At the pin and on master it is a placeholder: inscription 'standalone-local', protocol names /logos-blockchain/*/X.Y.Z, faucet_pk 0, no BN providers.
- At tag 0.3.0-rc.4 it is the devnet: chain_id 0.3.0-rc.4, protocol names /logos-blockchain-devnet-0.3.0-rc.4/*, 4 BN providers on 65.108.203.235.
- At tag 0.2.4 it is the testnet: /logos-blockchain-testnet-0.2.4/*, providers on 65.109.51.37.
  evidence: git -C /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain-module log -- config/node_config.yaml -> 7415183 2026-06-26 'chore: Devnet 0.2.0 rc.1'; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain-module/config/node_config.yaml:1-69,1139-1224; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/nodes/node/binary/src/cli/config/init.rs:37-64,127-241; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/nodes/node/binary/src/config/deployment/mod.rs:16,45-50; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/nodes/node/binary/src/config/deployment/settings.yaml:6,20-22,116,125,129; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/out/settings-0.3.0-rc.4.yaml; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/out/settings-0.2.4.yaml
- [answered|verified-from-source] Q1d. How upstream drives the module headless (doctests/tests)
  Runtime doctest (the config doctest is analogous but passes initial_peers):
1. nix build 'github:logos-co/logos-logoscore-cli' --out-link ./logos
2. nix build 'github:logos-co/logos-package-manager' --out-link ./lgpm
3. nix build 'github:logos-blockchain/logos-blockchain-module#lgx' --out-link ./blockchain-lgx
4. ./lgpm/bin/lgpm --modules-dir ./modules install --dir ./blockchain-lgx
5. ./logos/bin/logoscore daemon --modules-dir ./modules --persistence-path ./data &
6. sleep 8; ./logos/bin/logoscore load-module blockchain_module
7. logoscore call blockchain_module get_cryptarchia_info -> 'The node is not running.'
8. logoscore call blockchain_module generate_user_config @runtime-args.json, with {"skip_ibd":true,"net_port":3200,"blend_port":3201,"output":"user_config.yaml","use_persistence_paths":true}
9. Patch prolonged_bootstrap_period from '3600.000000000' to '5.000000000' with sed.
10. logoscore call blockchain_module start <cfg> ''
11. get_cryptarchia_info -> mode Bootstrapping; after sleep 15 -> Online, with height 0 and slot 0 (a node with no peers and no stake never produces blocks).
12. wallet_get_known_addresses -> 5 addresses.
13. wallet_get_balance <addr> -> 'Unknown wallet address.'
14. stop; does_state_exist -> true; purge_state; does_state_exist -> false; logoscore stop.

Other drivers:
- The deployment Docker script runs `AppRun call blockchain_module start "$CFG" "/node-data/deployment.yaml"` with LOG_BACKEND=file.
- Unit tests use the module-builder mockCLibs: tests/mocks/mock_logos_blockchain.cpp (570 lines) plus tests/stubs/logos_blockchain.h (334 lines).
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain-module/doctests/blockchain-module-runtime.test.yaml:40-330; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain-module/doctests/blockchain-module-config.test.yaml:88-200; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/deployment/scripts/run_node.sh:5-21; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain-module/tests/CMakeLists.txt:8-23
- [answered|verified-from-source] Q2. c-bindings C API: start/stop/query, threading/callbacks, config sections, ports, disk
  Size of the API: 54 extern "C" functions at the pin, listed in out/ffi-pin.txt. The set is identical to tag 0.3.0-rc.4's.

Start:
- Signature: start_lb_node(config_path, custom_deployment_path|NULL) -> FfiStatusResult<LogosBlockchainNode*>.
- It parses the user YAML with OnUnknownKeys::Fail and applies env overrides: LOG_* (LOG_BACKEND=Stdout/Stderr/File, LOG_LEVEL, LOG_FILTER), NET_HOST/PORT/NODE_KEY/INITIAL_PEERS, BLEND_*, HTTP_HOST, STATE_PATH, DEPLOYMENT.
- Deployment precedence: an explicit path wins over the DEPLOYMENT env var, which wins over the compiled-in settings.yaml.
- It then calls Runtime::new() (a multi-thread tokio runtime with one worker per CPU) and run_node_from_config, which installs a global panic hook that calls process::exit(1). It starts every service except BlendCore/Edge/Broadcast, which the blend orchestrator starts on demand.
- It returns once the services are spawned, not when they are ready.

Stop:
- shutdown_node(node) runs the Overwatch shutdown and then blocking_wait_finished.
- Shutting down less than about 250 ms after start deadlocks, and upstream's own test waits 2 s first (Overwatch issue 150).

Threading:
- Query calls run runtime.block_on on the caller's thread.
- Stream callbacks fire on tokio worker threads, and the char* is only valid for the duration of the call.
- Calling an FFI function from inside a callback panics, which with the panic hook means exit.
- The C API has no user_data pointer, so the module keeps a static s_instance.

UserConfig sections: network, blend, cryptarchia (service.bootstrap.prolonged_bootstrap_period default 3600 s, network.bootstrap.ibd.peers, leader.wallet), time (NTP pool.ntp.org:123), sdp, api (listen 127.0.0.1:8080), storage (backend.folder_name ./db), kms (keys), wallet (known_keys, voucher_master_key_id), pow, tracing, state (base_folder ./state). This version has no DA section and no DA service. Deployment = {blend, network, cryptarchia(genesis_block, epoch_config, pow_config, sdp_config, faucet_pk), time.slot_duration, mempool}.

Ports:
- UDP 3000 on 0.0.0.0: libp2p QUIC.
- UDP 3400: blend QUIC listener. Only relevant in core mode (inferred).
- TCP 127.0.0.1:8080: HTTP API, always started.
- Outbound NTP.
- NAT traversal is on by default: autonat, UPnP via igd-next, NAT-PMP, and a gateway monitor via netdev/netlink. Passing external_address switches the config to nat: static.

Disk:
- RocksDB at <state>/<folder_name>. The path is joined, so an absolute storage_path wins.
- Recovery state lives in storage.
- Logs: hourly rolling files, at most 10, in '.' or logs_path, plus stdout.
- keystore.yaml next to the config.
- Defaults are relative to the CWD, so on Android pass absolute paths or use_persistence_paths.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/c-bindings/src/api/lifecycle.rs:42-129,196-200,233-247; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/c-bindings/src/node.rs:98-124; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/c-bindings/src/api/subscriptions.rs:58-124,174-206,244-281; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/c-bindings/src/api/network.rs:16-27,53-62; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/c-bindings/src/api/config.rs:32-157,380-438; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/nodes/node/binary/src/lib.rs:138-160,162-283 (set_hook at 254),285-310; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/nodes/node/binary/src/panic.rs:11-46; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/nodes/node/binary/src/cli/mod.rs:159-246,469-472; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/nodes/node/binary/src/config/mod.rs:178-316,459-461; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/nodes/node/binary/src/config/storage/mod.rs:13-18; state.rs:11-16; tracing/serde/logger.rs:20-41; api/serde.rs:34-41; blend/serde/core.rs:29-41; network/serde/mod.rs:57-59; network/serde/nat.rs:11-54; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain-module/src/logos_blockchain_module.h:33-35; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/out/ffi-pin.txt
- [answered|verified-from-source] Q3. Real-work signal and joinable public network (registration/keys/stake/tokens?)
  Signals, in order:
1. get_network_info n_peers > 0. This is the analogue of connectionStateChanged.
2. get_cryptarchia_info height and slot increasing, with mode 'Bootstrapping'. The node flips to 'Online' after prolonged_bootstrap_period, 3600 s by default. The docs say to confirm slot and height increase, n_peers > 0, and that bootstrapping takes about 1 h.
3. processedBlock and libBlock events arriving.
4. get_block(tip) returns a header.
5. get_chain_id returns the deployment chain id, expected '0.3.0-rc.4' (inferred by decoding the inscription).
6. get_time_info current_slot advances every second even offline.

Networks:
- Devnet 0.3.0-rc.4 (tag 39916dc, 2026-09-23). Host 65.108.203.235, IBD peers from .github/release/devnet-peers.txt: udp/3000 12D3KooWNbZTQ86TZ9MrZ2wm6iUFFj25AFTzFLUD7i6XkZHoUzU8; udp/3001 12D3KooWNhXaH4XTX6Pp66NDQZxZpXYQzeruwwraMvTxojz1QXPJ; udp/3002 12D3KooWNTLPg5uYPKgZCDvzyaWNwZNcwVKmfS2bNv52E9L9P7Hf; udp/50001 12D3KooWMULUG8RXC2esnfLcVzGHohf6KNPSswkCKa1mdpXz4tHH. Faucet: devnet.blockchain.logos.co/web/faucet.
- Testnet 0.2.4, chain 0.2.1. Host 65.109.51.37 udp/3000, 3001, 3002 and 50001, peer IDs in testnet-peers.txt and the logos-docs CLI guide. Its FFI lacks get_network_info, get_chain_id, blend_info and pow_*.

What joining needs:
- No registration, stake or tokens. generate_user_config makes fresh keys.
- IBD uses only initial_peers that carry a /p2p/ id.
- Tokens (from the faucet) are needed only for transactions. Stake counts about 2 epochs later (docs say about 3.5 h).
- A blend core node additionally needs an SDP declaration, funded notes and a public UDP port.

Caveat: devnet is an RC network 'for internal devnet testing', with protocol names versioned per RC. The next RC will strand an rc.4 build.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/.github/release/devnet-peers.txt:1-4; testnet-peers.txt:1-4; release-content.md:36-111,133-136; rc-disclaimer.md:1-7; /home/fryorcraken/src/logos-co/logos-docs/docs/blockchain/get-started/run-a-logos-blockchain-node-from-cli.md:62-204; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/out/settings-0.3.0-rc.4.yaml:6,20-22,362-393,427-431; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/nodes/node/binary/src/cli/config/init.rs:160-186; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/out/ffi-0.2.4.txt
- [pass|verified-by-experiment] Q3b. Relationship of the module-pinned node rev to the public release tags
  - `git merge-base 35a4a666 0.3.0-rc.4` = 35a4a666, so the pin is an ancestor of rc.4.
- rc.4 = pin + 3 commits: 1a7768c 'Update inscribe', 3fd48e1 'chore: genesis ceremony for devnet version 0.3.0-rc.4', 39916dc 'Update cargo files'.
- The pin has 0 commits that rc.4 lacks.
- c-bindings diff is empty. Under nodes/services/core/zk/blend/consensus/ledger/libp2p only 1 file changed (+358/-57): settings.yaml.
- The extern fn sets at the pin and at rc.4 are identical.
- rc.4's settings.yaml has the same key schema as the pin's DeploymentSettings (network_absorption_in_rounds, target_peering_degree, pow_config.reward.pow_share, and so on).

Conclusion: a pin build started with the rc.4 settings.yaml as its deployment behaves like the 0.3.0-rc.4 release. Module HEAD 4b07e58 and module tag 0.3.0-rc.4 both need only FFI that rc.4 has.

For comparison, 0.3.0-rc.3 forks at d4be596 (2026-09-16) and is 24 commits behind the pin.
  evidence: bash /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/bc-surface-rel2.sh -> /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/logs/rel2.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/logs/rel.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/logs/all.log (FFI comparison section)
- [answered|verified-from-source] Q4. Runtime zk work for a plain node; build-time vs runtime artefacts; can blend/leadership/DA be disabled
  Verification:
- Always on. Groth16 verification uses pure-Rust arkworks (ark-groth16/ark-bn254, no asm feature). The verification keys come from lbc-*-sys artifacts::VERIFICATION_KEY via include_bytes.
- It covers PoL proofs in headers and ZkSig proofs in transactions.

Proving: witness generator C++ plus rapidsnark groth16_prover_zkey_buffer, with PROVING_KEY embedded via include_bytes. Nothing is loaded from disk at runtime.
- (a) PoL: when the leader wins a slot, which needs aged stake notes. chain-leader waits for Online first (chain-leader lib.rs:432-439).
- (b) PoQ via blend: blend waits for Online (blend lib.rs:218-228).
  - Mode rule: Broadcast if the membership is smaller than minimum_network_size, Core if this node is a member, else Edge (mode.rs:59-76). On devnet (4 genesis BN providers, minimum 2) a fresh node is Edge.
  - Every epoch, once secret PoL info arrives, the edge handler builds RealLeaderAndPowProofsGenerator. Its PoW stream is eagerly prefilled (Buffered pre-polls, stream.rs:22-39; BUFFER_SIZE=2) on a 2-thread rayon pool. It mines blend PoW puzzles (calibrated at about 50 s of one Raspberry Pi 5 core per solution, settings.yaml comment) and makes pow_quota = num_blend_layers = 1 PoQ proof per solution.
  - That is about 2 PoW solutions plus 2 PoQ proofs per epoch even when nothing is sent. A failure there is `.expect("PoW PoQ proof creation should not fail.")`, a panic, which exits the process.
- (c) zksign: any transaction signed with a ZK key, including wallet_transfer_funds, channel_deposit and pow_claim.
- (d) PoC: leader_claim.
- (e) PoW token mining is off until pow_start_mining (service.rs:525).

Disabling:
- No config switch disables blend or leadership. BLEND_ABSTAIN_ON_FAILURE only changes delivery failure detection.
- There is no DA in this node.
- Workaround: keep the node in the prolonged bootstrap period. It still applies IBD and gossiped blocks (pbp.rs:72-95) but never goes Online, so no proving runs. That is patches/follower-mode.extra.yaml.

Build-time consequence: all 4 lbc -sys crates are linked. Verification needs their VK JSON. Follower mode never executes witness generators or rapidsnark, so stub libs would not be called at runtime (inferred). Any Online path needs real Android circuit libs and rapidsnark.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/zk/proofs/pol/src/lib.rs:76-97,125-130; src/verification_key/mod.rs:15-23; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/zk/groth16/Cargo.toml:12-26; Cargo.toml:188-193 (no ark asm); /home/fryorcraken/src/logos-blockchain/logos-blockchain-circuits/rust/logos-blockchain-circuits-common/src/artifacts.rs:36-44; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/zk/circuits/prover/src/rapidsnark.rs:10-19; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/services/blend/src/mode.rs:49-89; edge/current_epoch.rs:183-231; edge/handlers.rs:51-80; lib.rs:218-228; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/blend/provers/src/crypto/leader/send.rs:81-104; provers/pow/mod.rs:38-49,70-139,173-205; provers/leader_and_pow/mod.rs:15-21,48-60; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/utils/src/tokio/stream.rs:18-39; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/services/blend/src/edge/settings.rs:45-50; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/services/chain/chain-leader/src/lib.rs:418-439; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/services/chain/chain-service/src/service/phases/pbp.rs:55-95; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/services/pow/src/service.rs:525-560; grep hits: kms/keys/src/keys/zk/private.rs, signature.rs (zksign prove); core/src/proofs/leader_proof.rs, leader_claim_proof.rs
- [answered|verified-by-experiment] Q5. Heavy native deps / every -sys crate, with Android cross-compile risk
  Method: offline `cargo tree -p logos-blockchain-c --target aarch64-linux-android -e normal,build` at the pin gives 547 unique packages. A BFS over Cargo.lock gives 740 (an over-approximation).

-sys crates in the real Android tree:
- logos-blockchain-circuits-{poc,pol,poq,signature}-sys 0.5.7: HIGH risk. They link prebuilt static C++ libs plus GMP from LBC_ROOT_DIR (no Android bundle exists), embed zkeys via include_bytes, and lbc-build emits -lstdc++.
- librocksdb-sys 0.17.3+10.4.2: MEDIUM. RocksDB 10.4.2 C++ is compiled from source with cc. The rocksdb features are only bindgen-runtime, so there is no compression lib; bindgen needs host libclang plus Android sysroot args.
- clang-sys 1.8.1: build-time only (host).
- netlink-sys 0.8.8: pure Rust, via netdev in the NAT gateway monitor. MEDIUM at runtime, because Android 11+ restricts netlink.
- linux-raw-sys 0.12.1 and dirs-sys 0.5.0: LOW.

Non-sys native code:
- rust-rapidsnark (e91187f8): links static rapidsnark, fr, fq and gmp from RAPIDSNARK_LIB_DIR (iden3 Android prebuilts exist), plus -lc++ and -lc on Android. Its x86_64 asm is the likely cause of the ADX/SIGILL issue (inferred).
- ring 0.17.14: C/asm, supported on Android. Pulled in by libp2p-quic/rustls, and by ureq in circuits-build (a host build dependency).
- quinn/quinn-udp, if-watch, igd-next, natpmp, utoipa-swagger-ui (vendored feature, no download): LOW.

In Cargo.lock but not in the Android tree (target- or feature-gated): openssl-sys, libz-sys, bzip2-sys, tikv-jemalloc-sys (the jemalloc feature is off), security-framework-sys, core-foundation-sys, system-configuration-sys, windows-sys, js-sys/web-sys.

Absent entirely: aws-lc, zstd-sys, lz4-sys, blst, c-kzg.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/out/native-crates-aarch64.txt; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/out/why.txt; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/out/tree-aarch64-linux-android.txt; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/services/storage/Cargo.toml:27; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/libp2p/Cargo.toml:22-40; /nix/store/h6iir14haf6gi3kznr24shrmgpb20vch-cargo-git-https-github.com-logos-blockchain-logos-blockchain-rust-rapidsnark.git-e91187f8ccb5bbfc7bb00dac88169112428da78f/rust-rapidsnark-0.1.3/build.rs:7-63,118-122; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/research/digest/circuits.md C10,C14,C23
- [answered|verified-from-source] Q6. Consumers of blockchain_module and candidate inter-module calls
  Consumers found in local code:
- rust-client/example-module 'blockchain_client_example' (Rust cdylib, dependencies [blockchain_module]). It polls get_cryptarchia_info every 5 s and exposes last_height, poll_count, last_info, last_error and poll_now. It is the upstream inter-module example. Its client crate depends on logos-blockchain-core, common-http-client and http-api-common at 6ddfc0b26, i.e. the whole circuits/rapidsnark stack, so it is heavy for Android.
- zone-sdk backend over the same client (consensus_info, time_info, channel_state, block_stream, lib_stream, block, block_events, post_transaction, fund_tx).
- logoscore-cli tests.

Not consumers:
- lez-indexer-module talks to the L1 node over HTTP (bedrock_config.addr, default http://localhost:8080), not through liblogos. It has no module dependencies.
- logos-execution-zone-module has none either.

Not available locally: the Basecamp blockchain UI (logos-blockchain-ui). Its release submodule directory is empty (open).

Candidate calls for a small universal C++ probe with dependencies ["blockchain_module"], following the lez_probe pattern:
- With the node running and no network needed: get_chain_id, get_time_info (slot ticks every second), get_cryptarchia_info, wallet_get_known_addresses, get_network_info.
- Static, needing only a config path: get_peer_id(cfg), read_accounts(cfg), read_pow_config(cfg).
- With the network: get_block(tip), get_blocks(from, to), and the processedBlock/libBlock events.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain-module/rust-client/example-module/metadata.json:1-30; rust-lib/src/lib.rs:1-90; rust-lib/blockchain_client_example.lidl:1-11; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain-module/rust-client/Cargo.toml:13-21; README.md:12-43; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain-module/zone-sdk/src/lib.rs:135-187; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/lez-indexer-module/README.md:4,72; metadata.json:10; ls /home/fryorcraken/src/logos-blockchain/blockchain-modules-release/submodules/logos-blockchain-ui -> empty; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/research/digest/desktop-probe.md C10 (lez_probe pattern)
- [answered|inferred] Q7. Resource profile (disk growth, RAM, CPU, bandwidth)
  From the docs (verified-from-source): 2 cores at 2 GHz, 1 GB RAM minimum, 100+ GB SSD 'with ability to expand', 1 Mbps; ADX required on x86_64; bootstrapping takes about 1 h.

From code and config (verified-from-source):
- Blocks carry at most 1024 transactions and 2 MiB of transaction payload.
- Devnet slot is 1 s with activation coefficient f=1/30, so about 1 block per 30 s (about 2,900 per day), each mostly header plus PoL proof (inferred).
- RocksDB is built without compression, and logs rotate hourly keeping 10 files.
- Threads: one tokio worker per CPU; blend PoW uses 2 rayon threads per epoch once Online; PoW mining would use all CPUs, but only if started.
- gossipsub mesh_n=6 with a 1 s heartbeat, plus kademlia, identify and autonat.

Chain age: devnet rc.4 genesis is about 2026-09-23, so the chain is about 2 days old and IBD is on the order of thousands of blocks. Testnet 0.2.4 genesis is about 2026-09-04 (both decoded from the inscription, inferred).

CPU while syncing is dominated by arkworks Groth16 verification per block and per ZkSig transaction (not measured).

lib size: the node embeds all 4 zkeys, since every prover is reachable. At v0.5.3 they total pol 12.7 + poq 11.5 + poc 5.3 + signature 4.5 = about 34 MB, plus witness .dat files of about 0.5 MB, so expect a large liblogos_blockchain.so (inferred; v0.5.7 sizes not checked).

RAM, bandwidth and disk growth on device were not measured (open).
  evidence: /home/fryorcraken/src/logos-co/logos-docs/docs/blockchain/get-started/run-a-logos-blockchain-node-from-cli.md:26-35,204; /home/fryorcraken/src/logos-co/logos-docs/docs/run-a-node/get-started/run-logos-node-blockchain-storage-delivery.md:43-46; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/core/src/block/mod.rs:30-34; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/out/settings-0.3.0-rc.4.yaml:28-33,362; ls -la /nix/store/ai2mn1mcxlrbhpp9b4rpgqxc2ibpqn9v-logos-blockchain-circuits-0.5.3/*/ (in logs/all.log section 6); /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain-module/config/node_config.yaml:7-56 (gossipsub defaults)
- [answered|verified-from-source] Failure modes that matter on Android (host-process killers and lifecycle traps)
  - (1) Global panic hook: log_and_exit_hook calls std::process::exit(1) on any panic in any thread of the logos_host process, once start_lb_node has run.
- (2) IBD failure (no IBD peer returns a tip, 3 attempts) makes chain-network call overwatch.shutdown(). The node stops by itself. The module keeps its node pointer and does not notice, and later calls fail with relay errors. The app must detect this and stop/restart, and should start only when the network is up.
- (3) Calling stop less than about 250 ms after start can deadlock Overwatch (upstream waits 2 s).
- (4) Calling any FFI or module method from inside a block-event callback on the node's thread panics.
- (5) Default paths are relative to the CWD: ./state, ./db and '.' for logs. On Android use use_persistence_paths or absolute state_path, storage_path, logs_path and output.
- (6) The HTTP API always binds TCP 127.0.0.1:8080. Pass http_addr to avoid clashes.
- (7) A second generate_user_config into the same directory fails with 'Keystore file exists. Use `update` command.'
- (8) Genesis in the future parks the node in AwaitingGenesisTime silently.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/nodes/node/binary/src/panic.rs:11-46; lib.rs:254; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/services/chain/chain-network/src/lib.rs:327-356; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/c-bindings/src/api/lifecycle.rs:233-247; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain-module/src/logos_blockchain_module.h:33-35; .cpp:705-723; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/nodes/node/binary/src/cli/config/init.rs:28-52; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain-module/doctests/blockchain-module-runtime.test.yaml:183-193
- [not-run|open] Open items not resolved here
  - Live reachability of the devnet peers, and whether devnet is still on rc.4. Not probed. The bc-desktop experiment should confirm this.
- netdev/netlink behaviour on Android 11+. Mitigation: pass external_address to force nat: static.
- Whether tokio accepts a 1-year prolonged_bootstrap_period sleep. Inferred safe, since it is below tokio's roughly 2.2-year timer horizon.
- Whether wallet calls fail cleanly or panic when circuit libs are stubs. Avoid calling them in follower mode.
- Size, RAM and CPU of a real Android liblogos_blockchain.so.
- NDK resolution of rapidsnark's -lc++ versus librocksdb-sys cc (expected c++_shared).
- The bindgen-runtime cross-compile flags for librocksdb-sys.
- ADX support on the x86_64 emulator. Only relevant once proving runs.
- The Basecamp blockchain UI call set.
- Epoch length on devnet in wall-clock terms.
  evidence: n/a

### Patches
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/patches/follower-mode.extra.yaml -- extra YAML for blockchain_module.merge_user_config(cfg,cfg,extra,false,false): keeps the node in the prolonged bootstrap period (1 year) so chain-leader and blend never start, meaning no PoL/PoQ/PoW proving on device while it still syncs and follows the chain.
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/patches/devnet-rc4-gen-args.json -- generate_user_config args for devnet 0.3.0-rc.4 (4 bootstrap peers with /p2p ids so IBD is enabled, use_persistence_paths, HTTP moved to 127.0.0.1:18080 to avoid :8080 clashes).
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/patches/module-quiet-newblock-log.diff -- drops the per-block full-JSON fprintf in on_new_block_callback (logcat noise); the event itself is unchanged.
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/out/settings-0.3.0-rc.4.yaml -- not a diff: the devnet rc.4 deployment file to pass as start()'s second argument when liblogos_blockchain is built at the module pin 35a4a666 instead of tag 0.3.0-rc.4 (the two differ only in this file).

### Artifacts
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/logs/all.log
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/logs/rel.log
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/logs/rel2.log
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/out/lb-tags.txt
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/out/lbm-tags.txt
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/out/settings-0.3.0-rc.4.yaml
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/out/settings-0.2.4.yaml
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/out/ffi-pin.txt
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/out/ffi-0.3.0-rc.4.txt
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/out/ffi-0.2.4.txt
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/out/tree-aarch64-linux-android.txt
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/out/tree-x86_64-linux-android.txt
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/out/metadata-aarch64.json
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/out/native-crates-aarch64.txt
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/out/why.txt
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/src/logos-blockchain (shared clone checked out at 35a4a666)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/src/tags.git (node history since 2026-08-20 plus release tags)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-surface/src/module.git (module HEAD plus tags 0.3.0-rc.4 and 0.2.4)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/bc-surface-all.sh
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/bc-surface-rel.sh
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/bc-surface-rel2.sh
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/bc-surface-native.py

### Repro
Run these in order:
1. bash /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/bc-surface-all.sh
   - Lists remote tags (git ls-remote).
   - Fetches the settings.yaml and extern-fn list for release tags 0.3.0-rc.4 and 0.2.4.
   - Makes a shared clone at pin 35a4a666, taking its objects from the bc-android-build clone and falling back to a GitHub fetch.
   - Runs offline cargo tree/metadata for aarch64 and x86_64 Android. This relies on ~/.cargo already having the crates and on toolchain 1.98.1 being installed.
   - Runs bc-surface-native.py and `cargo tree -i` for each native crate, and lists the v0.5.3 zkey sizes in the nix store.
2. bash /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/bc-surface-rel.sh
   - Node history via shallow-since 2026-08-20, plus the module release tags' flake pins.
3. bash /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/bc-surface-rel2.sh
   - Deepens the rc.4 and 0.2.4 tags by 60 commits. Shows that pin 35a4a666 is an ancestor of 0.3.0-rc.4 and that rc.4 is the pin plus 3 commits.

Everything else is file:line reads of .work/upstream/{logos-blockchain c4c86be, logos-blockchain-module 4b07e58} and ~/src/logos-co/logos-docs.

### Next steps
- Decide the node rev. Recommended: build logos-blockchain-c at tag 0.3.0-rc.4 so start(cfg, "") joins devnet. Equivalent: build at pin 35a4a666 and ship out/settings-0.3.0-rc.4.yaml as the deployment argument. Pair it with module HEAD 4b07e58 (module-builder 0.3.1) or module tag 0.3.0-rc.4 (builder 0.2.6).
- Android native build of logos-blockchain-c (the bc-android-build agent's scope): Rust 1.98.1; targets aarch64-linux-android and x86_64-linux-android with NDK r27c; RUSTFLAGS -C link-arg=-Wl,-z,max-page-size=16384; RAPIDSNARK_LIB_DIR pointing at the iden3 Android v0.0.8 libs; LBC_ROOT_DIR as an Android v0.5.7 bundle (zkeys, vkeys and .dat from the release; lib{circuit}.a and libgmp.a NDK-built, or stubs for follower mode only); lbc-build -lstdc++ patched to c++_shared; librocksdb-sys bindgen with LIBCLANG_PATH and BINDGEN_EXTRA_CLANG_ARGS_<target> set to the NDK sysroot; ship libc++_shared.so.
- Module plugin for Android: NDK builds of libfyaml plus the boost and nlohmann headers. LogosModule.cmake has no Android support (mobile-search C9). A quick plumbing test is possible first: build blockchain_module_plugin against tests/mocks/mock_logos_blockchain.cpp and tests/stubs/logos_blockchain.h as a fake liblogos_blockchain.so, to prove Kotlin -> liblogos -> module calls before the Rust lib exists (inferred feasible; the mock uses the LOGOS_CMOCK harness).
- Desktop confirmation before Android (bc-desktop agent): with logoscore, run generate_user_config @devnet-rc4-gen-args.json, then merge_user_config with follower-mode.extra.yaml, then start, then poll get_network_info and get_cryptarchia_info. Confirms the devnet peers are live and that follower mode syncs with no prover activity (grep the logs for 'PoW PoQ' or 'pow-puzzle').
- Inter-module step: a universal C++ probe (bc_probe) with optional_dependencies or dependencies ["blockchain_module"] that calls modules().blockchain_module.get_chain_id(), get_time_info(), get_cryptarchia_info() and get_network_info() and returns a JSON summary. Avoid Rust blockchain_client_example on Android, because it pulls logos-blockchain-core and the circuits.
- Milestone after follower mode: either let the node go Online on devnet, which needs real Android PoQ, rapidsnark and GMP (eager blend PoW plus PoQ each epoch), or run the standalone single-node chain (nodes/node/standalone-node-config.yaml plus standalone-deployment-config.yaml, which gives the node's own keys stake), which needs real PoL proving. Both exercise the circuits on the device.

---

## Full report

## Design brief (bc-surface): blockchain_module on Android

### 1. Bottom line
- **Build pairing (verified by experiment).** The module's flake pins logos-blockchain master at `35a4a666`. That commit is the fork point of devnet tag `0.3.0-rc.4`: rc.4 is the pin plus 3 commits (inscribe, genesis ceremony, cargo version), the C-bindings are identical, and the only node file that changes is `settings.yaml`.
- **Default network at the pin.** `settings.yaml` is the deployment compiled into the node. At the pin (and on master) it is a placeholder chain called `standalone-local` with `/X.Y.Z` protocol names. A pin build started with `deployment=""` joins no public network.
- **Two ways to join devnet:**
  - Build `logos-blockchain-c` at tag **0.3.0-rc.4** and call `start(cfg, "")`.
  - Build the pin and pass `.work/experiments/bc-surface/out/settings-0.3.0-rc.4.yaml` as the deployment argument.
- **Module version.** Use module HEAD `4b07e58` or module tag `0.3.0-rc.4`. Every FFI function either one calls exists at rc.4.
- **What joining needs.** Nothing: no registration, stake or tokens. `generate_user_config` makes fresh keys.
- **Devnet IBD peers** (host 65.108.203.235, from `.github/release/devnet-peers.txt`):
  - udp/3000: `12D3KooWNbZTQ86TZ9MrZ2wm6iUFFj25AFTzFLUD7i6XkZHoUzU8`
  - udp/3001: `12D3KooWNhXaH4XTX6Pp66NDQZxZpXYQzeruwwraMvTxojz1QXPJ`
  - udp/3002: `12D3KooWNTLPg5uYPKgZCDvzyaWNwZNcwVKmfS2bNv52E9L9P7Hf`
  - udp/50001: `12D3KooWMULUG8RXC2esnfLcVzGHohf6KNPSswkCKa1mdpXz4tHH`
- **Devnet caveats.** Genesis is about 2026-09-23 (inferred), so IBD is small. Devnet is an RC network, so a new RC strands this build.
- **Testnet alternative.** Testnet 0.2.4 (65.109.51.37) needs module 0.2.4. Its FFI has no `get_network_info`, `get_chain_id`, `pow_*` or `blend_info`.

### 2. Runtime zk: what actually runs on a plain node
- **Verification.** Always runs: arkworks Groth16 in pure Rust, with the verification keys embedded at build time.
- **Proving.** Uses the C++ witness generator plus rapidsnark, with zkeys embedded via `include_bytes`. Nothing is read from disk. It happens in four places:
  - **Blend edge PoQ.** Once the chain is Online, the node eagerly mines 2 PoW puzzle solutions and builds 2 PoQ proofs every epoch, even when idle. A failure there panics, and the node's panic hook then calls `exit(1)`.
  - **PoL.** Only when the node leads, which needs stake.
  - **zksign.** For any wallet transaction.
  - **PoC.** For `leader_claim`.
- **PoW mining.** Off by default.
- **DA.** None in this node.
- **Switching it off.** No config disables blend or leadership, but both wait for Online. **Follower mode** exploits that: set `cryptarchia.service.bootstrap.prolonged_bootstrap_period` to 1 year (`patches/follower-mode.extra.yaml`). The node keeps syncing and applying blocks in Bootstrapping mode and never proves anything.

### 3. What must be true of the native build
- **liblogos_blockchain.so** (cdylib from `-p logos-blockchain-c`):
  - rustc 1.98.1, NDK r27c, 16 KB `max-page-size`, `libc++_shared` shipped.
  - Links all four `lbc-*-sys` crates, v0.5.7. Build-time data must come from the matching release bundle: zkey, vkey and `.dat`.
  - Android `lib{circuit}.a` and `libgmp.a` are needed. Stubs are acceptable only in follower mode.
  - Patch lbc-build's `-lstdc++`.
  - `RAPIDSNARK_LIB_DIR` points at the iden3 Android v0.0.8 libs.
  - librocksdb-sys builds RocksDB 10.4.2 C++ from source, uncompressed, with bindgen-runtime (host libclang plus Android sysroot args).
  - ring and netlink-sys are also in the tree.
  - No openssl, aws-lc, zstd, jemalloc or KZG.
  - Expect a large .so: about 34 MB of zkeys at v0.5.3 sizes.
- **blockchain_module_plugin:** libfyaml (NDK), boost headers, nlohmann_json, and liblogos_blockchain.

### 4. Call sequence for the Kotlin wrapper over liblogos
1. Load the module: `logos_core_load_module("blockchain_module")`.
2. If `user_config.yaml` does not exist yet, call `generate_user_config(<patches/devnet-rc4-gen-args.json>)`.
   - This uses `use_persistence_paths:true`. Alternatively pass absolute `output`, `state_path`, `storage_path` and `logs_path` under `filesDir`, because the node's defaults are relative to the CWD.
   - It returns the absolute config path.
   - A second call fails with "Keystore file exists".
3. `merge_user_config(cfg, cfg, <follower-mode.extra.yaml text>, false, false)`. This is the same pattern the module's own `pow_configure` uses.
4. `start(cfg, "")`, or `start(cfg, "<abs>/settings-0.3.0-rc.4.yaml")` for a pin build.
   - Start only when the network is up. If IBD fails, the node shuts itself down and the module does not notice.
   - Wait at least 2 s before any `stop()`: stopping sooner can deadlock Overwatch.
5. Poll every 2-5 s:
   - `get_network_info`: `n_peers > 0` is the connected signal.
   - `get_cryptarchia_info`: `height` and `slot` rise, `mode` stays Bootstrapping in follower mode.
   - `get_time_info`: `current_slot` ticks every second.
   - `get_chain_id`: expected `0.3.0-rc.4`.
6. Consume events:
   - `processedBlock`: block plus tip, tip_slot, lib, lib_slot.
   - `libBlock`.
   - `newBlock`: the payload is a JSON string wrapped as `{"block":"..."}`.
   - Each stream sends `null` once when it ends. Re-subscribe with the matching `subscribe_to_*`.
   - Never call module or FFI methods from inside an event callback on the node thread: it panics, which exits the process.
7. Show a header: `get_block(<tip>)`.
8. `stop()`.

### 5. Inter-module demo
Upstream's `blockchain_client_example` (Rust, depends on blockchain_module, polls height every 5 s) is the reference. It pulls in logos-blockchain-core and the circuits, so it is too heavy for Android.

Instead, write a universal C++ `bc_probe` with dependency `blockchain_module` (lez_probe pattern). It calls:
- `modules().blockchain_module.get_chain_id()`
- `get_time_info()`
- `get_cryptarchia_info()`
- `get_network_info()`

These are all read-only and need no network except for peers and height. `get_peer_id`, `read_accounts` and `read_pow_config` also work before start.

### 6. Other runtime facts
- **Ports.**
  - UDP 3000 (libp2p QUIC).
  - UDP 3400 (blend listener, core mode only; inferred).
  - TCP 127.0.0.1:8080 (HTTP API, always started). Change it with `http_addr`.
  - Outbound NTP.
  - NAT traversal is on by default (autonat, UPnP, NAT-PMP, and a netdev/netlink gateway monitor). If netlink misbehaves on Android, pass `external_address` to switch to static NAT.
- **Environment overrides.** `LOG_BACKEND=Stderr`, `LOG_LEVEL`, `STATE_PATH`, `HTTP_HOST`, `DEPLOYMENT` and others are read at start.
- **Docs resource minimums.** 2 cores, 1 GB RAM, SSD 100+ GB, 1 Mbps; ADX required on x86_64 (rapidsnark).
- **Devnet load.** About 1 block per 30 s (f=1/30, 1 s slots; inferred).
- **On-device RAM, disk and bandwidth.** Not measured.

### 7. Open questions
- Are the devnet peers reachable, and is devnet still on rc.4?
- How do netdev/netlink behave on Android 11+?
- Does tokio accept a 1-year sleep for the bootstrap period? (Inferred yes.)
- Do wallet calls fail cleanly or panic when the circuit libs are stubs?
- What are the real .so size, RAM and CPU figures?
- Does NDK resolve rapidsnark's `-lc++` to `c++_shared` as expected?
- Does the x86_64 emulator expose ADX? (Only matters once proving runs.)
- Which calls does the Basecamp blockchain UI make? (Its repo is not available locally.)

