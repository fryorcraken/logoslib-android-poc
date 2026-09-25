#!/usr/bin/env bash
# ndk-runtime: proposed minimal Android patches for logos-module-loader-qt
# (logos_host_qt + parent-side loader), applied to the experiment clone, saved
# as diffs, then checked:
#   * logos_host.cpp / qt_app.cpp  -fsyntax-only for x86_64 Android at API 28 and
#     34, unpatched vs patched, with the Qt 6.11.1 android_x86_64 headers and the
#     logos SDK headers (logos-plugin-qt, logos-protocol, logos-module)
#   * the patched parent-side loader rebuilt into the prefix (smoke re-run tests
#     host discovery without LOGOS_HOST_PATH)
set -u
W=${REPO_ROOT}/.work/experiments/ndk-runtime
NDK=${HOME}/android-ndk/android-ndk-r27c
TC=$NDK/toolchains/llvm/prebuilt/linux-x86_64
PREFIX=$W/prefix/x86_64
QT=${REPO_ROOT}/.work/probe/qt/6.11.1/android_x86_64
LC=${HOME}/src/logos-co
NINJA=/nix/store/7bgiqc706pzzb1gmwgpzdfg491w4a8nx-ninja-1.13.1/bin/ninja
R=$W/src/logos-module-loader-qt
LOG=$W/logs/host-patches.log
export TMPDIR=$W/tmp
mkdir -p "$W/logs" "$W/patches" "$TMPDIR"
exec 3>&1 >"$LOG" 2>&1
trap 'grep -E "^(CHECK|PATCH|BUILD)" "$LOG" >&3' EXIT
date -Is

syntax() { # tag api file
  local tag=$1 api=$2 f=$3
  if "$TC/bin/clang++" --target=x86_64-linux-android$api --sysroot="$TC/sysroot" -std=c++17 -fPIC -fsyntax-only \
      -DQT_CORE_LIB -DQT_NETWORK_LIB -DQT_REMOTEOBJECTS_LIB \
      -I"$R/src/host" -I"$LC/logos-plugin-qt/cpp" -I"$LC/logos-protocol/cpp" -I"$LC/logos-module/src" \
      -isystem "$PREFIX/include" -isystem "$QT/include" -isystem "$QT/include/QtCore" \
      -isystem "$QT/include/QtNetwork" -isystem "$QT/include/QtRemoteObjects" \
      -DSPDLOG_COMPILED_LIB -DSPDLOG_FMT_EXTERNAL -DSPDLOG_SHARED_LIB -DFMT_SHARED "$f"; then
    echo "CHECK $tag api$api $(basename "$f"): compiles"
  else
    echo "CHECK $tag api$api $(basename "$f"): COMPILE ERROR"
  fi
}

git -C "$R" checkout -q -- .
for api in 28 34; do
  syntax upstream $api "$R/src/host/logos_host.cpp"
  syntax upstream $api "$R/src/host/qt/qt_app.cpp"
done

python3 - "$R" <<'PY'
import sys
r = sys.argv[1]
def sub(path, old, new):
    p = f"{r}/{path}"
    s = open(p).read()
    assert old in s, (path, old[:60])
    open(p, "w").write(s.replace(old, new, 1))

# A. backtrace(3) is bionic API 33+: guard it (the handler still reports the
#    signal and re-raises; frames are just absent below API 33).
sub("src/host/logos_host.cpp",
"""#ifndef _WIN32
#include <execinfo.h>
#endif""",
"""#if !defined(_WIN32) && (!defined(__ANDROID__) || __ANDROID_API__ >= 33)
#include <execinfo.h>
#define LOGOS_HAVE_BACKTRACE 1
#endif""")
sub("src/host/logos_host.cpp",
"""    void* frames[64];
    const int n = ::backtrace(frames, 64);""",
"""    void* frames[64];
#ifdef LOGOS_HAVE_BACKTRACE
    const int n = ::backtrace(frames, 64);
#else
    const int n = 0;  // bionic: backtrace(3) only from API 33
#endif""")

