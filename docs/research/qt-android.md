# Qt for Android

> Research track `qt-android`, 2026-09-25. Written by a research agent and then checked by a
> second, adversarial agent, whose non-confirmed verdicts are listed under "Verifier".
> Claims are tagged verified-from-source / verified-by-experiment / inferred / open.
> Absolute paths point at the author's local checkouts (`~/src/logos-co`,
> `~/src/logos-blockchain`) at the revisions in [../investigation.md](../investigation.md);
> `.work/` paths are local scratch, not committed. The synthesis is in
> [../investigation.md](../investigation.md).


### Summary
Current logos-liblogos pins logos-nix f55bf91, which pins stock NixOS/nixpkgs e9f00bd. On Linux that gives Qt 6.9.2, with only nixpkgs packaging patches and no Logos fork. logos-nix also has a second pin, nixpkgs b5aa0fbd, which gives Qt 6.11.1. That pin is used for Windows and iOS. logos-nix master (not yet pinned by liblogos) also uses it for a from-source Android arm64 cross build.

No Logos binary or source uses Qt private APIs. I checked the ELF files: 0 Qt_6_PRIVATE_API imports in liblogos_core, protocol, qt_host, logos_host_qt and the module plugins. The only importer is libQt6RemoteObjects itself: 27 QtCore-private symbols on both Linux 6.9.2 and Android 6.11.1. So the Electron POC's "exact Qt" trap becomes: use ONE Qt build for QtCore and QtRemoteObjects, a host Qt of the same version for moc/repc, and a runtime Qt at least as new as the compile Qt. Once we build everything for Android ourselves, that is automatic.

Qt modules needed: Core, Network and RemoteObjects. Qml is needed only for modules with a .rep replica factory. LEZ needs nothing more. The container, module-loader, package-manager and process-stats repos are Qt-free.

Official Qt prebuilts exist for 6.9.2 and 6.11.1 (arm64_v8a and x86_64, with the qtremoteobjects add-on). I downloaded Qt 6.11.1 android_arm64_v8a qtbase and qtremoteobjects (96 MB):
- It was built with NDK r27c (27.2.12479018). That NDK is installed here.
- It defaults to android-28 (min API 28) and needs platform android-36 and build-tools 36.0.0, which are also installed.
- Every .so has 16 KB LOAD alignment (0x4000). Qt6::Platform passes -Wl,-z,max-page-size=16384 to every consumer target.
- The 6.9.x prebuilts only got 16 KB support in 6.9.3, so 6.9.2 is not 16 KB-ready.

Recommendation: official Qt 6.11.1 for arm64-v8a and x86_64, with RemoteObjects, plus host linux_gcc_64 6.11.1 with qtremoteobjects. This matches the logos-nix non-Linux pin. The Nix Android route exists on logos-nix master but is arm64-only and lacks the repc/qtremoteobjects wiring, so it is a later convergence path.

Embedding: a plain Kotlin app can load Qt Core with no QtActivity, but three things are required:
1. Qt6Android.jar must be in the APK. Qt Core's JNI_OnLoad does FindClass(org/qtproject/qt/android/QtNative), registers natives on it and on QtInputDelegate, and returns JNI_ERR if either fails.
2. Set TMPDIR to cacheDir before anything else. Otherwise QtRO's local: socket goes to /tmp and the listen fails.
3. Load the libraries and run QCoreApplication::exec on one dedicated Java thread, the way Qt's QtThread does.

QtRO local: sockets are allowed by SELinux, both inside one app process and between processes of the same app.

