# Experiment: qt-jvmless

> Gating experiment, 2026-09-25. Machine-written by the experiment agent; logs and scripts in
> [../../experiments/qt-jvmless](../../experiments/qt-jvmless); patches in [../../patches](../../patches).
> `.work/` paths refer to local scratch that is not committed.


### Summary
The liblogos subprocess model works on Android, but only with a small fix. Without it, stock Qt 6.11.1 crashes in a process that has no Java VM: the QCoreApplication constructor itself segfaults on a null VM pointer (QCoreApplicationPrivate::init -> appVersion() and, if that call is skipped, QLoggingRegistry::initializeRules -> QStandardPaths). The fix is ~60 lines of code and needs no Qt rebuild: before constructing QCoreApplication, call QtCore's own exported JNI_OnLoad with a fake JavaVM whose functions all return NULL. QtCore stores the VM pointer before it fails, so later JNI paths just return empty values instead of crashing. With the fix, QCoreApplication, QPluginLoader, QtRemoteObjects over both local: and localabstract: sockets, and SIGTERM shutdown all worked on the x86_64 API 34 emulator. They also worked from a real app (Part 2): the helper was exec'd from nativeLibraryDir with both ProcessBuilder and native posix_spawn, it ran in the app's own untrusted_app domain, and the parent<->child socket in cacheDir needed no SELinux change. Qt6Android.jar is not required. Without it, the app's own QCoreApplication crashes in the same way, but calling QtCore's JNI_OnLoad with the app's real VM (ignoring its JNI_ERR) makes it work. The helper process always needs the fake-VM fix. The emulator was shut down at the end.

### Results
- [pass|verified-by-experiment] X1.1 Install Qt 6.11.1 android_x86_64 (qtbase + qtremoteobjects) and host linux_gcc_64 6.11.1 with qtremoteobjects using aqt
  aqt 3.3.0 (existing venv). Commands, run from .work/probe/qt: `.work/probe/qt-venv/bin/aqt install-qt all_os android 6.11.1 android_x86_64 --archives qtbase -m qtremoteobjects --outputdir .work/probe/qt` and `.work/probe/qt-venv/bin/aqt install-qt linux desktop 6.11.1 linux_gcc_64 --archives qtbase icu -m qtremoteobjects --outputdir .work/probe/qt`. Result: 6.11.1/android_x86_64 (96M; x86_64 archive is qtbase-Linux-RHEL_9_6-Clang-Android-Android_ANY-X86_64.7z) and 6.11.1/gcc_64 (176M, includes libexec/moc and repc). target_qt.conf has HostPrefix=../../gcc_64.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/qt-jvmless-aqt.sh; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/aqt.log
- [pass|verified-by-experiment] X1.2 Build qro_server/qro_client as PIE executables and a trivial plugin with NDK r27c + Qt toolchain (x86_64, android-34, c++_shared)
  Configured with cmake -G 'Unix Makefiles' (no ninja on host), CMAKE_TOOLCHAIN_FILE=<qt>/android_x86_64/lib/cmake/Qt6/qt.toolchain.cmake, QT_HOST_PATH=<qt>/gcc_64, ANDROID_NDK_ROOT=r27c, ANDROID_ABI=x86_64, ANDROID_PLATFORM=android-34, ANDROID_STL=c++_shared. Uses plain add_executable, because qt_add_executable makes a .so on Android. `file` reports 'ELF 64-bit LSB pie executable, interpreter /system/bin/linker64'. Every LOAD segment is aligned to 0x4000. NEEDED: libQt6RemoteObjects_x86_64.so, libQt6Network_x86_64.so, libQt6Core_x86_64.so, libc++_shared.so, liblog, libdl, libm, libc. Among the Qt libs, only libQt6Core exports JNI_OnLoad@@Qt_6. The plugin is a MODULE with Q_PLUGIN_METADATA(IID 'org.logos.test.EchoInterface/1.0' FILE echo_plugin.json).
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/qt-jvmless-build.sh; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/build.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/src/CMakeLists.txt; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/build/x86_64
- [fail|verified-by-experiment] X1.3a Does stock Qt 6.11.1 QCoreApplication run in a native executable with no JavaVM?
  SIGSEGV (null pointer dereference at 0x0), exit status 139, in the QCoreApplication constructor. Symbolized stack: QJniEnvironment::getJniEnv()+0x2e <- QJniObject internals <- QCoreApplicationPrivate::appVersion() <- QCoreApplicationPrivate::init() <- QCoreApplication::QCoreApplication. Source: qcoreapplication.cpp:202 builds QJniObject(QAndroidApplication::context()), and qjnienvironment.cpp:69-70 calls vm->GetEnv on QtAndroidPrivate::javaVM(), which is null. Calling QCoreApplication::setApplicationVersion() first skips appVersion (lines 819-820) but still crashes one step later: QCoreApplicationPrivate::init()+0xd4 -> QLoggingRegistry::instance() -> initializeRules (qcoreapplication.cpp:827, unconditional on Android) -> QStandardPaths::locateAll(GenericConfigLocation) -> standardLocations -> writableLocation -> getFilesDir -> QJniObject -> getJniEnv. The earlier research assumed only JNI-backed APIs would crash. In fact QCoreApplication itself cannot be constructed, so logos_host_qt as shipped cannot start on Android.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/x1-run.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/x1-crash.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/symbolize.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/qtsrc/qtbase/src/corelib/kernel/qcoreapplication.cpp:202,819-827; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/qtsrc/qtbase/src/corelib/kernel/qjnienvironment.cpp:65-83; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/qtsrc/qtbase/src/corelib/io/qloggingregistry.cpp:336-384; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/qtsrc/qtbase/src/corelib/io/qstandardpaths_android.cpp:157-197
