# Experiment: bc-desktop

> Blockchain-module research, 2026-09-25. Machine-written by the experiment agent; scripts and
> small logs in [../../experiments/bc-desktop](../../experiments/bc-desktop); patches in [../../patches](../../patches);
> node config fixtures in [../../config/blockchain](../../config/blockchain). `.work/` paths are local scratch.


### Summary
The blockchain_module (logos-blockchain-module 4b07e58, which builds the node at logos-blockchain 35a4a666) works end to end under liblogos on Linux x86_64 with the probe's logoscore and lgpm. The .lgx build took 19.7 min (1002 derivations built, 226 fetched, 1.0 GiB download). Its closure is 811 MiB and the .lgx file is 48.7 MB. load-module takes 41-102 ms. The live API has 48 module methods plus name/version/lidl (51 total) and 3 events (newBlock, processedBlock, libBlock). The repo's committed blockchain_module.lidl is stale: it lists 41 methods.

Three runs:
- **run1, the module's own runtime doctest.** A peerless generated config goes Bootstrapping to Online at height 0 and emits no events.
- **run2, the node repo's own standalone config pair.** A one-node chain produced 719 blocks in 12 min, with one Groth16 leadership proof per block. That is 2127 events, about 1.23 CPU cores on average, and host RSS growing from 99 to 340 MB.
- **run3, public devnet.** The master-built module joined devnet 0.3.0-rc.4. It used rc.4's embedded deployment file plus one added key (mempool.tx_ttl) and 4 dial-only peers at 65.108.203.235. It synced 4958 blocks in about 30-40 s at about 1.1 cores, then followed the head at about 0.1% CPU with RSS flat at 288 MB.

The module's default deployment at this rev is a placeholder "standalone-local" chain with X.Y.Z protocol names, so it joins no public network without an explicit deployment file.

Payload:
- **liblogos_blockchain.so:** 89.8 MB, already stripped. It compresses to 47.0 MB with gzip -9 and 33.6 MB with xz. It embeds all 4 Bedrock zkeys, the witness .dat files and the verification keys (34.0 MiB, found by byte probes). strace shows no circuit file is opened at runtime. It needs only libstdc++, libgcc_s, libm, libc and ld-linux.
- **Host process:** maps 58 .so files, 172.4 MiB in total.

Runtime surprises:
- rapidsnark writes MyLogFile.log into the host's working directory on every proof.
- The plugin prints every full block JSON to stderr.
- The node always opens an HTTP API TCP listener and a QUIC UDP port.
- start() blocks until all services are up. Restarting a synced but still-Bootstrapping node took about 26 s, longer than the 20 s default RPC timeout.

Inter-module call: a 5-file bc_probe module (dependencies ["blockchain_module"]) was built in 19 s. It called modules().blockchain_module.get_cryptarchia_info, get_time_info and get_network_info in 0-1 ms each and tracked the height live (20 CLI round trips in 257 ms). All started processes were stopped cleanly and the socket dir was left empty.

