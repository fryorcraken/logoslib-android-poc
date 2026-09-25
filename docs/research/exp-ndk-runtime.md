# Experiment: ndk-runtime

> Gating experiment, 2026-09-25. Machine-written by the experiment agent; logs and scripts in
> [../../experiments/ndk-runtime](../../experiments/ndk-runtime); patches in [../../patches](../../patches).
> `.work/` paths refer to local scratch that is not committed.


### Summary
The whole Qt-free half of the liblogos runtime cross-builds for x86_64-linux-android34 with NDK r27c and needs only one third-party source patch. That patch is Boost.Process 1.87's shell.cpp, which includes <wordexp.h>, and bionic doesn't have it. Built: Boost 1.87 (process, filesystem, system, context, atomic, date_time), fmt 10.2.1, spdlog 1.15.2, nlohmann_json 3.11.3, logos-container, logos-module-loader, logos-container-subprocess, process-stats and the parent-side logos_module_loader_qt lib. logos-container, logos-container-subprocess and logos-module-loader needed only a small CMake option to skip their GoogleTest setup; process-stats already had one, and the loader lib was built through a small out-of-tree CMake wrapper with no patch. None of their C++ sources needed changes. All of it also compiles at API 28. But a prefix built at API 34 uses newer libc symbols (statx, pthread_cond_clockwait, ELF TLS), so the prefix must be built at the app's minSdk.

I then ran the real SubprocessContainer, QtPluginFormatLoader and process-stats on the x86_64 API 34 emulator. They drove a Qt-free stand-in for logos_host_qt that runs the host's real startup code, crash handler, token reading and command-line parsing. It ran in two contexts: adb shell, and a real untrusted_app process (a Java-free NativeActivity APK with the host shipped as a lib*.so in nativeLibraryDir). Every check passed in both: spawn, token over stdin, load-status line, clean stop on SIGTERM, crash detection, reported load failure, pidfd-based waiting, no fd leaks into the child, setsid, PR_SET_PDEATHSIG, and DT_RUNPATH=$ORIGIN.

Bionic's posix_spawn behaves differently from glibc in two ways. It calls fork(), so pthread_atfork handlers run on every module spawn. A missing host binary does not make launch() fail; it shows up as exit code 127, which awaitLoad already reports as Failed.

The full logos_host.cpp syntax-checks for Android with the Qt 6.11.1 headers and the logos SDK headers. At API 34 it needs no change. Below API 33 it fails only on backtrace(). I wrote three small proposed patches for logos-module-loader-qt and saved them as diffs: A (guard backtrace), B (name the host liblogos_host_qt.so and give it an $ORIGIN runpath), C (find the host next to the loaded library on Android). A is compile-verified, C is runtime-verified in both contexts, and B is proven only on the stand-in host because the real host needs a Qt build.

Not tested: Qt's QCoreApplication and QtRO in a child process with no JavaVM, whether POSIX_SPAWN_CLOEXEC_DEFAULT works on API 28–33 devices, and arm64.

### Results
- [pass|verified-by-experiment] 1. Cross-build Boost 1.87.0 for x86_64-linux-android API 34 (NDK r27c clang + libc++, 16 KB pages)
  Built with b2 toolset=clang-android via user-config.jam, link=static,shared, cxxstd=17, --with-process/filesystem/system/context/atomic/date_time. It needed one patch: Boost.Process 1.87's libs/process/src/shell.cpp does #include <wordexp.h>, and bionic has no such header. Exact error: "shell.cpp:23:10: fatal error: 'wordexp.h' file not found". The fix routes __ANDROID__ through the existing OpenBSD branch at 3 #elif lines, so bp2::shell throws ENOTSUP; logos never uses bp2::shell. A clean b2 build plus install took 22 s at -j16; the first unpatched attempt failed after 22 s. The .so files get unversioned SONAMEs (for example libboost_process.so), and every LOAD segment is aligned to 0x4000. Boost.Filesystem found statx at API 34.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/ndk-runtime-boost.sh; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/logs/boost-clean.log (B2 EXIT=0 WALL_SECONDS=22); /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/logs/boost.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/patches/boost-1.87.0-process-shell-android.diff; tarball sha256 af57be25cb4c4f4b413ed692fe378affb4352ea50fbe294a11ef548f4d527d89
