#!/usr/bin/env bash
# bc-android-build step 2: cargo metadata for the android target, prebuilt inputs
# (circuits v0.5.7 host bundle for data files, iden3 rapidsnark v0.0.8 android zips),
# circuits repo copy at v0.5.7 with submodules, circom 2.2.2.
set -u
EXP=${REPO_ROOT}/.work/experiments/bc-android-build
SRC="$EXP/src/logos-blockchain"
IN="$EXP/inputs"
mkdir -p "$EXP/logs" "$IN" "$EXP/out" "$EXP/tools"
exec > >(tee "$EXP/logs/inputs.log") 2>&1
echo "== $(date -Is) inputs"

cd "$SRC" || exit 1
cargo metadata --format-version 1 --filter-platform x86_64-linux-android > "$EXP/out/metadata-x86_64-android.json" 2> "$EXP/logs/metadata.err"
echo "metadata-exit=$? bytes=$(stat -c %s "$EXP/out/metadata-x86_64-android.json")"

echo "== downloads"
cd "$IN" || exit 1
CT=logos-blockchain-circuits-v0.5.7-linux-x86_64.tar.gz
[ -f "$CT" ] || curl -fsSL --retry 3 -o "$CT" "https://github.com/logos-blockchain/logos-blockchain-circuits/releases/download/v0.5.7/$CT"
echo "circuits sri: sha256-$(openssl dgst -sha256 -binary "$CT" | base64)  (expected sha256-kqDGrYENSGYxUYt7myR6K2b2avb4+N3OOBrLvf7cD38= from circuits-nix-hashes.json 0.5.7 x86_64-linux)"
[ -d logos-blockchain-circuits-v0.5.7-linux-x86_64 ] || tar -xzf "$CT"
find logos-blockchain-circuits-v0.5.7-linux-x86_64 -maxdepth 2 -printf '%p %s\n' | sort
for a in x86_64 arm64; do
  Z=rapidsnark-android-$a-v0.0.8.zip
  [ -f "$Z" ] || curl -fsSL --retry 3 -o "$Z" "https://github.com/iden3/rapidsnark/releases/download/v0.0.8/$Z"
  sha256sum "$Z"
  unzip -o -q "$Z"
done
find . -path '*rapidsnark-android*' -printf '%p %s\n' | sort

echo "== circuits repo v0.5.7 + submodules"
CS="$EXP/src/logos-blockchain-circuits"
if [ ! -d "$CS/.git" ]; then
  git clone --shared ${HOME}/src/logos-blockchain/logos-blockchain-circuits "$CS"
fi
git -C "$CS" -c advice.detachedHead=false checkout v0.5.7
git -C "$CS" log -1 --format='%H %d %s'
git -C "$CS" config submodule.circomlib.url https://github.com/iden3/circomlib.git
git -C "$CS" config submodule.rapidsnark.url https://github.com/iden3/rapidsnark.git
git -C "$CS" submodule update --init --recursive 2>&1 | tail -20
git -C "$CS" submodule status --recursive
ls "$CS/rapidsnark"

echo "== circom"
nix eval --raw nixpkgs#circom.version 2>&1; echo
if [ ! -x "$EXP/tools/circom/bin/circom" ]; then
  if [ ! -d "$EXP/src/circom" ]; then
    git clone --branch v2.2.2 --depth 1 https://github.com/iden3/circom.git "$EXP/src/circom"
  fi
  cd "$EXP/src/circom" || exit 1
  git log -1 --format='%H %d'
  START=$(date +%s)
  RUSTFLAGS="-A dead_code" cargo install --locked --path circom --root "$EXP/tools/circom" 2>&1 | tail -5
  echo "circom build seconds=$(( $(date +%s) - START ))"
fi
"$EXP/tools/circom/bin/circom" --version
echo DONE
