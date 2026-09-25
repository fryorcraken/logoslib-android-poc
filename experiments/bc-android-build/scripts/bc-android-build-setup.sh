#!/usr/bin/env bash
# bc-android-build step 1: copy logos-blockchain at the rev the blockchain module pins,
# make sure the pinned toolchain + android targets exist, dump the dependency tree,
# and fetch the prebuilt inputs (circuits v0.5.7 host bundle for data files, iden3 rapidsnark android zips).
set -u
EXP=${REPO_ROOT}/.work/experiments/bc-android-build
UP=${REPO_ROOT}/.work/upstream
REV=35a4a666e22a51eb98fe8a050854e57fe3420899
mkdir -p "$EXP/logs" "$EXP/src" "$EXP/dl" "$EXP/out" "$EXP/patches"
exec > >(tee "$EXP/logs/setup.log") 2>&1
echo "== $(date -Is) setup"

SRC="$EXP/src/logos-blockchain"
if [ ! -d "$SRC/.git" ]; then
  git clone --shared "$UP/logos-blockchain" "$SRC"
fi
if ! git -C "$SRC" cat-file -e "$REV^{commit}" 2>/dev/null; then
  git -C "$SRC" fetch --depth 30 https://github.com/logos-blockchain/logos-blockchain.git "$REV"
fi
git -C "$SRC" -c advice.detachedHead=false checkout "$REV"
git -C "$SRC" log -1 --format='HEAD %H %ci %s'
echo "-- c-bindings diff pinned..fresh HEAD (c4c86be):"
git -C "$SRC" diff --stat "$REV" c4c86be18c58b5b09c3650e93871c8cfb624885b -- c-bindings Cargo.toml Cargo.lock flake.nix rust-toolchain.toml 2>&1 | tail -20
echo "-- lbc / rapidsnark pins at REV:"
grep -n 'lbc-.*tag\|rust-rapidsnark.*rev' "$SRC/Cargo.toml"
grep -n 'logos-blockchain-circuits/v\|rust-rapidsnark/' "$SRC/flake.nix"
cat "$SRC/rust-toolchain.toml" | grep channel

echo "== toolchain"
cd "$SRC" || exit 1
rustup show active-toolchain || rustup toolchain install "$(grep channel rust-toolchain.toml | cut -d'"' -f2)"
TC_CH=$(grep channel rust-toolchain.toml | cut -d'"' -f2)
rustup target add --toolchain "$TC_CH" x86_64-linux-android aarch64-linux-android
rustup target list --toolchain "$TC_CH" --installed
cargo --version
rustc --version

echo "== cargo tree (android x86_64)"
cargo tree -p logos-blockchain-c --target x86_64-linux-android -e normal,build > "$EXP/out/cargo-tree-x86_64-android.txt" 2> "$EXP/logs/cargo-tree.err"
echo "tree-exit=$? lines=$(wc -l < "$EXP/out/cargo-tree-x86_64-android.txt")"
tail -5 "$EXP/logs/cargo-tree.err"
# (the first run used --no-dedupe here, which took ~30 min; the deduped listing gives the same unique set)
cargo tree -p logos-blockchain-c --target x86_64-linux-android -e normal,build --prefix none 2>/dev/null | sed 's/ (\*)//; s/ (proc-macro)//' | sort -u > "$EXP/out/cargo-tree-x86_64-android.unique.txt"
wc -l < "$EXP/out/cargo-tree-x86_64-android.unique.txt"
cargo metadata --format-version 1 --filter-platform x86_64-linux-android > "$EXP/out/metadata-x86_64-android.json" 2> "$EXP/logs/metadata.err"
echo "metadata-exit=$?"

echo "== downloads"
cd "$EXP/dl" || exit 1
CT=logos-blockchain-circuits-v0.5.7-linux-x86_64.tar.gz
[ -f "$CT" ] || curl -fL --retry 3 -o "$CT" "https://github.com/logos-blockchain/logos-blockchain-circuits/releases/download/v0.5.7/$CT"
echo "circuits sri: sha256-$(openssl dgst -sha256 -binary "$CT" | base64)  (expected sha256-kqDGrYENSGYxUYt7myR6K2b2avb4+N3OOBrLvf7cD38=)"
[ -d logos-blockchain-circuits-v0.5.7-linux-x86_64 ] || tar -xzf "$CT"
find logos-blockchain-circuits-v0.5.7-linux-x86_64 -maxdepth 2 | sort
for a in x86_64 arm64; do
  Z=rapidsnark-android-$a-v0.0.8.zip
  [ -f "$Z" ] || curl -fL --retry 3 -o "$Z" "https://github.com/iden3/rapidsnark/releases/download/v0.0.8/$Z"
  sha256sum "$Z"
  unzip -o -q "$Z"
done
find . -maxdepth 3 -path '*rapidsnark-android*' | sort
echo DONE
