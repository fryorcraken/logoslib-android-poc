#!/usr/bin/env bash
# wallet-android: clone logos-execution-zone, fetch the rev locked by
# logos-execution-zone-module 825d2a4 (d8596eb7, ref v0.2.5-rc2), check it out.
set -u
EXP=${REPO_ROOT}/.work/experiments/wallet-android
REV=d8596eb734bf9c9ce801afb92df06098a2eb098a
mkdir -p "$EXP/logs" "$EXP/patches" "$EXP/out"
LOG="$EXP/logs/setup.log"
exec > >(tee "$LOG") 2>&1

echo "== clone --shared"
if [ ! -d "$EXP/lez/.git" ]; then
  git clone --shared --no-checkout ${HOME}/src/logos-blockchain/logos-execution-zone "$EXP/lez"
fi
cd "$EXP/lez" || exit 1
if ! git cat-file -e "$REV^{commit}" 2>/dev/null; then
  echo "== fetching $REV from github"
  git fetch https://github.com/logos-blockchain/logos-execution-zone.git "$REV" || \
    git fetch https://github.com/logos-blockchain/logos-execution-zone.git v0.2.5-rc2
fi
git cat-file -e "$REV^{commit}" && echo "rev present"
git -c advice.detachedHead=false checkout -f "$REV"
git log -1 --format='%H %ci %s'
echo "== tags containing / pointing"
git fetch https://github.com/logos-blockchain/logos-execution-zone.git 'refs/tags/v0.2.5-rc2:refs/tags/v0.2.5-rc2' 2>&1 | tail -2
git rev-parse 'v0.2.5-rc2^{commit}' 2>/dev/null
echo "== toolchain files"
ls -la "$EXP/lez" | grep -i toolchain
cat "$EXP/lez"/rust-toolchain* 2>/dev/null
echo "== wallet-ffi Cargo.toml"
cat "$EXP/lez/lez/wallet-ffi/Cargo.toml" 2>/dev/null || find "$EXP/lez" -name Cargo.toml -path '*wallet-ffi*'
echo "== lez/common Cargo.toml"
cat "$EXP/lez/lez/common/Cargo.toml" 2>/dev/null || find "$EXP/lez" -name Cargo.toml -path '*common*' | head
echo "== workspace members"
grep -n -A80 '^\[workspace\]' "$EXP/lez/Cargo.toml" | head -120
echo "== rustup"
rustup --version
rustup toolchain list
echo DONE