### Results
- [pass|verified-by-experiment] 1. Build the .lgx from rev 4b07e58: output name, build time, closure size
  The flake exposes #lgx (also default, lgx-portable, install, headers-lp/-qt, lidl, rust-client-example*, apps.generate, checks.unit-tests). Command: nix build -L --cores 8 --max-jobs 2 github:logos-blockchain/logos-blockchain-module/4b07e58b8ae9bfea3e953f234c97d1f276e799a0#lgx. The rev must be the full hash for github: URLs. Build: exit 0 in 1184 s (19.7 min). The dry-run listed 1002 derivations to build and 226 paths to fetch (1.0 GiB download, 3.8 GiB unpacked). Rust 1.98.1 via crane: deps-only check 4m03s, deps build 4m41s, main logos-blockchain-c crate 7m05s. Release profile is codegen-units=1, lto=fat, strip=true (Cargo.toml:11-14). The Qt/SDK closure was already in the store. Free disk went from 64G to 60G during the build. Closures: lgx 811.4 MiB, module-lib 765.0 MiB, module 855.0 MiB. .lgx file 48,664,128 B, variant linux-amd64-dev (plugin 3,553,248 B + libfyaml.so.0 804,584 B + liblogos_blockchain.so 89,783,760 B + assets/lidl). The module's flake.lock pins logos-blockchain 35a4a666 (2026-09-22) with circuits v0.5.7 (ebf7ddf), matching the Cargo.lock lbc-*-sys v0.5.7. The fresh upstream clone (c4c86be) is shallow and does not contain 35a4a666; nix fetched it to /nix/store/774q3zqa7pm44p8fjjqybnhsycq3mhss-source.
  evidence: .work/experiments/bc-desktop/logs/build-summary.txt; Line numbers are from .work/experiments/bc-desktop/logs/lgx-build.txt: 8318 and 8830 (deps Finished 4m03s / 4m41s), 8912 (main crate Finished 7m05s); .work/experiments/bc-desktop/logs/flakeshow.txt, lgx-dryrun.txt; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain-module/flake.lock:194-200 (logos-blockchain rev 35a4a666); /nix/store/774q3zqa7pm44p8fjjqybnhsycq3mhss-source/Cargo.toml:11-14
- [pass|verified-by-experiment] 2. Install with lgpm, seed built-ins, start daemon under the experiment dir, load blockchain_module, dump module-info
  Install: lgpm --modules-dir .../bc-desktop/modules --allow-unsigned install --file <lgx>, 0.6 s. The daemon ran with --config-dir .../bc-desktop/cfg and --persistence-path .../bc-desktop/persist and was up in 265-272 ms. load-module blockchain_module took 41 ms (run1), 102 ms (run2) and ok (run3), with no dependencies. module-info lists 48 module methods plus name/version/lidl, all returning 'result' ({success,value,error}), and 3 events: newBlock(tstr), processedBlock(tstr), libBlock(tstr). The committed repo .lidl has only 41 methods; it lacks subscribe_to_new/processed/lib_blocks, merge_user_config, pow_configure, read_accounts and read_pow_config. Use module-info or the lidl shipped in the .lgx (assets/lidl, 3494 B) as the contract. DEVIATION: TMPDIR/socket dir is .work/bcs, not under experiments/bc-desktop. Any dir under experiments/bc-desktop is at least 84 bytes, and 84 + 37 exceeds the 108-byte sun_path limit, which crashes capability_module (desktop-probe C13). Qt canonicalises tempPath, so a symlink does not help. The dir is empty after clean stops.
  evidence: .work/experiments/bc-desktop/logs/install.txt; .work/experiments/bc-desktop/logs/run1/module-info.json (9312 B) and run1/run.log:14-17; .work/scripts/bc-desktop-common.sh (SOCK comment)
