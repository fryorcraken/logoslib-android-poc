# Android packaging

> Research track `android-pkg`, 2026-09-25. Written by a research agent and then checked by a
> second, adversarial agent, whose non-confirmed verdicts are listed under "Verifier".
> Claims are tagged verified-from-source / verified-by-experiment / inferred / open.
> Absolute paths point at the author's local checkouts (`~/src/logos-co`,
> `~/src/logos-blockchain`) at the revisions in [../investigation.md](../investigation.md);
> `.work/` paths are local scratch, not committed. The synthesis is in
> [../investigation.md](../investigation.md).


### Summary
Android packaging for the liblogos POC. On the arm64-v8a/x86_64 ABIs, everything must be rebuilt with the NDK against libc++_shared. Nix Linux (glibc/libstdc++) .so's cannot be reused. logos-nix already has an Android Qt 6.11.1 cross set (API 28, NDK r27.0, c++_shared, legacyPackaging=false, DT_NEEDED gate). Bionic honours DT_RUNPATH/${ORIGIN} from API 24. Bionic resolves DT_NEEDED by file name in the app's linker namespace: the APK lib/<abi> dir or nativeLibraryDir. AGP packages only **/*.so, and PackageManager extracts only lib*.so (non-debuggable apps, API ≤35). So versioned sonames must be renamed to lib*.so, with SONAME set and DT_NEEDED rewritten; fixing names at link time beats patchelf. A plugin can be dlopen'd from filesDir: SELinux grants app_data_file execute and the namespace permits /data. Android 17 (target 37) requires files passed to System.load to be read-only. execve from app data is denied for targetSdk≥29. A helper executable can run only (a) from nativeLibraryDir as lib*.so with useLegacyPackaging=true, or (b) via /system/bin/linker64 'base.apk!/lib/<abi>/x.so', which needs an upstream code change. Such children count toward the phantom-process killer (32 system-wide) and have no JVM. 16 KB: NDK r27c defaults to 4 KB LOAD alignment (measured). The sibling repo's .so's are all 4 KB aligned even though its APK passes zipalign -P 16. We need -Wl,-z,max-page-size=16384 (or ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON) everywhere. Verdict: load modules in-process with a new in-process ModuleContainer, and ship .lgx in assets, extracted read-only to filesDir. Subprocess-per-module is possible but not recommended for the POC. If isolation is needed, use android:process services instead.

### Claims
- [C1|high|verified-from-source] Bionic resolves DT_RUNPATH (API >= 24) and rewrites ${ORIGIN} to the directory of the ELF file. ${LIB}/${PLATFORM} are not implemented. patchelf --set-rpath writes DT_RUNPATH (not DT_RPATH) by default, which is the tag bionic reads. DT_RPATH is not listed as supported; the loader code only reads DT_RUNPATH.
- [C2|high|verified-by-experiment] The bionic docs say DT_SONAME is required ('Enforced for API level >= 23'). The basename-as-soname fallback exists only for targetSdk <= 22. In practice, a library without SONAME still loads by file name: the sibling app ships librln.so and libdelivery_jni.so with no SONAME and was verified on an emulator (targetSdk 37). The staging script should still always set SONAME == file name.
- [C3|critical|verified-from-source] Versioned sonames (libQt6Core.so.6, libpq.so.5.17) cannot be shipped through jniLibs. AGP's MergeNativeLibsTask merges only **/*.so, plus gdbserver/gdb.setup. PackageManager extracts only lib*.so files for non-debuggable apps on API <= 35. The staging script must rename every shipped ELF to lib<name>.so, set its SONAME to that name, and rewrite every DT_NEEDED that points at it. Absolute-path DT_NEEDED entries fail on API >= 23.
- [C4|high|verified-from-source] On Android, Qt names its libraries with an ABI suffix (lib<name>_<abi>.so, e.g. libQt6Core_arm64-v8a.so, via qt_android_apply_arch_suffix / the SUFFIX property) and flattens its plugins to libplugins_<type>_<name>_<abi>.so in lib/<abi>/. QFactoryLoader filters plugins with 'libplugins_%1_*.so'. QLibrary on Android retries dlopen with '/' replaced by '_'. Since Qt 6.9, Qt loads libraries and plugins straight from the APK (extractNativeLibs=false) by default. Modules built against logos-nix's Android Qt will therefore carry DT_NEEDED libQt6*_arm64-v8a.so and need no renaming.
- [C5|critical|verified-from-source] On current targetSdk levels, the app process can dlopen a plugin .so from app-private storage (filesDir, e.g. extracted from an .lgx). SELinux grants untrusted_app_all 'app_data_file:file { r_file_perms execute }' (audited with auditallow). libnativeloader's classloader namespace permits absolute paths under /data:/mnt/expand. Android 10 only removed execve() and PROT_EXEC mappings through writable fds. From targetSdk 37 (Android 17), files passed to System.load() must be read-only, or UnsatisfiedLinkError 'Attempt to load writable file' is thrown; that check sits in Java Runtime.load0. The docs do not say that native dlopen() is covered.
- [C6|high|verified-by-experiment] A .so can be loaded straight from the APK (API >= 23) if the entry is stored uncompressed and page-aligned. Bionic rejects zip entries whose offset is not a multiple of page_size(), so on 16 KB devices the entry must be 16 KB aligned. AGP 8.5.1+ does this. Measured on the sibling APK (AGP 9.4.0, minSdk 26): extractNativeLibs=false, every lib/ entry 'Stored', and 'zipalign -c -P 16 -v 4' passes.
- [C7|critical|verified-from-source] A helper executable cannot be exec'd from app data when targetSdk >= 29: execute_no_trans on app_data_file exists only in the untrusted_app_27 domain (25 < targetSdk <= 28). appdomain has x_file_perms on apk_data_file. So an executable shipped as jniLibs/<abi>/libxxx.so and extracted to nativeLibraryDir with useLegacyPackaging=true (extractNativeLibs=true) can be posix_spawn'd. Extraction forces compressed-in-APK storage and a larger installed size. The executable also needs 16 KB LOAD alignment.
- [C8|high|verified-from-source] A host executable can also stay inside the APK and run via the system linker: execve('/system/bin/linker64', {'linker64', '<apk>!/lib/arm64-v8a/liblogos_host_qt.so', args...}). linker_main.cpp accepts 'path.zip!/PROGRAM' (PIE only). SELinux allows untrusted_app_all system_linker_exec execute_no_trans ('Chrome Crashpad uses the dynamic linker to load native executables from an APK'). Current upstream cannot use this without a change: logos-module-loader-qt checks fs::exists(LOGOS_HOST_PATH), and logos-container-subprocess posix_spawns that path directly. /proc/self/exe then points at linker64.
- [C9|high|verified-from-source] Android 12+ counts native child processes forked by apps as 'phantom processes'. By default ActivityManager keeps at most 32 of them system-wide (DEFAULT_MAX_PHANTOM_PROCESSES = 32) and trims the excess with reason 'Trimming phantom processes'. Phantom processes that use too much CPU while their parent is in the background are also killed. The only control is the settings_enable_monitor_phantom_procs flag (a developer option / adb setting, which ordinary users will not change).
- [C10|critical|verified-by-experiment] NDK r27c links with 4 KB LOAD alignment by default. -Wl,-z,max-page-size=16384 produces 16 KB (0x4000 / 'align 2**14'). The NDK CMake toolchain adds that flag for arm64-v8a and x86_64 only when ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON. NDK r28+ defaults to 16 KB. Google Play requires 16 KB support for apps targeting API 35+; updates without it cannot be released from February 1, 2027.
- [C11|high|verified-by-experiment] Every .so the sibling logos-android-wrap-poc stages (liblogosdelivery.so, libdelivery_jni.so, librln.so) has 4 KB LOAD alignment (0x1000), yet its APK passes zipalign -c -P 16. Zip-level alignment (which AGP does) is separate from ELF segment alignment, which needs a relink. On a 16 KB device that app would run in page-size compat mode or fail. The new staging script must check LOAD p_align itself.
- [C12|high|verified-by-experiment] patchelf 0.15.2 (the version in the local store and in nixpkgs#patchelf) keeps DT_GNU_HASH on Android ELFs. When a rename grows .dynstr, it appends a new RW PT_LOAD aligned to 0x10000 (a multiple of 16 KB, so acceptable); with --page-size 16384 that segment is aligned to 0x4000. patchelf never fixes the alignment of existing LOAD segments, so 4 KB-linked inputs still have to be relinked. The DT_GNU_HASH loss noted in the sibling repo came from host strip, not from patchelf.
- [C13|critical|verified-by-experiment] An app must have exactly one C++ runtime. Because the POC has several .so's, that runtime must be libc++_shared.so, packaged in the APK. GNU libstdc++ is not supported by the NDK. So no Nix-built Linux library (glibc and libstdc++, sonames like libc.so.6 and libstdc++.so.6) can be reused, and all C/C++ code has to be rebuilt with NDK clang. The NDK r27c libc++_shared.so is already 16 KB aligned. NDK's libc++.so is a linker script that resolves to libc++_shared (INPUT(-lc++_shared)), so a Rust build.rs that links 'c++' (e.g. rapidsnark) ends up depending on the same shared runtime.
- [C14|critical|verified-from-source] logos-nix already has an Android target: Qt 6.11.1 cross-built from source for arm64-v8a only, API 28, compileSdk 36, NDK 27.0.12077973, ANDROID_STL=c++_shared, Qt's bundled 3rdparty libs (so no nixpkgs sonames leak in), openssl_runtime. Its mkQtAndroidApk runs androiddeployqt --aux-mode and gradle with legacyPackaging=false, and it fails the build if any shipped .so has a DT_NEEDED that is neither packaged nor an NDK stub library at the API level. It passes no 16 KB flag, so its Qt libraries are probably 4 KB aligned (NDK r27 default).
- [C15|medium|verified-by-experiment] Sibling repo practice (logos-android-wrap-poc). Native libraries are built outside Gradle with NDK clang (ADR 0003). scripts/stage-jnilibs.sh copies the built .so's and the JNI shim into <gradle-module>/src/main/jniLibs/<abi>/ and runs NDK llvm-strip --strip-unneeded; it avoids host strip and patchelf. Each native library gets its own Gradle module/AAR (ADR 0001). Kotlin loads the dependency before the shim (System.loadLibrary("logosdelivery"), then ("delivery_jni")). librln.so was built with `cross rustc --crate-type=cdylib` in Docker, not cargo-ndk; its .comment/.note show NDK r25b / clang 14.0.6, and it has no SONAME. The upstream rapidsnark crate's CI does use cargo-ndk.
- [C16|medium|verified-from-source] Module plugins do not follow the lib*.so convention. lez_core's metadata main is 'lez_core_plugin', and the package manager appends '.so' on non-Apple, non-Windows builds, giving <modulesDir>/lez_core/lez_core_plugin.so. That works in filesDir. If plugins go into jniLibs instead, they have to be renamed to lib*.so and the manifest main changed to match, because PackageManager extraction and the lib*.so convention (C3) apply there.
- [C17|medium|verified-from-source] The .lgx tooling has no Android variant. nix-bundle-lgx variants are darwin-{arm64,amd64} and linux-{arm64,amd64} (plus -dev). Its #portable bundler copies non-Qt dependencies next to the plugin and rewrites RUNPATH to $ORIGIN. That relocation also works on Android (DT_RUNPATH, API >= 24), but only with NDK-built payloads under a new android variant name. How liblgx names that variant on a bionic build is open.
- [C18|medium|verified-from-source] Google Play policy forbids downloading executable code (.so) from anywhere but Play. For Play builds, module .lgx files must ship inside the APK (e.g. assets/) and be extracted locally. Downloading .lgx at runtime technically loads (C5) but is only acceptable for a sideloaded POC.
- [C19|high|verified-from-source] Upstream liblogos has no in-process container today. The default is logos-container-subprocess (one OS process per module, posix_spawn of logos_host_qt). An in-process container is a documented extension point: a new package defining the makeContainer() factory, or a loader registered via ModuleManager::loaders().registerLoader(...) before logos_core_start(). bionic provides posix_spawn from API 28 and defines POSIX_SPAWN_CLOEXEC_DEFAULT, so the subprocess container would compile for Android.
- [C20|medium|inferred] On Android, logos_host_qt cannot be found automatically. The resolver falls back to next-to-program_location(), which in an app is /system/bin/app_process64, or to <modulesDir>/../bin, which is app data and cannot be exec'd. LOGOS_HOST_PATH must therefore be set (setenv before logos_core_init) to <nativeLibraryDir>/liblogos_host_qt.so. The child inherits environ, so LD_LIBRARY_PATH/QT_* can be passed the same way.
- [C21|medium|verified-from-source] APK size: .so files are stored uncompressed (the default since AGP 3.6/4.2 for minSdk >= 23), so they dominate the APK. The sibling's universal APK is 85.7 MB, 90.8% of it native code for two ABIs. Per-ABI splits or an AAB (mandatory for new Play apps since Aug 2021) roughly halve per-device size. Setting useLegacyPackaging=true (needed for an extracted host executable) compresses libraries in the APK but copies them to disk at install time.
- [C22|low|inferred] AGP 9 rejects an explicit android:extractNativeLibs attribute in the manifest. Extraction has to be configured with packaging { jniLibs { useLegacyPackaging = true } }, which is app-wide, not per library.
- [C23|critical|inferred] Verdict: running each module in a raw subprocess is technically possible on Android but a poor choice for this POC. Problems: (1) it needs either extracted libraries (useLegacyPackaging) or the linker64 + apk!/ trick, and that trick needs an upstream code change; (2) the children are phantom processes (32 system-wide, CPU-killed in the background, invisible to ActivityManager); (3) a child has no JavaVM, so whether Qt for Android (QtCore/QtRemoteObjects) initialises in a JVM-less process is unknown; (4) children are frozen or killed with the app's process group anyway. Recommended: load modules in-process with an in-process ModuleContainer. If isolation is needed, use per-module <service android:process=":mod_x"> processes, which zygote forks with a JVM and ActivityManager manages.

### Open questions
- Does Qt 6.11 for Android (QtCore, QtNetwork, QtRemoteObjects) initialise and run in a native executable with no JavaVM, i.e. logos_host_qt started by posix_spawn or linker64? QtCore on Android normally gets the JavaVM from JNI_OnLoad. Needs an on-device test.
- When the linker runs an executable as 'linker64 <apk>!/lib/arm64-v8a/liblogos_host_qt.so', does it resolve the executable's DT_NEEDED through DT_RUNPATH=$ORIGIN (a zip path) or through LD_LIBRARY_PATH? On which minimum API level does linker64 direct execution work (Android 10 inferred)?
- Which .lgx variant name should an Android (bionic) build use? What does liblgx's lgx_host_variant() return when built with the NDK (probably linux-arm64, which would clash with desktop payloads)? nix-bundle-lgx has no android variant.
- Can liblogos / QPluginLoader load a module plugin by a 'base.apk!/lib/<abi>/libx.so' path, so plugins stay in the APK with extractNativeLibs=false? Or do APK-resident plugins require useLegacyPackaging=true plus a symlink from the filesDir modules tree into nativeLibraryDir?
- Is patchelf-modified output (extra PT_LOAD, moved .dynstr/.dynamic) accepted by bionic on real devices, especially for libraries using RELR / Android packed relocations? Prefer link-time -soname and avoid patchelf until this is tested.
- Will Android extend the Android 17 read-only requirement from System.load() to native dlopen()? Currently undocumented; mark extracted plugin files read-only anyway.
- Are the Qt 6.11.1 Android libraries built by logos-nix (NDK 27.0, no flexible-page-size flag) 4 KB aligned? Check with llvm-readelf -lW on libQt6Core_arm64-v8a.so once built; Qt 6.10+ claims 16 KB support out of the box, but that may assume Qt's own build flags.
- Minimum SDK choice: logos-nix pins API 28 (posix_spawn needs 28). ELF TLS needs 29, and LLD's default rosegment breaks pre-29 crash unwinding unless -Wl,--no-rosegment is used. Should the POC use minSdk 29+?

### Recommendations
- Rebuild everything with one pinned NDK (r27c 27.2.12479018 like the sibling, or r28+) and libc++_shared: liblogos_core, Qt (via logos-nix pkgsAndroid), boost/spdlog/fmt (prefer static), module plugins, and Rust cdylibs via cargo-ndk. Never stage Nix Linux .so's. Reject any ELF whose DT_NEEDED contains libc.so.6, libstdc++.so.6, libgcc_s.so.1, ld-linux*, or any versioned or absolute name.
- Link every Android .so and executable with '-Wl,-z,max-page-size=16384 -Wl,-soname,<file> -Wl,--build-id=sha1' (CMake: -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON; Rust: RUSTFLAGS='-C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-soname,libwallet_ffi.so'). Propose adding ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON to logos-nix androidToolchainFlags.
- Write the staging script (the Android analogue of bundle-runtime.js) as a closure walk plus gate, reading ELFs with llvm-readelf instead of running ldd. For each entry point (JNI shim, liblogos_core, Qt plugins actually used, module plugins, optional host exe), collect DT_NEEDED and resolve each name against the staging dir. Fail on anything neither staged nor present in <ndk>/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/<triple>/<minSdk>/*.so. This is the same gate as logos-nix/nix/android/mk-apk.nix:172-200.
- The per-file checks in the staging script must fail on: LOAD p_align < 0x4000 (llvm-readelf -lW f.so | awk '$1=="LOAD"{print $NF}'); a missing SONAME or SONAME != file name (llvm-readelf -d); TEXTREL; any W+E segment; a missing .note.android.ident (llvm-readelf -n), a cheap NDK-built check; and a file name that does not match lib*.so.
- Rename only when a name cannot be fixed at link time: 'patchelf --page-size 16384 --set-soname libfoo.so libfoo.so' plus 'patchelf --page-size 16384 --replace-needed libfoo.so.5 libfoo.so <each dependent>'. Always pass --page-size 16384. Strip with the NDK's llvm-strip --strip-unneeded, never host strip, and keep unstripped copies for ndk-stack.
- Layout: jniLibs/<abi>/ (flat, names globally unique) gets libc++_shared.so from the same NDK, Qt libs as lib<Name>_<abi>.so, Qt plugins as libplugins_<type>_<name>_<abi>.so, liblogos_core.so and the JNI shim. Module .lgx files go in src/main/assets/modules/. At first run, extract them to filesDir/modules/<module>/ (setReadOnly before writing, per the Android 14 DCL guidance) and call logos_core_add_modules_dir(filesDir/modules). Module-private dependencies (e.g. libwallet_ffi.so) stay beside the plugin, reached through DT_RUNPATH=$ORIGIN. Shared dependencies (Qt, liblogos SDK, libc++_shared) must NOT be duplicated inside the .lgx.
- Keep the default packaging (useLegacyPackaging=false, which is extractNativeLibs=false), minSdk >= 28, and AGP >= 8.5.1. Verify every APK with 'zipalign -c -P 16 -v 4 app.apk', 'unzip -v app.apk | grep lib/' (all entries Stored) and 'aapt2 dump xmltree --file AndroidManifest.xml app.apk | grep extractNativeLibs'. zipalign passing is not enough, because the sibling APK passes with 4 KB ELFs; run the ELF alignment gate as well.
- Build an in-process ModuleContainer (new package implementing makeContainer(), or registerLoader before logos_core_start) instead of shipping logos_host. Only if the subprocess path must be demonstrated: ship logos_host_qt as jniLibs/<abi>/liblogos_host_qt.so (PIE, 16 KB), set useLegacyPackaging=true, and setenv LOGOS_HOST_PATH=<nativeLibraryDir>/liblogos_host_qt.so before logos_core_init. Expect phantom-process kills in the background.
- Ship arm64-v8a first, since logos-nix supports only that ABI; add x86_64 for the emulator later. Use ABI splits or an AAB for distribution so each device receives one ABI's worth of native code.

### Verifier (non-confirmed only)
- [C8] partially-correct: Missing a hard API floor. Running the linker directly ('linker64 PROGRAM' or 'path.zip!/PROGRAM') only exists from Android 10 (API 29). On Android 9 (API 28, the minSdk logos-nix/Qt 6.11 use), linker64 run as a program only prints 'This is %s, the helper program for dynamic executables' and exits. So route (b) also needs minSdk 29 or a fallback, on top of the upstream code change the claim already notes. The rest checks out: SELinux rule, upstream fs::exists/posix_spawn lines, PIE requirement.
- [C9] partially-correct: The 32-process default and the 'Trimming phantom processes' kill are verified. Two parts are not: (1) 'The only control is settings_enable_monitor_phantom_procs' is wrong. max_phantom_processes is a DeviceConfig key (adb shell device_config put activity_manager max_phantom_processes N; resets unless device_config sync is disabled), and Android 14+ has a Developer Options toggle, 'Disable child process restrictions'. (2) The excess-CPU kill is sourced from XDA/Termux write-ups, not from the cited PhantomProcessList.java, which has no CPU threshold. It is plausible (AMS power checks) but should be marked 'secondary source'. Also verified from source: killPhantomProcessGroupLocked kills all phantom children when the parent app process dies.
- [C12] partially-correct: The 0x10000 alignment of the appended LOAD is arm64-only. On x86_64 (the emulator ABI here), patchelf 0.15.2 without --page-size appends a RW PT_LOAD aligned to 0x1000 (4 KB). That breaks 16 KB compliance even for a library linked with -z max-page-size=16384. The staging script must always pass '--page-size 16384' (verified to give 0x4000 on both ABIs). The final sentence is also refuted: host GNU strip 2.45.1 keeps .gnu.hash/DT_GNU_HASH on the x86_64 liblogosdelivery.so, as does host strip followed by patchelf --replace-needed. On arm64, host strip cannot process the file at all ('Unable to recognise the format'). The sibling's reported GNU_HASH loss could not be reproduced with the local tools, and its cause remains unknown. Unchanged: patchelf never realigns existing LOADs, and nixpkgs#patchelf is 0.15.2 (patchelfUnstable is 0.18.0-unstable-2025-08-13).
- [C14] partially-correct: (1) 'Its Qt libraries are probably 4 KB aligned' is contradicted by the pinned Qt 6.11.1 source. qtbase defines feature android_16kb_pages with CONDITION 'ANDROID AND CMAKE_ANDROID_NDK_VERSION >= 25.0.0 AND ABI arm64-v8a|x86_64' and no default-off. When on, it adds target_link_options(Platform INTERFACE "-Wl,-z,max-page-size=16384"). Qt::Platform is a dependency of every Qt target and of user projects linking Qt. With NDK 27.0 on arm64-v8a the feature should auto-enable, and both Qt libs and any CMake module linking Qt6 inherit 16 KB alignment (inferred from source; not measured on a built Qt). Non-Qt artifacts (cargo/Nim) still need the flag. (2) The set exports and wires only qtbase, qtdeclarative, qtshadertools and qtsvg for Android. The Android overlay has no qtremoteobjects/repc host-tool wiring, which the Windows overlay needed, and liblogos requires QtRemoteObjects. (3) Minor: legacyPackaging=false is at mk-apk.nix:149, not :148.
- [C19] partially-correct: It compiles, but it would fail at runtime on Android 9-12. The NDK r27c header defines POSIX_SPAWN_CLOEXEC_DEFAULT unconditionally, so subprocess_container.cpp:533-534 always ORs it in. bionic's posix_spawnattr_setflags accepts that flag only from Android 13 (API 33). On API 28-32 it returns EINVAL, and spawnChild never reaches posix_spawn, so every module load fails. Supporting API < 33 requires an upstream change: a runtime check, or closing fds via file actions only (addCloseForeignFds already does this). The negative claim 'no in-process container' holds: a grep of logos-liblogos, logos-container*, logos-module-loader*, logos-cpp-sdk, logos-qt-sdk, logos-plugin-qt, logos-protocol and logos-module finds no in-process implementation and no Android/iOS guards.

Confirmed: C1, C2, C3, C4, C5, C6, C7, C10, C11, C13, C23

### Verifier missed findings
- Embedding Qt in a Kotlin app is a packaging requirement in its own right, even in-process. In QtCore, JNI_OnLoad -> initJNI does FindClass("org/qtproject/qt/android/QtNative") and calls its activity()/service()/classLoader() statics. It returns JNI_ERR (so System.loadLibrary throws) if Qt's Java runtime (Qt6Android.jar) is not in the app's dex. The JVM only runs JNI_OnLoad for a library passed to System.loadLibrary, not for DT_NEEDED dependencies. If the app only calls System.loadLibrary("logos_core"), g_javaVM stays null, and the first QPluginLoader::load() dereferences a null JavaVM (see C23). The staging/Gradle setup must therefore ship Qt6Android.jar (logos-nix sets QT_ANDROID_JAR_PATH=${qtbase}/jar/Qt6Android.jar) and System.loadLibrary("Qt6Core_<abi>") before liblogos_core, or reuse Qt's QtLoader/androiddeployqt flow. Evidence: qtbase 6.11.1 src/corelib/kernel/qjnihelpers.cpp:279-338 and :482-515 (extracted under .work/verify-android-pkg/qtsrc); /home/fryorcraken/src/logos-co/logos-nix/nix/android/cross-overlay.nix:246-248. Status: verified-from-source (Qt); the JNI_OnLoad-only-for-loadLibrary part is inferred from standard JNI behaviour.
- patchelf's appended-segment alignment depends on the ABI. On x86_64, patchelf 0.15.2 (= nixpkgs#patchelf) adds a 4 KB-aligned PT_LOAD whenever .dynstr grows (--set-soname, --replace-needed to a longer name, --set-rpath). That turns a 16 KB-linked x86_64 .so into a non-compliant one. Every patchelf call in the staging script must pass --page-size 16384, and the script's final gate must check that every LOAD p_align is >= 0x4000 after patching, not before. Evidence: bash .work/scripts/verify-android-pkg-pe16k.sh ('RW 0x1000' without --page-size on x86_64; 'RW 0x4000' with it). Status: verified-by-experiment.
- Qt 6.11.1 builds for Android with 16 KB pages automatically. configure.cmake:1311-1316 feature android_16kb_pages (NDK >= 25, arm64-v8a/x86_64) -> QtPlatformTargetHelpers.cmake:34-35 target_link_options(Platform INTERFACE -Wl,-z,max-page-size=16384). This propagates to any CMake target linking Qt6 (liblogos_core, logos_host, Qt-plugin modules). The 16 KB work is therefore mainly for non-Qt artifacts: Rust cdylibs (RUSTFLAGS='-C link-arg=-Wl,-z,max-page-size=16384'), Nim libraries and plain-C shims. Status: verified-from-source; not measured on a built Qt.
- The logos-nix Android cross set cannot yet build liblogos: it exports and wires only qtbase/qtdeclarative/qtshadertools/qtsvg. The Android overlay lacks the -DQt6RemoteObjectsTools_DIR (host repc) wiring the Windows overlay needed for qtremoteobjects. The Android Qt is 6.11.1, while native Linux liblogos builds use Qt 6.9.2. Evidence: /home/fryorcraken/src/logos-co/logos-nix/flake.nix:32-36 and :324-325; nix/android/cross-overlay.nix:357-375; nix/windows/cross-overlay.nix:57-66, 361-368.
- ABI and emulator mismatch: logos-nix Android is arm64-v8a only ('One ABI is one pseudo-system'). The sibling project found that on this x86_64 host the arm64 AVD refuses to boot ('System image must match the host architecture') and verified on x86_64 instead. A POC built on logos-nix's Qt therefore cannot run on the local emulator without adding an x86_64 pseudo-system (the ndkTriple map already has x86_64) or using a physical arm64 device. Evidence: /home/fryorcraken/src/logos-co/logos-nix/flake.nix:104-108; README.md:164-171; git -C /home/fryorcraken/src/fryorcraken/logos-android-wrap-poc show c3866c3.
- The sibling did not use cargo-ndk for librln. nim-src/logos-delivery/scripts/build_rln_android.sh runs 'cross rustc --release --lib --target=... --crate-type=cdylib' inside cross-rs Docker images that bundle their own NDK. The resulting librln.so carries NDK r25b / clang 14.0.6 identity, rustc 1.95, no SONAME and 4 KB LOADs, and stage-jnilibs.sh never strips it (it strips only liblogosdelivery.so and libdelivery_jni.so). This path is not reproducible under Nix and bypasses the NDK the rest of the app uses. Evidence: build_rln_android.sh:17-29; .github/workflows/ci-nim-android.yml:88-90; stage-jnilibs.sh:71-74; verify-android-pkg-elf.sh .comment/.note.android.ident output.
- NDK version skew to settle: logos-nix Qt uses NDK 27.0.12077973, the local NDK and the sibling's gradle ndkVersion are r27c 27.2.12479018, and the sibling's librln used r25b. All code must share one libc++_shared.so, which the staging script copies from one chosen NDK. Mixing 27.0 and 27.2 (both LLVM 18) is probably ABI-safe but should be pinned. Evidence: logos-nix/flake.nix:128; logos-android-wrap-poc/android/gradle/libs.versions.toml:11; librln note 'r25b'. Status: inferred.
- mkQtAndroidApk's DT_NEEDED gate only checks .so files already in android-build/libs/<abi> ('Link-time sonames only; dlopen is out of scope'). Module plugins shipped as .lgx in assets and extracted to filesDir at runtime get no build-time check, so the new staging script needs its own gate over plugin .so's: every DT_NEEDED must be a packaged lib*.so or an NDK stub at the minSdk, SONAME == file name, and every LOAD p_align >= 0x4000. Evidence: /home/fryorcraken/src/logos-co/logos-nix/nix/android/mk-apk.nix:172-203.
- In an app process, Qt's applicationFilePath() returns empty on Android (qcoreapplication.cpp:2420-2422: 'the actual process on Android is the Java VM'). boost::dll::program_location() resolves to app_process64, which logos-module-loader-qt's resolveLogosHostPath uses as a fallback (qt_plugin_format_loader.cpp:125-129). Any liblogos path logic based on the executable location is meaningless on Android, so LOGOS_HOST_PATH / module dirs must be passed explicitly (e.g. from Context.filesDir / applicationInfo.nativeLibraryDir). Status: verified-from-source (Qt, logos code); consequence inferred.
- A native executable exec'd from nativeLibraryDir (subprocess route) is not in the app's classloader linker namespace. Its DT_NEEDED Qt/libc++ libs are presumably not found unless it carries DT_RUNPATH=$ORIGIN (supported from API 24) or the parent sets LD_LIBRARY_PATH=nativeLibraryDir in the environ that subprocess_container passes through (subprocess_container.cpp:549 passes 'environ'). Status: inferred, not tested on device.
- The rapidsnark dependency (relevant for LEZ provers) pulls prebuilt Android static archives over the network from https://rapidsnark.zkmopro.org/<target>.zip in build.rs. This conflicts with a Nix sandbox build and with 'rebuild all C++ with our NDK'. Plan either a vendored/fixed-output fetch or a source build of rapidsnark with the chosen NDK. Evidence: /home/fryorcraken/src/logos-blockchain/logos-blockchain-rust-rapidsnark/crates/build.rs:17-35,53-63; download_rapidsnark.sh:26.

---

## Full report

## Packaging the Logos runtime into an Android app (the Android analogue of `scripts/bundle-runtime.js`)

### 1. What changes from the Electron POC

The Electron POC's `scripts/bundle-runtime.js` walks an `ldd` closure from the addon, `logos_host` and the module plugins. It copies every non-glibc library into one flat `lib/` and rewrites each RUNPATH to `$ORIGIN` (`/home/fryorcraken/src/fryorcraken/liblogos-electron-poc/scripts/bundle-runtime.js:15-19,185-198`). It deliberately keeps glibc from the host and does bundle libstdc++.

On Android **none of those Nix-built Linux libraries can be reused**:

- The NDK supports one C++ runtime per app. With more than one `.so` that runtime is `libc++_shared.so`, and it must be packaged in the APK. GNU libstdc++ is not supported ([NDK C++ support](https://developer.android.com/ndk/guides/cpp-support): "An application should not use more than one C++ runtime" … "If your application includes multiple shared libraries, use libc++_shared.so" … "GNU libstdc++ is not supported in the NDK").
- Qt for Android itself refuses anything else: `QtPlatformAndroid.cmake` fails with "The Qt libraries on Android only supports the shared library configuration of stl".
- A glibc build carries DT_NEEDED entries such as `libc.so.6` and `libstdc++.so.6`, which bionic does not provide.

So the Android pipeline is: rebuild everything with NDK clang, then stage the results. The staging step keeps the useful half of bundle-runtime.js (the closure walk and the gate). The RUNPATH rewriting mostly goes away, because the app's linker namespace already searches `lib/<abi>`.

That rebuild path already exists upstream. `logos-nix` has an Android target: Qt 6.11.1 cross-built from source for arm64-v8a only, with API 28, compileSdk 36 and NDK 27.0.12077973 (`/home/fryorcraken/src/logos-co/logos-nix/flake.nix:104-137`).

- It passes `-DANDROID_STL=c++_shared` and uses Qt's own `src/3rdparty` libraries instead of nixpkgs'. A nixpkgs library would become a DT_NEEDED soname that nothing on the device provides; the README says this was "measured on a physical arm64 device" (`nix/android/cross-overlay.nix:99-110,296-317`, `README.md:188-194`).
- Its `mkQtAndroidApk` runs `androiddeployqt --aux-mode` plus gradle with `legacyPackaging=false`.
- It fails the build when a shipped `.so` has a DT_NEEDED that is neither packaged nor an NDK stub library at the API level (`nix/android/mk-apk.nix:148,172-200`). That gate is exactly the check our staging script needs.

### 2. How bionic resolves libraries

**Search path.** An app's JNI libraries live in the classloader linker namespace. That namespace "is configured so that only the JNI libraries embedded in the APK is accessible" plus public NDK libraries ([libnativeloader README](https://android.googlesource.com/platform/art/+/main/libnativeloader/README.md)). DT_NEEDED is resolved against the app library directory, which has been on the search path since API 18 ([android-changes-for-ndk-developers.md](https://android.googlesource.com/platform/bionic/+/main/android-changes-for-ndk-developers.md)).

With `extractNativeLibs=false` that directory is the APK itself (`base.apk!/lib/<abi>`). The sibling repo shows the default AGP 9.4 build does exactly this: its APK has `extractNativeLibs=false` and every `lib/` entry `Stored`. `liblogosdelivery.so`'s DT_NEEDED `librln.so` resolves from the APK, and the app was run on an emulator (`logos-android-wrap-poc/README.md:28-34`; experiment `android-pkg-inspect.sh`).

**Absolute paths.** `dlopen()` by absolute path is also permitted anywhere under `/data` and `/mnt/expand`. The source is `kAlwaysPermittedDirectories = "/data:/mnt/expand"` in [library_namespaces.cpp](https://android.googlesource.com/platform/art/+/main/libnativeloader/library_namespaces.cpp).

**RUNPATH.** DT_RUNPATH is supported from API 24, and "`${ORIGIN}` will be rewritten at runtime to the directory containing the ELF file". `${LIB}` and `${PLATFORM}` are not implemented. The loader reads only DT_RUNPATH (linker.cpp: `if (d->d_tag == DT_RUNPATH) si->set_dt_runpath(...)`). patchelf writes DT_RUNPATH by default (experiment 4(d)), so `$ORIGIN` relocation works for module-private dependencies that sit next to a plugin in app storage. This is the same mechanism `nix-bundle-lgx#portable` uses on Linux (`/home/fryorcraken/src/logos-co/nix-bundle-lgx/README.md:17`).

**SONAME.** The docs say "Missing SONAME (Enforced for API level >= 23)". The basename fallback only survives for targetSdk ≤ 22 (bionic commit [75108f4](https://android.googlesource.com/platform/bionic/+/75108f4%5E!/): `target_sdk_version <= 22`). In practice a library without SONAME still loads by file name: the sibling's `librln.so` (Rust cdylib) and `libdelivery_jni.so` (raw `clang -shared`) both lack SONAME and work at targetSdk 37. The staging script should still enforce `SONAME == file name`, because matching an already-loaded library is done by soname.

Raw clang and rustc do not add `-soname`; the NDK build systems do. The NDK maintainers' guide says "`-Wl,-soname,$NAME_OF_LIBRARY` argument is required" ([BuildSystemMaintainers.md](https://android.googlesource.com/platform/ndk/+/master/docs/BuildSystemMaintainers.md)).

**Versioned names and non-`lib*.so` names.** The linker itself only matches file names, but packaging filters files out:

- AGP's `MergeNativeLibsTask` includes only `**/*.so` plus `gdbserver` and `gdb.setup` ([source](https://android.googlesource.com/platform/tools/base/+/studio-master-dev/build-system/gradle-core/src/main/java/com/android/build/gradle/internal/tasks/MergeNativeLibsTask.kt)). A `libQt6Core.so.6` or `libpq.so.5.17` in jniLibs is silently dropped.
- "Until API level 36, PackageManager would only install files whose names match the glob `lib*.so` when extracting native libraries for non-debuggable apps." So `lez_core_plugin.so` would be extracted on debug builds but missing on release builds when extraction is on.

The rule for the staging script: every ELF shipped via jniLibs must be named `lib<name>.so`, with SONAME equal to that name and every dependent's DT_NEEDED rewritten. Absolute-path DT_NEEDED entries fail on API ≥ 23 ("Invalid DT_NEEDED Entries").

**Qt's own naming.** Qt for Android appends the ABI to library file names (`qt_android_apply_arch_suffix`, [doc](https://doc.qt.io/qt-6/qt-android-apply-arch-suffix.html)), giving e.g. `libQt6Core_arm64-v8a.so`. It flattens plugins into `lib/<abi>/`:

- `QFactoryLoader` on Android filters plugins with `"libplugins_%1_*.so"` ([qfactoryloader.cpp](https://raw.githubusercontent.com/qt/qtbase/dev/src/corelib/plugin/qfactoryloader.cpp)).
- `QLibrary` retries `dlopen` with `/` replaced by `_` ([qlibrary_unix.cpp](https://raw.githubusercontent.com/qt/qtbase/dev/src/corelib/plugin/qlibrary_unix.cpp)).
- Since Qt 6.9, loading straight from the APK is the default ([Qt 6.9 Android updates](https://www.qt.io/blog/qt-6.9-android-updates)).

So module plugins built against logos-nix's Android Qt will have DT_NEEDED `libQt6Core_arm64-v8a.so` and need no renaming. Renaming is only needed for artifacts that came from a Linux-style build.

### 3. Plugins outside jniLibs: dlopen from app storage, or from the APK

**From `filesDir` (extracted from an `.lgx` in `assets/`, or downloaded).** This is allowed:

- SELinux: `allow untrusted_app_all app_data_file:file { r_file_perms execute }; auditallow …` with the comment "Some apps ship with shared libraries and binaries that they write out to their sandbox directory and then execute" ([untrusted_app_all.te](https://android.googlesource.com/platform/system/sepolicy/+/main/private/untrusted_app_all.te)).
- The namespace permits `/data` (see §2).
- Android 10's W^X change forbids only `execve()` of app-home files and PROT_EXEC mappings through a writable fd ([Android 10 changes](https://developer.android.com/about/versions/10/behavior-changes-10)).

Android 17 tightens this for targetSdk 37: "All native files loaded using `System.load()` must be marked as read-only. Otherwise, the system throws `UnsatisfiedLinkError`" ([Android 17 changes](https://developer.android.com/about/versions/17/behavior-changes-17)). The check is in Java `Runtime.load0` ([Intune issue #343](https://github.com/microsoftconnect/ms-intune-app-sdk-android/issues/343): "Attempt to load writable file"). A native `dlopen()` issued by liblogos/Qt is not documented as covered. Even so, extracted plugin files should be made read-only; Android 14's DCL guidance is to call `setReadOnly()` before writing.

Play policy forbids downloading `.so` code from outside Play ([policy](https://support.google.com/googleplay/android-developer/answer/9888379)). For Play builds the `.lgx` files must therefore ship in the APK. Runtime download is fine only for a sideloaded POC.

**Directly from the APK.** Supported from API 23 when the entry is stored uncompressed and page-aligned. The linker rejects `entry.offset % page_size() != 0` ([linker.cpp](https://android.googlesource.com/platform/bionic/+/main/linker/linker.cpp)), so 16 KB devices need 16 KB zip alignment, which AGP ≥ 8.5.1 provides.

Whether liblogos/QPluginLoader accepts a `base.apk!/lib/<abi>/libx.so` path as a module `main` is open. A module tree in `filesDir` is the least surprising layout. The package manager resolves `<dir>/<main>.so` on non-Apple, non-Windows builds (`/home/fryorcraken/src/logos-co/logos-package-manager/src/package_manager_lib.cpp:585-599`); for lez_core that is `lez_core_plugin.so` (`logos-execution-zone-module/metadata.json:14`).

### 4. Helper executable (`logos_host_qt`) and the subprocess-per-module model

**What upstream does.** liblogos's default container is `logos-container-subprocess`, "one OS process per module" (`logos-liblogos/README.md:15`). It `posix_spawn`s the host path directly (`subprocess_container.cpp:549`). The host is found via `LOGOS_HOST_PATH`, then next to `program_location()`, then `<modulesDir>/../bin`, and must pass `fs::exists` (`logos-module-loader-qt/src/qt_plugin_format_loader.cpp:118-148`).

On Android `program_location()` is `app_process64`, and `modulesDir/../bin` is app data, which cannot be exec'd. `posix_spawn` itself is available from API 28, and bionic defines `POSIX_SPAWN_CLOEXEC_DEFAULT` (NDK `spawn.h:50,57`).

**Where an app can exec from.**

- Targeting API ≥ 29, an app cannot exec its data files. `execute_no_trans` on `app_data_file` exists only in `untrusted_app_27` ("25 < targetSdkVersion <= 28", [untrusted_app_27.te](https://android.googlesource.com/platform/system/sepolicy/+/main/private/untrusted_app_27.te)).
- `appdomain` does have `x_file_perms` on `apk_data_file` ([app.te](https://android.googlesource.com/platform/system/sepolicy/+/main/private/app.te)).

That leaves two workable forms:

1. **Extract to `nativeLibraryDir`.** Package the PIE executable as `jniLibs/<abi>/liblogos_host_qt.so` and set `packaging.jniLibs.useLegacyPackaging = true`. That setting is app-wide; AGP 9 rejects the manifest attribute. Then `setenv("LOGOS_HOST_PATH", nativeLibraryDir + "/liblogos_host_qt.so")`. Cost: libraries are compressed in the APK and copied to disk at install time ([page-sizes doc](https://developer.android.com/guide/practices/page-sizes)).
2. **Run through the system linker.** Leave the executable inside the APK and run `execve("/system/bin/linker64", {"linker64", "<apk>!/lib/arm64-v8a/liblogos_host_qt.so", …})`.
   - `linker_main.cpp` documents `linker64 [--list] path.zip!/PROGRAM` (PIE only).
   - SELinux allows it: "Chrome Crashpad uses the dynamic linker to load native executables from an APK … `allow untrusted_app_all system_linker_exec:file execute_no_trans`".
   - It needs an upstream change, since the container spawns the host path directly and the resolver requires `fs::exists`. `/proc/self/exe` then points at linker64 ([Termux notes](https://github.com/termux/termux-packages/wiki/Termux-execution-environment)).

**Lifetime.** Children forked this way are "phantom processes":

- `DEFAULT_MAX_PHANTOM_PROCESSES = 32`, system-wide ([ActivityManagerConstants.java](https://android.googlesource.com/platform/frameworks/base/+/main/services/core/java/com/android/server/am/ActivityManagerConstants.java)).
- The excess is killed as "Trimming phantom processes" ([PhantomProcessList.java](https://android.googlesource.com/platform/frameworks/base/+/main/services/core/java/com/android/server/am/PhantomProcessList.java)).
- Phantom processes are killed when they use too much CPU while the parent is in the background ([XDA](https://www.xda-developers.com/android-12-background-app-limitations-major-headache/)).
- The only override is a developer/adb setting.

A spawned child also has no JavaVM. Whether Qt for Android's QtCore/QtRemoteObjects work in a JVM-less process is unverified.

**Verdict.** Subprocess-per-module is *possible* but not viable as the POC's primary path. The recommended path is to **load modules in-process**. Upstream has no in-process container yet, but documents it as an extension point: a package defining `makeContainer()`, or `ModuleManager::loaders().registerLoader(...)` before `logos_core_start()` (`logos-liblogos/docs/spec.md:51,321`).

If process isolation is required later, use per-module `<service android:process=":mod_x">` processes rather than raw exec ([service element](https://developer.android.com/guide/topics/manifest/service-element)). Those are zygote-forked with a JVM, managed by ActivityManager, and able to load the same jniLibs. Communication would go over QtRemoteObjects on a local socket.

### 5. 16 KB pages

**Measured with NDK r27c.**

- A default link gives `LOAD … Align 0x1000`.
- Adding `-Wl,-z,max-page-size=16384` gives `0x4000`, shown by llvm-objdump as `align 2**14` (experiment §1).
- The NDK CMake toolchain adds that flag for arm64-v8a and x86_64 only when `ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON` (`/home/fryorcraken/android-ndk/android-ndk-r27c/build/cmake/flags.cmake:35-39`). NDK r28+ does it by default.
- The NDK's own `libc++_shared.so` is already 16 KB aligned.

**Play requirement.** Apps targeting API 35+ must support 16 KB pages, and "Starting February 1, 2027, if your app updates don't support 16 KB memory page sizes, you won't be able to release these updates" ([page-sizes](https://developer.android.com/guide/practices/page-sizes)). On a 16 KB kernel, 4 KB ELFs run in page-size compat mode.

**Lesson from the sibling repo.** All its staged `.so` files have 4 KB LOAD alignment:

- `liblogosdelivery.so` and `libdelivery_jni.so`: NDK r27c.
- `librln.so`: `cross rustc` with NDK r25b / clang 14.0.6.

Yet its APK passes `zipalign -c -P 16`. Zip alignment is done by AGP; ELF alignment requires a relink. The gate must check both.

logos-nix's Android Qt is built with NDK 27.0 and no flexible-page-size flag, so it is probably 4 KB aligned. Adding `-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON` to `androidToolchainFlags` would fix that. Qt says 6.10+ supports 16 KB out of the box ([Qt blog](https://www.qt.io/blog/android-15-and-16-support)).

### 6. patchelf and stripping on Android ELFs (measured)

patchelf 0.15.2, the version in the store and in `nixpkgs#patchelf`:

- Keeps DT_GNU_HASH, which bionic needs from API 23 ("GNU hashes").
- When `--set-soname`, `--replace-needed` or `--set-rpath` grows `.dynstr`, it appends a new RW `PT_LOAD` aligned to `0x10000`. That is 16 KB-compatible; `--page-size 16384` makes it `0x4000`.
- It never realigns existing segments. A 4 KB input stays 4 KB.

The sibling's note that DT_GNU_HASH was lost came from a *host* `strip`, not from patchelf (`stage-jnilibs.sh:31-37`). NDK `llvm-strip --strip-unneeded` keeps alignment, GNU_HASH and section headers (measured). Section headers are required from API 24.

Prefer fixing names at link time with `-Wl,-soname`. Use patchelf only for third-party binaries, always with `--page-size 16384`, and test on a device (bionic's ELF validation is stricter from API 26).

### 7. Rust

The sibling built `librln.so` with `cross rustc --crate-type=cdylib` in Docker (`nim-src/logos-delivery/scripts/build_rln_android.sh:21-29`), not with cargo-ndk. The rapidsnark crate's CI uses `cargo ndk -t <target> build`. Its `build.rs` links `c++` for clang (`crates/build.rs:41-54`). In the NDK sysroot, `libc++.so` is the linker script `INPUT(-lc++_shared)` (measured), so Rust modules end up depending on the app's single `libc++_shared.so`.

Recommended: `cargo ndk -t arm64-v8a --platform <minSdk> build --release` with `RUSTFLAGS="-C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-soname,lib<crate>.so"`, using the same NDK as everything else.

### 8. What the staging script must do

Inputs are NDK-built artifacts only: logos-nix Android Qt, liblogos_core, the JNI shim, module plugins and their dependencies (e.g. `libwallet_ffi.so`), and optionally the host executable.

1. **Closure walk (the ldd replacement).** From the entry points, run `$NDKBIN/llvm-readelf -d f.so | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'`. Resolve each name against the staging set and the NDK stubs in `sysroot/usr/lib/<triple>/<minSdk>/*.so`. Fail on anything unresolved, as in the mk-apk.nix gate. Also add Qt plugins that are loaded by `dlopen`, which the walk cannot see (bundle-runtime.js hit the same problem with tls/networkinformation, lines 295-326). Qt's TLS backend `dlopen`s libssl (`openssl_runtime`), so libssl and libcrypto must be supplied via `QT_ANDROID_EXTRA_LIBS` (`logos-nix/README.md:196-199`).
2. **Per-file checks.** Fail the build on any of these:
   - `llvm-readelf -h`: machine is not AArch64/X86-64, or type is not DYN.
   - `llvm-readelf -n`: no `NT_ANDROID_TYPE_IDENT`.
   - `llvm-readelf -lW`: any `LOAD` align below `0x4000`, or any segment with both W and E.
   - `llvm-readelf -d`: TEXTREL present, SONAME missing or not equal to the file name, or DT_NEEDED absolute, versioned, or naming glibc/libstdc++.
   - The file name does not match `lib*.so`.
3. **Fixups, only when unavoidable.**
   - `patchelf --page-size 16384 --set-soname libX.so libX.so`
   - `patchelf --page-size 16384 --replace-needed libX.so.5 libX.so <dependents>`
   - For modules that live in `filesDir`: `patchelf --page-size 16384 --set-rpath '$ORIGIN' <plugin>`
4. **Strip.** `$NDKBIN/llvm-strip --strip-unneeded` on copies, keeping the unstripped originals for `ndk-stack`.
5. **Place the files.**
   - `app/src/main/jniLibs/<abi>/` (flat, names must be unique): `libc++_shared.so` from the same NDK, `libQt6*_<abi>.so`, the `libplugins_<type>_<name>_<abi>.so` files that are needed, `liblogos_core.so`, and the JNI shim.
   - `app/src/main/assets/modules/*.lgx`: extracted at first run into `filesDir/modules/<name>/` (read-only), then `logos_core_add_modules_dir()`. Plugins keep their upstream names there. Module-private dependencies sit beside them and are reached through `$ORIGIN`. Qt, liblogos and libc++ are *not* duplicated inside the `.lgx`.
   - Only for the subprocess experiment: `jniLibs/<abi>/liblogos_host_qt.so` (PIE, 16 KB) with `useLegacyPackaging = true` and `LOGOS_HOST_PATH` set.
6. **APK verification.**
   - `$BT/zipalign -c -P 16 -v 4 app.apk`
   - `unzip -v app.apk | grep lib/`: every entry `Stored`.
   - `$BT/aapt2 dump xmltree --file AndroidManifest.xml app.apk | grep extractNativeLibs`
   - Re-run the ELF alignment loop on the libraries extracted from the APK.

### 9. APK size

Native code dominates. The sibling's universal APK is 85.7 MB, 90.8% of it `lib/**` for two ABIs (`logos-android-wrap-poc/README.md:49-91`); a logos-nix one-window Qt app is 19 MiB. Libraries are stored uncompressed by default (AGP 3.6/4.2+), which gives a smaller install and no extraction.

Build arm64-v8a only at first, since logos-nix supports only that ABI. Distribute with ABI splits (`splits { abi { isEnable = true; reset(); include("arm64-v8a","x86_64"); isUniversalApk = false } }`) or an AAB, which is mandatory for new Play apps since August 2021 ([APK splits](https://developer.android.com/build/configure-apk-splits)).

### 10. What carries over from the sibling repo

- Build native code outside Gradle with NDK clang, and let Gradle only package `jniLibs` (ADR 0003).
- Strip with NDK `llvm-strip`, not host tools.
- Load dependencies in order from Kotlin (`System.loadLibrary("logosdelivery")`, then the shim).
- Pin the NDK version in `libs.versions.toml` (`ndk = "27.2.12479018"`).

What must change:

- The 4 KB alignment.
- Missing SONAMEs.
- `cross` in Docker with NDK r25b for Rust; use cargo-ndk with the pinned NDK instead.
- The per-library AAR split (ADR 0001) does not map directly onto a liblogos runtime whose modules are data (`.lgx`), not Gradle dependencies.

