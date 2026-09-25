#!/usr/bin/env bash
# bc-desktop: fetch strace (from cache.nixos.org via the same nixpkgs the Logos Qt stack uses).
set -u
E=${REPO_ROOT}/.work/experiments/bc-desktop
mkdir -p "$E/logs"
nix build 'github:NixOS/nixpkgs/e9f00bd893984bc8ce46c895c3bf7cac95331127#strace' -o "$E/strace" 2>&1 | tail -5
ls -la "$E/strace/bin/strace" && "$E/strace/bin/strace" -V | head -1
