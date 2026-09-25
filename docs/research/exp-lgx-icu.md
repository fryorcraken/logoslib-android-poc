# Experiment: lgx-icu

> Gating experiment, 2026-09-25. Machine-written by the experiment agent; logs and scripts in
> [../../experiments/lgx-icu](../../experiments/lgx-icu); patches in [../../patches](../../patches).
> `.work/` paths refer to local scratch that is not committed.


### Summary
Yes. liblgx can drop its bundled ICU on Android by using the platform ICU C API, as long as the minimum API is 31. All ICU use in liblgx sits in one file, src/core/path_normalizer.cpp (NFC normalize, the NFC check, and lowercasing). I ported it from the ICU C++ API (icu::Normalizer2 / UnicodeString) to six C functions: unorm2_getNFCInstance, unorm2_normalize, unorm2_isNormalized, u_strFromUTF8WithSub, u_strToUTF8WithSub and u_strToLower. The NDK r27c libicu.so stub exports all six, unversioned, from API 31. The NDK ships no ICU C++ API: the original file fails with "'unicode/normalizer2.h' file not found".

Results:
- **Desktop equivalence:** the original and ported files produce byte-identical output on 30 test vectors under 6 locale settings, including composed vs decomposed é, Hangul jamo, canonical reordering, singletons, composition exclusions where NFC grows (U+0958, U+1D15E), invalid UTF-8, embedded NUL, and inputs of 5000+ characters.
- **Upstream tests:** logos-package 4cdb302 built through its own flake passes 436/436 ctest both unpatched and patched. The patched liblgx no longer needs libicui18n.
- **Android build:** the whole patched liblgx (static lgx_core, shared lgx_shared, lgx CLI) cross-builds with NDK r27c for x86_64 and arm64 at API 34. The only NEEDED libraries are libz.so, libicu.so, libm, libdl, libc and libc++_shared, so no ICU ships in the APK. The desktop probe had 37.7 MiB of ICU mapped.
- **API 28:** fails at compile time ("introduced in Android 31"), and with the CMake patch it stops at configure with a clear message.

Revisions:
- The probe's lgpm 2c56ec7 locks logos-package 4cdb302, which is exactly /nix/store/7f6d5ba9...-source. The probe's logoscore 6a0a2f4 runs a liblgx built from that same source.
- The local liblogos checkout (7fee75b) pins lpm d88abaa, which locks an older logos-package, 49151f0. That rev has no platform_variant.cpp; its variant logic is in lpm's own package_manager_lib.cpp.
- path_normalizer.cpp is byte-identical in every logos-package revision found in the store, so the port applies to all of them.

Other liblgx dependencies on Android:
- **zlib:** provided by the NDK sysroot (libz.so, API 21+).
- **libsodium:** not in the NDK. It cross-builds from the official 1.0.20 tarball in about 12 s per ABI, linked statically.
- **nlohmann_json and cpp-semver:** header-only, fetched from GitHub by FetchContent at configure time.

I also wrote an __ANDROID__ branch for platform_variant.cpp as a proposal only (returns android-x86_64 / android-arm64). Nothing was run on a device or emulator.

### Results
- [pass|verified-by-experiment] Q1a: Is /nix/store/7f6d5ba9jv4hkn2r923kxjxac271i5hn-source the liblgx (logos-package) source, and which revision is it?
  Yes. It is github:logos-co/logos-package 4cdb302051ebcd231eeaeeaa2011fcf857541ce4. `nix flake prefetch github:logos-co/logos-package/4cdb302...` returns exactly this store path. Its CMakeLists.txt builds lgx_core, the optional lgx_shared (liblgx.so) and the lgx CLI. It needs ZLIB, libsodium (pkg-config or find_library), ICU uc+i18n, nlohmann_json 3.11 and cpp-semver 0.4.0 (FetchContent fallbacks for the last two). ICU is used only in src/core/path_normalizer.cpp.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/logs/revs.log (section 4: '4cdb302... -> /nix/store/7f6d5ba9...-source ^^^ MATCHES'); /nix/store/7f6d5ba9jv4hkn2r923kxjxac271i5hn-source/CMakeLists.txt:9-44,84-115; /nix/store/7f6d5ba9jv4hkn2r923kxjxac271i5hn-source/src/core/path_normalizer.cpp:3-6,13-49,108-116
