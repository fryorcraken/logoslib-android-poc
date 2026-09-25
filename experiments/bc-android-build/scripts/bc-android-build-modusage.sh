#!/usr/bin/env bash
# Which header functions does blockchain_module (4b07e58) call, and are they all exported by the android .so?
set -u
EXP=${REPO_ROOT}/.work/experiments/bc-android-build
MOD=${REPO_ROOT}/.work/upstream/logos-blockchain-module/src
for T in x86_64-linux-android aarch64-linux-android; do
  O="$EXP/out/$T"
  [ -f "$O/exports-all.txt" ] || continue
  echo "== $T"
  python3 - "$O/logos_blockchain.h" "$O/exports-all.txt" "$MOD/logos_blockchain_module.cpp" <<'PY'
import re, sys
hdr = open(sys.argv[1]).read()
hdr = re.sub(r'/\*.*?\*/', '', hdr, flags=re.S)
hdr = re.sub(r'//[^\n]*', '', hdr)
funcs = set(re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*)\s*\([^;{]*\)\s*;', hdr))
exp = set(open(sys.argv[2]).read().split())
src = open(sys.argv[3]).read()
used = sorted(f for f in funcs if re.search(r'\b' + re.escape(f) + r'\s*\(', src))
print(f"module calls {len(used)} header functions; missing from .so exports: {[f for f in used if f not in exp]}")
print("used:", " ".join(used))
PY
done
