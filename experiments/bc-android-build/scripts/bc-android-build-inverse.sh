#!/usr/bin/env bash
# Who pulls each native crate into logos-blockchain-c for the android target?
set -u
EXP=${REPO_ROOT}/.work/experiments/bc-android-build
cd "$EXP/src/logos-blockchain" || exit 1
exec > >(tee "$EXP/out/cargo-tree-inverse.txt") 2>&1
for c in openssl-sys native-tls librocksdb-sys bzip2-sys libz-sys ring rust-rapidsnark logos-blockchain-circuits-poc-sys logos-blockchain-circuits-pol-sys logos-blockchain-circuits-poq-sys logos-blockchain-circuits-signature-sys; do
  echo "=================== $c"
  cargo tree --offline -p logos-blockchain-c --target x86_64-linux-android -e normal -i "$c" --depth 6 2>&1 | head -60
done
