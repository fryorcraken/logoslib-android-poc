# Experiments

Evidence behind [`docs/investigation.md`](../docs/investigation.md). Each directory is a
self-contained run with its scripts and captured logs.

| Directory | What it shows | Where |
| --- | --- | --- |
| [`desktop-probe/`](desktop-probe) | lez_core 0.4.2 loads under liblogos (logoscore) from published flakes, does real wallet work, reads the live LEZ testnet, and is called by another module (`lez_probe`) over liblogos's own transport | Linux x86_64 |
| [`lp-inprocess/`](lp-inprocess) | A pure-C caller (no Qt headers) loads lez_core and calls it through the `lp_*` C ABI in-process. The only Qt C++ is a ~60-line QCoreApplication loop. This is the route the Android JNI shim will take. | Linux x86_64 |

Android gating experiments (X1-X9 in `docs/investigation.md` §8). Their full write-ups are in
`docs/research/exp-*.md`. Scripts were run from the repo root with scratch output under
`.work/` (gitignored), and paths are written as `${REPO_ROOT}` / `${HOME}`.

| Directory | What it shows | Where |
| --- | --- | --- |
| [`qt-jvmless/`](qt-jvmless) | Stock Qt 6.11.1 crashes in a JVM-less process. A fake-JavaVM prime of QtCore's `JNI_OnLoad` fixes it. `QCoreApplication`, `QPluginLoader` and QtRO work, including a helper exec'd from an APK's `nativeLibraryDir`. `Qt6Android.jar` is not needed. | x86_64 API 34 emulator |
| [`ndk-runtime/`](ndk-runtime) | Boost 1.87, spdlog/fmt, the logos container, loaders and process-stats cross-build for Android. The real `SubprocessContainer` spawns a host from inside an APK. | Emulator |
| [`lgx-icu/`](lgx-icu) | liblgx ported to the NDK's ICU C API: identical output and upstream tests pass, so no ICU ships in the APK | Desktop + NDK build |
| [`desktop-harness/`](desktop-harness) | `getPluginMethods` introspection, the first-call race, `lp_invoke` blocking vs `lp_invoke_async`, and event delivery | Desktop |
| [`bc-surface/`](bc-surface) | Blockchain module and node C-bindings: API, runtime needs, when it proves, follower mode, devnet peers | Source |
| [`bc-android-build/`](bc-android-build) | `liblogos_blockchain.so` cross-built for x86_64 and arm64, with circom circuits, GMP and witness libs built for Android and release zkeys reused | NDK build |
| [`bc-desktop/`](bc-desktop) | blockchain_module under logoscore: offline doctest; a standalone block producer (719 blocks, on-host PoL proofs); a devnet join (~5k blocks synced in ~40 s, then following at ~0.1% CPU); `bc_probe` inter-module calls | Desktop |
| [`wallet-android/`](wallet-android) | lez_core's `wallet-ffi` builds for Android (14-15 MB) and reads the LEZ testnet over HTTPS with no JVM | Emulator (LEZ no longer the target) |

The Android emulator on this host boots only with its window hidden (`-qt-hide-window`);
`-no-window` segfaults at cold boot.

## desktop-probe

The scripts expect to be run from the repo root. They keep all state under `.work/probe`
(gitignored).

```bash
nix build github:logos-co/logos-logoscore-cli/6a0a2f4e96aa078a0a30080595075bcf46fb9a5d#cli -o .work/probe/logos
nix build github:logos-co/logos-package-manager/2c56ec7bf1e187523d6ed0cb2abde04737c24414#cli -o .work/probe/lgpm
nix build github:logos-blockchain/logos-execution-zone-module/825d2a41262b9882aa0f9ca837cb03635f7980c2#lgx -o .work/probe/lez-lgx
bash experiments/desktop-probe/scripts/probe-install-lez.sh      # lgpm install into .work/probe/modules
bash experiments/desktop-probe/scripts/probe-daemon-start.sh     # daemon + capability_module + load lez_core
bash experiments/desktop-probe/scripts/probe-calls-offline.sh    # name/version/base58 round trip
bash experiments/desktop-probe/scripts/probe-calls-wallet.sh     # create_new, accounts, save, testnet block height
bash experiments/desktop-probe/scripts/probe-reopen.sh           # reopen with calibration_limit=5 (1.08 s)
bash experiments/desktop-probe/scripts/probe-daemon-stop.sh
bash experiments/desktop-probe/scripts/probe-build-lezprobe.sh   # build modules/lez_probe
bash experiments/desktop-probe/scripts/probe-intermodule2.sh     # lez_probe -> lez_core over QtRO
```

Result highlights:

- lez_core loads in 27 ms, with no module dependencies.
- `create_new` takes ~35 s at the default `calibration_limit` of 100, more than the 20 s IPC
  timeout.
- `get_current_block_height` returns 23791 from `https://testnet.lez.logos.co` in 671 ms.
- `lez_probe` → `lez_core` round trips take 0-2 ms, and `ss` shows a direct socket between
  the two module host processes.

## lp-inprocess

See [`lp-inprocess/build.sh`](lp-inprocess/build.sh) for how to build it and
[`run-2026-09-25.log`](lp-inprocess/run-2026-09-25.log) for the output.
[`run-long-tmpdir-2026-09-25.log`](lp-inprocess/run-long-tmpdir-2026-09-25.log) shows the
`sun_path` limit. With an 82-character `TMPDIR`, the QtRO socket path is 118 bytes,
`capability_module` fails to listen and crashes, and `load_module` returns 0.