# B. Android packaging of the host executable: APKs only install lib*.so into
#    nativeLibraryDir, and CMake's Android platform ignores INSTALL_RPATH, so
#    name it liblogos_host_qt.so and give it DT_RUNPATH=$ORIGIN.
sub("src/CMakeLists.txt",
"""# RPATH so the wrapped binary finds Qt / SDK libs at runtime
if(APPLE)""",
"""# RPATH so the wrapped binary finds Qt / SDK libs at runtime
if(ANDROID)
    # An APK installs only lib*.so into nativeLibraryDir, and CMake's Android
    # platform emits no rpath for INSTALL_RPATH: name the host accordingly and
    # let it find its sibling libraries next to itself.
    set_target_properties(logos_host_qt PROPERTIES
        OUTPUT_NAME "liblogos_host_qt" SUFFIX ".so")
    target_link_options(logos_host_qt PRIVATE "LINKER:-rpath,$ORIGIN")
elseif(APPLE)""")

# C. Parent-side host discovery on Android: program_location() is
#    /system/bin/app_process64 inside an app, so also look next to the library
#    this code is linked into (liblogos_core.so in nativeLibraryDir), for the
#    lib-prefixed name from B. LOGOS_HOST_PATH keeps precedence.
sub("src/qt_plugin_format_loader.cpp",
"""    for (const auto& name : {"logos_host_qt", "logos_host"}) {
        auto candidate = (dir / (std::string(name) + kExeSuffix)).lexically_normal();
        if (fs::exists(candidate))
            return candidate;
    }
    return {};""",
"""    for (const auto& name : {"logos_host_qt", "logos_host"}) {
        auto candidate = (dir / (std::string(name) + kExeSuffix)).lexically_normal();
        if (fs::exists(candidate))
            return candidate;
    }
#ifdef __ANDROID__
    // APKs install only lib*.so files, so the host ships as liblogos_host_qt.so.
    if (auto candidate = (dir / "liblogos_host_qt.so").lexically_normal(); fs::exists(candidate))
        return candidate;
#endif
    return {};""")
sub("src/qt_plugin_format_loader.cpp",
"""    if (logosHostPath.empty() || !fs::exists(logosHostPath)) {
        if (!modulesDirs.empty()) {""",
"""#ifdef __ANDROID__
    // Inside an app, program_location() is /system/bin/app_process64; the host
    // sits next to the library this code is linked into (nativeLibraryDir).
    if (logosHostPath.empty()) {
        auto found = findInDir(fs::path(boost::dll::this_line_location().parent_path().string()));
        if (!found.empty())
            logosHostPath = found.string();
    }
#endif

    if (logosHostPath.empty() || !fs::exists(logosHostPath)) {
        if (!modulesDirs.empty()) {""")
PY
echo "PATCH apply exit=$?"
git -C "$R" diff -- src/host/logos_host.cpp > "$W/patches/logos-module-loader-qt-A-host-backtrace-api33.diff"
git -C "$R" diff -- src/CMakeLists.txt > "$W/patches/logos-module-loader-qt-B-host-android-name-rpath.diff"
git -C "$R" diff -- src/qt_plugin_format_loader.cpp > "$W/patches/logos-module-loader-qt-C-loader-android-host-discovery.diff"
git -C "$R" diff > "$W/patches/logos-module-loader-qt-android-all.diff"
git -C "$R" diff --stat | sed 's/^/PATCH /'

for api in 28 34; do
  syntax patched $api "$R/src/host/logos_host.cpp"
  syntax patched $api "$R/src/host/qt/qt_app.cpp"
done

# Rebuild the parent-side loader (patch C) into the prefix.
B=$W/build/logos-module-loader-qt-parent-x86_64
rm -rf "$B"
cmake -S "$W/src/wrap/loader-qt-parent" -B "$B" -G Ninja -DCMAKE_MAKE_PROGRAM="$NINJA" \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=x86_64 -DANDROID_PLATFORM=android-34 -DANDROID_STL=c++_shared \
  -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_FIND_ROOT_PATH="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH -DBoost_USE_STATIC_LIBS=ON \
  -DLOADER_QT_SRC="$R" -DLOGOS_CONTAINER_ROOT="$PREFIX" -DLOGOS_MODULE_LOADER_ROOT="$PREFIX" \
  && cmake --build "$B" -j16 -- -k 0 && cmake --install "$B"
echo "BUILD patched loader-qt-parent exit=$?"
date -Is