### Claims
- [C1|critical|verified-by-experiment] logos-liblogos (current checkout) pins logos-nix rev f55bf91b8a723ee5c27c39c773b034255538d280, whose nixpkgs is stock NixOS/nixpkgs e9f00bd893984bc8ce46c895c3bf7cac95331127 (not a logos-co fork); qt6.qtbase there is 6.9.2.
- [C2|medium|verified-by-experiment] The pinned Qt 6.9.2 is nixpkgs-stock. qtbase carries only 9 nixpkgs packaging patches (plugin path from PATH, qmake, sbom, qmlimportscanner and so on) and qtremoteobjects has no patches. logos-nix's native overlays touch only the cargo/crate fetchers, not Qt.
- [C3|high|verified-by-experiment] logos-nix has a second pin, nixpkgs-windows b5aa0fbd, which gives Qt 6.11.1. It is used for Windows, iOS and, on logos-nix master only, Android. So the Logos stack is already built against Qt 6.11.1 on non-Linux targets, and liblogos exposes an x86_64-windows package set through logos-nix.lib.mkWindowsPkgs.
- [C4|critical|verified-by-experiment] No Logos code uses Qt private headers or Qt6::*Private targets. In Linux 6.9.2 and Android 6.11.1 alike, the only Qt_6_PRIVATE_API importer is libQt6RemoteObjects itself, with 27 undefined QtCore-private symbols (QMetaObjectBuilder, QObjectPrivate and so on). The Logos ELF files import only Qt_6 and Qt_6.9 version tags. So the Electron POC's 'exact Qt' constraint is really: QtRemoteObjects must be from the same Qt build as QtCore, host tools must be the same version, and the runtime must be at least as new as the compile-time Qt. Once we build everything for Android ourselves, that just means using ONE Qt consistently.
- [C5|high|verified-from-source] The Qt modules the stack needs are Core, Network and RemoteObjects. Qml is needed only for modules that declare a .rep replica factory. LEZ (lez_core) is a plain logos_module with EXTERNAL_LIBS wallet_ffi, so it needs only Core and RemoteObjects. logos-container, container-subprocess, module-loader, package-manager and process-stats are Qt-free.
- [C6|critical|verified-by-experiment] Official Qt prebuilt Android binaries, including the qtremoteobjects add-on, exist for 6.9.2 and 6.11.1 (also 6.8.3, 6.10.1, 6.11.3 and 6.12.0) for android_arm64_v8a and android_x86_64. From Qt 6.7 onward aqt installs them under host 'all_os'. The matching host linux_gcc_64 desktop Qt with qtremoteobjects is also available.
- [C7|high|verified-by-experiment] The official Qt 6.11.1 android_arm64_v8a prebuilt was built with NDK r27c (27.2.12479018), which is exactly the NDK installed here. It defaults to ANDROID_PLATFORM android-28. Qt 6.11 documents API 28-36, JDK 21+, platforms;android-36 and build-tools;36.0.0, all of which are installed (JDK 25).
- [C8|high|verified-by-experiment] Every .so in the official Qt 6.11.1 arm64 prebuilt (Core, Network, RemoteObjects and the plugins) has LOAD p_align 0x4000, i.e. 16 KB. Qt was configured with 'Using 16KB page sizes in Android ... yes', and Qt6::Platform passes INTERFACE_LINK_OPTIONS -Wl,-z,max-page-size=16384, so every Logos target that links Qt6::Core is also linked 16 KB-aligned. Non-Qt libraries (Boost, spdlog, OpenSSL, Rust wallet_ffi) need their own flag: ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON in NDK r27 CMake, or -Wl,-z,max-page-size=16384.
- [C9|high|verified-from-source] Qt 6.9.2's Android prebuilts predate Qt's 16 KB page support, which arrived in 6.9.3. 6.10 and later support it out of the box. That, plus the logos-nix 6.11.1 alignment, is why 6.11.1 is recommended over 6.9.2.
- [C10|high|verified-from-source] The target Qt refuses a mismatched host. Qt6CoreDependencies and Qt6RemoteObjectsDependencies require Qt6CoreTools and Qt6RemoteObjectsTools at 6.11.1 or newer, so a same-version host Qt with qtremoteobjects (for repc) is needed. target_qt.conf expects it at HostPrefix=../../gcc_64. The Nix 6.9.2 host Qt cannot be used as QT_HOST_PATH for a 6.11.1 target.
- [C11|high|verified-by-experiment] Nix route: logos-nix master (commit 5378de5, 2026-09-07) cross-builds Qt 6.11.1 from source for Android arm64-v8a only. It uses NDK 27.0.12077973, API 28 and compileSdk 36, and adds mkQtAndroidApk. It asserts only qtbase, qtdeclarative, qtshadertools and qtsvg. pkgsAndroid.qt6.qtremoteobjects evaluates, but its cmakeFlags have no Qt6RemoteObjectsTools_DIR or host prefix, although the Windows overlay says those flags are needed. liblogos's pinned logos-nix (f55bf91) predates the Android support. Upstream nixpkgs pkgsCross.aarch64-android-prebuilt.qt6.qtbase will not even evaluate without allowing unfree, and needs the logos-nix overlay's many fixes.
- [C12|critical|verified-from-source] Qt Core's JNI_OnLoad (exported only by libQt6Core and the qtforandroid platform plugin) calls initJNI. initJNI does FindClass("org/qtproject/qt/android/QtNative"), calls the static methods activity(), service() and classLoader(), registers natives on QtNative and QtInputDelegate plus the permission, native-interface and extras natives, and returns JNI_ERR if any step fails. So a plain Kotlin app must ship Qt6Android.jar in its dex, and R8 must keep it.
- [C13|high|verified-from-source] Without QtActivity or QtService, Qt's Android context is null, because QtAndroidPrivate::context() returns the activity, then the service, then nullptr. Qt's class loader is also null unless QtNative.setClassLoader is called, and QtAndroidPrivate::findClass then fails for app classes on natively attached threads. The Java-side environment QtLoader normally sets (HOME=filesDir, TMPDIR=cacheDir, QT_PLUGIN_PATH, via Os.setenv) is missing too, so the app must set it itself.
- [C14|high|inferred] Qt itself loads its libraries and runs main() on a dedicated Java thread (QtThread, 'qtMainLoopThread'), not on the Android UI thread. For a Core-only app, the event loop is Qt's own UNIX dispatcher (GLib is off in the prebuilt) and is independent of the Android Looper. The first thread that adopts Qt thread data becomes the Qt main thread, and QCoreApplication warns if it is built on another thread. So load Qt and construct and exec() the QCoreApplication on one dedicated thread, and never touch Qt from the UI thread before that.
- [C15|critical|verified-from-source] logos-protocol's QtRO URLs are 'local:logos_<module>_<instanceId>', which is relative, so QLocalServer puts the socket under QDir::tempPath(). QDir::tempPath() is TMPDIR, or else _PATH_TMP, which defaults to '/tmp' because bionic's paths.h has no _PATH_TMP. On Android, without TMPDIR, RemoteTransportHost::publishObject therefore fails to listen. The app must Os.setenv("TMPDIR", cacheDir) before any Logos or Qt code runs; child processes inherit it.
- [C16|high|inferred] Android SELinux lets an app create unix socket files in its own data directory, and lets a domain connect to its own unix stream sockets. So QtRO local: works inside one app process and between processes of the same app (same uid, domain and categories). QtRO also registers a 'localabstract:' scheme under Q_OS_LINUX, which is defined on Android, but logos-protocol does not use it.
- [C17|medium|verified-by-experiment] The Android Qt prebuilts use ABI-suffixed sonames, e.g. libQt6Core_arm64-v8a.so, and depend only on NDK system libraries plus libc++_shared.so, which the app must package from the same NDK. Qt Network uses OpenSSL at runtime (dlopen) rather than linking it. logos-protocol and liblogos_core do link OpenSSL (libssl/libcrypto 3) directly, so an Android OpenSSL build is needed anyway.
- [C18|medium|verified-from-source] Qt also has an official non-GUI route: a QtService or QtServiceBase declared in the manifest with android.app.lib_name, whose native main() runs QAndroidService. It can run in its own process (android:process) or in-process. This is the fallback if the manual QCoreApplication-on-a-thread embedding misbehaves. Qt Quick for Android (QtQuickView, Qt Gradle plugin) is for embedding QML UI and is not needed for a Core-only runtime.
- [C19|medium|inferred] If liblogos keeps spawning logos_host_qt as a separate process (logos-container-subprocess), two things follow. (1) For targetSdk 29 or higher, the executable must run from the APK's native library directory, packaged as lib*.so and extracted, because only untrusted_app_27 may execve from the app data dir. (2) The child has no JavaVM, and Qt's QJniEnvironment::getJniEnv dereferences QtAndroidPrivate::javaVM() without a null check, so any Qt Core path that reaches JNI in the child will crash. QtRO and QLocalSocket are pure POSIX.
- [C20|low|inferred] Licensing: Qt Core, Network and RemoteObjects can be used under LGPLv3. Shipping them as dynamically linked .so files inside an APK counts as dynamic linking. The obligations are to include the licence texts, provide the Qt source or a written offer (with any modifications), and allow relinking, which is easy for an open-source app using unmodified official binaries. The Qt Java binding templates (QtActivity, QtService, QtApplication) are BSD-3-Clause or commercial.
- [C21|medium|verified-from-source] Minimum API: Qt 6.11 requires minSdk 28, which is higher than the sibling wrap-POC's minSdk 26. The new app must use minSdk 28 or higher; targetSdk and compileSdk of 36 match Qt's template and the installed SDK.

