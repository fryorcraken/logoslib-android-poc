#!/usr/bin/env bash
# Save the experiment's patches as diffs (a leading "# rationale" line; git apply ignores text before "diff --git").
set -u
EXP=${REPO_ROOT}/.work/experiments/bc-android-build
P="$EXP/patches"
mkdir -p "$P"
CS="$EXP/src/logos-blockchain-circuits"
BC="$EXP/src/logos-blockchain"
{ echo "# rationale: add an android-lib target and make the ld -r / ar steps overridable (LD/AR) so the CI witness-generator Makefile can drive NDK clang++/ld.lld/llvm-ar; default linux/macos/windows behaviour unchanged. Applies to logos-blockchain-circuits v0.5.7 (ebf7ddf5)."
  git -C "$CS" diff -- .github/resources/witness-generator/Makefile; } > "$P/circuits-01-witness-makefile-android-lib.diff"
{ echo "# rationale: lbc-build emits cargo:rustc-link-lib=stdc++ for every non-macOS target; on Android emit c++ (NDK linker script -> libc++_shared) because the NDK-built circuit libs reference std::__ndk1. Applies to logos-blockchain-circuits v0.5.7 (ebf7ddf5)."
  git -C "$CS" diff -- rust/logos-blockchain-circuits-build/src/lib.rs; } > "$P/circuits-02-lbc-build-libcxx-on-android.diff"
{ echo "# rationale: point the workspace at the patched lbc-build copy via [patch] (experiment wiring; upstream would instead bump the lbc tag). Applies to logos-blockchain 35a4a666."
  git -C "$BC" diff -- Cargo.toml; } > "$P/logos-blockchain-01-patch-lbc-build.diff"
{ echo "# rationale: automatic Cargo.lock consequence of patch 01 (lbc-build source becomes a path); not hand-edited."
  git -C "$BC" diff -- Cargo.lock; } > "$P/logos-blockchain-01b-Cargo.lock-consequence.diff"
ls -la "$P"
head -1 "$P"/*.diff