- [pass|verified-by-experiment] X1.3b With a fix (fake JavaVM passed to QtCore's own JNI_OnLoad), do QCoreApplication + QtRO over a local socket + QPluginLoader work without a JVM?
  The fix is in src/nojvm_shim.h. Before QCoreApplication is constructed, it locates QtCore via dladdr(&qVersion), finds its JNI_OnLoad with dlsym, and calls it with a fake JavaVM. In that VM, GetEnv and AttachCurrentThread return a JNIEnv whose function table returns 0/NULL for every call (GetJavaVM is implemented). Qt's initJNI stores g_javaVM = vm as its first statement (qjnihelpers.cpp:281), then fails on FindClass and returns JNI_ERR (-1), which we ignore. After that the following work: QCoreApplication; QPluginLoader (metaData IID read, instance() returns EchoPlugin, qobject_cast<EchoInterface*> succeeds, hello() returns 'hello from echoplugin'); QRemoteObjectRegistryHost::setRegistryUrl + enableRemoting('Echo'); in a separate client process, QRemoteObjectNode::connectToNode + acquireDynamic + waitForSource + QMetaObject::invokeMethod(Q_RETURN_ARG(QRemoteObjectPendingCall)) for Q_INVOKABLE QString echo(QString) and QVariant callRemoteMethod(QString,QString,QVariantList). callRemoteMethod has the same shape as logos ModuleProxy. The sum call returned 42, round trip 0-3 ms, and two client processes were served in a row. SIGTERM goes through a self-pipe to a QSocketNotifier and QCoreApplication::quit, as in logos_host_qt, and exits cleanly. The helper's /proc/self/maps shows 0 libart.so mappings. Transport per context: in the adb shell domain, localabstract:qro_t works; local:qro_t works as root (su), creating a socket file in TMPDIR.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/src/nojvm_shim.h; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/x1-run.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/x1-t2.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/qtsrc/qtbase/src/corelib/kernel/qjnihelpers.cpp:279-365,482-515
- [partial|verified-by-experiment] X1.3c How do JNI-backed Qt Core APIs behave under the fix?
  Each probe ran in its own process, and none crashed. Values under the fix: QStandardPaths Temp, Cache, AppData and Home are all empty. QCoreApplication::applicationVersion() is ''. QAndroidApplication::sdkVersion() is 0 and context is invalid. QLocale::system() is 'C'. QTimeZone::systemTimeZoneId() is empty; systemTimeZone() is valid, but named zones are not ('Europe/Paris' is invalid). QSysInfo::productVersion() is '-1.-1'. QDateTime::currentDateTime(), QTime::currentTime() and QDir::tempPath() (reads TMPDIR) work. applicationFilePath and applicationDirPath come from argv[0], because Android Qt never reads /proc/self/exe (qcoreapplication.cpp:2420-2422), so libraryPaths() = the executable's directory = nativeLibraryDir. The host and modules must not rely on QStandardPaths, named QTimeZone or the system locale in the helper; pass paths on the command line or via env instead.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/x1-run.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/x2-R1-A-default.logcat
- [partial|verified-by-experiment] X1 side findings: TMPDIR and SELinux in the adb shell context
  (1) In the adb `shell` SELinux domain, creating a filesystem socket in /data/local/tmp is denied: `avc: denied { create } ... scontext=u:r:shell:s0 tcontext=u:object_r:shell_data_file:s0 tclass=sock_file`. Qt then reports QLocalServer SocketAccessError and QtRO ListenFailed (lastError 11). This comes from the adb test harness, not the app (see X2). (2) With TMPDIR unset, QDir::tempPath() is /tmp, which does not exist on Android, so QtRO listen fails (ListenFailed, tested as root). TMPDIR must be set. (3) QtRO logs 'It is recommended to use localabstract over local on Android' (qconnection_local_backend.cpp:47,150). It is only a warning; local: works in the app.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/avc.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/x1-run.log
- [pass|verified-by-experiment] X2 Can an app exec a helper executable shipped as lib*.so from nativeLibraryDir?
  Build settings: AGP 9.4.0, Kotlin 2.4.20 and the Gradle 9.7.1 wrapper, as in logos-android-wrap-poc; minSdk 34, targetSdk 36, compileSdk 37, x86_64 only; packaging.jniLibs.useLegacyPackaging=true, which gives extractNativeLibs=true in the manifest. The extracted libqro_server.so has mode 100755 and canExecute=true. ProcessBuilder(nativeLibraryDir/libqro_server.so) with LD_LIBRARY_PATH=nativeLibraryDir and TMPDIR=cacheDir starts it, and so does posix_spawn from JNI with the app's environ, after Os.setenv of TMPDIR and LD_LIBRARY_PATH; the second is the logos-container-subprocess style (runs R8, R9). ps -A shows the child named libqro_server.so, with PPID = app pid, the same uid, and the same label u:r:untrusted_app:s0:c193,c256,c512,c768. Its /proc/self/maps has 0 libart mappings (the app has 4). The only avc denials are 4 per run of `{ search } name="tests" shell_test_data_file` from the child's dynamic linker; they have no functional effect. After am force-stop, no helper was left in any of 9 runs. After the app crashed (R3), the helper was also gone.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/x2-run.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/x2-R1-A-default.logcat; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/x2-R8-A-nativespawn.logcat; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/app/app/build.gradle.kts; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/app/app/src/main/kotlin/org/logos/qrotest/MainActivity.kt
- [pass|verified-by-experiment] X2 Do SELinux rules allow the parent<->child local socket?
  The child creates cacheDir/qro_t as `srwx------ u0_a193 u0_a193_cache u:object_r:app_data_file:s0:c193,c256,c512,c768`, and the app's JNI QtRO client connects and gets 'OK echo:... | sum=42 | 1-3 ms'. localabstract:qro_t also works (R5). No avc denial for sock_file create or unix_stream_socket connectto appeared in any app run (AVC_SUMMARY: other-than-linker-tests-dir-search=0). A stale socket file left from a previous run did not block startup: QtRO removes it and retries listen (qconnection_local_backend.cpp:153-157). The client connected within about 260 ms (R8, R9).
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/x2-run.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/x2-R5-A-abstract.logcat
- [pass|verified-by-experiment] X2 Is Qt6Android.jar required (variant A vs B)?
  The jar is not required, but the in-app QtCore must be given the process's JavaVM one way or another. R1, variant A (jar in dex, System.loadLibrary('Qt6Core_x86_64') first): Qt's JNI_OnLoad succeeds (g_javaVM equals the real VM) and the result is OK. R3, variant B with no help: the app process crashes with SIGSEGV on thread 'logos-qt'. debuggerd symbolized the same path as in X1: QJniEnvironment::getJniEnv+46 <- appVersion+470 <- init+162 <- QCoreApplication ctor <- Java_org_logos_qrotest_NativeBridge_runClient. R2, variant B with our JNI code calling QtCore's JNI_OnLoad(realVM) and ignoring JNI_ERR: OK; without the jar, Qt fails FindClass(QtNative) but g_javaVM stays set. R7, variant B with the fake-VM fix in the app: also OK. R4, variant B with a JNI lib that has no JNI_OnLoad of its own: System.loadLibrary throws `UnsatisfiedLinkError: JNI_ERR returned from JNI_OnLoad in .../libqrotest_jni_noonload.so`. ART's lookup of JNI_OnLoad reached QtCore's copy through the DT_NEEDED chain, and without the jar it fails. So a JNI bridge that links QtCore must define its own JNI_OnLoad unless the jar is shipped.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/x2-run.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/x2-R3-B-none.crash; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/x2-R4-B-noonload.logcat; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/src/qrotest_jni.cpp
- [pass|verified-by-experiment] X2 Does the helper still need the fix when the parent app is a correctly initialised Qt app?
  Yes, it does. R6 ran variant A with the helper's --jvm-mode=none: the helper exits with rc=139 (SIGSEGV; tombstone Cmdline shows libqro_server.so --jvm-mode=none), and the client reports 'FAIL replica never became valid within 10000 ms'. The helper never inherits a JavaVM, so logos_host_qt must include the fix on Android, or Qt must be patched.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/x2-R6-A-childnoshim.crash; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/x2-run.log
- [fail|verified-by-experiment] Emulator: headless boot as specified (-no-window -gpu swiftshader_indirect)
  On this host, `emulator -avd delivery-demo -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect` SIGSEGVs (core dumped) during cold boot, right after 'Failed to load snapshot default_boot'. The wallet-android and ndk-runtime sessions logged the same crash. Workaround used: the windowed qemu binary with the window hidden and a private read-only instance: `emulator -avd delivery-demo -read-only -port 5570 -no-audio -no-boot-anim -no-snapshot-save -qt-hide-window`. Boot completes in 32 s; SELinux is Enforcing and the page size is 4096. The instance was shut down with `adb -s emulator-5570 emu kill`, and no qemu process remains. -read-only means the AVD itself was not modified.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/emulator.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/emulator-hidden.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/emu-start.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/qt-jvmless-emu-start.sh
- [partial|inferred] Proposed patch for logos_host_qt (logos-module-loader-qt) to run on Android
  Drafted, never compiled in the repo: patches/logos-module-loader-qt-android-nojvm-shim.patch against 888da92. It adds src/host/qt/android_nojvm_shim.h and calls logos_android_nojvm::primeQtCoreWithoutJvm() in QtApp::init() under #if defined(__ANDROID__), before `new QCoreApplication`. The code matches the experiment's nojvm_shim.h apart from renamed identifiers. It was drafted in a shared clone; the original repo is untouched. It was not compiled in the repo, because no Android build of logos-module-loader-qt exists yet. The other option, patching Qt itself (null-check g_javaVM in QJniEnvironment::getJniEnv), would need a Qt build from source and was not tried.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/patches/logos-module-loader-qt-android-nojvm-shim.patch; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/src-copies/logos-module-loader-qt

### Patches
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/patches/logos-module-loader-qt-android-nojvm-shim.patch (proposed, base logos-module-loader-qt 888da92, never compiled in the repo; adds src/host/qt/android_nojvm_shim.h and a call in QtApp::init before new QCoreApplication; code identical to the tested .work/experiments/qt-jvmless/src/nojvm_shim.h)
- No Logos repo was modified. No Qt patch. All test code is new, under .work/experiments/qt-jvmless/src and .work/experiments/qt-jvmless/app.

### Artifacts
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/probe/qt/6.11.1/android_x86_64
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/probe/qt/6.11.1/gcc_64
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/src/nojvm_shim.h
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/src/common.h
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/src/qro_server.cpp
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/src/qro_client.cpp
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/src/client_core.h
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/src/qrotest_jni.cpp
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/src/echo_plugin.h
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/src/echo_object.h
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/src/CMakeLists.txt
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/build/x86_64/qro_server
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/build/x86_64/qro_client
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/build/x86_64/libechoplugin.so
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/build/x86_64/libqrotest_jni.so
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/build/x86_64/libqrotest_jni_noonload.so
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/app/app/build/outputs/apk/withjar/debug/app-withjar-debug.apk
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/app/app/build/outputs/apk/nojar/debug/app-nojar-debug.apk
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/app/app/src/main/kotlin/org/logos/qrotest/MainActivity.kt
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/app/app/build.gradle.kts
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/x1-run.log
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/x1-crash.log
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/x1-t2.log
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/symbolize.log
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/avc.log
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/x2-run.log
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/logs/ (x2-R1..R9 *.logcat and *.crash, aqt.log, build.log, app-build.log, emu-start.log, emulator.log, emulator-hidden.log, qtsrc.log)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/qt-jvmless/qtsrc/qtbase (v6.11.1 sparse: src/corelib, src/network/socket) and qtsrc/qtremoteobjects (v6.11.1), read-only reference
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/qt-jvmless-*.sh

### Repro
Each step is one Bash call of the form `bash <script>`; all scripts are in /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts:
1. qt-jvmless-aqt.sh: aqt install of android_x86_64 (qtbase + qtremoteobjects) and linux_gcc_64 (qtbase + icu + qtremoteobjects) 6.11.1 into .work/probe/qt.
2. qt-jvmless-build.sh: cmake 'Unix Makefiles' with the Qt toolchain file, QT_HOST_PATH=gcc_64, NDK r27c, x86_64, android-34, c++_shared. Output goes to .work/experiments/qt-jvmless/build/x86_64.
3. qt-jvmless-emu-start.sh: `emulator -avd delivery-demo -read-only -port 5570 -no-audio -no-boot-anim -no-snapshot-save -qt-hide-window`, started detached with setsid nohup; then wait-for-device and poll sys.boot_completed. -no-window SIGSEGVs on this host.
4. qt-jvmless-x1-run.sh: pushes qro_server, qro_client, libechoplugin.so, libQt6{Core,Network,RemoteObjects}_x86_64.so and libc++_shared.so to /data/local/tmp/q on emulator-5570. It then runs `cd /data/local/tmp/q && export TMPDIR=/data/local/tmp/q LD_LIBRARY_PATH=/data/local/tmp/q` and these cases:
   - T0a: `./qro_server --jvm-mode=none` crashes (139).
   - T0b: `--jvm-mode=appversion` crashes (139).
   - T1: `./qro_server --jvm-mode=shim --url=localabstract:qro_t &` then `QJL_JVM_MODE=shim ./qro_client localabstract:qro_t 8000`, run twice: RESULT OK.
   - T1r: the same with local:qro_t, run through `su 0 sh -c`.
   - T2 (SIGTERM shutdown): re-run with qt-jvmless-x1-t2.sh, which uses pkill -x.
   - T3: TMPDIR unset.
   - T4: `--probe=androidctx|stdpaths|timezone|locale|sysinfo`.
   qt-jvmless-symbolize.sh symbolizes the crash frames.
5. qt-jvmless-app-build.sh: sets JAVA_HOME=/usr/lib/jvm/java-21-openjdk, because /usr/bin/java is a JRE-only JDK 25. It copies the Gradle wrapper from logos-android-wrap-poc and stages jniLibs/x86_64: libqro_server.so (the server executable, renamed), the plugin, both JNI libs, the Qt libs and libc++_shared. Then `./gradlew --no-daemon assembleWithjarDebug assembleNojarDebug`.
6. qt-jvmless-x2-run.sh: installs both APKs. Each run does `am force-stop`, `logcat -c` and `am start -W -n <pkg>/org.logos.qrotest.MainActivity <extras>`, then collects logcat, the crash buffer, `ps -A -o PID,PPID,USER,LABEL,NAME`, `run-as <pkg> ls -laZ cache`, and ps again after force-stop. Runs:
   - R1: org.logos.qrotest.a, default.
   - R2: org.logos.qrotest.b, jvmMode=realvm.
   - R3: .b with `--es jvmMode none`.
   - R4: .b with `--es jvmMode none --es jniLib qrotest_jni_noonload`.
   - R5: .a with `--es url localabstract:qro_t`.
   - R6: .a with `--es serverJvmMode none`.
   - R7: .b with `--es jvmMode shim`.
   - R8: .a with `--es spawn native`.
   - R9: .b with `--es spawn native`.
7. `adb -s emulator-5570 emu kill`.

### Next steps
- Put the no-JVM fix into logos_host_qt: apply or adapt patches/logos-module-loader-qt-android-nojvm-shim.patch, build logos-module-loader-qt for Android, and confirm it starts under the app. The other option is to carry a one-line Qt patch that null-checks g_javaVM in QJniEnvironment::getJniEnv/QtAndroidPrivate::context, but that means building Qt from source instead of using the official prebuilts.
- In the embedding app, before constructing QCoreApplication for liblogos_core, do one of: (a) add Qt6Android.jar and call System.loadLibrary("Qt6Core_<abi>") first, or (b) define your own JNI_OnLoad in the JNI bridge and call QtCore's JNI_OnLoad(realVM) while ignoring JNI_ERR. Both passed on the emulator; (b) avoids shipping the jar. The bridge must define its own JNI_OnLoad either way, otherwise ART picks up QtCore's through DT_NEEDED and loadLibrary fails.
- Set TMPDIR=cacheDir, and LD_LIBRARY_PATH=nativeLibraryDir (or give the host a DT_RUNPATH of $ORIGIN; not tested), in the app process via Os.setenv before liblogos spawns anything; posix_spawn with the inherited environ was verified. Set LOGOS_HOST_PATH=nativeLibraryDir/liblogos_host_qt.so explicitly: boost::dll::program_location() in the app returns app_process64, which I inferred and did not test.
- Audit liblogos, the modules and lez_core for QStandardPaths, named QTimeZone, QLocale::system and QSysInfo version use in the helper process. Under the fix these return empty/C/-1 values; pass directories on the command line instead.
- Not tested and still open: Android 12+ phantom-process limits (32 child processes system-wide, and background CPU kills) could kill long-lived module subprocesses. Build a stress test with N module helpers running while the app is in the background.
- Repeat on arm64 and on a device with 16 KB pages and API 35/36. Only the x86_64 API 34 emulator (4 KB pages) was tested; the arm64 AVD does not boot on this host.
- Next integration step: replace qro_server with the real logos_host_qt plus the lez_core plugin (lp_* ABI), with liblogos_core in-process in the app, over the same nativeLibraryDir-exec and cacheDir-socket layout.

---

## Full report

## qt-jvmless: can the liblogos subprocess model run on Android?

**Answer: yes, with one required fix.** Stock Qt 6.11.1 cannot even construct `QCoreApplication` in a process that has no Java VM. A fake-JavaVM fix of about 60 lines, needing no Qt rebuild, makes Qt Core, QtRemoteObjects over a local socket, and QPluginLoader work. That held both in `adb shell` and in a helper started by a real app. Tested on the x86_64 emulator, API 34 image.

### Part 1 (X1): native executables, no JavaVM

- **Qt install:** done with aqt 3.3.0 into `.work/probe/qt/6.11.1/{android_x86_64,gcc_64}`:
  - `aqt install-qt all_os android 6.11.1 android_x86_64 --archives qtbase -m qtremoteobjects --outputdir .work/probe/qt`
  - `aqt install-qt linux desktop 6.11.1 linux_gcc_64 --archives qtbase icu -m qtremoteobjects --outputdir .work/probe/qt`
- **Build:** plain `add_executable`, because `qt_add_executable` makes a `.so` on Android. The result is a PIE executable with interpreter `/system/bin/linker64` and 16 KB-aligned LOAD segments. The plugin is a MODULE library with `Q_PLUGIN_METADATA`.
- **Stock Qt fails.** `QCoreApplication`'s constructor segfaults on a null pointer. The symbolized path is `QCoreApplication()` → `QCoreApplicationPrivate::init()` → `appVersion()` (qcoreapplication.cpp:202) → `QJniObject` → `QJniEnvironment::getJniEnv()`, which calls `vm->GetEnv` on a null `javaVM()`.
- **Skipping `appVersion` is not enough.** With `setApplicationVersion()` called first, it still crashes in `init()`: `QLoggingRegistry::initializeRules()` (qcoreapplication.cpp:827, always called on Android) → `QStandardPaths::locateAll(GenericConfigLocation)` → `getFilesDir()` → `QJniObject` → `getJniEnv`. So `logos_host_qt` as shipped cannot start on Android.
- **The fix** (`src/nojvm_shim.h`), which must run before `QCoreApplication` is constructed:
  - It finds QtCore with `dladdr(&qVersion)`, looks up its `JNI_OnLoad`, and calls it with a fake JavaVM whose JNIEnv returns 0/NULL for every call.
  - Qt's `initJNI` stores `g_javaVM = vm` first (qjnihelpers.cpp:281), then fails on `FindClass` and returns JNI_ERR, which is ignored.
  - From then on every Qt JNI path gets an invalid object and returns an empty value instead of crashing.
- **What works with the fix:**
  - `QCoreApplication`.
  - `QPluginLoader`: IID read, `instance()`, `qobject_cast` and `hello()` all work.
  - `QRemoteObjectRegistryHost::setRegistryUrl` plus `enableRemoting`.
  - A client in a separate process: `connectToNode`, `acquireDynamic`, and `invokeMethod` returning `QRemoteObjectPendingCall`. Both `echo(QString)` and `callRemoteMethod(QString,QString,QVariantList)` were tested; the second has the same shape as logos ModuleProxy. The sum call returned 42 with a round trip of 0–3 ms.
  - Two client processes in a row.
  - SIGTERM shutdown through the self-pipe, as in logos_host_qt.
  - The helper's `/proc/self/maps` shows 0 `libart.so` mappings.
- **What degrades under the fix:**
  - `QStandardPaths` returns empty paths and `applicationVersion` is `''`.
  - `sdkVersion` is 0, `QLocale::system()` is `C`, and named time zones are invalid.
  - `QSysInfo::productVersion()` is `-1.-1`.
  - `QDir::tempPath()` honours TMPDIR.
  - `applicationFilePath` comes from argv[0], so `libraryPaths()` is the executable's directory.
- **Test-harness artifacts, not app problems:**
  - The adb `shell` domain may not create a `sock_file` in `/data/local/tmp` (avc denied), so `local:` fails there. `localabstract:` works, and `local:` works as root.
  - With TMPDIR unset, `tempPath()` is `/tmp`, which does not exist, so listen fails.

### Part 2 (X2): real Kotlin app

- **Setup:** AGP 9.4.0, Kotlin 2.4.20, Gradle 9.7.1, minSdk 34, targetSdk 36, `useLegacyPackaging=true`, x86_64 only.
- **Helper process:** `libqro_server.so` in `nativeLibraryDir` has mode 755, and both ways of starting it work:
  - `ProcessBuilder` with LD_LIBRARY_PATH and TMPDIR set.
  - Native `posix_spawn(environ)` after `Os.setenv`, which is how logos-container-subprocess spawns.
- **The child** runs as `untrusted_app` with the same MLS categories, PPID equal to the app's pid, and no libart. After `am force-stop` no helper was left (9 of 9 runs). When the app crashed, its helper died too.
- **SELinux:** the child creates `cache/qro_t` (`app_data_file`, mode 0700 socket) and the app's JNI client connects to it. `localabstract:` works too. The only avc denials are 4 per run of the child's dynamic linker searching a `tests` directory, with no effect.
- **Qt6Android.jar is not required:**

| Run | App-side setup | Result |
|---|---|---|
| R1 | Variant A: jar plus `System.loadLibrary("Qt6Core_x86_64")` first | OK |
| R2 | Variant B: no jar; bridge calls QtCore `JNI_OnLoad(realVM)` itself | OK |
| R3 | Variant B with nothing extra | App crashes in the `QCoreApplication` constructor, same path as X1 |
| R4 | Variant B, bridge without its own `JNI_OnLoad` | `UnsatisfiedLinkError` "JNI_ERR returned from JNI_OnLoad": ART found QtCore's `JNI_OnLoad` through DT_NEEDED |
| R6 | Variant A, but helper started without the fix | Helper exits 139 and the client times out |
| R7 | Variant B with the fake-VM fix in the app | OK |

- **What this means for the integration:**
  - `logos_host_qt` always needs the fix on Android.
  - The app side needs either the jar or a manual `JNI_OnLoad(realVM)` call.
  - A JNI bridge that links QtCore must define its own `JNI_OnLoad` unless the jar is shipped.

### Patches

- No Logos or Qt repo was modified.
- `patches/logos-module-loader-qt-android-nojvm-shim.patch` (base 888da92) is a proposal drafted in a shared clone, never compiled in the repo. It adds `android_nojvm_shim.h` and a call in `QtApp::init`.

### Emulator

- The specified `-no-window -gpu swiftshader_indirect` boot segfaults on this host.
- I used `-read-only -port 5570 -qt-hide-window -no-snapshot-save` instead (boot 32 s) and killed it at the end with `adb -s emulator-5570 emu kill`.

### Still unknown

- arm64 devices, 16 KB-page devices, and API 35/36.
- Android 12+ phantom-process limits on long-lived helpers.
- The real `logos_host_qt`, `liblogos_core` and `lez_core` on Android.
- The drafted patch, which has not been compiled in the repo.
- Other Qt APIs under the fix (SSL, `QProcess`, `QNetworkInformation`).
- The cause of the linker's `tests` directory search.

