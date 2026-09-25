# hello_module

The smallest useful Logos module. It exists to prove the Android wrapper (see
[`docs/plan.md`](../../docs/plan.md), M3 and M4) before a real module is loaded.

It is a universal core module with no dependencies. The whole implementation is the impl
class in [`src/hello_module_impl.h`](src/hello_module_impl.h); the generators derive its
contract from that header:

```
module hello_module {
  method ping() -> tstr                 // "pong"
  method echo(text: tstr) -> tstr       // text, unchanged
  method add(a: int, b: int) -> int     // a + b
  method fire(tag: tstr) -> bool        // emits hello(tag), returns true

  event hello(tag: tstr)
}
```

## Building

`scripts/android/build-runtime.sh` builds it for Android (step `hello`). The script copies
this directory to `build/android/<abi>/modsrc/hello_module`, runs the code generators
there, as logos-module-builder's Nix path does for an `interface: "universal"` module, and
configures this `CMakeLists.txt` with the Qt/NDK toolchain. The generated sources never
land in this directory.

The result is staged as `build/android/<abi>/modules/hello_module/`:

- `hello_module_plugin.so`
- `manifest.json`, whose `main` is keyed by the variant liblgx reports under bionic
  (`linux-x86_64-dev` on x86_64, `linux-arm64-dev` on arm64-v8a)
- `variant`

There is no desktop (Nix) build of this module.
