#!/usr/bin/env bash
# Build the in-process lp_* harness (desktop, Linux x86_64).
#
# main.c is pure C (no Qt headers): it loads a module with logos_core_load_module()
# and calls it with the lp_* C ABI from a thread that is NOT the Qt thread -- the shape
# a JNI shim has on Android. qt_loop.cpp is the only Qt C++: it owns a QCoreApplication,
# logos_core_start() and exec() on one dedicated thread.
#
# Needs, from the same liblogos build (the 2026-09-25 run used the liblogos in the closure
# of logos-logoscore-cli 6a0a2f4, i.e. logos-liblogos db45024, Qt 6.9.2, logos-protocol 0.9.0):
#   LIBLOGOS_INCLUDE  dir containing logos_core.h and logos_protocol.h
#   LIBLOGOS_LIBDIR   dir containing liblogos_core.so and liblogos_protocol.so
# and pkg-config able to find the SAME Qt6Core (e.g. inside liblogos' nix develop shell).
#
# Run: TMPDIR=<short dir> ./exp_lp_inproc <modules-dir> <persistence-dir> lez_core
# Keep TMPDIR short: QtRO socket paths are $TMPDIR/logos_<module>_<12 hex> and must fit
# in sun_path (108 bytes) -- see run-long-tmpdir-2026-09-25.log for what happens otherwise.
set -euo pipefail
: "${LIBLOGOS_INCLUDE:?set LIBLOGOS_INCLUDE}" "${LIBLOGOS_LIBDIR:?set LIBLOGOS_LIBDIR}"
here="$(cd "$(dirname "$0")" && pwd)"
out="${OUT_DIR:-$here/build}"
mkdir -p "$out"
g++ -std=c++17 -fPIC -c "$here/qt_loop.cpp" -o "$out/qt_loop.o" \
  $(pkg-config --cflags Qt6Core) -I"$LIBLOGOS_INCLUDE"
gcc -std=gnu11 -c "$here/main.c" -o "$out/main.o" -I"$LIBLOGOS_INCLUDE"
g++ -o "$out/exp_lp_inproc" "$out/main.o" "$out/qt_loop.o" \
  -L"$LIBLOGOS_LIBDIR" -llogos_core -llogos_protocol $(pkg-config --libs Qt6Core) \
  -Wl,-rpath,"$LIBLOGOS_LIBDIR" -Wl,-rpath,"$(pkg-config --variable=libdir Qt6Core)" -lpthread
echo "built $out/exp_lp_inproc"
