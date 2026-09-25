#!/usr/bin/env bash
# wallet-android: regenerate final patch files with a one-line rationale header
# (text before the first "diff --git" is ignored by git apply).
set -u
EXP=${REPO_ROOT}/.work/experiments/wallet-android
P="$EXP/patches"
cd "$EXP/lez" || exit 1
exec > >(tee "$EXP/logs/patches.log") 2>&1

OLD01="$P/01-common-drop-bedrock-http-client.diff"
if ! head -1 "$OLD01" | grep -q '^Rationale'; then
  { echo "Rationale: minimal form asked for in X3 - drop lez/common's only Bedrock edge (logos-blockchain-common-http-client, used only by From<BasicAuth> for BasicAuthCredentials) so wallet-ffi stops pulling Bedrock circuits/rapidsnark/GMP. BREAKS sequencer_core/indexer_core (they use that From impl); prefer 01b."; echo; cat "$OLD01"; } > "$OLD01.tmp"
  mv "$OLD01.tmp" "$OLD01"
fi

{ echo "Rationale: non-breaking replacement for 01 - make logos-blockchain-common-http-client optional in lez/common behind feature bedrock-auth, enabled only by sequencer_core and indexer_core, so wallet-ffi's graph has no Bedrock crates."; echo;
  git diff -- lez/common lez/sequencer/core/Cargo.toml lez/indexer/core/Cargo.toml; } > "$P/01b-common-bedrock-auth-feature.diff"

{ echo "Rationale: opt-in feature webpki-roots on wallet and wallet-ffi; make_subclient() calls jsonrpsee HttpClientBuilder::with_custom_cert_store(rustls ClientConfig with ring provider + webpki_roots::TLS_SERVER_ROOTS), so HTTPS to the sequencer works in a process without a JavaVM (rustls-platform-verifier panics there)."; echo;
  git diff -- lez/wallet/Cargo.toml lez/wallet/src/multi_client.rs lez/wallet-ffi/Cargo.toml Cargo.lock; } > "$P/02-wallet-webpki-roots-feature.diff"

{ echo "Rationale: full working-copy state on top of logos-execution-zone d8596eb7 (v0.2.5-rc2) = 01b + 02."; echo; git diff; } > "$P/all-combined.diff"

git diff --stat
wc -l "$P"/*.diff
head -1 "$P"/*.diff
echo DONE