- [answered|verified-from-source] 3a. Which network does the shipped config target?
  None public. The embedded default deployment at 35a4a666 has protocol names like /logos-blockchain/*/X.Y.Z and a genesis inscription decoding to 'standalone-local'. get_chain_id returned 'standalone-local' in run1. lifecycle.rs:26-30 documents: 'binary default deployment (e.g. devnet for release candidates and testnet for releases)'. Release tags carry the real settings.yaml; master carries a placeholder. Testnet (65.109.51.37, the config doctest's peer) runs 0.2.x with protocol names testnet-0.2.1 (0.2.3 settings). Devnet (65.108.203.235) runs 0.3.0-rc.4. The module's config/node_config.yaml is an old-schema devnet config that no code or test references. The runtime doctest deliberately runs peerless with skip_ibd.
  evidence: /nix/store/774q3zqa7pm44p8fjjqybnhsycq3mhss-source/nodes/node/binary/src/config/deployment/settings.yaml:6,20-22,92,116,129; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/upstream/logos-blockchain/c-bindings/src/api/lifecycle.rs:26-30; .work/experiments/bc-desktop/logs/nodesrc.txt, releases.txt, releases2.txt, deploydiff.txt
- [pass|verified-by-experiment] 3b. run1: the module's runtime doctest flow (generated config, skip_ibd, no peers)
  Call sequence: get_cryptarchia_info returns error 'The node is not running.'. generate_user_config @args.json with {skip_ibd, net_port 3200, blend_port 3201, http_addr 127.0.0.1:18480, output user_config.yaml, use_persistence_paths} takes 20 ms and returns <persist>/blockchain_module/<inst>/user_config.yaml plus keystore.yaml. The generated config's bootstrap wait is shortened from 3600 s to 5 s by editing the YAML. start <cfg> '' takes 48 ms. Mode goes Bootstrapping, then Online at t+5 s; height and slot stay 0. get_chain_id returns standalone-local. get_time_info returns {current_epoch 2007, current_slot 12042737, genesis 1778280849000, slot 1000 ms}. get_network_info shows all zeros. blend_info returns node_id with core_info null. wallet_get_known_addresses returns 6 addresses. wallet_get_balance returns 'Unknown wallet address.' (as the doctest documents). pow_claimable_rewards returns 0. get_peer_id and read_accounts work. get_blocks 0 10 returns []. stop takes 30 ms. does_state_exist returned FALSE after 40 s, while the doctest (runtime.test.yaml:299-305) expects true; the cause was not investigated. 0 events. Host RSS: 34 MB loaded, 67 MB peak after start, about 56 MB steady, 41-42 threads, about 0.2% CPU.
  evidence: .work/experiments/bc-desktop/logs/run1/run.log:19-157; .work/experiments/bc-desktop/logs/run1/daemon.log
- [pass|verified-by-experiment] 3c. Real-work signal offline: node repo's standalone single-node chain (run2)
  start <standalone/node.yaml> <standalone/deployment.yaml> took 48 ms; the files are the node repo's own pair with ports and paths changed (patch 02). The node proposed a block every slot: height 718 after about 12 min, 719 'proposed block' log lines, 719 Groth16 proofs in rapidsnark's log. LIB trailed tip by 30 slots. Events: 719 newBlock (about 1.2 KB), 719 processedBlock (about 1.2 KB), 689 libBlock (about 200 B). The first event arrived 7 s after start. Wallet balances were readable (e3635f... = 100000). get_block and get_block_events on the tip worked. Why a single staker wins every slot was not investigated. Resources over 707 s: 1.23 cores average (1.14-1.29). RSS grew roughly linearly from 99 to 327 MB (hwm 340 MB, 57-58 threads) with no plateau seen. The state DB was 53 MB after 719 blocks, mostly an unflushed 50.9 MB RocksDB WAL. daemon.log 1.15 MB, node file log 342 KB, rapidsnark MyLogFile.log 1.03 MB.
  evidence: .work/experiments/bc-desktop/logs/run2/run.log; .work/experiments/bc-desktop/logs/run2/analysis.txt; .work/experiments/bc-desktop/logs/run2/events.jsonl; .work/experiments/bc-desktop/logs/run2/MyLogFile.log
- [pass|verified-by-experiment] 3d. Real-work signal online: can the master-built module join a public network? (run3, devnet)
  Yes, devnet. Deployment = devnet 0.3.0-rc.4's embedded settings.yaml plus mempool.tx_ttl (patch 01). tx_ttl is the only key-level schema difference; it was added preemptively and parsing without it was not tried. The config was generated through the module with initial_peers /ip4/65.108.203.235/udp/{3000,3001,3002,50001}/quic-v1 (no peer ids) and explicit paths. Results: get_chain_id returned 0.3.0-rc.4. n_peers was 4 within 10 s. With no IBD peers the node still synced by chain sync, from height 402 at t+10 s to 4958 by t+40 s, at about 1.1 cores and about 150 blocks/s. After that it followed the head: tip slot advanced in step with wall-clock time and gained 9 blocks in 5 min. Following cost about 0.1% of a core with RSS flat at 288 MB. The DB was 17.4 MB after 4960 blocks. There were 9946 events (27 MB of JSON) and 12 MB of daemon.log in 6.5 min. Mode stayed Bootstrapping and LIB stayed at genesis because the generated prolonged_bootstrap_period is 3600 s. Phase B (stop, then start in the same host with IBD peers) needed about 26.5 s to replay 4958 blocks. The CLI call therefore failed with METHOD_FAILED 'timed out after 20000ms', although the node did start. The second start also logs 'Ctrl-C signal handler already registered'. Testnet (0.2.x) was not tried.
  evidence: .work/experiments/bc-desktop/logs/run3/run.log:27-205 and :216-297; .work/experiments/bc-desktop/logs/run3/network-info-A.json; .work/experiments/bc-desktop/logs/deploydiff.txt; .work/experiments/bc-desktop/patches/01-devnet-deployment-tx_ttl.diff
- [pass|verified-by-experiment] 3e. Ports, runtime files, circuit artefacts (strace openat/execve)
  Ports held by the host: UDP 0.0.0.0:<net_port> (libp2p QUIC; 3200, 3210 or 3220) and TCP 127.0.0.1:<http_addr> (the node's HTTP API; 18480, 18481 or 18482, always started). Blend ports were never bound because the node is not a core blend node. Outbound traffic goes to NTP pool.ntp.org:123 and to peers. Files opened: the config and deployment YAML, the RocksDB dir, the node file-log dir, /etc/hosts, /etc/resolv.conf, /etc/localtime, locale-archive, /sys/class/net/*/{type,speed}, /sys/devices/system/cpu/{online,possible}, /proc/sys/kernel/random/uuid, and relative 'MyLogFile.log' (rapidsnark's trace, written to the process working directory on every proof). NO zkey, .dat, verification key or circuit files were opened in any run, and no TLS certificate stores. Artefacts are compiled in: pol/src/lib.rs:79 uses lbc_pol_sys::artifacts::PROVING_KEY. Side effect: in run2, MyLogFile.log landed in the POC project root (the host's working directory). It was moved to logs/run2/, and run3 starts the daemon from its own run directory.
  evidence: .work/experiments/bc-desktop/logs/run{1,2,3}/strace-summary.txt and opened.txt; .work/experiments/bc-desktop/logs/run2/run.log:37-39,334-348; /nix/store/774q3zqa7pm44p8fjjqybnhsycq3mhss-source/zk/proofs/pol/src/lib.rs:76-81
