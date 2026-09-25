#!/usr/bin/env bash
# bc-surface: source-level facts for the blockchain module (no builds).
#  1. remote tags of logos-blockchain / logos-blockchain-module (which public nets exist)
#  2. deployment identity + FFI surface of the latest release tags
#  3. offline cargo tree / metadata for logos-blockchain-c at the module-pinned rev, android targets
set -u
W=${REPO_ROOT}/.work
EXP=$W/experiments/bc-surface
PIN=35a4a666e22a51eb98fe8a050854e57fe3420899
LB_URL=https://github.com/logos-blockchain/logos-blockchain.git
LBM_URL=https://github.com/logos-blockchain/logos-blockchain-module.git
mkdir -p "$EXP/logs" "$EXP/out" "$EXP/src" "$EXP/patches"
exec > >(tee "$EXP/logs/all.log") 2>&1
echo "== $(date -Is) bc-surface-all"

echo "== 1. remote tags"
git ls-remote --tags "$LB_URL" | grep -v '\^{}' | awk '{print $2}' | sed 's#refs/tags/##' | sort -V > "$EXP/out/lb-tags.txt"
echo "lb tags: $(wc -l < "$EXP/out/lb-tags.txt")"; tail -12 "$EXP/out/lb-tags.txt"
git ls-remote "$LB_URL" HEAD refs/heads/master
git ls-remote --tags "$LBM_URL" | grep -v '\^{}' | awk '{print $2}' | sed 's#refs/tags/##' | sort -V > "$EXP/out/lbm-tags.txt"
echo "module tags:"; cat "$EXP/out/lbm-tags.txt"
git ls-remote "$LBM_URL" HEAD refs/heads/master