- [pass|verified-by-experiment] Q1b: Which logos-package revision do logos-package-manager d88abaa and the probe's lgpm 2c56ec7 lock, and does the store path match?
  lpm 2c56ec7bf1e187523d6ed0cb2abde04737c24414 locks logos-package 4cdb302 (narHash sha256-EMV9DfMN...), which is /nix/store/7f6d5ba9 (MATCH). The probe's lgpm binary was built from lgx-lib-0.1.0.drv (hynaxz9...) with src=/nix/store/hgs0k...-7f6d5ba9...-source. The probe's logoscore 6a0a2f4 runtime closure also runs a liblgx from that same drv (/nix/store/j00icnw...-lgx-lib-0.1.0), so the whole desktop baseline uses logos-package 4cdb302. lpm d88abaa1f3f5d4a4268d7cdfbec98d816e0a0385 (the ROOT logos-package-manager input of the local logos-liblogos 7fee75b flake.lock, node logos-package-manager_5) locks logos-package 49151f003690333764d73f956d64e1245e2a0c38, which is /nix/store/ias6bmsz...-source (NOT a match). 49151f0 has no platform_variant.cpp, installed_package.* or main_resolution.*; in d88abaa the variant logic lives in lpm's own src/package_manager_lib.cpp:1368-1397 (same __APPLE__/__linux__/_WIN32 table, no __ANDROID__). The local lpm checkout 40930aa locks logos-package 542305b (/nix/store/rdzzxz...), which differs from 4cdb302 only in manifest/merge code, docs and tests. The source copied for this work is 4cdb302.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/logs/revs.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/logs/revs2.log (A: root.logos-package-manager -> logos-package-manager_5 rev=d88abaa1; B: logoscore closure lgx-lib deriver hynaxz9 -> src 7f6d5ba9; C: diff -rq results); /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/meta/lpm-2c56ec7bf1e187523d6ed0cb2abde04737c24414.flake.lock; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/meta/lpm-d88abaa1f3f5d4a4268d7cdfbec98d816e0a0385.flake.lock; /nix/store/n5y4l9nh5ad2iw7rp3plzy6s3fp608dn-source/src/package_manager_lib.cpp:1368-1397 (lpm d88abaa); /nix/store/8vw0bbq4fwsh7p3pqrbyqarpjpqw3f1s-source/src/package_manager_lib.cpp:1431 'return lgx_host_variant();' (lpm 2c56ec7)
- [pass|verified-by-experiment] Q1c: Is path_normalizer.cpp the same across the logos-package revisions in play?
  Yes. sha256 8db754f237d5... is identical in all 26 logos-package source trees in the store (1eae01c, 3cb520c, 49151f0, 4cdb302, 542305b, among others). Patch 0001 passes `git apply --check` against 49151f0, 542305b, 1eae01c and 3cb520c.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/logs/revs.log (section 6); /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/logs/patches.log
- [pass|verified-by-experiment] Q2: Does NDK r27c have ICU4C C API headers and a libicu.so stub, and can the ICU C++ API be used instead?
  Headers are in sysroot/usr/include/unicode (ICU 75.1: unorm2.h, ustring.h, utypes.h, ...), with every function marked __INTRODUCED_IN(31). sysroot/usr/include/uconfig_local.h sets U_DISABLE_RENAMING 1 (so symbols are unversioned, e.g. 'unorm2_normalize', not '_75') and U_SHOW_CPLUSPLUS_API 0. The sysroot has no unistr.h or normalizer2.h, and the libicu.so stub exports 0 C++ symbols. Stubs exist at usr/lib/<triple>/{31,32,33,34,35}/libicu.so for x86_64, aarch64, i686 and arm, and meta/system_libs.json lists 'libicu.so': '31'. The six functions the port uses are all exported (T) by the x86_64 and aarch64 stubs at both API 31 and API 34. The original C++-API file does not compile with the NDK: "fatal error: 'unicode/normalizer2.h' file not found".
  evidence: /home/fryorcraken/android-ndk/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/uconfig_local.h:27-31; /home/fryorcraken/android-ndk/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/unicode/unorm2.h:140,266,436; /home/fryorcraken/android-ndk/android-ndk-r27c/meta/system_libs.json:15; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/logs/ndk.log (section 0 and 'ORIGINAL path_normalizer.cpp (expected failure)')
