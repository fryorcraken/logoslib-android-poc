#!/usr/bin/env bash
# Post-build checks on out/<triple>/liblogos_blockchain.so: weak TLS-wrapper undefineds, embedded circuit data,
# libc++ vs libstdc++ symbol binding, build-path leakage.
set -u
EXP=${REPO_ROOT}/.work/experiments/bc-android-build
TC=${HOME}/android-ndk/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64/bin
for T in x86_64-linux-android aarch64-linux-android; do
  O="$EXP/out/$T"
  SO="$O/liblogos_blockchain.so"
  [ -f "$SO" ] || continue
  case $T in x86_64*) A=x86_64;; *) A=aarch64;; esac
  exec > >(tee "$EXP/logs/verify-$T.log") 2>&1
  echo "=== $T"
  echo "-- binding of undefined rocksdb TLS wrappers"
  "$TC/llvm-readelf" --dyn-syms -W "$SO" | grep -E '_ZTH|_ZTW' | head
  echo "-- undefined WEAK count / GLOBAL count"
  "$TC/llvm-readelf" --dyn-syms -W "$SO" | awk '$7=="UND" && $5=="WEAK"' | wc -l
  "$TC/llvm-readelf" --dyn-syms -W "$SO" | awk '$7=="UND" && $5=="GLOBAL"' | wc -l
  echo "-- C++ runtime symbols imported (sample) and which NEEDED lib provides them"
  "$TC/llvm-nm" -D --undefined-only "$SO" | awk '{print $2}' | grep -E '^_Zn|^_Zd|__cxa_|__gxx_personality|_ZNSt3__1|_ZNKSt3__1' | wc -l
  L=${HOME}/android-ndk/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/$T
  "$TC/llvm-nm" -D --defined-only "$L/34/libstdc++.so" | awk '{print $3}' | sed 's/@.*//' | sort -u > "$O/libstdcxx-syms.txt"
  "$TC/llvm-nm" -D --undefined-only "$SO" | awk '{print $2}' | sed 's/@.*//' | sort -u > "$O/undefined.txt"
  echo "undefined symbols that the minimal system libstdc++.so also defines: $(comm -12 "$O/undefined.txt" "$O/libstdcxx-syms.txt" | tr '\n' ' ')"
  echo "-- embedded circuit data (first 256 bytes of each file searched in the .so)"
  python3 - "$SO" "$EXP/lbc-android/$A" <<'PY'
import sys, os
so = open(sys.argv[1], 'rb').read()
root = sys.argv[2]
for c in ("poc", "pol", "poq", "signature"):
    for f in ("proving_key.zkey", "verification_key.json", "witness_generator.dat"):
        p = os.path.join(root, c, f)
        d = open(p, 'rb').read()
        full = so.find(d) >= 0
        head = so.find(d[:256]) >= 0
        print(f"{c}/{f:22s} size={len(d):9d} head-in-so={head} full-copy-in-so={full}")
PY
  echo "-- witness generator + rapidsnark code present (strings)"
  grep -c -a 'Witness generation \[circom main()\] failed' "$SO"
  grep -c -a 'Not all inputs have been set' "$SO"
  "$TC/llvm-strings" -n 6 "$SO" | grep -c -i 'groth16\|rapidsnark\|zkey'
  echo "-- build-path leakage"
  "$TC/llvm-strings" -n 8 "$SO" | grep -o '${HOME}/[^ ]*' | cut -d/ -f1-6 | sort | uniq -c | sort -rn | head -8
  echo "-- /etc paths referenced"
  "$TC/llvm-strings" -n 6 "$SO" | grep -o '/etc/[A-Za-z0-9_./-]*' | sort | uniq -c
done