### Open questions
- Does the whole Logos C++ stack (liblogos, logos-protocol, qt-sdk, plugin-qt, module-loader-qt, logos-module-builder modules, lez_core) compile unchanged against Qt 6.11.1 on Android? The Windows target on the 6.11.1 pin suggests yes, but nothing has been built for Android yet.
- Not tested on a device or emulator: loading libQt6Core_<abi>.so from a plain Kotlin app with only Qt6Android.jar added, then running QCoreApplication::exec on a dedicated Java thread and doing a QtRO local: publish/acquire round trip with TMPDIR=cacheDir. A minimal smoke APK is needed.
- Does anything in liblogos or QtRO reach a JNI-backed Qt Core API (QStandardPaths, QTimeZone, QSysInfo, QNetworkInformation, the SSL certificate store) that would return nothing or crash with a null Android context? This matters especially in a JVM-less child process.
- Should the POC keep liblogos's subprocess container (logos_host_qt as an executable packaged as lib*.so and exec'd from nativeLibraryDir), or run modules in-process for Android? This belongs to the container/loader research area, but it decides whether QtRO crosses process boundaries.
- Is the prebuilt android_x86_64 6.11.1 package (not downloaded) 16 KB-aligned and built with r27c like the arm64 one? Very likely, since Qt's Android builds share one configuration, but I did not measure it.
- Can logos-nix's Android overlay be extended with qtremoteobjects (host repc via -DQt6RemoteObjectsTools_DIR plus the host prefix path) and an x86_64-android pseudo-system, so the POC could later move to a Nix-built Qt? I evaluated this but did not build it.
- Will Qt 6.11's Gradle/AGP 9.0.0 and Kotlin 2.3.0 template work with the installed JDK 25? This only matters if Qt's androiddeployqt/gradle template is used; a hand-written Kotlin app with its own Gradle setup avoids it.