echo "== 2. release tags: deployment identity + FFI"
TAGS=$W/experiments/bc-surface/src/tags.git
[ -d "$TAGS" ] || git init -q --bare "$TAGS"
LATEST_RC=$(grep -E '^[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$' "$EXP/out/lb-tags.txt" | sort -V | tail -1)
LATEST_REL=$(grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' "$EXP/out/lb-tags.txt" | sort -V | tail -1)
echo "latest rc=$LATEST_RC latest release=$LATEST_REL"
for T in $LATEST_RC $LATEST_REL; do
  git -C "$TAGS" fetch -q --depth 1 "$LB_URL" "refs/tags/$T:refs/tags/$T" || echo "fetch $T failed"
  echo "---- tag $T: $(git -C "$TAGS" log -1 --format='%H %ci %s' "$T")"
  git -C "$TAGS" show "$T:nodes/node/binary/src/config/deployment/settings.yaml" > "$EXP/out/settings-$T.yaml" 2>&1
  grep -n -E 'protocol_name|pubsub_topic|gossipsub_protocol|inscription|locators|/ip4|faucet_pk|min_stake|threshold|security_param|slot_duration' -A0 "$EXP/out/settings-$T.yaml" | grep -v -E '^\s*$' | head -40
  echo "-- c-bindings extern fns at $T:"
  git -C "$TAGS" grep -h -o -E 'extern "C" fn [a-z_0-9]+' "$T" -- c-bindings/src | sed 's/extern "C" fn //' | sort -u > "$EXP/out/ffi-$T.txt"
  tr '\n' ' ' < "$EXP/out/ffi-$T.txt"; echo
  git -C "$TAGS" show "$T:rust-toolchain.toml" 2>/dev/null | grep channel
  git -C "$TAGS" show "$T:Cargo.toml" 2>/dev/null | grep -E 'lbc-poq-sys|rust-rapidsnark' | head -3
done

echo "== 3. local clone at module pin $PIN"
SRC=$EXP/src/logos-blockchain
if [ ! -d "$SRC/.git" ]; then
  git clone -q --shared --no-checkout "$W/upstream/logos-blockchain" "$SRC"
fi
if ! git -C "$SRC" cat-file -e "$PIN^{commit}" 2>/dev/null; then
  git -C "$SRC" fetch -q "$W/experiments/bc-android-build/src/logos-blockchain" "$PIN" 2>/dev/null \
    || git -C "$SRC" fetch -q --depth 5 "$LB_URL" "$PIN"
fi
git -C "$SRC" -c advice.detachedHead=false checkout -q -f "$PIN"
git -C "$SRC" log -1 --format='HEAD %H %ci %s'
echo "-- c-bindings extern fns at pin:"
git -C "$SRC" grep -h -o -E 'extern "C" fn [a-z_0-9]+' "$PIN" -- c-bindings/src | sed 's/extern "C" fn //' | sort -u > "$EXP/out/ffi-pin.txt"
tr '\n' ' ' < "$EXP/out/ffi-pin.txt"; echo
echo "-- FFI symbols the module (4b07e58) calls that the pin lacks:"
grep -o -E '::[a-z_0-9]+\(' "$W/upstream/logos-blockchain-module/src/logos_blockchain_module.cpp" | tr -d ':(' | sort -u > "$EXP/out/module-calls.txt"
grep -o -E '(^|[^:a-z_])(start_lb_node|shutdown_node|get_balance|transfer_funds|get_known_addresses|free_known_addresses|get_wallet_notes|free_wallet_notes|get_leader_aged_notes|free_leader_aged_notes|get_claimable_vouchers|free_claimable_vouchers|free_cstring|free_cryptarchia_info|free_time_info|free_pow_claimable_rewards|is_ok)\(' "$W/upstream/logos-blockchain-module/src/logos_blockchain_module.cpp" | sed -E 's/^[^a-z_]//; s/\($//' | sort -u >> "$EXP/out/module-calls.txt"
sort -u -o "$EXP/out/module-calls.txt" "$EXP/out/module-calls.txt"
comm -23 "$EXP/out/module-calls.txt" "$EXP/out/ffi-pin.txt"
for T in $LATEST_RC $LATEST_REL; do
  echo "-- module calls missing at $T:"; comm -23 "$EXP/out/module-calls.txt" "$EXP/out/ffi-$T.txt" | tr '\n' ' '; echo
done

echo "== 4. offline cargo tree/metadata (android)"
cd "$SRC" || exit 1
cargo --version
for TGT in aarch64-linux-android x86_64-linux-android; do
  cargo tree --offline -p logos-blockchain-c --target "$TGT" -e normal,build > "$EXP/out/tree-$TGT.txt" 2> "$EXP/logs/tree-$TGT.err"
  echo "tree $TGT exit=$? lines=$(wc -l < "$EXP/out/tree-$TGT.txt")"; tail -3 "$EXP/logs/tree-$TGT.err"
done
cargo metadata --offline --format-version 1 --filter-platform aarch64-linux-android > "$EXP/out/metadata-aarch64.json" 2> "$EXP/logs/metadata.err"
echo "metadata exit=$? bytes=$(wc -c < "$EXP/out/metadata-aarch64.json")"; tail -3 "$EXP/logs/metadata.err"
python3 "$W/scripts/bc-surface-native.py" "$SRC/Cargo.lock" "$EXP/out/tree-aarch64-linux-android.txt" "$EXP/out/metadata-aarch64.json" > "$EXP/out/native-crates-aarch64.txt" 2>&1
echo "native exit=$?"; cat "$EXP/out/native-crates-aarch64.txt"

echo "== 5. why-trees for native crates"
for C in openssl-sys openssl native-tls ring aws-lc-sys aws-lc-rs librocksdb-sys zstd-sys lz4-sys libz-sys bzip2-sys tikv-jemalloc-sys rust-rapidsnark logos-blockchain-circuits-poq-sys logos-blockchain-circuits-pol-sys logos-blockchain-circuits-poc-sys logos-blockchain-circuits-signature-sys igd-next if-watch netlink-sys rustls reqwest tonic tracing-loki quinn utoipa-swagger-ui blst c-kzg; do
  OUT=$(cargo tree --offline -p logos-blockchain-c --target aarch64-linux-android -e normal,build -i "$C" --depth 4 2>&1 | head -25)
  echo "---- $C"; echo "$OUT"
done > "$EXP/out/why.txt"
grep -c '' "$EXP/out/why.txt"
echo "-- rustls/ring/tls feature view:"
cargo tree --offline -p logos-blockchain-c --target aarch64-linux-android -e features -i rustls 2>&1 | head -40
cargo tree --offline -p logos-blockchain-c --target aarch64-linux-android -e features -i reqwest 2>&1 | head -40

echo "== 6. sizes of embedded circuit data (host bundle in nix store, v0.5.3 as proxy)"
ls -la /nix/store/ai2mn1mcxlrbhpp9b4rpgqxc2ibpqn9v-logos-blockchain-circuits-0.5.3/*/ 2>&1 | head -60
ls -la "$W/experiments/bc-android-build/dl" 2>&1 | head
du -sh "$EXP" 2>/dev/null
echo "== DONE $(date -Is)"