- [pass|verified-by-experiment] 4. Native payload: .so in the host's /proc/<pid>/maps; liblogos_blockchain.so raw/stripped/gzip; NEEDED
  The blockchain_module host maps 58 .so files, 180,772,760 B (172.4 MiB). By group: liblogos_blockchain 85.6 MiB, ICU 37.7 MiB (desktop Qt build), 'other' desktop libs 16.6, Qt6 Core/Network/RemoteObjects 12.7, openssl 8.4, glibc 3.6, libstdc++/gcc 3.6, plugin 3.4, libfyaml 0.8. liblogos_blockchain.so: raw 89,783,760 B, already stripped (profile strip=true, nm reports no symbols), gzip -9 46,998,283 B, xz -9 33,617,740 B. Sections: .rodata 48,989,192; .text 34,358,880; .eh_frame 2,296,120; .gcc_except_table 1,429,056. Byte probes found all 12 Bedrock artefacts 5/5 each (pol/poq/poc/signature zkey + witness .dat + vk = 35,640,804 B, 34.0 MiB of .rodata). NEEDED: libstdc++.so.6, libgcc_s.so.1, libm.so.6, libc.so.6, ld-linux-x86-64.so.2. No openssl. RUNPATH points at glibc-2.42/gcc-15.2 while the host runs glibc-2.40/gcc-14.3; this works because the highest symbol versions needed are GLIBC_2.38 and GLIBCXX_3.4.30. There are 54 exported C functions. 434 undefined dynamic symbols, 171 of them libstdc++ (RocksDB 10.4.2, circuit witness generators, rapidsnark). Plugin: 3,553,248 raw / 2,917,520 stripped / 1,053,007 gzip; it NEEDS liblogos_blockchain.so, libfyaml.so.0, Qt6 RO/Network/Core, boost_system, ssl, crypto and libstdc++. libfyaml: 804,584 / 733,496 / 307,884.
  evidence: .work/experiments/bc-desktop/logs/payload.txt; .work/experiments/bc-desktop/logs/payload/host-so-sized.txt; .work/scripts/bc-desktop-embedprobe.py
