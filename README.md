# logoslib-android-poc

A **proof of concept**: embed `liblogos_core` (the Logos Core host and module loader) in an
Android/Kotlin app, load the **Logos blockchain module** (an L1 node) into it at runtime, drive
it, and show a second module calling it over liblogos's own transport.

The first target was LEZ (`lez_core`). It was investigated in depth: see
[`docs/investigation.md`](docs/investigation.md) §1-3. The target then switched to the
blockchain module. The findings on liblogos, Qt and Android carry over unchanged.

This is the Android counterpart to
[`liblogos-electron-poc`](https://github.com/fryorcraken/liblogos-electron-poc), which did the
same thing inside an Electron AppImage with the `delivery` module. It takes the opposite
trade-off to
[`logos-android-wrap-poc`](https://github.com/fryorcraken/logos-android-wrap-poc), which skips
`liblogos_core` and wraps each Nim library's C FFI directly. That approach needs a hand-written
JNI shim per library and has no shared inter-module transport.

## Status

**The Logos blockchain node runs as a liblogos module inside an Android app and syncs the
public devnet. A second module calls it over liblogos's own transport.** Tested on the x86_64
API 34 emulator.

<img src="docs/img/m5-blockchain.png" alt="Demo app: blockchain node synced to devnet 0.3.0-rc.4, 4 peers, 5273 newBlock events, bc_probe returning the live height" width="300" align="right">

- `LogosCore` (Kotlin) starts `liblogos_core` inside the app process. Every module runs in its
  own `liblogos_host_qt.so` child process, exec'd from the APK's native library directory.
- **Blockchain module:** it joins devnet `0.3.0-rc.4` as a follower and syncs ~5.3k blocks to
  the tip in 32-38 s. It then follows the head at under 1% CPU and ~160 MB RSS. `newBlock`
  events reach Kotlin.
- **Inter-module:** `bc_probe` calls `blockchain_module` over liblogos's QtRO transport and
  returns the live height in 0-1 ms. Nothing was hand-written for the hop.
- **On-device proving:** an offline single-node chain produces a block per second, each with
  a PoL Groth16 proof generated on the device. It uses the Bedrock circuits built for
  Android.
- **Test module:** `hello_module` answers `ping` in 3-5 ms and delivers an event in 2-5 ms.

See [`docs/android-build.md`](docs/android-build.md) to build and run it, and
[`docs/blockchain-android.md`](docs/blockchain-android.md) for the node on Android.

| Bar | State |
| --- | --- |
| Source-grounded investigation of the module graph, circuits, Qt/Android, call routes and packaging | Done: [`docs/investigation.md`](docs/investigation.md) |
| Module loaded and driven under liblogos, plus an inter-module call over liblogos's transport | Done on desktop with lez_core / [`lez_probe`](modules/lez_probe): [`experiments/desktop-probe`](experiments/desktop-probe) |
| Pure-C, in-process module calls through the `lp_*` C ABI (the route the JNI shim will use) | Done on desktop: [`experiments/lp-inprocess`](experiments/lp-inprocess) |
| Qt + QtRemoteObjects in a JVM-less module process, exec'd from an APK on the emulator | Works with a ~60-line fix: [`experiments/qt-jvmless`](experiments/qt-jvmless) |
| Qt-free liblogos runtime (Boost, container, loader) cross-built and run on the emulator | Done: [`experiments/ndk-runtime`](experiments/ndk-runtime) |
| Kotlin wrapper for liblogos + a trivial module on the emulator (load, call, event, clean stop) | **Done**, 18/18 checks on the x86_64 API 34 emulator: [`android/`](android), [`scripts/android/`](scripts/android), [`docs/android-build.md`](docs/android-build.md) |
| Blockchain module under liblogos on desktop: joins devnet, syncs, follows the head; `bc_probe` calls it | Done: [`experiments/bc-desktop`](experiments/bc-desktop), [`modules/bc_probe`](modules/bc_probe) |
| Node library `liblogos_blockchain.so` for Android, with L1 circuits built for Android | **Done** by a repo script (x86_64 run; arm64 built by the experiment): [`scripts/android/build-blockchain.sh`](scripts/android/build-blockchain.sh) |
| Blockchain module on Android: devnet follower synced to the tip, `newBlock` events in Kotlin | **Done**, 17/17 checks on the emulator (M5) |
| Inter-module call on Android: `bc_probe` → `blockchain_module` | **Done** (M6) |
| arm64 phone, 16 KB-page device, phantom-process limit for a long-running node | Not tested: no arm64 emulator on this host |

## Findings in brief

- **Only `lez_core` needs loading**, plus the `capability_module` that liblogos brings up
  itself. lez_core declares no module dependencies and wraps one native library, the Rust LEZ
  wallet (`libwallet_ffi.so`). It talks only to an LEZ sequencer over HTTPS JSON-RPC.
- **"lez_core uses the blockchain module" is not right.** No Logos Core module dependency
  exists in either direction. The L1 sits *behind the sequencer*: the sequencer inscribes L2
  blocks on the L1 (data availability, ordering, finality, bridge), and the separate indexer
  reads them back. The wallet uses neither.
  - The only L1 link the wallet has is at build time, through one type conversion.
  - The framing probably comes from `blockchain-modules-release`, which packages `lez_core`
    next to `blockchain_module`.
  - The Electron POC's `delivery → rln → lez_rln → lez_core` chain came from a branch build.
    `liblogos_lez_rln_module` 3.0+ no longer depends on `lez_core`.
- **"Blockchain circuits" means two ZK stacks pulled in by the wallet library.** Neither is
  needed at runtime for a public-only demo.
  - The Bedrock circom circuits, with rapidsnark and GMP, come in through one
    `BasicAuthCredentials` conversion in `lez/common`. No Android bundle exists for them, so
    the plan is to patch that edge out.
  - RISC Zero proving sits behind the default `prove` feature. Build without it. The RISC Zero
    guest programs are prebuilt and committed.
- **No upstream Android support for liblogos or Logos modules.**
  - logos-nix master has an arm64-only Android Qt 6.11.1 set, without QtRemoteObjects, and
    it has never been built by CI.
  - The official Qt 6.11.1 Android prebuilts are the practical route: x86_64 and arm64, with
    QtRO, 16 KB-aligned, built with NDK r27c.
  - No Logos binary uses Qt private API. The Electron POC's "exact Qt version" trap therefore
    reduces to using one Qt build consistently.
- **Calling a module does not need Qt C++ after all.** The Electron POC concluded that
  in-process calls require `LogosAPI`/`LogosAPIClient` C++. The `lp_*` C ABI in
  `liblogos_protocol` does the same job from inside the host process, with no daemon, no
  gateway and no token plumbing. It was verified with a pure-C caller. The only Qt C++ left is
  about 60 lines that own a `QCoreApplication` on a dedicated thread.
- **liblogos's one-process-per-module model works on Android.** Each module's
  `logos_host_qt` ships in the APK as `liblogos_host_qt.so` and is exec'd from
  `nativeLibraryDir`. Stock Qt crashes in a process with no JavaVM, but priming QtCore's own
  `JNI_OnLoad` with a fake VM (~60 lines, no Qt rebuild) fixes it. On the emulator this was
  verified from inside an APK: exec from the APK's library dir, the SELinux rules for the
  socket between app and child, and QtRO, all with minSdk 34. The app itself does not need
  `Qt6Android.jar`.

## Layout

```
android/                 Gradle project: :logos-core (Kotlin API + JNI shim) and :demo-app
scripts/android/         NDK builds of dependencies, runtime, node library; staging, APK, emulator
docs/android-build.md    build and run from scratch; M4 acceptance evidence
docs/blockchain-android.md  node library build for Android, pins, runtime caveats
docs/investigation.md    findings, each marked verified-from-source / by-experiment / inferred
docs/plan.md             milestones M0-M8 with acceptance checks
docs/research/           per-track research notes with claims, evidence and verifier verdicts
experiments/             desktop probe, in-process lp_* harness, Android gating experiments
patches/                 narrow patches to upstream repos, grouped by repo (none upstreamed yet)
modules/hello_module/    trivial test module (ping, echo, event), runs on the emulator
modules/bc_probe/        tiny module that calls blockchain_module (inter-module demo, desktop-proven)
modules/lez_probe/       tiny module that calls lez_core (inter-module pattern, desktop-proven)
```

## Licence

Dual-licensed under [MIT](LICENSE-MIT) or [Apache 2.0](LICENSE-APACHE), at your option.

---

## Disclaimer

This is an independent community project intended to demonstrate some of the
capabilities and potential uses of the Logos technology stack. It has been
developed independently by its contributor(s) and is not built for, on behalf
of, or as part of the work of Logos or the Institute of Free Technology. It has
not been reviewed, audited, approved, or endorsed by Logos or the Institute of
Free Technology. The project, including its code, documentation, views, and
functionality, is the sole responsibility of its contributor(s) and should not
be attributed to Logos or the Institute of Free Technology.
