# logoslib-android-poc

A **proof of concept**: embed `liblogos_core` (the Logos Core host and module
loader) in an Android/Kotlin app, load **LEZ** (Logos Execution Zone) modules
into it at runtime, and call them.

This is the Android counterpart to
[`liblogos-electron-poc`](https://github.com/fryorcraken/liblogos-electron-poc),
which did the same thing inside an Electron AppImage with the `delivery`
module. It is also the opposite trade-off to
[`logos-android-wrap-poc`](https://github.com/fryorcraken/logos-android-wrap-poc),
which skips `liblogos_core` and wraps each Nim library's C FFI directly, at the
cost of a hand-written JNI shim per library and no shared inter-module
transport.

The question is whether `liblogos_core` and Qt can be embedded in an Android app
at all, and if so, what loading and driving a real LEZ module costs in APK size,
native-code complexity, and Qt-for-Android dependency.

## Status

**Investigation in progress.** Nothing here builds yet. Findings and the
implementation plan will land in this README and under `docs/`.

## Licence

Dual-licensed under [MIT](LICENSE-MIT) or [Apache 2.0](LICENSE-APACHE), at
your option.

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