- [pass|verified-by-experiment] 5. Inter-module call against blockchain_module (lez_probe pattern)
  bc_probe is a universal module. It pins the same module-builder rev as blockchain_module (16e2f6b, 0.3.1) and has a flake input named blockchain_module pointing at 4b07e58, with metadata dependencies ["blockchain_module"]. It built in 19 s (3 derivations); the generated wrapper blockchain_module_api.h has 51 methods and 3 events. The generated std client returns StdLogosResult ({success, value (json), error}), and get_cryptarchia_info's value is a JSON string. Calls ran while the standalone node was producing blocks: chain_info_via_bc returned height/slot/tip/lib/mode in 0-1 ms; time_info_via_bc and network_info_via_bc also worked; height_via_bc tracked the live height (56, 658, 718). 20 sequential CLI calls (CLI to bc_probe to blockchain_module) took 257 ms in total. load-module bc_probe took 39 ms with blockchain_module already loaded. bc_probe host RSS was 24.7 MB. Recommended read-only target: get_cryptarchia_info. It is cheap, works in every state, and returns a clean 'The node is not running.' error when stopped. get_time_info and get_network_info are good secondary targets.
  evidence: .work/experiments/bc-desktop/src/bc_probe/; .work/experiments/bc-desktop/logs/bcprobe-summary.txt, bcprobe-build.txt; .work/experiments/bc-desktop/logs/run2/run.log:40-53,267-286
- [pass|verified-by-experiment] Clean shutdown / no leftover processes
  Each run ends with blockchain_module.stop (23-68 ms), then logoscore stop. The daemon exits along with its strace wrapper, and the socket dir .work/bcs is empty. pgrep for logos_host/logoscore found nothing afterwards. The stop log contains about 19 lines of 'ERROR ... task N was cancelled' (Overwatch shutdown noise).
  evidence: .work/experiments/bc-desktop/logs/run1/run.log:161-170; run2/run.log:374-382; run3/run.log:206-215
- [partial|open] Open items
  Not settled by these runs:
- Does RSS in block-producer mode plateau? It grew about 20 MB/min for 12 min.
- Why does the standalone single staker win every slot?
- Why did does_state_exist return false after run1 when the doctest expects true?
- Is tx_ttl actually required when parsing the rc.4 deployment?
- Can this build join testnet (0.2.x, older schema without pow_config)?
- Does the LIB stay at genesis on devnet only because of the 3600 s Bootstrapping hold, which makes restart replay grow with chain length?
- How long do PoL proving and RocksDB take on ARM or Android?
- What does rapidsnark's MyLogFile.log do when the working directory is read-only (Android's /)?
- Will master stay wire-compatible with devnet after rc.4?
  evidence: 

### Patches
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-desktop/patches/01-devnet-deployment-tx_ttl.diff: add mempool.tx_ttl to devnet 0.3.0-rc.4's deployment so node 35a4a666 parses it. This is the only key-level difference; with it the master-built module joined devnet.
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-desktop/patches/02-standalone-node-config-paths-ports.diff: the node repo's standalone-node-config.yaml with ports changed (3000 to 3210, API 8080 to 18481) and absolute state and log dirs, so it runs inside logoscore without clashes. This is the offline block-producer real-work fixture.
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-desktop/patches/03-generated-config-short-bootstrap.diff: the module doctest's edit of the generated config, prolonged_bootstrap_period 3600 s to 5 s, so the node reaches Online quickly.

