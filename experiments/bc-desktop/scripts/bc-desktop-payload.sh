#!/usr/bin/env bash
# bc-desktop: native payload of the blockchain_module host (from the /proc/<pid>/maps captured in run2)
# and a close look at liblogos_blockchain.so (sizes, NEEDED, sections, circuit/prover content).
set -u
source ${REPO_ROOT}/.work/scripts/bc-desktop-common.sh
OUT="$E/logs/payload"
mkdir -p "$OUT" "$E/stripped"
MAPS="$E/logs/run2/host.maps.end"
[ -f "$MAPS" ] || MAPS="$E/logs/run2/host.maps"
[ -f "$MAPS" ] || MAPS="$E/logs/run1/host.maps"
{
echo "maps file: $MAPS"
awk '{print $6}' "$MAPS" | grep -E '\.so' | sort -u > "$OUT/host-so.txt"
while read -r f; do printf '%11d  %s\n' "$(stat -L -c %s "$f")" "$f"; done < "$OUT/host-so.txt" | sort -n -r > "$OUT/host-so-sized.txt"
cat "$OUT/host-so-sized.txt"
awk '{t+=$1} END {printf "blockchain_module host: %d mapped .so, %d bytes (%.1f MiB)\n", NR, t, t/1048576}' "$OUT/host-so-sized.txt"
echo "== grouped =="
awk '{
  f=$2; g="other";
  if (f ~ /liblogos_blockchain/) g="liblogos_blockchain (Rust node)";
  else if (f ~ /blockchain_module_plugin/) g="blockchain_module plugin";
  else if (f ~ /libfyaml/) g="libfyaml";
  else if (f ~ /libQt6/) g="Qt6 libs";
  else if (f ~ /liblogos|logos_host|liblgx|package_manager/) g="logos runtime";
  else if (f ~ /boost/) g="boost";
  else if (f ~ /openssl|libssl|libcrypto/) g="openssl";
  else if (f ~ /glibc|libc\.so|libm\.so|ld-linux|libpthread|libdl|librt/) g="glibc";
  else if (f ~ /gcc|libstdc|libgcc/) g="libstdc++/libgcc";
  else if (f ~ /icu/) g="icu";
  s[g]+=$1; c[g]++
} END { for (g in s) printf "%-34s %3d files %10d bytes (%.1f MiB)\n", g, c[g], s[g], s[g]/1048576 }' "$OUT/host-so-sized.txt" | sort -k5 -n -r

B="$MODS/blockchain_module/liblogos_blockchain.so"
PL="$MODS/blockchain_module/blockchain_module_plugin.so"
echo "== installed module files =="
ls -la "$MODS/blockchain_module"
for f in "$B" "$PL" "$MODS"/blockchain_module/libfyaml*; do
  [ -f "$f" ] || continue
  b=$(basename "$f")
  strip --strip-unneeded -o "$E/stripped/$b" "$f" 2>/dev/null || cp "$f" "$E/stripped/$b"
  printf '%-34s raw=%11d stripped=%11d gzip9(stripped)=%11d xz(stripped)=%11d\n' "$b" "$(stat -c %s "$f")" "$(stat -c %s "$E/stripped/$b")" "$(gzip -9 -c "$E/stripped/$b" | wc -c)" "$(xz -9 -c "$E/stripped/$b" | wc -c)"
done
echo "== liblogos_blockchain.so: file / NEEDED / RUNPATH / SONAME =="
file -L "$B"
readelf -d "$B" | grep -E 'NEEDED|RUNPATH|RPATH|SONAME'
echo "== liblogos_blockchain.so: sections (largest) =="
size -A "$B" | sort -k2 -n -r | head -12
echo "== exported C API =="
nm -D --defined-only "$B" | awk '$2=="T"{print $3}' | sort > "$OUT/lb-exports.txt"
wc -l < "$OUT/lb-exports.txt"; tr '\n' ' ' < "$OUT/lb-exports.txt"; echo
echo "== undefined (imported) symbols count and libc++/libstdc++ ABI hints =="
nm -D --undefined-only "$B" | wc -l
nm -D --undefined-only "$B" | grep -c -E '_ZNSt|_ZSt|GLIBCXX'
nm -D --undefined-only "$B" | grep -o -E 'GLIBC_[0-9.]+|GLIBCXX_[0-9.]+|CXXABI_[0-9.]+' | sort -u | tr '\n' ' '; echo
echo "== circuit / prover content probes (strings) =="
for pat in pol_generate_witness poq_generate_witness poc_generate_witness signature_generate_witness groth16_prover rapidsnark __gmpz proving_key .zkey witness_generator verification_key rocksdb RocksDB sqlite libp2p quic; do
  printf '%-28s %s\n' "$pat" "$(strings -n 6 "$B" | grep -c -F "$pat")"
done
echo "== embedded circuit artefacts (byte probes against the v0.5.7 circuits bundle the build used) =="
python3 "$W/scripts/bc-desktop-embedprobe.py" "$B" /nix/store/wzi7bxa2nvlcnsy7q6cm2m0yk0nnqhig-logos-blockchain-circuits-0.5.7
echo "== symbol-table probes (static/local symbols survive only if not stripped) =="
nm "$B" 2>&1 | head -2
echo "== plugin NEEDED =="
readelf -d "$PL" | grep -E 'NEEDED|RUNPATH'
} 2>&1 | tee "$E/logs/payload.txt"