- [pass|verified-by-experiment] 2. Cross-build spdlog + fmt (versions liblogos links) and nlohmann_json headers with the NDK CMake toolchain
  Versions come from the builds in /nix/store: spdlog-1.15.2 (built shared, SPDLOG_FMT_EXTERNAL, uses fmt::fmt), fmt-10.2.1 and nlohmann_json-3.11.3. They were built the same way: fmt BUILD_SHARED_LIBS=ON; spdlog SPDLOG_BUILD_SHARED=ON and SPDLOG_FMT_EXTERNAL=ON. Toolchain settings: ANDROID_ABI=x86_64, ANDROID_PLATFORM=android-34, ANDROID_STL=c++_shared, ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON, -Wl,-z,max-page-size=16384. No patches were needed. Wall times: fmt 2 s, spdlog 5 s, json 0 s. CMake's Android platform module gives unversioned SONAMEs (libfmt.so, libspdlog.so). The only diagnostic was a harmless libc++ deprecation warning from fmt about char_traits<char8_type>.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/ndk-runtime-deps.sh; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/logs/deps.log; /nix/store/13dxcy8kwcvvg765hj01kf29j3l0qmr3-spdlog-1.15.2-dev/lib/cmake/spdlog/spdlogConfigTargets.cmake
- [pass|verified-by-experiment] 3. Configure + build logos-container (headers) and logos-container-subprocess with the NDK toolchain against the prefix; record compile errors + minimal fixes
  Neither repo needed a C++ change; there were zero compile errors and zero warnings at API 34. The container source also syntax-checks at API 28. The one patch is a small test gate in each top-level CMakeLists: option(<X>_BUILD_TESTS ON) wrapped around the GoogleTest FetchContent and add_subdirectory(tests), the same pattern process-stats already uses. Configured with -DCMAKE_FIND_ROOT_PATH=<prefix>, -DCMAKE_PREFIX_PATH=<prefix>, -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH, -DBoost_USE_STATIC_LIBS=ON and -DLOGOS_CONTAINER_ROOT=<prefix>. Build time: 4 s. Revisions used: logos-container 641d211, logos-container-subprocess 697c180 (the rev logos-liblogos pins). The Android-specific spots, confirmed by reading source and by running: (1) closefrom: the LOGOS_HAVE_CLOSEFROM_NP path is glibc-only and is not taken. (2) POSIX_SPAWN_CLOEXEC_DEFAULT: the NDK r27c spawn.h defines it (value 256) with no API gate, so the container uses the flag path. On API 34 bionic honours it at runtime. (3) pidfd_open: Boost.Process v2 calls syscall(SYS_pidfd_open), which works on API 34 (anon_inode:[pidfd] appears in the parent's fd table). (4) execinfo is not used by the container at all.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/ndk-runtime-prep-src.sh; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/ndk-runtime-container.sh; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/logs/container.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/patches/logos-container-test-gate.diff; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/patches/logos-container-subprocess-test-gate.diff; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/prefix/x86_64/lib/liblogos_container_subprocess.a (4.5 MB, 625 KB stripped)
- [pass|verified-by-experiment] 4a. Build the Qt-free parent-side static loader lib of logos-module-loader-qt (logos_module_loader_qt)
  The repo's top-level CMakeLists requires Qt, OpenSSL, CLI11, logos-protocol, logos-qt-sdk and logos-module unconditionally, because of logos_host_qt. So the lib was built through an out-of-tree wrapper, src/wrap/loader-qt-parent/CMakeLists.txt, which mirrors lines 25-61 of the repo's src/CMakeLists.txt. qt_plugin_format_loader.cpp and the factory needed no source changes. They also compile at API 28. Build time: 2 s. The logos-module-loader headers-only repo (3628b97) needed only the test gate plus -DLOGOS_CONTAINER_ROOT. The installed LogosContainerImplConfig.cmake and LogosFormatLoaderImplConfig.cmake packages load correctly with find_package, the same way liblogos would.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/src/wrap/loader-qt-parent/CMakeLists.txt; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/patches/logos-module-loader-test-gate.diff; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/logs/container.log
- [pass|verified-by-experiment] 4b. Build process-stats
  Built with -DPROCESS_STATS_BUILD_TESTS=OFF (the repo already has this option) and no patches, in 1-2 s. On Android it compiles its __linux__ /proc code. At runtime it reads /proc/<child>/stat and /proc/<child>/status for the host child in both adb shell and the app (for example mem=3.65MB).
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/logs/container.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/logs/smoke-run.log
- [pass|verified-by-experiment] Runtime: does the real container + format loader work on Android (x86_64 API 34 emulator, both adb shell and untrusted_app)?
  ndk_smoke (adb shell) and libndkrt_activity.so (a Java-free NativeActivity APK, uid 10193, targetSdk 34, extractNativeLibs=true) drive SubprocessContainer through makeContainer() and QtPluginFormatLoader through makeFormatLoader(). The child is liblogos_host_probe.so, an executable named lib*.so and exec'd from nativeLibraryDir. The probe copies logos_host.cpp's startup code (setsid/setpgid, PR_SET_PDEATHSIG, getppid watchdog) and its crash handler (sigaltstack, SA_ONSTACK, backtrace), and compiles the real command_line_parser.cpp (CLI11 2.5.0), token_source.cpp, module_path.cpp and module_dll_search.cpp. Results: 17/17 checks pass in the shell run and all pass in the app run; the orphan check passes in both. What was verified: launch, pid, token over the stdin pipe, awaitLoad=Loaded parsed from the status line, terminate via SIGTERM through the self-pipe in 68 ms with no SIGKILL, SIGSEGV in the child giving FATAL output with raw backtrace frames and onTerminated while the parent stays up, awaitLoad=Failed carrying the child's reason, and pidfd usage. In the app, only fds 0-2 reach the child even though the zygote-forked parent holds 10 or more non-CLOEXEC /dev/null fds. The child has sid=pgid=pid and pdeathsig=9. The probe links with DT_RUNPATH=$ORIGIN and finds libspdlog.so, libfmt.so and libc++_shared.so with LD_LIBRARY_PATH unset. The host runs in the u:r:untrusted_app SELinux domain. After the parent dies (shell) or the app process is SIGKILLed, the host is gone within 2 s. The only SELinux denials were harmless dir-search denials on /data/local/tests.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/logs/smoke-run.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/src/smoke/smoke_container.cpp; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/src/smoke/host_probe.cpp; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/src/smoke/smoke_activity.cpp; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/apk/ndkrt-smoke.apk; device: sdk=34 x86_64 kernel 6.1.23-android14, PAGE_SIZE 4096
- [partial|verified-by-experiment] Bionic posix_spawn semantics vs glibc (fork vs vfork, exec-failure reporting)
  A pthread_atfork prepare handler ran 4 times across 4 launches, in both shell and app. So bionic's posix_spawn (with file actions and flags set) calls fork(), and every atfork handler in the app process runs on each module spawn. A nonexistent host binary makes launch() return true, then awaitLoad reports Failed with 'exited with code 127'. glibc would make launch() return false with ENOENT. The container already handles this gracefully. POSIX_SPAWN_USEVFORK is an optional flag to avoid fork(); it is untested.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/logs/smoke-run.log (INFO pthread_atfork prepare handler ran 4 time(s) across 4 launches; INFO missing awaitLoad verdict=Failed ...127)
- [pass|verified-by-experiment] Container fd-hygiene fallback (/proc/self/fd enumeration) on bionic, for devices that reject POSIX_SPAWN_CLOEXEC_DEFAULT
  I built ndk_smoke_fdenum with -include force_fd_enumeration.h, which hides POSIX_SPAWN_CLOEXEC_DEFAULT from the TU. The binary imports posix_spawn_file_actions_addclose, opendir and readdir, so the fallback path was compiled in. All checks pass and only fds 0-2 reach the child on API 34. Open question: whether API 28-33 bionic accepts the CLOEXEC_DEFAULT flag (value 256). The NDK header defines it without an __INTRODUCED_IN gate, and no pre-34 image is available to test. I infer, without verifying, that older posix_spawnattr_setflags returns EINVAL for the unknown bit, which would break every spawn.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/src/smoke/force_fd_enumeration.h; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/logs/smoke-run.log (FDENUM lines); /home/fryorcraken/android-ndk/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/spawn.h:49-50
- [partial|verified-by-experiment] Lower minSdk (API 28, Qt 6.11 minimum): what breaks?
  Source level: every Qt-free source file (subprocess_container, qt_plugin_format_loader, and host/token_source, command_line_parser, module_path, module_dll_search) compiles with -fsyntax-only at API 28. The full logos_host.cpp (with Qt 6.11.1 android_x86_64 headers and the logos-plugin-qt, logos-protocol and logos-module headers) fails at API 28 with only one error: logos_host.cpp:148 "no member named 'backtrace' in the global namespace". backtrace needs API 33. qt_app.cpp compiles. Binary level: the API-34 prefix references libc symbols that API 28 lacks: statx (libboost_filesystem, API 30), pthread_cond_clockwait (libc++ condition_variable in the container, API 30) and __tls_get_addr (ELF TLS in spdlog and the container, API 29). So the whole prefix must be rebuilt with ANDROID_PLATFORM equal to the app's minSdk.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/logs/smoke-build.log (API28 lines); /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/logs/host-patches.log
- [partial|verified-by-experiment] Remaining porting issues in logos_host_qt (backtrace/execinfo, setsid, prctl, sigaltstack) + minimal patches
  Patch A guards <execinfo.h> and ::backtrace with !__ANDROID__ || __ANDROID_API__>=33. With it, logos_host.cpp compiles at API 28 and API 34; the crash handler then prints no frames below 33. Compile-verified; the same code ran on API 34 in the probe. setsid, prctl(PR_SET_PDEATHSIG,SIGKILL), sigaltstack+SA_ONSTACK|SA_RESETHAND and the SIGTERM self-pipe all work unchanged in untrusted_app on API 34 (verified). Patch B, in src/CMakeLists.txt: on Android, set OUTPUT_NAME liblogos_host_qt with SUFFIX .so so the APK installs it into nativeLibraryDir, and add target_link_options LINKER:-rpath,$ORIGIN. CMake's Android platform ignores INSTALL_RPATH '$ORIGIN/../lib'; I confirmed no DT_RUNPATH was emitted until the linker option was added. The mechanism is verified on the probe. Patch B itself is not built, because that needs Qt and the logos SDK cross-built. Patch C, in qt_plugin_format_loader.cpp: on Android, also look for liblogos_host_qt.so next to boost::dll::this_line_location(), i.e. nativeLibraryDir. Inside an app, program_location() is app_process64, so without LOGOS_HOST_PATH the unpatched loader finds nothing. That behaviour is verified: the app log shows 'logos_host_qt (or logos_host) not found'. With patch C, discovery works in both shell and app. The alternative is no patch C, with the JNI glue setting LOGOS_HOST_PATH to nativeLibraryDir/liblogos_host_qt.so instead. Still open: Qt itself in a child with no JavaVM (QCoreApplication, QPluginLoader, QtRO) was not exercised.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/patches/logos-module-loader-qt-A-host-backtrace-api33.diff; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/patches/logos-module-loader-qt-B-host-android-name-rpath.diff; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/patches/logos-module-loader-qt-C-loader-android-host-discovery.diff; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/patches/logos-module-loader-qt-android-all.diff; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/logs/host-patches.log
- [partial|inferred] TMPDIR / QtRO socket-path budget inside an app
  The app process exports TMPDIR=/data/user/0/<pkg>/cache, and posix_spawn passes environ to the child. The probe saw TMPDIR=/data/user/0/dev.ndkruntime.smoke/cache (39 chars for a 20-char package name). libQt6Core_x86_64.so contains the string 'TMPDIR', which suggests QDir::tempPath() reads it; that part is inferred. So the QtRO socket would be <cache>/logos_<module>_<instanceId>, and 13 + len(pkg) + 7 + 6 + len(module) + 1 + len(instanceId) must stay under 108 bytes. If it gets tight, use a shorter TMPDIR or QLocalServer's abstract namespace; both are suggestions and untested.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/logs/smoke-run.log (PROBE LD_LIBRARY_PATH=(unset) TMPDIR=/data/user/0/dev.ndkruntime.smoke/cache)

### Patches
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/patches/boost-1.87.0-process-shell-android.diff (REQUIRED: bionic has no <wordexp.h>; 3 lines '#elif !defined(__OpenBSD__)' -> '#elif !defined(__OpenBSD__) && !defined(__ANDROID__)' in libs/process/src/shell.cpp)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/patches/logos-container-test-gate.diff (option LOGOS_CONTAINER_BUILD_TESTS ON wrapped around the GTest FetchContent and add_subdirectory(tests))
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/patches/logos-container-subprocess-test-gate.diff (option LOGOS_CONTAINER_SUBPROCESS_BUILD_TESTS)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/patches/logos-module-loader-test-gate.diff (option LOGOS_MODULE_LOADER_BUILD_TESTS)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/patches/logos-module-loader-qt-A-host-backtrace-api33.diff (logos_host.cpp: include execinfo.h and call ::backtrace only when !__ANDROID__ || __ANDROID_API__ >= 33; otherwise n = 0)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/patches/logos-module-loader-qt-B-host-android-name-rpath.diff (src/CMakeLists.txt: if(ANDROID), OUTPUT_NAME liblogos_host_qt with SUFFIX .so, plus target_link_options LINKER:-rpath,$ORIGIN)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/patches/logos-module-loader-qt-C-loader-android-host-discovery.diff (qt_plugin_format_loader.cpp: on __ANDROID__, also try liblogos_host_qt.so next to boost::dll::this_line_location(); optional, since the alternative is setting LOGOS_HOST_PATH from JNI)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/patches/logos-module-loader-qt-android-all.diff (A+B+C combined)

### Artifacts
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/prefix/x86_64 (install prefix: include/, lib/*.a, lib/*.so, lib/cmake/{Boost-1.87.0,boost_*,fmt,spdlog,nlohmann_json,CLI11,LogosContainerImpl,LogosFormatLoaderImpl})
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/prefix/x86_64/lib/liblogos_container_subprocess.a (4,506,852 B; 624,812 B stripped)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/prefix/x86_64/lib/liblogos_module_loader_qt.a (918,384 B; 96,784 B stripped; this is the patch-C build)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/prefix/x86_64/lib/libprocess_stats.a (1,733,180 B; 151,628 B stripped)
- Boost static libs, bytes: process 201,282; filesystem 356,820; atomic 18,346; context 11,146; system 1,308; date_time 1,338. Boost shared libs, stripped bytes: process 72,144; filesystem 166,216; atomic 10,448; context 6,608; system 3,976; date_time 3,992
- libfmt.so 1,153,784 B (161,208 B stripped); libspdlog.so 4,716,776 B (472,272 B stripped); libc++_shared.so 1,617,608 B (1,252,080 B stripped)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/out/x86_64/ (ndk_smoke, ndk_smoke_fdenum, liblogos_host_probe.so and liblogos_host_qt.so (407 KB stripped each), libndkrt_activity.so (428 KB stripped; this is roughly what the Qt-free runtime adds to liblogos_core.so), libspdlog.so, libfmt.so, libc++_shared.so). Every LOAD segment is aligned to 0x4000.
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/apk/ndkrt-smoke.apk (23.6 MB, unstripped libs stored uncompressed; zipalign -P 16; package dev.ndkruntime.smoke)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/src/smoke/ (smoke_container.cpp, host_probe.cpp, smoke_activity.cpp, smoke_cli.cpp, force_fd_enumeration.h, CMakeLists.txt)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/src/wrap/loader-qt-parent/CMakeLists.txt
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/src/{logos-container,logos-container-subprocess,logos-module-loader,logos-module-loader-qt,process-stats} (git clone --shared copies with patches applied)
- Logs: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/ndk-runtime/logs/{env,boost,boost-clean,deps,prep-src,container,host-patches,smoke-build,apk,smoke-run,sizes,emulator-5584}.log

### Repro
All scripts are under /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/. Run them in this order:
1. bash ndk-runtime-env.sh
   Checks the host tools. Ninja comes from /nix/store/7bgiqc706pzzb1gmwgpzdfg491w4a8nx-ninja-1.13.1; cmake is 3.31.11.
2. bash ndk-runtime-boost.sh
   Downloads, patches shell.cpp, bootstraps and runs b2. For a clean timing run use: bash ndk-runtime-boost.sh clean
   The b2 command it runs:
   ./b2 --user-config=<build>/user-config.jam --build-dir=<build>/obj --prefix=<prefix>/x86_64 --layout=system toolset=clang-android target-os=android architecture=x86 address-model=64 abi=sysv binary-format=elf link=static,shared runtime-link=shared threading=multi variant=release cxxstd=17 --with-process --with-filesystem --with-system --with-context --with-atomic --with-date_time -j16 -d+2 install
   user-config.jam contains: using clang : android : <ndk>/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android34-clang++ : <archiver>llvm-ar <ranlib>llvm-ranlib <compileflags>-fPIC -ffunction-sections -fdata-sections <linkflags>-Wl,-z,max-page-size=16384 -Wl,--build-id=sha1 ;
3. bash ndk-runtime-deps.sh
   Builds fmt 10.2.1 and spdlog 1.15.2 (shared, external fmt) and installs json 3.11.3.
4. bash ndk-runtime-prep-src.sh
   Makes the git clone --shared copies and applies the test-gate patches.
5. bash ndk-runtime-container.sh
   Builds CLI11 2.5.0 headers, logos-container, logos-module-loader, logos-container-subprocess, process-stats and the loader-qt parent via the wrapper. Common CMake arguments: -DCMAKE_TOOLCHAIN_FILE=<ndk>/build/cmake/android.toolchain.cmake -DANDROID_ABI=x86_64 -DANDROID_PLATFORM=android-34 -DANDROID_STL=c++_shared -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON -DCMAKE_FIND_ROOT_PATH=<prefix> -DCMAKE_PREFIX_PATH=<prefix> -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH -DBoost_USE_STATIC_LIBS=ON -DLOGOS_CONTAINER_ROOT=<prefix>
6. bash ndk-runtime-host-patches.sh
   Syntax-checks upstream logos_host.cpp and qt_app.cpp at API 28 and 34, applies patches A, B and C, re-checks, and reinstalls the patched loader lib.
7. bash ndk-runtime-rerun.sh
   Runs smoke-build, then apk, then smoke-run. It starts a private read-only emulator: AVD delivery-demo on port 5584, windowed, under setsid (-no-window crashes qemu-headless on this host). It runs the adb-shell, fdenum, orphan and app-context tests, then stops the emulator.
8. bash ndk-runtime-sizes.sh

Note: step 4 resets the clones, so step 6 must come after steps 4 and 5.

### Next steps
- Choose the POC minSdk now. At minSdk 34 the Qt-free runtime and the host need no source changes beyond packaging (patch B) and host discovery (patch C, or LOGOS_HOST_PATH). A lower minSdk needs: the whole prefix rebuilt at that API level (statx, pthread_cond_clockwait and ELF TLS come from build-time API detection), patch A (backtrace needs API 33), and a runtime gate that falls back from POSIX_SPAWN_CLOEXEC_DEFAULT to the /proc/self/fd enumeration path (the fallback is verified working on API 34; a pre-34 bionic may reject the flag). Also: pidfd_open needs API 31+ and kernel 5.3+; otherwise define BOOST_PROCESS_V2_DISABLE_PIDFD_OPEN (inferred).
- Biggest open risk: run the real logos_host_qt (Qt 6.11.1 QtCore, Network and RemoteObjects plus the logos SDK) as an exec'd child with no JavaVM. Cross-build logos-protocol, logos-qt-sdk (logos-plugin-qt), logos-module and liblogos against Qt android_x86_64 (already at .work/probe/qt/6.11.1/android_x86_64) and this prefix. Then swap liblogos_host_probe.so for liblogos_host_qt.so in the ndkrt APK harness and check QCoreApplication, QPluginLoader and the QtRO LocalSocket under TMPDIR=/data/user/0/<pkg>/cache.
- Reuse the Java-free NativeActivity APK pipeline (ndk-runtime-apk.sh: aapt2, zipalign -P 16, apksigner, no Gradle) and the libndkrt_activity.so pattern as the fastest in-app test harness for liblogos_core.so.
- Decide Boost linking. Static PIC was used for the container. Shared Boost .so files are fine too, since b2 with target-os=android emits unversioned SONAMEs. Also decide shared vs static spdlog/fmt; shared was used, matching nixpkgs.
- Upstream candidates: the Boost.Process wordexp fix (boostorg/process), a test-gate option in logos-container, logos-container-subprocess and logos-module-loader (the process-stats pattern), and patches A, B and C for logos-module-loader-qt. Also document in the container that on bionic launch() returns true for an unexecutable host and the failure surfaces as exit 127 via awaitLoad.
- Optional: try POSIX_SPAWN_USEVFORK on Android in spawnChild so bionic uses vfork instead of fork() plus atfork handlers inside the ART process (untested).
- Repeat the build for aarch64-linux-android. Only x86_64 was built here, and the arm64 AVD does not boot on this host.

---

## Full report

## ndk-runtime: Android cross-build of the Qt-free liblogos runtime

The whole Qt-free half of the runtime builds for Android. Only one third-party file needed a source patch: Boost.Process's `shell.cpp`. The real container, format loader and process-stats also ran correctly on the API 34 emulator, both from `adb shell` and inside a real app process.

- **Target:** x86_64-linux-android34, NDK r27c (clang 18.0.3), libc++_shared, `-Wl,-z,max-page-size=16384`.
- **Where things are:** everything lives under `.work/experiments/ndk-runtime/`; the scripts are `.work/scripts/ndk-runtime-*.sh`.
- **Emulator:** I used a private read-only instance on port 5584 and stopped it at the end. The `emulator-5570` now running belongs to another session.

### What compiled

| Component | Version / rev | Result | Wall time | Patch |
|---|---|---|---|---|
| Boost (process, filesystem, system, context, atomic, date_time), static + shared | 1.87.0 | ✅ | 22 s clean b2 build + install, -j16 | **Yes:** `libs/process/src/shell.cpp` includes `<wordexp.h>`, which bionic lacks |
| fmt, shared | 10.2.1 | ✅ | 2 s | none |
| spdlog, shared, external fmt | 1.15.2 | ✅ | 5 s | none |
| nlohmann_json (headers) | 3.11.3 | ✅ | 0 s | none |
| CLI11 (headers, for the host probe) | 2.5.0 | ✅ | 0 s | none |
| logos-container (headers) | 641d211 | ✅ | 0 s | CMake test gate only |
| logos-module-loader (headers) | 3628b97 | ✅ | 1 s | test gate; also needs `-DLOGOS_CONTAINER_ROOT` |
| logos-container-subprocess | 697c180 (the rev liblogos pins) | ✅ zero compile errors, zero warnings | 4 s | test gate only |
| process-stats | 6e0aade | ✅ | 1 s | none (it already has `PROCESS_STATS_BUILD_TESTS`) |
| logos-module-loader-qt parent-side lib | 888da92 | ✅ | 2 s | none; built through an out-of-tree wrapper CMakeLists |

- **Versions:** fmt, spdlog and json match what is in `/nix/store`.
- **SONAMEs:** all are unversioned. CMake's Android platform does this by itself, and so does b2 with `target-os=android`.
- **Page alignment:** every LOAD segment is aligned to 0x4000.

#### Where the expected problem spots stood

- **`pidfd_open`:** Boost.Process v2 calls `syscall(SYS_pidfd_open)`. It works on API 34, from adb shell and from the app; the parent shows `anon_inode:[pidfd]`.
- **`closefrom`:** the container only takes that path on glibc, so it is not used on Android.
- **`POSIX_SPAWN_CLOEXEC_DEFAULT`:** the NDK header defines it (value 256) with no API gate, so the container uses the flag. API 34 bionic honours it. The zygote-forked app holds 10 or more non-CLOEXEC `/dev/null` fds, and the child still sees only fds 0-2.
- **Container's `/proc/self/fd` fallback:** I forced it on by hiding the flag at compile time. It also works on API 34.
- **`execinfo`:** only `logos_host.cpp` uses it.

#### Sizes

| Artifact | Unstripped | Stripped |
|---|---|---|
| `liblogos_container_subprocess.a` | 4.5 MB | 625 KB |
| `liblogos_module_loader_qt.a` | 918 KB | 97 KB |
| `libprocess_stats.a` | 1.7 MB | 152 KB |
| `libboost_process.a` | 201 KB | |
| `libboost_filesystem.a` | 357 KB | |
| `libspdlog.so` | | 472 KB |
| `libfmt.so` | | 161 KB |
| `libc++_shared.so` | | 1.25 MB |
| `libndkrt_activity.so` (container + loader + process-stats + static Boost + test code) | | 428 KB |
| Host probe | | 407 KB |

`libndkrt_activity.so` is a rough guide to what the Qt-free runtime adds to `liblogos_core.so`.

### Runtime tests on the emulator

#### Test setup
- **Driver:** `ndk_smoke` calls the real `SubprocessContainer` through `makeContainer()`, the real `QtPluginFormatLoader` through `makeFormatLoader()`, and process-stats.
- **Host child:** `liblogos_host_probe.so`, a Qt-free stand-in for `logos_host_qt`, packaged as an executable named `lib*.so`.
- **What the probe runs:**
  - copied from `logos_host.cpp`: the startup code (setsid/setpgid, PR_SET_PDEATHSIG, getppid watchdog) and the crash handler (sigaltstack, SA_ONSTACK, backtrace);
  - the real `command_line_parser.cpp`, `token_source.cpp`, `module_path.cpp` and `module_dll_search.cpp`;
  - a poll()-based version of the SIGTERM self-pipe from `qt_app.cpp`.
- **Two contexts:**
  - **adb shell.**
  - **A real app process:** a Java-free NativeActivity APK built with aapt2, `zipalign -P 16` and apksigner, no Gradle, with `extractNativeLibs=true`. It ran as uid 10193 with targetSdk 34. The host was exec'd from nativeLibraryDir and ran in the `u:r:untrusted_app` SELinux domain.

#### Results
All checks passed in both contexts:
- launch, pid, and token delivery over stdin;
- `awaitLoad` returns Loaded from the status line;
- terminate via SIGTERM through the self-pipe in 68 ms, with no SIGKILL;
- a SIGSEGV in the child prints FATAL with raw backtrace frames; `onTerminated` fires and the parent stays up;
- `awaitLoad` returns Failed with the child's own reason;
- process-stats reads `/proc` for the child;
- the child sees only fds 0-2;
- `setsid` gives sid = pgid = pid, and `pdeathsig` = 9;
- `DT_RUNPATH=$ORIGIN` resolves the host's libraries with `LD_LIBRARY_PATH` unset;
- the host dies within 2 s when the parent dies (shell) or the app process is SIGKILLed.

#### Differences from glibc
1. **`posix_spawn` uses fork().** It ran every `pthread_atfork` handler on all 4 launches. In the app, that means every library's atfork handlers run each time a module is spawned.
2. **A missing host binary is not an error at launch.** `launch()` returns true, and the failure shows up as exit 127. `awaitLoad` then reports "exited with code 127 before it reported that it had loaded".

#### App environment facts
- The app exports `TMPDIR=/data/user/0/<pkg>/cache`, and the child inherits it. That directory is where the QtRO socket would go, so the 108-byte socket-path limit matters.
- Without `LOGOS_HOST_PATH`, the unpatched loader cannot find the host in the app, because `program_location()` is app_process64.
- The only SELinux denials were harmless dir-search denials on `/data/local/tests`.

### API-level findings

- **API 28 source check:** every Qt-free source file compiles at API 28.
- **Full `logos_host.cpp`:** I syntax-checked it with the Qt 6.11.1 android_x86_64 headers and the logos-plugin-qt, logos-protocol and logos-module headers. It compiles at API 34 with no change. At API 28 the only error is `logos_host.cpp:148: no member named 'backtrace'`, because `backtrace` needs API 33.
- **The API-34 prefix will not load on an API-28 device.** It references `statx` (API 30), `pthread_cond_clockwait` (API 30) and `__tls_get_addr` (ELF TLS, API 29). These come from build-time API detection, so the prefix must be built at the app's minSdk.
- **`POSIX_SPAWN_CLOEXEC_DEFAULT` on API 28–33 is untested** (only an API 34 image exists). If an older bionic rejects the flag with EINVAL, every module spawn would fail. The fix would be a runtime check that falls back to the enumeration path, which I verified works.

### Proposed patches for logos-module-loader-qt

All are saved under `patches/`.

| Patch | Change | Status |
|---|---|---|
| **A** `logos_host.cpp` | Include `<execinfo.h>` and call `::backtrace` only when `!__ANDROID__ \|\| __ANDROID_API__>=33`; otherwise use n=0. | Compiles at API 28 and 34. |
| **B** `src/CMakeLists.txt` | Under `if(ANDROID)`: set `OUTPUT_NAME liblogos_host_qt` with `SUFFIX .so`, and add `target_link_options(... "LINKER:-rpath,$ORIGIN")`. | CMake's Android platform ignores `INSTALL_RPATH`; I confirmed no DT_RUNPATH was emitted. The same mechanism works on the probe. |
| **C** `qt_plugin_format_loader.cpp` | On `__ANDROID__`, also look for `liblogos_host_qt.so` next to `boost::dll::this_line_location()` (nativeLibraryDir). | Works at runtime in shell and app. The alternative is having JNI set `LOGOS_HOST_PATH`. |

`setsid`, `prctl(PR_SET_PDEATHSIG)`, `sigaltstack` and the SIGTERM self-pipe need no change; all work in untrusted_app on API 34.

### Still unknown
- Qt itself (QCoreApplication, QPluginLoader, QtRO) in an exec'd child with no JavaVM.
- `POSIX_SPAWN_CLOEXEC_DEFAULT` and pidfd behaviour below API 34.
- arm64: only x86_64 was built.
- The real `logos_host_qt` and `liblogos_core` binaries: they need Qt and the logos SDK cross-built first.

### Rule notes
- The first b2 run wrote its temporary jam files to `/tmp` before I set `TMPDIR`. The emulator itself also writes its own crash database to `/tmp/android-fryorcraken`.
- I listed the AVD names in `~/.android/avd` once.