### Artifacts
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-desktop/blockchain-lgx (-> /nix/store/62a1k21mspk7xgicqkp7pkwqq1sngbay-logos-blockchain_module-module-lib-lgx-0.0.999, 48.7 MB .lgx)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-desktop/blockchain-lib (-> logos-blockchain_module-module, headers + lib)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-desktop/modules/ (blockchain_module, bc_probe, capability_module, modules_state as installed)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-desktop/src/bc_probe/ (inter-module probe module source + flake.lock)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-desktop/bcprobe-lgx
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-desktop/standalone/{node.yaml,deployment.yaml}
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-desktop/devnet-data/deployment-devnet-0.3.0-rc.4.yaml
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-desktop/deployments/settings-{0.2.3,0.3.0-rc.4}.yaml
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-desktop/logs/run1/{run.log,daemon.log,module-info.json,module-info.txt,user_config.yaml,strace-summary.txt}
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-desktop/logs/run2/{run.log,daemon.log,events.jsonl,analysis.txt,host.maps.end,MyLogFile.log,strace-summary.txt}
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-desktop/logs/run3/{run.log,daemon.log,events.jsonl,network-info-A.json,strace-summary.txt}
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-desktop/logs/{build-summary.txt,lgx-build.txt,lgx-dryrun.txt,install.txt,payload.txt,bcprobe-summary.txt,nodesrc.txt,releases.txt,releases2.txt,deploydiff.txt}
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/bc-desktop/stripped/ (stripped copies used for size measurements)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/bcs (empty short QtRO socket dir, see deviation)

