#!/usr/bin/env bash
# lgx-icu: desktop equivalence test. Build the same test vectors against the
# ORIGINAL (ICU C++ API) and PORTED (ICU C API) path_normalizer.cpp with nix
# ICU 76.1, run both under several locales and diff. Also run upstream's gtest
# suites (test_path_normalizer.cpp, test_platform_variant.cpp) on the port.
set -u
EXP=${REPO_ROOT}/.work/experiments/lgx-icu
mkdir -p "$EXP/logs" "$EXP/bin/desktop" "$EXP/out"
LOG="$EXP/logs/desktop.log"
exec > >(tee "$LOG") 2>&1

ICU_DEV=/nix/store/083x1zrd8rnrkq1plphxvc2vdzgk8dvj-icu4c-76.1-dev
ICU_LIB=/nix/store/w24hkb1b9v50r3sgpvmk8kwyi04x7imq-icu4c-76.1/lib
GT_DEV=/nix/store/i4jy5k3i83gdcz76d7i7ymp500rz63pw-gtest-1.17.0-dev
GT_LIB=/nix/store/1ispb16svjqwv4l2amy4jfygy5k8pkdr-gtest-1.17.0/lib
ORIG_SRC=/nix/store/7f6d5ba9jv4hkn2r923kxjxac271i5hn-source
PORT_SRC=$EXP/src/logos-package-4cdb302
B=$EXP/bin/desktop
CXX=g++
echo "compiler: $($CXX --version | head -1)"

build() { # name srcroot
  echo "--- build $1"
  $CXX -std=c++17 -O2 -Wall -Wextra \
    -I"$2/src/core" -I"$ICU_DEV/include" \
    "$EXP/test/pathnorm_vectors.cpp" "$2/src/core/path_normalizer.cpp" \
    -L"$ICU_LIB" -licuuc -Wl,-rpath,"$ICU_LIB" -o "$B/$1"
  echo "exit=$?"
}
build vectors-orig "$ORIG_SRC"
build vectors-port "$PORT_SRC"

echo
echo "== NEEDED / ICU symbols imported"
for b in vectors-orig vectors-port; do
  echo "-- $b NEEDED:"; readelf -d "$B/$b" | grep NEEDED
  echo "-- $b undefined ICU symbols:"; nm -D --undefined-only "$B/$b" | grep -i -e icu -e '_76' | sed 's/^ *//'
done

echo
echo "== run + diff under several locales"
ALLOK=1
for LOC in unset C.UTF-8 en_US.UTF-8 de_DE.UTF-8 tr_TR.UTF-8 lt_LT.UTF-8; do
  for b in vectors-orig vectors-port; do
    if [ "$LOC" = unset ]; then
      env -u LC_ALL -u LANG -u LC_MESSAGES -u LC_CTYPE "$B/$b" > "$EXP/out/$b.$LOC.txt"; rc=$?
    else
      env LC_ALL="$LOC" "$B/$b" > "$EXP/out/$b.$LOC.txt"; rc=$?
    fi
    echo "$b [$LOC] exit=$rc $(tail -1 "$EXP/out/$b.$LOC.txt")"
  done
  if cmp -s "$EXP/out/vectors-orig.$LOC.txt" "$EXP/out/vectors-port.$LOC.txt"; then
    echo "   => [$LOC] orig and port outputs IDENTICAL ($(wc -l < "$EXP/out/vectors-port.$LOC.txt") lines)"
  else
    echo "   => [$LOC] outputs DIFFER:"; diff "$EXP/out/vectors-orig.$LOC.txt" "$EXP/out/vectors-port.$LOC.txt"; ALLOK=0
  fi
done
echo "ALL_LOCALES_IDENTICAL=$ALLOK"
echo "-- locale sensitivity of toLowercase (capital-I-ascii / dotted-capital-I rows):"
grep -A1 -e '^capital-I-ascii' -e '^dotted-capital-I' "$EXP/out/vectors-port.C.UTF-8.txt" "$EXP/out/vectors-port.tr_TR.UTF-8.txt" "$EXP/out/vectors-orig.tr_TR.UTF-8.txt"

echo
echo "== upstream gtest suites"
gtest_build() { # name srcroot files...
  local name=$1 root=$2; shift 2
  $CXX -std=c++17 -O1 -I"$root/src" -I"$root/src/core" -I"$ICU_DEV/include" -I"$GT_DEV/include" \
    "$@" -L"$ICU_LIB" -licuuc -L"$GT_LIB" -lgtest -lgtest_main -pthread \
    -Wl,-rpath,"$ICU_LIB" -Wl,-rpath,"$GT_LIB" -o "$B/$name"
  echo "build $name exit=$?"
}
gtest_build gtest-pathnorm-orig "$ORIG_SRC" "$ORIG_SRC/tests/test_path_normalizer.cpp" "$ORIG_SRC/src/core/path_normalizer.cpp"
gtest_build gtest-pathnorm-port "$PORT_SRC" "$ORIG_SRC/tests/test_path_normalizer.cpp" "$PORT_SRC/src/core/path_normalizer.cpp"
gtest_build gtest-variant-port "$PORT_SRC" "$PORT_SRC/tests/test_platform_variant.cpp" "$PORT_SRC/src/core/platform_variant.cpp"
for t in gtest-pathnorm-orig gtest-pathnorm-port gtest-variant-port; do
  echo "--- $t"
  "$B/$t" 2>&1 | grep -e '^\[  PASSED' -e '^\[  FAILED' -e '^\[==========\]' -e 'Failure'
  echo "exit=${PIPESTATUS[0]}"
done
