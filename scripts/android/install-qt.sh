#!/usr/bin/env bash
# scripts/android/install-qt.sh -- install the official Qt prebuilts the Android build uses,
# with aqtinstall: the Android target Qt for each ABI and the same-version desktop Qt whose
# moc/repc/rcc run on the build machine.
#
# What gets installed (aqt --outputdir = the parent of QT_ROOT, so QT_ROOT/<arch> appears):
#   android_x86_64      qtbase + qtremoteobjects   (Qt's own 16 KB-aligned Android build,
#   android_arm64_v8a   qtbase + qtremoteobjects    libQt6Core_<abi>.so naming)
#   gcc_64              qtbase + icu + qtremoteobjects (host: libexec/moc, repc, rcc; the
#                       Android installs' target_qt.conf points at ../../gcc_64)
# Commands (the ones the qt-jvmless experiment used):
#   aqt install-qt all_os android $QT_VERSION android_x86_64 --archives qtbase -m qtremoteobjects --outputdir <out>
#   aqt install-qt all_os android $QT_VERSION android_arm64_v8a --archives qtbase -m qtremoteobjects --outputdir <out>
#   aqt install-qt linux desktop $QT_VERSION linux_gcc_64 --archives qtbase icu -m qtremoteobjects --outputdir <out>
#
# Inputs (environment, all optional):
#   QT_ROOT     where Qt ends up (env.sh default: <repo>/.work/probe/qt/6.11.1)
#   AQT_VENV    Python venv holding aqtinstall (default <repo>/.work/probe/qt-venv; created
#               with `python3 -m venv` + `pip install aqtinstall==$AQTINSTALL_VERSION`)
#   FORCE=1     reinstall a target that is already there
# Outputs
#   $QT_ROOT/{android_x86_64,android_arm64_v8a,gcc_64}   (~100 MB, ~95 MB, ~180 MB)
#   build/logs/install-qt-<abi>.log
# Pinned versions: scripts/android/versions.env (QT_VERSION 6.11.1, AQTINSTALL_VERSION 3.3.0).
# Network: pypi.org (aqtinstall), download.qt.io mirrors (Qt archives); first run only.
#
# Usage
#   bash scripts/android/install-qt.sh [x86_64|arm64-v8a|all]   (default x86_64; the host
#                                                                gcc_64 Qt is always included)
# Re-runnable: a target whose Qt6RemoteObjects CMake package is present is skipped.
set -Eeuo pipefail

WANT="${1:-x86_64}"
case "$WANT" in
  x86_64|arm64-v8a|all) ;;
  -h|--help) sed -n '2,/^set -Eeuo/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1; exit 0 ;;
  *) echo "install-qt.sh: unknown argument '$WANT' (x86_64|arm64-v8a|all; see --help)" >&2; exit 2 ;;
esac
export ABI=x86_64; [ "$WANT" = arm64-v8a ] && ABI=arm64-v8a
# shellcheck source=env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
log_setup install-qt
trap 'on_error install-qt' ERR

QT_OUT="$(dirname "$QT_ROOT")"
[ "$(basename "$QT_ROOT")" = "$QT_VERSION" ] || die "QT_ROOT must end in /$QT_VERSION (aqt installs into <out>/$QT_VERSION), got $QT_ROOT"
AQT_VENV="${AQT_VENV:-$REPO_ROOT/.work/probe/qt-venv}"
AQT="$AQT_VENV/bin/aqt"
mkdir -p "$QT_OUT"

step_begin install-qt
if [ ! -x "$AQT" ] || ! "$AQT" version 2>&1 | grep -q "v$AQTINSTALL_VERSION "; then   # prints to stderr
  say "-- creating $AQT_VENV with aqtinstall==$AQTINSTALL_VERSION"
  python3 -m venv "$AQT_VENV"
  "$AQT_VENV/bin/pip" install -q "aqtinstall==$AQTINSTALL_VERSION"
fi
"$AQT" version

targets=()
case "$WANT" in
  x86_64) targets=(android_x86_64) ;;
  arm64-v8a) targets=(android_arm64_v8a) ;;
  all) targets=(android_x86_64 android_arm64_v8a) ;;
esac
targets+=(gcc_64)

cd "$QT_OUT"   # aqt writes aqtinstall.log into the current directory
for t in "${targets[@]}"; do
  if [ "$FORCE" != 1 ] && [ -d "$QT_ROOT/$t/lib/cmake/Qt6RemoteObjects" ]; then
    say "-- $t: already installed in $QT_ROOT/$t (FORCE=1 to reinstall)"
    continue
  fi
  case "$t" in
    gcc_64) args=(linux desktop "$QT_VERSION" linux_gcc_64 --archives qtbase icu -m qtremoteobjects) ;;
    *)      args=(all_os android "$QT_VERSION" "$t" --archives qtbase -m qtremoteobjects) ;;
  esac
  say "-- aqt install-qt ${args[*]} --outputdir $QT_OUT"
  "$AQT" install-qt "${args[@]}" --outputdir "$QT_OUT"
done

# ---- sanity: what env.sh / the CMake builds use
for t in "${targets[@]}"; do
  case "$t" in
    gcc_64)
      for f in libexec/moc libexec/repc libexec/rcc lib/cmake/Qt6/Qt6Config.cmake; do
        [ -e "$QT_ROOT/gcc_64/$f" ] || die "$QT_ROOT/gcc_64/$f missing after install"
      done ;;
    android_*)
      sfx=${t#android_}; [ "$sfx" = arm64_v8a ] && sfx=arm64-v8a
      for f in "lib/libQt6Core_$sfx.so" "lib/libQt6Network_$sfx.so" "lib/libQt6RemoteObjects_$sfx.so" \
               lib/cmake/Qt6/qt.toolchain.cmake; do
        [ -e "$QT_ROOT/$t/$f" ] || die "$QT_ROOT/$t/$f missing after install"
      done ;;
  esac
  say "-- $t: OK ($(du -sh "$QT_ROOT/$t" | cut -f1))"
done
step_done install-qt "qt=$QT_VERSION aqt=$AQTINSTALL_VERSION targets=${targets[*]}"
say "install-qt: OK ($QT_ROOT: ${targets[*]})"