### Repro
All scripts are in /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/ and are run as 'bash <path>'. Shared variables and helpers are in bc-desktop-common.sh, which the others source. Logs go to .work/experiments/bc-desktop/logs/.
1. bc-desktop-flakeshow.sh: flake metadata, flake show, #lgx dry-run.
2. bc-desktop-nodesrc.sh: locate node source 35a4a666; show embedded deployment, ceremony inputs, standalone configs.
3. bc-desktop-build.sh: nix build --cores 8 --max-jobs 2 of #lgx and #default, time and closure sizes. Background it; bc-desktop-wait.sh waits for it.
4. bc-desktop-tools.sh: strace 6.16 from cache.nixos.org.
5. bc-desktop-releases.sh, bc-desktop-releases2.sh, bc-desktop-deploydiff.sh: remote tags, testnet/devnet settings.yaml, schema diff against master.
6. bc-desktop-install.sh: seed built-ins, lgpm install, manifest, NEEDED.
7. bc-desktop-build-bcprobe.sh: build and install the inter-module probe from .work/experiments/bc-desktop/src/bc_probe.
8. bc-desktop-run1-solo.sh: module runtime doctest flow under strace (about 45 s).
9. bc-desktop-run2-standalone.sh: standalone block producer plus bc_probe calls, 12 min (background; bc-desktop-wait-run2.sh). Then bc-desktop-mylog.sh moves rapidsnark's MyLogFile.log out of the project root, and bc-desktop-run2-analyse.sh digests the run.
10. bc-desktop-payload.sh (uses bc-desktop-embedprobe.py): mapped .so set, sizes, sections, NEEDED, embedded zkeys.
11. bc-desktop-run3-devnet.sh: devnet join in 2 phases, about 6.5 min (background; bc-desktop-wait-run3.sh).
12. bc-desktop-strace.sh: openat/execve summaries for all runs.
13. bc-desktop-patches.sh: writes patches/*.diff.

Minimal manual sequence (daemon with --config-dir/--persistence-path and TMPDIR at 70 bytes or fewer):
- logoscore load-module blockchain_module
- Offline block producer: logoscore call blockchain_module start <standalone/node.yaml> <standalone/deployment.yaml>, then poll get_cryptarchia_info. Height rises about 1/s.
- Devnet: logoscore call blockchain_module generate_user_config @gen-args.json (initial_peers /ip4/65.108.203.235/udp/{3000,3001,3002,50001}/quic-v1), then start <user_config.yaml> <deployment-devnet-0.3.0-rc.4.yaml>. n_peers reaches 4 and height about 4958 within about 40 s.
- logoscore watch blockchain_module --json streams newBlock, processedBlock and libBlock.

### Next steps
- Android real-work target: use the standalone pair (patch 02) as the offline test and devnet rc.4 (patch 01 + 4 dial peers) as the online test. The standalone test also exercises PoL proving: embedded zkeys, circom witness generation, GMP, rapidsnark. For a sync-only phone demo, a devnet follower costs about 0.1% CPU and about 290 MB RSS after sync.
- Call start() through an in-process LogosAPIClient with a Timeout well above 20 s. start blocks until every service is up, and a restart replays all blocks since LIB (26.5 s for 4958 blocks while LIB is stuck at genesis during the 3600 s Bootstrapping hold). Consider lowering prolonged_bootstrap_period.
- Before running on Android, chdir the host process to an app-private writable dir, or patch rapidsnark's logger. rapidsnark writes MyLogFile.log (about 1.4 KB per proof) to the working directory on every Groth16 proof.
- Patch the plugin's on_new_block_callback (logos_blockchain_module.cpp:490) to stop printing every full block JSON to stderr. It produced 12 MB of daemon log in 6.5 min of devnet sync and would flood logcat.
- The generated config always runs the HTTP API on TCP and NTP to pool.ntp.org. On Android pin http_addr to 127.0.0.1:<port>, or find a way to disable the API; check NTP reachability.
- Android native build of liblogos_blockchain (NDK r27c, libc++_shared, 16 KB pages) needs: RocksDB 10.4.2 C++ via librocksdb-sys; lbc-*-sys v0.5.7 circuit libs built with the NDK, whose zkeys, .dat and vk (34 MiB) are embedded at build time via include_bytes!, so LBC_ROOT_DIR must hold the v0.5.7 release data files (reuse them, never regenerate); rust-rapidsnark with iden3 Android libs via RAPIDSNARK_LIB_DIR; and the lbc-build -lstdc++ fix. Budget about 47 MB gzip (about 34 MB xz) for this .so, and fat LTO with codegen-units=1 (7 min for the main crate on x86 desktop).
- Run the standalone producer longer (30-60 min) to see whether host RSS plateaus. It grew about 20 MB/min to 340 MB in 12 min.
- Pin a devnet-compatible node rev for Android. Master 35a4a666 plus the rc.4 deployment works today, but master's embedded deployment is a placeholder and future master commits may break wire compatibility. Alternatively override the module's logos-blockchain input to tag 0.3.0-rc.4. Testnet (0.2.x) was not tried.

---

## Full report

## bc-desktop: blockchain_module under liblogos on Linux x86_64

### Summary
The blockchain_module works end to end on desktop under liblogos. I built it from logos-blockchain-module 4b07e58, which pins the node at logos-blockchain 35a4a666. It ran headless with the probe's logoscore and lgpm, and an inter-module probe called into it successfully.

### Build (verified-by-experiment)
- **Command:** `nix build --cores 8 --max-jobs 2 github:logos-blockchain/logos-blockchain-module/4b07e58b8ae9bfea3e953f234c97d1f276e799a0#lgx`. The rev must be the full hash.
- **Time:** 1184 s (19.7 min). 1002 derivations built, 226 paths fetched (1.0 GiB).
- **Rust breakdown:** deps check 4m03s, deps build 4m41s, main crate 7m05s. The release profile uses fat LTO with codegen-units=1.
- **Closures:** lgx 811.4 MiB, module-lib 765.0 MiB.
- **.lgx file:** 48.7 MB, variant linux-amd64-dev.
- **Pins:** node 35a4a666 and circuits v0.5.7 in both flake.lock and Cargo.lock, so no drift.

### API (verified-by-experiment)
- **Methods:** `module-info` lists 48 methods plus name/version/lidl. Every method returns `result` = {success, value, error}.
- **Events:** newBlock, processedBlock, libBlock.
- **Stale committed lidl:** the repo's `blockchain_module.lidl` has only 41 methods. It is missing subscribe_to_* ×3, merge_user_config, pow_configure, read_accounts and read_pow_config.
- **Contract to use:** module-info, or the lidl shipped inside the .lgx.

### Which network (verified-from-source)
- **Default deployment:** the default embedded at 35a4a666 is a placeholder "standalone-local" chain with `X.Y.Z` protocol names. Real network settings are only committed at release tags.
- **Testnet** (65.109.51.37) runs 0.2.x.
- **Devnet** (65.108.203.235) runs 0.3.0-rc.4.

### Runs
| run | setup | result | host RSS | CPU |
|---|---|---|---|---|
| run1 | Module's runtime doctest: generated config, skip_ibd, bootstrap shortened to 5 s | Online at height 0, no events. `does_state_exist` returned false, but the doctest expects true. | 34 MB loaded, about 56-67 MB running | about 0.2% |
| run2 | Node repo's standalone pair (patch 02) | 719 blocks in 12 min, one PoL Groth16 proof per block. 2127 events. Wallet balances readable. | 99 → 340 MB, still growing | 1.23 cores |
| run3 | Devnet rc.4 deployment + tx_ttl (patch 01), 4 dial-only peers | 4 peers. Synced 4958 blocks in about 30-40 s, then followed the head. | 288 MB flat | 1.1 cores while syncing, about 0.1% while following |

### Runtime behaviour to know before Android
- **Ports:** the host opens UDP for libp2p QUIC and always opens a TCP listener for the node's HTTP API. It also contacts NTP at pool.ntp.org:123.
- **Circuit files:** none are opened at runtime. All 4 zkeys, the witness .dat files and the verification keys (34.0 MiB) are embedded in `liblogos_blockchain.so`.
- **Stray log file:** rapidsnark writes `MyLogFile.log` into the process working directory on every proof. In run2 it landed in the POC project root; I moved it to `logs/run2/`.
- **Log volume:** the plugin prints every full block JSON to stderr, which gave 12 MB of daemon log in 6.5 min of devnet sync.
- **Slow start on restart:** `start()` blocks until all services are up. A restart replays every block since LIB. On devnet LIB stayed at genesis because the generated config holds the node in Bootstrapping for 3600 s. The restart took 26.5 s, longer than the 20 s default RPC timeout, so the CLI reported a timeout even though the node did start.
- **Second start in the same process:** it logs "Ctrl-C signal handler already registered".

### Payload (verified-by-experiment)
- **Host process:** maps 58 .so files, 172.4 MiB in total.
- **liblogos_blockchain.so size:** 89.8 MB and already stripped. It compresses to 47.0 MB with gzip -9 and 33.6 MB with xz.
- **Sections:** .rodata 49.0 MB (34 MiB of it is embedded circuit data), .text 34.4 MB.
- **NEEDED:** libstdc++, libgcc_s, libm, libc, ld-linux. Nothing else.
- **Symbol versions:** at most GLIBC_2.38 and GLIBCXX_3.4.30.
- **C API:** 54 exported functions.
- **Plugin:** 2.9 MB stripped. **libfyaml:** 0.73 MB stripped.

### Inter-module call (verified-by-experiment)
- **Module:** `bc_probe`, 5 files, `dependencies ["blockchain_module"]`. It built in 19 s.
- **Calls:** it uses the generated `modules().blockchain_module.*` client (return type StdLogosResult). Calls to get_cryptarchia_info, get_time_info and get_network_info each took 0-1 ms.
- **Timing:** 20 CLI round trips (CLI → bc_probe → blockchain_module) took 257 ms in total.
- **Recommended read-only target:** `get_cryptarchia_info`.

### Deviation
The socket dir (TMPDIR) is `.work/bcs`, not a directory under `experiments/bc-desktop`. The shortest possible path under the experiment dir is 84 bytes, and the socket name adds 37. That exceeds the 108-byte sun_path limit, which is known to crash capability_module. A symlink does not help because Qt resolves tempPath to its canonical path.

### Cleanup
No process I started is left running, and the socket dir is empty. The experiment dir uses 307 MB, and Nix store use grew by about 4-5 GB.