### Recommendations
- Use the official Qt 6.11.1 prebuilts via aqtinstall: android_arm64_v8a and android_x86_64 with '--archives qtbase -m qtremoteobjects', plus the host 'linux desktop 6.11.1 linux_gcc_64' with qtremoteobjects (and the icu archive, if the host tools need it). Install everything under one .work/qt/6.11.1/ prefix so target_qt.conf's HostPrefix=../../gcc_64 resolves.
- Build every C++ component (liblogos, protocol, qt-sdk, plugin-qt, module-loader-qt, capability/state modules, lez_core) against that one Qt. Use CMAKE_TOOLCHAIN_FILE=<qt>/android_<abi>/lib/cmake/Qt6/qt.toolchain.cmake, QT_HOST_PATH=<qt>/gcc_64, ANDROID_NDK_ROOT=/home/fryorcraken/android-ndk/android-ndk-r27c, ANDROID_PLATFORM=android-28 and ANDROID_STL=c++_shared. Build non-Qt dependencies (Boost, spdlog, fmt, OpenSSL 3, nlohmann, Rust wallet_ffi) with the same NDK and with ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON or -Wl,-z,max-page-size=16384.
- Never mix Qt builds: no desktop .lgx or Nix 6.9.2 binaries in the APK. Rebuild the .lgx module plugins per ABI against Android Qt 6.11.1.
- In the Kotlin app: add Qt6Android.jar (and Qt6AndroidNetwork.jar) plus androidx.core, with R8 keep rules for org.qtproject.qt.android.**. Package the ABI-suffixed Qt .so files and libc++_shared.so from NDK r27c in jniLibs/<abi>/. Set minSdk to 28 and targetSdk to 35 or 36.
- Before loading Qt, call Os.setenv for TMPDIR=cacheDir (required for QtRO local: sockets), HOME=filesDir, QT_PLUGIN_PATH=applicationInfo.nativeLibraryDir and the Logos modules dir. Optionally call QtNative.setClassLoader(context.classLoader) through a small helper class in package org.qtproject.qt.android, so Qt's JNI class lookup works on Qt-created threads.
- Start one dedicated Java thread and run everything Qt on it. On that thread, System.loadLibrary("c++_shared"), then explicitly "Qt6Core_<abi>" (so Qt's JNI_OnLoad runs), "Qt6Network_<abi>" and "Qt6RemoteObjects_<abi>", then the JNI bridge library. Then call a native method that constructs QCoreApplication, initialises logos_core_* and blocks in exec(). Marshal calls from Kotlin with QMetaObject::invokeMethod(..., Qt::QueuedConnection) and post results back through Handler(Looper.getMainLooper()).
- Use the QtService/QAndroidService pattern (optionally android:process=":logos") as the documented fallback if the plain embedding runs into Qt-internal assumptions about an Activity or Service.
- Early on, run a smoke test on the delivery-demo (x86_64) and delivery-demo-arm64 AVDs: QtRO RegistryHost plus a replica round trip on local:logos_test_<id> inside one process. Separately, check the 16 KB alignment of every packaged .so with llvm-readelf -l.
- Later, converge on logos-nix master's Android pin, which is the same Qt 6.11.1. Upstream a qtremoteobjects entry (Qt6RemoteObjectsTools_DIR plus host prefix path) and an x86_64-android target to its android overlay, so the APK can eventually be built with Nix.

### Verifier (non-confirmed only)
- [C3] partially-correct: At the rev liblogos actually pins (f55bf91) the second pin is scoped 'WINDOWS TARGET ONLY'. It is not used for iOS or Android there. iOS (b8f10e8) and Android (5378de5) were both added later and exist only on logos-nix master (HEAD 7c1eb8b). 'Built against Qt 6.11.1 on non-Linux targets' is also wrong: macOS stays on 6.9.2. Only the Windows cross set uses 6.11.1 today. The b5aa0fbd -> 6.11.1 and mkWindowsPkgs parts are correct.
- [C4] partially-correct: There are no Logos private-header or Private-target uses, and 0 Qt_6_PRIVATE_API imports in the Logos ELF files. Both are confirmed. But 'the only Qt_6_PRIVATE_API importer is libQt6RemoteObjects' is false. libQt6Network also imports QtCore private API: 51 symbols in Nix 6.9.2 and 47 in the Android 6.11.1 prebuilt. That is normal for any Qt module, so the practical rule holds: every Qt library must come from one Qt build. The Qt_6.9 tag in Logos binaries comes from 'qt_version_tag@Qt_6.9'. That is Qt's mechanism for requiring a runtime at least as new as the compile-time Qt. One caveat: upstream-built Qt (Nix, and the official Android prebuilt) defines the unqualified tag 'Qt_6_PRIVATE_API'. So a mismatched Core/RemoteObjects pair would probably NOT fail at dlopen on Android, and would break private ABI silently. The Electron failure came from a distro Qt (6.10.3 in /usr/lib64). That the distro qualifies its private-API tag with the version is inferred, not verified.

Confirmed: C1, C5, C6, C7, C8, C9, C10, C11, C12, C13, C14, C15, C16

### Verifier missed findings
- Qt already ships a public headless host for a non-Qt Android app. org.qtproject.qt.android.QtServiceBase is 'public class QtServiceBase extends Service' and is in Qt6Android.jar. Its onCreate calls QtServiceLoader.getServiceLoader(this), which sets HOME and TMPDIR and the class loader. It then calls QtNative.setService(this), loader.loadQtLibraries() and QtNative.startApplication(params, mainLibPath) on Qt's thread. A plain Kotlin app can subclass it and host QCoreApplication/QAndroidService there, with no QtActivity and no hand-rolled JNI bootstrap. Pitfalls: onDestroy ends with 'System.exit(0)', so run it in a separate process (android:process). The library list comes from res/values/libs.xml ('qt_libs', 'bundled_libs'), normally generated by androiddeployqt. Evidence: unzip -l jar/Qt6Android.jar -> QtServiceBase.class, QtServiceLoader.class, QtServiceEmbeddedDelegate.class; https://raw.githubusercontent.com/qt/qtbase/v6.11.1/src/android/jar/src/org/qtproject/qt/android/QtServiceBase.java; QtServiceLoader.java 'super(new ContextWrapper(service)); extractContextMetaData(service);'; https://doc.qt.io/qt-6/android-services.html (QtService in a separate process with meta-data android.app.lib_name).
- Logos binaries link OpenSSL 3 directly. The official Qt for Android is built with openssl_runtime (dlopen) and ships no libssl/libcrypto. So the APK must bundle an Android OpenSSL 3 build (arm64-v8a and x86_64, 16 KB-aligned) that liblogos links against and QtNetwork can dlopen. Use one copy for both. Qt's CI used 'prebuilt-openssl-3.5.4-for-android-ndk-r27c_16kb_fixed_symversions'. Evidence: /home/fryorcraken/src/logos-co/logos-protocol/cpp/CMakeLists.txt:31 find_package(OpenSSL REQUIRED), :142-143 OpenSSL::SSL/Crypto PUBLIC; /home/fryorcraken/src/logos-co/logos-liblogos/CMakeLists.txt:19; verify-qt-android-elf.sh shows [libssl.so.3] [libcrypto.so.3] NEEDED by liblogos_core, liblogos_protocol, logos_host_qt and every module plugin incl. lez_core_plugin; .work/probe/qt/6.11.1/android_arm64_v8a/config_qtbase.summary:49-52 'OpenSSL yes / Qt directly linked to OpenSSL no / OpenSSL 3.0 yes'; config_qtbase.opt:14 OPENSSL_ROOT_DIR=/Users/qt/prebuilt-openssl-3.5.4-for-android-ndk-r27c_16kb_fixed_symversions; logos-nix README.md:196-199 'Nothing bundles it yet'.
- ANDROID_STL=c++_shared is mandatory for anything that uses Qt, and all C++ in the process must share one NDK libc++_shared. The Linux lez_core module's libwallet_ffi.so has DT_NEEDED libstdc++.so.6 and libpcsclite.so.1. So the Rust wallet_ffi Android build must link c++_shared (not c++_static or libstdc++) and must drop or replace the pcsclite smart-card dependency, which Android does not provide. Evidence: .work/probe/qt/6.11.1/android_arm64_v8a/lib/cmake/Qt6/QtPlatformAndroid.cmake:36-37 'if(NOT ANDROID_STL STREQUAL c++_shared) message(FATAL_ERROR "The Qt libraries on Android only supports the shared library configuration of stl...'; verify-qt-android-elf.sh: libwallet_ffi.so NEEDED [libpcsclite.so.1] [libstdc++.so.6]; Android Qt libs NEEDED [libc++_shared.so].
- The QtRO wire protocol is itself Qt-version-sensitive, beyond ELF symbol versions. An Android app on Qt 6.11.1 must not expect to talk QtRO to a desktop logoscore/logosctl on Nix Qt 6.9.2, for example over a tcp:// registry. Keep every QtRO peer on the same Qt. Evidence: /home/fryorcraken/src/logos-co/logos-cpp-sdk/flake.nix:6-8 'Follows our logos-nix so both repos resolve the identical nixpkgs/Qt pin — the QRO wire is Qt-version-sensitive.'; /home/fryorcraken/src/logos-co/logos-nix/flake.nix:32-36 'there is no cross-platform QtRO link today'.
- The official Qt 6.11.1 Android prebuilt was built on a macOS host. aqt rewrites bin/target_qt.conf to HostPrefix=../../gcc_64 on install, but the CMake package files do not use target_qt.conf. A CMake cross build must pass QT_HOST_PATH, and QT_HOST_PATH_CMAKE_DIR if needed, pointing at a 6.11.1-or-newer desktop Qt that includes qtremoteobjects (for Qt6RemoteObjectsTools). A Nix 6.11.1 host (nixpkgs b5aa0fbd, cached for logos-nix's Windows set) also works, but needs Qt6RemoteObjectsTools_DIR, because Nix splits qtremoteobjects into its own prefix. Evidence: .work/probe/qt/aqtinstall.log:20,31 ('...qtbase-MacOS-MacOS_14-Clang-Android...7z', 'Patching .../bin/target_qt.conf'); bin/target_qt.conf:26 'HostSpec=macx-clang'; config_qtbase.opt:16 '-DQT_HOST_PATH=/Users/qt/work/install'; lib/cmake/Qt6/QtPublicDependencyHelpers.cmake:274-290; logos-nix/nix/windows/cross-overlay.nix:361-368.
- Loading .lgx modules at runtime is constrained by Android W^X rules. For targetSdk >= 29, an app cannot exec() files in its data directory: execute_no_trans on app_data_file is granted only to the untrusted_app_27 domain, i.e. targetSdk 26-28. dlopen (mmap-exec) of a .so there is still allowed. So plugin .so files extracted from an .lgx into filesDir can be dlopen'ed through QPluginLoader. But liblogos's default subprocess container, which spawns logos_host_qt, cannot exec a helper from filesDir. The helper must ship in the APK's nativeLibraryDir as lib*.so (extractNativeLibs), or modules must be loaded in-process. Evidence: https://android.googlesource.com/platform/system/sepolicy/+/refs/heads/main/private/untrusted_app_27.te 'This file defines the rules for untrusted apps running with 25 < targetSdkVersion <= 28' ... 'allow untrusted_app_27 app_data_file:file execute_no_trans;'; https://android.googlesource.com/platform/system/sepolicy/+/refs/heads/main/private/untrusted_app_all.te 'allow untrusted_app_all app_data_file:file { r_file_perms execute };'; /home/fryorcraken/src/logos-co/logos-liblogos/flake.nix:27,32 default-container = logos-container-subprocess, default-module-loader = logos-module-loader-qt (bin/logos_host_qt); /home/fryorcraken/src/logos-co/logos-module/src/logos_module.cpp:95 'new QPluginLoader(pluginPath)'.
- Module builds run host-side code generators that link Qt Core: logos-cpp-generator and logos-qt-generator. In a cross build they must run on the build machine; they are built by a separate compile.sh when LOGOS_CPP_SDK_IS_SOURCE. Otherwise pre-generated sources are used (the Nix preConfigure path). For Android, reuse the generator output from the Linux/Nix build, or build the generators against the host Qt. Evidence: /home/fryorcraken/src/logos-co/logos-module-builder/cmake/LogosModule.cmake:398-429 (cpp_generator_build via 'bash ${LOGOS_CPP_SDK_ROOT}/cpp-generator/compile.sh', run_cpp_generator_<module>), :430-436 'For nix builds, logos_sdk.cpp is already generated', :454-469 generated_code dir; /home/fryorcraken/src/logos-co/logos-cpp-sdk/cpp-generator/CMakeLists.txt:12-13 and /home/fryorcraken/src/logos-co/logos-qt-sdk/qt-generator/CMakeLists.txt:7-8 find_package(Qt... COMPONENTS Core).
- Android Qt libraries carry the ABI in their names (libQt6Core_arm64-v8a.so and so on), and Qt6Core's android-dependencies.xml makes androiddeployqt bundle the qtforandroid platform plugin, which needs Gui. A Core-only plain Kotlin app that skips androiddeployqt can leave Gui out. A QtLoader/QtServiceBase-based path reads the libs.xml that androiddeployqt generates. QtNetwork's system-proxy support (enabled: 'Use system proxies ... yes') uses Qt6AndroidNetwork.jar classes over JNI. Bundle that jar too if any tcp:// transport is used. Evidence: lib/Qt6Core_arm64-v8a-android-dependencies.xml '<lib file="plugins/platforms/libplugins_platforms_qtforandroid_arm64-v8a.so" />'; lib/Qt6Network_arm64-v8a-android-dependencies.xml 'jar/Qt6AndroidNetwork.jar'; unzip -l jar/Qt6AndroidNetwork.jar -> org/qtproject/qt/android/network/QtNetwork.class; config_qtbase.summary:92.
- The LEZ module's own lock agrees with liblogos on Qt. Its logos-module-builder chain pins logos-nix e637a1f/0e9e6d6, which resolve to nixpkgs e9f00bd (Qt 6.9.2). The extra root nixpkgs ac62194c (Qt 6.9.3) comes from the logos-execution-zone Rust input, not the Qt build. So the prebuilt lez_core .lgx is a Linux/Qt 6.9.2 artifact and has to be rebuilt from source for Android. Evidence: bash .work/scripts/verify-qt-android-lockrevs.sh on /home/fryorcraken/src/logos-blockchain/logos-execution-zone-module/flake.lock -> 'NixOS/nixpkgs ac62194c... x2', 'NixOS/nixpkgs e9f00bd... x443'; nix eval --raw github:NixOS/nixpkgs/ac62194c3917d5f474c1a844b6fd6da2db95077d#qt6.qtbase.version -> 6.9.3; verify-qt-android-elf.sh lez_core_plugin.so 'qt_version_tag@Qt_6.9', x86_64 glibc NEEDED.

---

## Full report

## Qt for Android for the liblogos stack: version, availability, embedding

Task key: `qt-android`. All `.work/...` paths are under `/home/fryorcraken/src/fryorcraken/logoslib-android-poc/`. The probe scripts are in `.work/scripts/qt-android-*.sh`. The downloaded Qt is in `.work/probe/qt/6.11.1/android_arm64_v8a` (96 MB).

### 1. Which Qt the current liblogos stack uses

**Pin chain (checked in the lock file).** `logos-liblogos/flake.nix:5-6` declares `logos-nix.url = "github:logos-co/logos-nix"; nixpkgs.follows = "logos-nix/nixpkgs";`. I resolved `flake.lock` with `.work/scripts/qt-android-lock.sh`:
- root `logos-nix` is `logos-co/logos-nix` rev `f55bf91b8a723ee5c27c39c773b034255538d280` (2026-08-14).
- root `nixpkgs` is **`NixOS/nixpkgs` rev `e9f00bd893984bc8ce46c895c3bf7cac95331127`**. This is the stock upstream repo, not a logos-co fork.
- Only two nixpkgs revisions appear anywhere in the lock: e9f00bd (124 nodes) and b5aa0fbd (113 nodes, `nixpkgs-windows`).

`nix eval --raw github:NixOS/nixpkgs/e9f00bd...#qt6.qtbase.version` returns **6.9.2**. The `/nix/store` paths `qtremoteobjects-6.9.2` and `qtbase-6.9.2` confirm it.

**Is it patched?** Only with nixpkgs' own packaging patches. qtbase has 9: `derive-plugin-load-path-from-PATH`, `allow-translations-outside-prefix`, the qmake fixes, `no-sbom`, `use-cmake-from-path`, and the qmlimportscanner fixes. qtremoteobjects has `[]`. logos-nix's native overlays only fix the cargo and crate fetchers (`logos-nix/flake.nix:204-209`). There is no Logos Qt fork.

**A second Logos Qt: 6.11.1.** logos-nix carries a second pin, `nixpkgs-windows = b5aa0fbd…`, which evaluates to **Qt 6.11.1**. The comment at `logos-nix/flake.nix:32` says: "Windows ships Qt 6.11.1 while Linux/macOS stay on 6.9.2".
- liblogos already builds an `x86_64-windows` package set on that pin (`logos-liblogos/flake.nix:77-83`).
- logos-nix **master** (local checkout at 7c1eb8b; commit 5378de5, 2026-09-07, "feat(android): Qt 6.11.1 for aarch64-android from source, APK packaging") uses the same pin for iOS and Android.
- liblogos's pinned logos-nix (f55bf91) predates that Android work.

**Private-API / exact-version constraint.** The Electron POC failed with `version 'Qt_6_PRIVATE_API' not found (required by .../libQt6RemoteObjects.so.6)` (`liblogos-electron-poc/README.md:383-384`). I measured where those private imports come from (`.work/scripts/qt-android-privsyms.sh`):
- `libQt6RemoteObjects.so.6` (6.9.2) imports **27** `Qt_6_PRIVATE_API` symbols from QtCore, such as `QMetaObjectBuilder::*` and `QObjectPrivate::QObjectPrivate(int)`.
- The Android 6.11.1 `libQt6RemoteObjects_arm64-v8a.so` has the same 27.
- **Every Logos ELF file imports 0 of them**: `liblogos_core.so`, `liblogos_protocol.so`, `liblogos_qt_host.so`, `logos_host_qt`, `capability_module_plugin.so`, `modules_state_plugin.so`. They need only the `Qt_6` and `Qt_6.9` version tags (`qt-android-misc.sh`).
- Grepping the stack's sources for `private/`, `_p.h` and `*Private` finds only comments, e.g. `logos-protocol/cpp/implementations/qt_remote/remote_transport.cpp:421` naming `QRemoteObjectNodePrivate::onClientRead` in a crash analysis.

So the constraint is Qt-internal: **QtRemoteObjects must come from the same Qt build as QtCore**, and the runtime Qt must be at least as new as the compile-time Qt (the `Qt_6.9` tag).

A second, looser coupling: "the QRO wire is Qt-version-sensitive" (`logos-cpp-sdk/flake.nix:7-8`). Inside one APK every process uses the same Qt, so this does not bite.

A third coupling applies to cross builds. The target config files require host tools of at least the same version: `Qt6CoreDependencies.cmake:41` has `"Qt6CoreTools\;6.11.1"` and `Qt6RemoteObjectsDependencies.cmake:40` has `"Qt6RemoteObjectsTools\;6.11.1"`, checked in `Qt6ConfigVersionImpl.cmake:22-23` (`VERSION_LESS` → incompatible).

**Verdict:** when we build liblogos, the modules and LEZ ourselves for Android, the constraint becomes "use ONE Qt consistently": one target Qt (Core, Network and RemoteObjects from the same release) plus a host Qt of the same version for moc and repc. No desktop `.lgx` or Nix 6.9.2 artifact may go into the APK.

### 2. Qt modules the stack and LEZ need

| Component | Qt components | Evidence |
|---|---|---|
| liblogos (logos_core) | Core, Network, RemoteObjects | `logos-liblogos/CMakeLists.txt:12-13`; `src/CMakeLists.txt:333-334` |
| logos-module-loader-qt (logos_host_qt) | Core, Network, RemoteObjects | `logos-module-loader-qt/CMakeLists.txt:10`; `src/CMakeLists.txt:90-92` |
| logos-protocol (static and shared) | Core, RemoteObjects (+ Boost.Asio, OpenSSL, nlohmann) | `logos-protocol/cpp/CMakeLists.txt:12,31,137-146` |
| logos-qt-sdk, logos-plugin-qt | Core, RemoteObjects | `logos-qt-sdk/cpp/CMakeLists.txt:9`; `logos-plugin-qt/cpp/CMakeLists.txt:9` |
| logos-module | Core | `logos-module/CMakeLists.txt:9` |
| Modules via logos-module-builder (capability, modules_state, lez_core, rln) | Core, RemoteObjects; **Qml only for a `.rep` replica factory** | `logos-module-builder/cmake/LogosModule.cmake:247-254, 612-613, 959` |
| LEZ `lez_core` | via builder (Core, RemoteObjects) + `EXTERNAL_LIBS wallet_ffi` | `logos-execution-zone-module/CMakeLists.txt:14-21`; `metadata.json` (`"interface": "universal"`) |
| logos-container, container-subprocess, module-loader, package-manager, process-stats | **no Qt** (nlohmann, Boost.process, spdlog) | CMake greps |

The needed set is **qtbase (Core, Network) + qtremoteobjects**. The generators (logos-cpp-generator, qt-host-generator, qt-generator) are host tools that use Qt Core. They emit source code, so they can come from any host Qt, including Nix. The `moc`/`repc` used in the build must match the target Qt version.

Non-Qt runtime dependencies of `liblogos_core.so` also need Android builds: Boost (process, context, filesystem, date_time, atomic, system), spdlog, fmt, OpenSSL 3 (libssl, libcrypto), nlohmann_json. That is outside Qt, but it matters for 16 KB alignment (below).

### 3. Official Qt for Android binaries

I installed aqtinstall 3.3.0 in `.work/probe/qt-venv` (`qt-android-aqt-list.sh`):
- `aqt list-qt all_os android` lists 6.7.0 through **6.9.2**, 6.9.3, 6.10.x, 6.11.0, **6.11.1**, 6.11.2, 6.11.3 and 6.12.0. From Qt 6.7 onward the Android host is `all_os`.
- For both 6.9.2 and 6.11.1, `--arch` lists `android_arm64_v8a android_x86_64 android_armv7 android_x86`, and `--modules` for arm64_v8a and x86_64 includes **qtremoteobjects**.
- The host `linux desktop 6.11.1 linux_gcc_64` is available with a `qtremoteobjects` module. Its base archives are `icu qtbase qtdeclarative qtdoc qtsvg qttools qttranslations qtwayland` (`qt-android-aqt-host.sh`).

I downloaded **6.11.1 android_arm64_v8a**, `--archives qtbase -m qtremoteobjects` (`qt-android-aqt-install.sh`; 96 MB installed). Inspection (`qt-android-inspect.sh`):
- **NDK:** `.note.android.ident` decodes to `r27c` / `12479018`, and `config_qtbase.opt` has `-android-ndk /opt/android/android-ndk-r27c`. That is exactly the installed `~/android-ndk/android-ndk-r27c` (`source.properties: Pkg.Revision = 27.2.12479018`). The Qt 6.11 docs agree: "Qt 6.11 uses NDK 27.2.12479018", "JDK 21 or above", `platforms;android-36`, `build-tools;36.0.0`. All of these are installed (JDK 25.0.4).
- **Min API:** `lib/cmake/Qt6/qt.toolchain.cmake:44` has `set(ANDROID_PLATFORM "android-28" ...)`, and the docs say "Android 9 (API 28) to 16 (API 36)". The sibling wrap-POC uses minSdk 26 (`logos-android-wrap-poc/android/gradle/libs.versions.toml:5`), so the new app must use minSdk ≥ 28.
- **16 KB pages:** all 24 `.so` files (`libQt6Core/Network/RemoteObjects/...` and the plugins) have LOAD `p_align = 0x4000`. `config_qtbase.summary:56` says "Using 16KB page sizes in Android ... yes". `QtPlatformTargetHelpers.cmake:34-35` adds `-Wl,-z,max-page-size=16384` to the `Qt6::Platform` INTERFACE (also in `Qt6Targets.cmake:65`), so **every Logos target linking Qt6::Core inherits 16 KB alignment**. Non-Qt libraries need `ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON` (NDK r27c `build/cmake/flags.cmake:35-38`) or an explicit `-Wl,-z,max-page-size=16384`. That includes rustc (`-C link-arg=...`).
- **6.9.2 is not 16 KB-ready.** The Qt blog "Android 15 and 16 support" (2025-09-26) says "16KB pages support will be available with 6.9.3", and Qt 6.10 "Supports 16KB pages out-of-the-box". Google Play requires 16 KB for apps targeting Android 15+.
- **Layout:** sonames carry the ABI (`libQt6Core_arm64-v8a.so`). DT_NEEDED is limited to NDK libraries (`libm libdl libz liblog libc`) plus `libc++_shared.so`. RemoteObjects needs Network and Core. OpenSSL is used at runtime only ("Qt directly linked to OpenSSL ... no", OpenSSL 3.0 yes). `QT_FEATURE_localserver 1`; GLib off.
- **Host:** `bin/target_qt.conf` has `HostPrefix=../../gcc_64`, and aqt warns "requires that the desktop version of Qt is also installed ... `aqt install-qt linux desktop 6.11.1 linux_gcc_64`". `androiddeployqt` is not part of the target build ("Android deployment tool ... no"). The archives are built by the Qt Company on a macOS host (`qtbase-MacOS-MacOS_14-Clang-Android-...7z`); this is harmless.
- **Java side:** `jar/Qt6Android.jar` (172 KB), `Qt6AndroidNetwork.jar` and `Qt6AndroidNetworkInformationBackend.jar`. Qt's Gradle template depends on `androidx.core:core:1.17.0` and pins AGP 9.0.0 and Kotlin 2.3.0.

### 4. The Nix route

- **Upstream nixpkgs:** `nix eval github:NixOS/nixpkgs/b5aa0fbd…#pkgsCross.aarch64-android-prebuilt.qt6.qtbase.drvPath` refuses to evaluate: "android-sdk-ndk-27.0.12077973 ... unfree license". The logos-nix overlay (`nix/android/cross-overlay.nix:116-131, 255-318`) documents why the stock recipe is wrong for Android:
  - desktop-Linux inputs such as systemd, wayland and cups;
  - system third-party libraries that become unresolvable DT_NEEDED sonames (`UnsatisfiedLinkError: ... libb2.so`);
  - openssl KTLS and pcre2 JIT, which do not work on bionic;
  - a patch that must be dropped.
- **logos-nix master** (`flake.nix:104-192`, `README.md:109-224`) makes it work, with limits:
  - Qt 6.11.1 from source for **arm64-v8a only**, NDK **27.0.12077973** (r27, not r27c), API 28, compileSdk 36.
  - `mkQtAndroidApk`, which is centred on `qt_add_executable` and androiddeployqt.
  - A measured build of 5m28s, with a 4.6 GiB closure.
  - Its asserted module set is qtbase, qtdeclarative, qtshadertools and qtsvg (`flake.nix:625`). `pkgsAndroid.qt6.qtremoteobjects` evaluates (`qtremoteobjects-aarch64-unknown-linux-android-6.11.1`), but its cmakeFlags have **no `Qt6RemoteObjectsTools_DIR` and no host prefix**. The Windows overlay says those are required for RemoteObjects (`nix/windows/cross-overlay.nix:56-83, 361-368`). `logosQtCrossCmakeFlags`' host prefix list for Android also omits qtremoteobjects (`cross-overlay.nix:360-369`).
  - There is no x86_64 ABI, which the emulator needs.
- **Building Qt from source by hand with the NDK** is only worth doing if Qt itself has to be patched.

**Verdict:** for the POC, use the **official prebuilt Qt 6.11.1**. It needs no Qt build, matches the installed NDK, SDK and JDK, supports 16 KB pages and both ABIs, and includes RemoteObjects. It is also the same Qt version logos-nix already uses for Windows, iOS and Android, so switching later to a Nix-built Qt (after adding qtremoteobjects and x86_64 to logos-nix's android overlay) changes no version. 6.9.2 would match the Linux desktop pin, but that buys nothing: desktop `.lgx` binaries are glibc/x86_64 and cannot run on Android anyway, and 6.9.2 lacks 16 KB support.

### 5. Embedding Qt Core in a plain Kotlin app (no QtActivity)

**What Qt Core does at load time.** `libQt6Core_<abi>.so` exports `JNI_OnLoad@@Qt_6`. The only other exporter is the `qtforandroid` QPA plugin, which we do not need. In qtbase v6.11.1 `src/corelib/kernel/qjnihelpers.cpp`, `JNI_OnLoad` → `QtAndroidPrivate::initJNI` does the following, and each step returns `JNI_ERR` on failure (so `System.loadLibrary` throws):
1. `env->FindClass("org/qtproject/qt/android/QtNative")`.
2. Calls the static methods `QtNative.activity()`, `service()` and `classLoader()`, and keeps global refs to the results.
3. Registers `updateNativeActivity` on QtNative, natives on `QtInputDelegate`, and the permission, native-interface and extras natives.

`QtAndroidPrivate::context()` returns the activity, else the service, else `nullptr`. So:
- **Qt6Android.jar is required in the app dex.** javap confirms that QtNative, QtInputDelegate, QtLoader, QtServiceBase, QtEmbeddedLoader and extras/QtAndroidBinder are all in it. Add R8 keep rules for `org.qtproject.qt.android.**`.
- Without QtActivity or QtService, `QNativeInterface::QAndroidApplication::context()` is null. APIs that need a context, such as QStandardPaths on Android, degrade, so pass paths from Kotlin instead. `QtNative.setActivity/setService/setClassLoader` are package-private statics (javap). A helper class in package `org.qtproject.qt.android` can call them before `System.loadLibrary`, which gives Qt a context and a class loader.
- `QtAndroidPrivate::findClass` tries `env->FindClass` first, then the stored class loader, and returns null if that is null (`qjniobject.cpp`). On threads attached natively (by Qt), app classes then cannot be found unless `setClassLoader` was called.

**What QtLoader normally does (which we must reproduce).** QtLoader.java v6.11.1 calls `Os.setenv` for `HOME=getFilesDir()`, `TMPDIR=getCacheDir()`, the font variables and `QT_PLUGIN_PATH`. It installs a class loader through `QtNative.setClassLoader`. It loads all libraries **on the Qt thread** (`QtNative.getQtThread().run(...)`). The docs ("How Qt for Android works") say the QtThread "qtMainLoopThread" does "Qt library loading... Starting the native application... The execution of main()", while UI work runs on the Android UI thread.

**Threading rules.** The first thread that adopts Qt thread data becomes Qt's main thread (`qthread.cpp` QAdoptedThread: "we are the main thread"). QCoreApplication warns "was not created in the main() thread" otherwise. A QCoreApplication without the QPA plugin uses the thread's own UNIX event dispatcher (`createEventDispatcher` → `QThreadData::createEventDispatcher`; GLib off), which is independent of the Android main Looper.

**Recipe (manual embedding):**
1. Gradle: `jniLibs/<abi>/` holds `libc++_shared.so` (from NDK r27c `sysroot/usr/lib/<triple>/`), `libQt6Core_<abi>.so`, `libQt6Network_<abi>.so`, `libQt6RemoteObjects_<abi>.so`, the Logos `.so` files and the JNI bridge. Add `Qt6Android.jar` (+ `Qt6AndroidNetwork.jar`) and `androidx.core:core`. Set minSdk 28 and target/compile SDK 35-36.
2. Early (Application.onCreate): `Os.setenv("TMPDIR", cacheDir.absolutePath, true)`, `HOME=filesDir`, `QT_PLUGIN_PATH=applicationInfo.nativeLibraryDir`, and the Logos environment variables. Optionally call `QtNative.setClassLoader(classLoader)` through the helper.
3. Start one Java `Thread("logos-qt")`. On it:
   - Call `System.loadLibrary` for `c++_shared`, then **explicitly** `Qt6Core_<abi>` so Qt's JNI_OnLoad runs. The JVM only calls JNI_OnLoad for the library it was asked to load; if the bridge library had no JNI_OnLoad, `dlsym` might even find Qt's through its dependencies. Then load `Qt6Network_<abi>`, `Qt6RemoteObjects_<abi>` and the bridge.
   - Call a native `run()` that constructs `QCoreApplication(argc, argv)`, initialises `logos_core_*`, and blocks in `exec()`.
4. Kotlin never touches QObjects directly. Calls go through a thread-safe queue or `QMetaObject::invokeMethod(obj, ..., Qt::QueuedConnection)`. Results come back through a JNI callback on the Qt thread → `Handler(Looper.getMainLooper())`. `QAndroidApplication::runOnAndroidMainThread` exists, but it depends on QtNative's Java runnables.
5. Do not create any QObject or QThread on the UI thread before step 3. Loading the libraries on the Qt thread also keeps static initialisers off the UI thread.
6. Shutdown: queue `QCoreApplication::quit()`, then join the thread. Never unload the libraries.

**Documented fallback:** the Qt Android Service pattern (`doc.qt.io/qt-6/android-services.html`). Declare `<service android:name=".LogosService" android:process=":logos">` extending `QtService`/`QtServiceBase`, with `<meta-data android:name="android.app.lib_name" .../>`. The native `main()` runs `QAndroidService app(argc, argv); return app.exec();`. Limitation: one service per process. Qt Quick for Android (QtQuickView, Qt Gradle plugin) is for embedding QML UI and is not needed here.

### 6. QtRemoteObjects on Android

- **How Logos addresses QtRO.** `logos-protocol/cpp/logos_instance.h:28` builds `local:logos_<module>_<instanceId>`. A relative name "lands under QDir::tempPath()" (`qt_socket_path.h:13-21`). `QFileSystemEngine::tempPath()` returns `TMPDIR`, or else `_PATH_TMP`, which falls back to `"/tmp"` because bionic's paths.h does not define it (grep of the NDK r27c sysroot finds none). `/tmp` does not exist for apps, so **without TMPDIR, `RemoteTransportHost::publishObject` fails** (`remote_transport.cpp:669-676` logs "failed to listen on"). With `TMPDIR=cacheDir`, the path is about 80 bytes (`/data/user/0/<pkg>/cache/logos_<mod>_<12hex>`), under the 108-byte `sun_path` limit; keep the package name short.
- **SELinux.** `untrusted_app_all.te` has `allow untrusted_app_all app_data_file:{ lnk_file sock_file fifo_file } create_file_perms;`, and `domain.te` has `allow domain self:unix_stream_socket { create_stream_socket_perms connectto };`. So local sockets in the app's own data directory work **within one process and between processes of the same app** (same uid, domain and categories). Other apps are separated by MLS categories, which the POC does not need.
- **Abstract namespace.** QtRO registers `localabstract` under `Q_OS_LINUX` (`qconnectionfactories.cpp`), and Android defines Q_OS_LINUX (`qsystemdetection.h:84-86`). The string is present in the Android `libQt6RemoteObjects`. logos-protocol hardcodes `local:`, so there is no reason to switch.
- **Across processes.** If liblogos keeps `logos-container-subprocess` (it spawns `logos_host_qt`), two things matter:
  - On targetSdk ≥ 29 an app cannot `execve` from its data directory; only `untrusted_app_27` has `app_data_file:file execute_no_trans`. `untrusted_app_all` still allows `execute`, so dlopen of module `.so` files from files/ works. The host binary must therefore be packaged as `lib*.so` in nativeLibraryDir, with extraction on (`useLegacyPackaging=true`). The sibling POC uses `extractNativeLibs="false"`.
  - The child process has no JavaVM, and `QJniEnvironment::getJniEnv()` calls `vm->GetEnv` without a null check. Any JNI-backed Qt Core API in the child would crash. QLocalSocket and QtRO themselves are POSIX-only. The child inherits TMPDIR from the parent's `Os.setenv`.

### 7. Licensing

Qt Core, Network and RemoteObjects are available under LGPLv3 (also GPL or commercial). Shipping them as dynamically linked `.so` files inside the APK is dynamic linking. The obligations are:
- include the licence texts;
- provide the Qt source, including any modifications, or a written offer;
- allow the user to relink.

For an open-source app with unmodified official binaries this is trivial. The Qt Java binding templates are `LicenseRef-Qt-Commercial OR BSD-3-Clause` (`src/android/java/.../bindings/QtService.java:3`). Sources: qt.io "Obligations of the GPL and LGPL"; qtcentre thread on bundled APK libraries.

### 8. Concrete recipe

**Qt for Android 6.11.1 (official binaries), arm64-v8a + x86_64, with RemoteObjects; host linux_gcc_64 6.11.1 with RemoteObjects; NDK r27c 27.2.12479018; SDK platform 36 / build-tools 36.0.0; JDK 21+; minSdk 28.**

Put these in `.work/scripts` scripts:
```
aqt install-qt linux desktop 6.11.1 linux_gcc_64 --archives qtbase icu -m qtremoteobjects --outputdir .work/qt
aqt install-qt all_os android 6.11.1 android_arm64_v8a --archives qtbase -m qtremoteobjects --outputdir .work/qt
aqt install-qt all_os android 6.11.1 android_x86_64   --archives qtbase -m qtremoteobjects --outputdir .work/qt
```

Configure every Logos C++ project with:
```
cmake -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=.work/qt/6.11.1/android_<abi>/lib/cmake/Qt6/qt.toolchain.cmake \
  -DQT_HOST_PATH=.work/qt/6.11.1/gcc_64 \
  -DANDROID_NDK_ROOT=/home/fryorcraken/android-ndk/android-ndk-r27c \
  -DANDROID_SDK_ROOT=/home/fryorcraken/android-sdk \
  -DANDROID_ABI=<arm64-v8a|x86_64> -DANDROID_PLATFORM=android-28 -DANDROID_STL=c++_shared
```
The qt.toolchain.cmake chains the NDK toolchain. Non-Qt dependencies get `-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON`. Verify with `llvm-readelf -lW` that every LOAD has `0x4000`. Then embed as described in section 5, with TMPDIR set before the first Logos or Qt call.

