# logoslib-android-poc

A **proof of concept**: embed `liblogos_core` (the Logos Core host and module loader) in an
Android/Kotlin app, load **LEZ** (Logos Execution Zone) modules into it at runtime, and call
them.

This is the Android counterpart to
[`liblogos-electron-poc`](https://github.com/fryorcraken/liblogos-electron-poc), which did the
same thing inside an Electron AppImage with the `delivery` module. It takes the opposite
trade-off to
[`logos-android-wrap-poc`](https://github.com/fryorcraken/logos-android-wrap-poc), which skips
`liblogos_core` and wraps each Nim library's C FFI directly. That approach needs a hand-written
JNI shim per library and has no shared inter-module transport.

## Status

**Investigation done; desktop reference working; Android build not started.**

| Bar | State |
| --- | --- |
| Source-grounded investigation of the module graph, circuits, Qt/Android, call routes and packaging | Done: [`docs/investigation.md`](docs/investigation.md) |
| lez_core loaded and driven under liblogos, plus the live LEZ testnet read | Done on desktop (Linux x86_64): [`experiments/desktop-probe`](experiments/desktop-probe) |
| Inter-module call (`lez_probe` → `lez_core`) over liblogos's own transport | Done on desktop: [`modules/lez_probe`](modules/lez_probe) |
| Pure-C, in-process module calls through the `lp_*` C ABI (the route the JNI shim will use) | Done on desktop: [`experiments/lp-inprocess`](experiments/lp-inprocess) |
| Android gating experiments: JVM-less Qt on the emulator, `wallet_ffi` for Android, NDK runtime build | In progress |
| Kotlin app on the emulator: load, call, inter-module | Not started. See [`docs/plan.md`](docs/plan.md) (M1-M8) |

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
- **The open Android question is where modules run.** liblogos spawns one `logos_host_qt`
  process per module. On Android that process would be an executable in `nativeLibraryDir`
  running with no JavaVM (minSdk 33 or higher), and it breaks `wallet_ffi`'s TLS verifier.
  The alternative is a new in-process container. The gating experiments decide between the
  two.

## Layout

```
docs/investigation.md    findings, each marked verified-from-source / by-experiment / inferred
docs/plan.md             milestones M0-M8 with acceptance checks
docs/research/           per-track research notes with claims, evidence and verifier verdicts
experiments/             desktop probe and in-process lp_* harness (scripts + logs)
modules/lez_probe/       tiny module that calls lez_core, for the inter-module demo
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
