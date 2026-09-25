# lez_probe

A minimal universal Logos Core module whose only job is to call `lez_core`. It demonstrates
inter-module communication over liblogos's own transport. It declares
`"dependencies": ["lez_core"]`, and logos-module-builder generates the typed
`modules().lez_core.*` client from that dependency. The module contains no hand-written IPC.

| Method | Calls |
| --- | --- |
| `ping()` | nothing |
| `lez_version()` | `lez_core.version()` |
| `to_base58_via_lez(hex)` | `lez_core.account_id_to_base58(hex)` |
| `roundtrip_via_lez(hex)` | `lez_core.account_id_to_base58`, then `account_id_from_base58` |

All of these are offline: no wallet and no network.

Desktop build: `nix build .#lgx` in this directory. It pins the same logos-module-builder
revision as lez_core `825d2a4`, and the flake input named `lez_core` resolves the
dependency. It built in 15 s and ran under logoscore (see
[`experiments/desktop-probe`](../../experiments/desktop-probe)). Android build: see
milestone M3/M7 in [`docs/plan.md`](../../docs/plan.md).

Keep each method declaration in `src/lez_probe_impl.h` on one line, because the code
generator parses the header line by line.