- [pass|verified-by-experiment] Q2b: Port path_normalizer.cpp to the ICU C API
  toNFC uses unorm2_getNFCInstance + unorm2_normalize, with preflight/regrow on U_BUFFER_OVERFLOW_ERROR because NFC can be longer than its input. isNFC uses unorm2_isNormalized. toLowercase uses u_strToLower with locale=nullptr, which is ICU's default locale and the same thing UnicodeString::toLower() uses. The conversions are u_strFromUTF8WithSub / u_strToUTF8WithSub with 0xFFFD, which is exactly what UnicodeString::fromUTF8 / toUTF8String call, so ill-formed UTF-8 still becomes U+FFFD. The one behaviour change is on allocation failure, where toNFC now returns nullopt. The port is unconditional (not #ifdef'd) because the same C API works on desktop ICU too; desktop liblgx then needs only libicuuc.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/patches/0001-path_normalizer-use-icu-c-api.patch; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/src/logos-package-4cdb302/src/core/path_normalizer.cpp
- [pass|verified-by-experiment] Q3a: Compile + link the port and a test main with NDK clang++ --target=x86_64-linux-android34 -stdlib=libc++ -licu; NEEDED?
  Built with exit 0, no warnings: the executable vectors-port-x86_64-34 and the shared library libpathnorm-port-x86_64-34.so. NEEDED is [libicu.so, libc++_shared.so, libm.so, libdl.so, libc.so]; with -static-libstdc++ it is [libicu.so, libm.so, libdl.so, libc.so]. Undefined imports are exactly the six unversioned C functions. The same holds for aarch64-linux-android34 with -z max-page-size=16384 (LOAD align 0x4000) and for x86_64 API 31. At API 28 compilation fails with 7 errors of the form "'u_strFromUTF8WithSub' is unavailable: introduced in Android 31". With -D__ANDROID_UNAVAILABLE_SYMBOLS_ARE_WEAK__ plus the API-31 stub it links (weak 'w' imports), but still NEEDs libicu.so. The emulator was not used, so nothing ran on Android.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/logs/ndk.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/bin/android/
- [pass|verified-by-experiment] Q3b: Desktop equivalence of the ported (C API) and original (C++ API) implementations
  Both were built with g++ 15.3.1 against nix ICU 76.1 (/nix/store/083x1...-icu4c-76.1-dev, libs /nix/store/w24hkb...-icu4c-76.1/lib). Output was compared on 30 vectors under LC_ALL unset, C.UTF-8, en_US.UTF-8, de_DE.UTF-8, tr_TR.UTF-8 and lt_LT.UTF-8: byte-identical in every case (81 lines each), with 18/18 known answers passing. Examples: e+U+0301 -> U+00E9; jamo U+1112 U+1161 U+11AB -> U+D55C; U+D558+U+11AB -> U+D55C; a U+0301 U+0323 -> U+1EA1 U+0301; U+212B -> U+00C5; U+0958 -> U+0915 U+093C; U+1D15E -> U+1D157 U+1D165; FF FE abc -> FFFD FFFD abc; 5000x NFD é -> 5000x U+00E9; final sigma ΟΔΟΣ -> οδος. Upstream gtest test_path_normalizer.cpp passes 21/21 for both the original and the port.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/logs/desktop.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/out/ (vectors-{orig,port}.<locale>.txt); /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/test/pathnorm_vectors.cpp
- [pass|verified-by-experiment] Q3c: Does the full patched liblgx still pass upstream's test suite on desktop?
  Each tree was built with its own flake (#all = CLI + liblgx + ctest). Upstream 4cdb302: 436/436 tests passed, and liblgx.so NEEDs libicuuc.so.76 + libicui18n.so.76 with 11 icu_76 C++ imports. Patched: 436/436 passed, liblgx.so NEEDs only libicuuc.so.76 (libicui18n dropped), and the imports are the six *_76 C functions.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/logs/nixcheck.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/logs/nix-upstream.build.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/logs/nix-patched.build.log
- [pass|verified-by-experiment] Q4a: liblgx's other native dependencies and their availability on Android
  zlib: provided by the NDK. FindZLIB found sysroot usr/lib/<triple>/34/libz.so (zlib 1.3.0.1) and zlib.h without help; libz.so is a public NDK library from API 21, and libz.a is also present. libsodium: not in the NDK; it must be cross-built. The official libsodium-1.0.20.tar.gz (sha256 ebb65ef6...ce19) configures with --host=<triple> and the NDK clang, and builds static+PIC in 11-12 s per ABI (x86_64 libsodium.a 769,650 B; arm64 593,728 B). Linked statically, it adds no NEEDED entry, which also avoids the versioned soname libsodium.so.26. liblgx uses only Ed25519 keypair/sign/verify, crypto_hash_sha256, base64 helpers, sodium_memzero and sodium_init, so OpenSSL 3 (already required by liblogos) could replace it (inferred). nlohmann_json 3.11.3 and cpp-semver 0.4.0 are header-only, fetched from GitHub by FetchContent at configure time (the NDK toolchain's find mode ONLY hides host copies); they need vendoring for offline builds. C++17 std::filesystem and <regex> come from NDK libc++. GTest is only needed with LGX_BUILD_TESTS=ON. The patched liblgx builds end to end: x86_64 and arm64 at API 34, 67-81 s configure+build each. liblgx.so stripped is 962,352 B (x86_64) / 798,368 B (arm64), NEEDED [libz.so, libicu.so, libm.so, libc++_shared.so, libdl.so, libc.so], with 43 exported lgx_* functions. The lgx CLI also builds; there is no option to skip it.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/logs/android-lgx.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/logs/lgx-x86_64.configure.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/logs/lgx-arm64-v8a.build.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/build/lgx-x86_64-34/liblgx.so; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/build/lgx-arm64-v8a-34/liblgx.so; /home/fryorcraken/android-ndk/android-ndk-r27c/meta/system_libs.json:26
- [pass|verified-by-experiment] Q4b: CMake change for Android ICU
  When ANDROID is set, the patch runs find_library(LGX_ANDROID_ICU_LIBRARY NAMES icu) and fails with a FATAL_ERROR naming API 31 if it is missing; otherwise it runs find_package(ICU REQUIRED COMPONENTS uc) (i18n dropped). ICU::uc ICU::i18n is replaced by ${LGX_ICU_LIBRARIES} in both lgx_core and lgx_shared. At API 34 it resolved sysroot .../34/libicu.so for both ABIs. At ANDROID_PLATFORM=android-28, configure stops with: 'CMake Error at CMakeLists.txt:52: liblgx: the NDK's libicu.so was not found. The ICU4C C API is available to apps from Android API 31; build with ANDROID_PLATFORM >= 31 (current: android-28).' Desktop nix build with the change: 436/436 tests passed.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/patches/0002-cmake-android-platform-libicu.patch; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/logs/android-lgx.log (negative check)
- [pass|verified-by-experiment] Q4c: __ANDROID__ branch proposal for platform_variant.cpp (lgx_host_variant)
  The patch adds an __ANDROID__ branch placed before __linux__ (bionic defines __linux__). It returns android-arm64 (__aarch64__), android-x86_64 (__x86_64__), and 'unknown' for other ABIs (fail closed; upstream today returns 'linux-x86' for them). It also adds android rows to tests/test_platform_variant.cpp: alias cases, plus foreign-OS checks. It is written as a proposal only; whether to use it is not decided. Compile-time check (-O0 asm): original gives x86_64 'linux-x86_64', arm64 'linux-arm64', armv7/i686 'linux-x86'; patched gives 'android-x86_64', 'android-arm64', 'unknown'. The built arm64 liblgx.so contains the literal 'android-arm64'; the x86_64 -O2 build inlines the string, so strings cannot find it. The patched test_platform_variant passes 11/11 on desktop, and the nix ctest run passes 436/436. This patch applies only to logos-package revisions that have platform_variant.cpp (4cdb302, 542305b). For lpm d88abaa / logos-package 49151f0, the equivalent change belongs in lpm's package_manager_lib.cpp:1374-1396, or use PackageManagerLib::setPlatformVariantOverride.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/patches/0003-platform_variant-android-branch.patch; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/logs/ndk.log (platform_variant section); /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/logs/desktop.log (gtest-variant-port); /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/logs/android-lgx.log ('android-arm64')
- [not-run|open] Does the port run correctly on an Android device/emulator (platform libicu.so at runtime)?
  Not run, by instruction: the emulator belongs to another task. The binaries are ready to run: bin/android/vectors-port-x86_64-34-staticcxx needs only libicu/libm/libdl/libc, and its output should match out/vectors-port.C.UTF-8.txt. The device ICU version differs from the desktop's 76.1 (Android 14 = ICU 72.1, inferred), but the test vectors use only long-assigned characters. It is also unverified whether a /data/local/tmp shell executable can resolve libicu.so from the i18n APEX; an app process can.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/bin/android/vectors-port-x86_64-34-staticcxx; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/out/vectors-port.C.UTF-8.txt
- [partial|inferred] Constraint: minimum API level for this approach
  Using the platform ICU requires minSdk >= 31. Compiling at API 28 fails, and there is no libicu.so stub below 31. A weak-symbol API-28 build still has NEEDED libicu.so, which (inferred) does not exist on Android 9-11, so the library would fail to load. This is higher than the Qt 6.11 / posix_spawn floor of 28. Options if API 28-30 must be supported: dlopen("libicu.so") lazily with a fallback, bundle a data-filtered ICU (nfc + case data only), or swap in a small NFC library. None of these was tested.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/logs/ndk.log (API 28 sections); /home/fryorcraken/android-ndk/android-ndk-r27c/meta/system_libs.json:15
- [partial|verified-by-experiment] Existing issues found (unchanged by the port)
  (1) toLowercase uses the process's ICU default locale. Under LC_ALL=tr_TR.UTF-8 both the original and the port turn 'LINUX-I686' into 'lınux-ı686' (dotless ı). In an Android app process the ICU default locale probably follows the device locale (inferred), so on a Turkish-locale device package or variant names containing 'I' would lowercase wrongly. Passing "" (root locale) to u_strToLower would make results the same everywhere; I did not include this in the patch. (2) validateArchivePath accepts ill-formed UTF-8: fromUTF8 turns it into U+FFFD, which counts as NFC, e.g. 'FF FE abc' gives valid=1. (3) The original file has an unused variable 'status' in toLowercase (g++ -Wunused-variable).
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/logs/desktop.log (locale sensitivity section); /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/out/vectors-orig.tr_TR.UTF-8.txt

### Patches
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/patches/0001-path_normalizer-use-icu-c-api.patch
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/patches/0002-cmake-android-platform-libicu.patch
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/patches/0003-platform_variant-android-branch.patch
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/patches/all-lgx-icu.patch

### Artifacts
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/src/logos-package-4cdb302 (patched copy of logos-package 4cdb302 = /nix/store/7f6d5ba9...-source)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/test/pathnorm_vectors.cpp
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/bin/desktop/ (vectors-orig, vectors-port, gtest-pathnorm-{orig,port}, gtest-variant-port)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/bin/android/ (vectors-port-x86_64-34[-staticcxx], vectors-port-arm64-34, vectors-port-x86_64-31, vectors-port-x86_64-28-weak, libpathnorm-port-{x86_64,arm64}-34.so, pv-*.s)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/build/lgx-x86_64-34/liblgx.so and lgx
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/build/lgx-arm64-v8a-34/liblgx.so and lgx
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/deps/sodium-{x86_64,arm64-v8a}/ (static libsodium 1.0.20 for Android API 34)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/out/ (test vector outputs per implementation/locale)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/meta/ (lpm flake.locks for d88abaa and 2c56ec7, drv closure JSON)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/lgx-icu/logs/ (revs.log, revs2.log, desktop.log, ndk.log, nixcheck.log, nix-{upstream,patched}.build.log, android-lgx.log, lgx-*.configure/build.log, sodium-*.log, patches.log)
- /nix/store/0ymadabv3720qyxykkazwxa4bfbv0m65-lgx-all-0.1.0 (patched desktop nix build)
- /nix/store/f5xkhsr2hpma3a6yd3mhzxqyavs83vvd-lgx-all-0.1.0 (upstream 4cdb302 desktop nix build)

### Repro
Run these in order (each is one approved-form command):
bash /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/lgx-icu-revs.sh        # resolve lpm d88abaa/2c56ec7 -> logos-package revs, prefetch, match 7f6d5ba9
bash /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/lgx-icu-revs2.sh       # root-input check, logoscore closure, tree diffs, copy source to experiments/lgx-icu/src (NOTE: re-running wipes src/, so re-apply patches/all-lgx-icu.patch with git -C <src> apply)
bash /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/lgx-icu-desktop.sh     # desktop orig-vs-port vectors x 6 locales + upstream gtests
bash /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/lgx-icu-ndk.sh         # NDK r27c compile/link x86_64/arm64 API 34/31/28, NEEDED, orig fails, variant literals
bash /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/lgx-icu-nixcheck.sh    # nix build #all upstream vs patched (436 ctest each)
bash /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/lgx-icu-android-lgx.sh # libsodium 1.0.20 cross-build + full patched liblgx CMake build for x86_64/arm64 API 34 + API 28 negative
bash /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/lgx-icu-patches.sh     # write patches, git-apply onto pristine copy, check 0001 on other revs
Key Android compile command: <NDK>/toolchains/llvm/prebuilt/linux-x86_64/bin/clang++ --target=x86_64-linux-android34 -stdlib=libc++ -std=c++17 -O2 -I<src>/src/core test/pathnorm_vectors.cpp <src>/src/core/path_normalizer.cpp -licu
Key CMake flags: -DCMAKE_TOOLCHAIN_FILE=<NDK>/build/cmake/android.toolchain.cmake -DANDROID_ABI=x86_64|arm64-v8a -DANDROID_PLATFORM=android-34 -DANDROID_STL=c++_shared -DLGX_BUILD_SHARED=ON -DLGX_BUILD_TESTS=OFF -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON -DSODIUM_LIBRARIES=<prefix>/lib/libsodium.a -DSODIUM_INCLUDE_DIRS=<prefix>/include (+ -Wl,-z,max-page-size=16384 for arm64)

### Next steps
- Run bin/android/vectors-port-x86_64-34-staticcxx on the x86_64 API 34 emulator once it is free: adb push it to /data/local/tmp, run it, and diff against out/vectors-port.C.UTF-8.txt. Also run it from inside the app process (JNI) to confirm libicu.so resolves under the app linker namespace, and check which ICU default locale an app process uses.
- Decide the minSdk: 31+ for the platform-ICU route. For 28-30, choose between lazy dlopen("libicu.so") with a fallback, a data-filtered bundled ICU, or a small NFC library.
- Consider changing toLowercase to use the root locale (pass "" to u_strToLower) so lowercasing is locale-independent (Turkish dotless-i issue). This would be a separate upstream change.
- Decide whether to adopt the android-* variant names (patch 0003) or keep linux-* manifests / PackageManagerLib::setPlatformVariantOverride. The liblogos flake pins lpm d88abaa, where the variant table is in package_manager_lib.cpp rather than liblgx, so the matching change must go there.
- Vendor nlohmann_json 3.11.3 and cpp-semver 0.4.0 (or pass their prefixes) so the Android CMake build of liblgx does not clone from GitHub at configure time.
- Optionally replace libsodium in liblgx with OpenSSL 3 (EVP Ed25519, SHA-256, base64), which liblogos already requires, to remove one cross-built dependency.
- Build package_manager_lib and liblogos_core on top of this Android liblgx: liblogos_core calls only lgx_semver_valid_range / lgx_semver_satisfies directly; package_manager_lib uses the rest.

---

## Full report

## lgx-icu: can liblgx use Android's own ICU instead of shipping ICU?

**Answer: yes, if the app's minimum API level is 31 or higher.** All of liblgx's ICU use is in one file, `src/core/path_normalizer.cpp` (NFC normalize, NFC check, lowercase). I ported it from the ICU C++ API (`icu::Normalizer2` / `icu::UnicodeString`) to six C functions that the NDK's `libicu.so` exports without version suffixes from API 31:

- `unorm2_getNFCInstance`, `unorm2_normalize`, `unorm2_isNormalized`
- `u_strFromUTF8WithSub`, `u_strToUTF8WithSub` (both with 0xFFFD, as UnicodeString does)
- `u_strToLower` (default locale, as `UnicodeString::toLower()` does)

The NDK sets `U_SHOW_CPLUSPLUS_API 0` and ships no `unistr.h` / `normalizer2.h`, so the original file cannot compile for Android (`'unicode/normalizer2.h' file not found`).

### Source and revisions (verified by experiment)
| Consumer | Locks logos-package | Store path |
|---|---|---|
| lgpm **2c56ec7** (probe) and logoscore 6a0a2f4 runtime liblgx | **4cdb302** | **/nix/store/7f6d5ba9...-source (match)** |
| lpm **d88abaa** (root input of the local logos-liblogos 7fee75b) | 49151f0 | /nix/store/ias6bmsz...-source (no platform_variant.cpp; variant table is in lpm's package_manager_lib.cpp:1374) |
| lpm 40930aa (local checkout) | 542305b | /nix/store/rdzzxz...-source |

- `path_normalizer.cpp` is byte-identical in all 26 logos-package trees in the store.
- The copy I worked on is `.work/experiments/lgx-icu/src/logos-package-4cdb302`.

### Equivalence (verified by experiment)
- **Desktop vectors:** original and port built against nix ICU 76.1 give byte-identical output on 30 vectors under 6 locale settings (unset, C, en_US, de_DE, tr_TR, lt_LT). The vectors cover NFD→NFC é, Hangul LVT jamo and LV+T, canonical reordering, singletons, composition exclusions where NFC grows (U+0958, U+1D15E), invalid UTF-8, embedded NUL and 5000-character inputs. All 18 known answers pass.
- **Upstream unit tests:** `test_path_normalizer` passes 21/21 for both versions.
- **Full nix build of logos-package 4cdb302:** 436/436 ctest pass, both unpatched and patched. The patched `liblgx.so` drops `libicui18n.so.76` and imports only the six `*_76` C functions.

### Android build (verified by experiment, NDK r27c; nothing was run on a device)
- **Test program and library:** the port plus the test main build with `--target=x86_64-linux-android34 -stdlib=libc++ -licu` (exit 0). NEEDED is `libicu.so, libc++_shared.so, libm.so, libdl.so, libc.so`, and the undefined imports are exactly the six C functions. aarch64 at API 34 (16 KB pages) and x86_64 at API 31 also build.
- **API 28:** 7 "unavailable: introduced in Android 31" errors. A weak-symbol build links but still NEEDs `libicu.so`, which does not exist before Android 12 (inferred).
- **Full patched liblgx (CMake):** builds for x86_64 and arm64 at API 34, using NDK zlib, NDK libicu, static libsodium 1.0.20 and nlohmann/cpp-semver via FetchContent.
  - `liblgx.so` stripped: 962 KB (x86_64) / 798 KB (arm64).
  - NEEDED: `libz.so libicu.so libm.so libc++_shared.so libdl.so libc.so`.
  - No ICU is shipped. The desktop probe mapped 37.7 MiB of ICU.
- **CMake at API 28:** configure stops with the explicit "API 31" error from patch 0002.

### Other dependencies
| Dependency | Android |
|---|---|
| zlib | NDK sysroot `libz.so` (API 21+) and zlib.h; FindZLIB finds them with no extra setup |
| libsodium | Not in the NDK. Cross-builds from the official 1.0.20 tarball in ~12 s per ABI; link it statically. Used only for Ed25519, SHA-256, base64 and memzero, so OpenSSL 3 could replace it (inferred) |
| nlohmann_json 3.11.3, cpp-semver 0.4.0 | Header-only; fetched from GitHub at configure time (vendor them for offline builds) |
| ICU | After the port: the platform `libicu.so` (API 31+) |
| GTest | Only needed for tests |

### Patches (`.work/experiments/lgx-icu/patches`)
Each patch applies cleanly with `git apply` to a pristine 4cdb302. 0001 also applies to 49151f0, 542305b, 1eae01c and 3cb520c.
- **0001-path_normalizer-use-icu-c-api.patch:** the port.
- **0002-cmake-android-platform-libicu.patch:** on Android, `find_library(icu)` with a FATAL_ERROR naming API 31; elsewhere `find_package(ICU COMPONENTS uc)` (i18n dropped).
- **0003-platform_variant-android-branch.patch:** a proposal only. Adds an `__ANDROID__` branch before `__linux__` that returns android-arm64 / android-x86_64, and "unknown" for other ABIs. Adds matching test rows.
- **all-lgx-icu.patch:** the three combined.

### Still open or inferred
- **Nothing ran on a device or emulator** (the emulator belongs to another task). The binaries are in `bin/android`, and the expected output is `out/vectors-port.C.UTF-8.txt`.
- **Minimum API level:** this approach needs 31, above the 28 floor used by Qt and posix_spawn. Options for 28-30: `dlopen` libicu with a fallback, bundle a data-filtered ICU, or use a small NFC library.
- **Locale bug, also present before the port:** `toLowercase` follows the process locale. Under tr_TR, `LINUX-I686` becomes `lınux-ı686` in both versions. Passing `""` (root locale) would fix it.
- **Invalid UTF-8, also present before the port:** `validateArchivePath` accepts ill-formed UTF-8, because it is turned into U+FFFD, which counts as NFC.

