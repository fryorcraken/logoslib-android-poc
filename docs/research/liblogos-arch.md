# liblogos_core architecture

> Research track `liblogos-arch`, 2026-09-25. Written by a research agent and then checked by a
> second, adversarial agent, whose non-confirmed verdicts are listed under "Verifier".
> Claims are tagged verified-from-source / verified-by-experiment / inferred / open.
> Absolute paths point at the author's local checkouts (`~/src/logos-co`,
> `~/src/logos-blockchain`) at the revisions in [../investigation.md](../investigation.md);
> `.work/` paths are local scratch, not committed. The synthesis is in
> [../investigation.md](../investigation.md).


### Summary
Current liblogos (logos-liblogos HEAD 7fee75b, 2026-09-14) is a thin C ABI (20 exported logos_core_* functions) over a ModuleManager that composes a link-time-selected ModuleContainer (default: logos-container-subprocess, posix_spawn of one logos_host_qt child per module, token over stdin, QtRO LocalSocket per module under QDir::tempPath()) with a ModuleFormatLoader (default: logos-module-loader-qt, which only resolves the host binary + argv). There is NO in-process container anywhere in the local repos and no env var/API/metadata switch: loadModuleInternal hard-codes format "qt-plugin" and never fills loaderConfig, and the default composite loader is registered first and accepts everything. In-process on Android therefore needs either (a) a new ModuleContainer package swapped in via the `default-container` flake input / LogosContainerImpl CMake config, or (b) C++-level runtime replacement via the exported-but-uninstalled ModuleManager::loaders().clearForTests()+registerLoader() (what liblogos' own tests do). The whole runtime is Qt-bound: liblogos_core, liblogos_protocol (only its lp_* header is Qt-free), liblogos_qt_host, logos-module and logos_host_qt all link QtCore(+RemoteObjects/Network); the container/loader contracts, container-subprocess, the parent-side Qt-plugin loader lib, process-stats, package_manager_lib and liblgx are Qt-free. logos_core_init is a no-op: the embedder must create QCoreApplication and pump the event loop on the thread that calls logos_core_start. On Android: lgx_host_variant() has no __ANDROID__ branch (returns linux-arm64), Qt temp path falls back to /tmp unless TMPDIR is set (Qt's own QtLoader.java sets it to cacheDir), exec() from app home is forbidden for targetSdk>=29 (logos_host_qt would have to ship in nativeLibraryDir and be named via LOGOS_HOST_PATH), posix_spawn needs API 28 and logos_host's backtrace() API 33. No android output exists in the liblogos flake; logos-nix HEAD (not the rev liblogos pins) has an aarch64-android Qt 6.11.1 set that does not list qtremoteobjects. The Electron POC is actually one week old (2026-09-18) and its description of upstream is still essentially accurate.

### Claims
- [C1|critical|verified-from-source] By default every module runs in its own logos_host_qt subprocess. The default loader is CompositeModuleLoader(SubprocessContainer, QtPluginFormatLoader), built through the link-time factory seams LogosCore::makeContainer()/makeFormatLoader(). The implementations come from the flake input slots default-container (logos-container-subprocess) and default-module-loader (logos-module-loader-qt).
- [C2|critical|verified-from-source] None of the local logos-co repos contains an in-process container or format loader. The contract does anticipate one: ModuleContainer is documented as 'subprocess, docker, in-process', and LoadedModuleHandle.pid is -1 for in-proc.
- [C3|critical|verified-from-source] No env var, C API call or module metadata selects the container or loader at runtime. loadModuleInternal hard-codes desc.format = "qt-plugin" and never populates desc.loaderConfig. The registry returns the first loader whose canHandle() is true. The default composite is registered first (lazily, in call_once), and SubprocessContainer::canHandle always returns true. So a loader added with registerLoader() alongside the default can never win. The only ways to switch are a build-time swap (the default-container input / the LogosContainerImpl CMake config) or a C++-level replacement via ModuleManager::loaders().clearForTests() + registerLoader(), which is what liblogos' own tests do.
- [C4|high|verified-by-experiment] liblogos_core.so exports about 1032 dynamic symbols. These include the C++ internals needed for runtime loader replacement (ModuleManager::loaders(), ModuleLoaderRegistry::registerLoader/clearForTests/select, makeContainer). The headers declaring them (module_manager.h, module_loader_registry.h, module_loader.h) are not installed; include.nix installs only logos_core.h plus the SDK headers.
- [C5|critical|verified-from-source] logos_core_init(argc, argv) is a no-op and does not create a QCoreApplication. The embedder must construct one. Core's outbound calls (capability_module registration, readiness watches, the modules_state feed) run on the thread that called logos_core_start() and need that thread's Qt event loop. requestObject/informModuleToken spin nested event loops. liblogos' own spec.md still claims init creates the QCoreApplication, which is stale.
- [C6|high|verified-from-source] Each module host publishes on a QtRO LocalSocket registry URL 'local:logos_<module>_<instanceId>'. The name is relative, so the socket file lands in QDir::tempPath(). Qt's tempPath() is $TMPDIR, falling back to _PATH_TMP or '/tmp'. Bionic's paths.h defines no _PATH_TMP, so on Android without TMPDIR the sockets would go to /tmp, which an app cannot write. Qt's own QtLoader.java sets TMPDIR=context.getCacheDir(); a plain Kotlin app that does not use Qt's Java loader must set TMPDIR (and HOME) itself. Core's own LogosAPI("core") binds no socket, because RemoteTransportHost listens lazily on publishObject.
- [C7|high|verified-from-source] Environment and filesystem inputs the runtime reads. Environment: LOGOS_HOST_PATH (host binary), LOGOS_INSTANCE_ID (created and exported by logos_core_start, inherited by children), LOGOS_LOG_LEVEL / SPDLOG_LEVEL, LOGOS_SOCKET_GROUP / LOGOS_SOCKET_MODE, LOGOS_MOCK_FIXTURE, and TMPDIR (both via Qt and via std::filesystem::temp_directory_path in lgpm installs). Filesystem: persistence goes to the path set by logos_core_set_persistence_base_path; no config files are read by liblogos_core. The host binary is resolved in this order: LOGOS_HOST_PATH, then the directory of boost::dll::program_location(), then <first modulesDir>/../bin, trying the names logos_host_qt or logos_host.
- [C8|high|verified-from-source] Threads and processes created by the default container: one asio io_context thread (IoRuntime); one leaked, process-lifetime spawn thread (SpawnRuntime) that every posix_spawn goes through; and per module one logos_host_qt child. The child calls setsid(), sets prctl(PR_SET_PDEATHSIG, SIGKILL), runs a detached getppid() watchdog thread, and reads its UUID token from stdin (--token-source stdin). It prints a 'plugin loaded' status line on stdout, which logos_core_load_module waits for (10 s, dropping to 1 s once a host is seen to stay silent). Teardown sends SIGTERM (request_exit) and escalates to terminate after 5 s. capability_module and, if installed, modules_state are spawned inside logos_core_start.
- [C9|critical|verified-from-source] Blockers for the subprocess route on Android. Apps targeting API 29+ cannot execve() files in their writable home directory, so logos_host_qt would have to ship inside the APK's native library dir (named lib*.so, extractNativeLibs) and be pointed to via LOGOS_HOST_PATH; the program_location() fallback resolves the app_process binary and would not find it (inferred). posix_spawn* needs API 28. logos_host.cpp includes <execinfo.h> and calls backtrace() on every non-Windows build, and bionic only provides it from API 33. Android 12+ also limits phantom child processes system-wide (32 by default).
- [C10|high|verified-by-experiment] Qt dependency map. Linking Qt: liblogos_core (Core, RemoteObjects; Network appears in NEEDED); liblogos_protocol (Core, RemoteObjects; Qt-free only in its public lp_* C header; the plain TCP transport is Qt-free code inside a Qt-linked library); liblogos_qt_host (Core, RemoteObjects); logos_host_qt (Core, Network, RemoteObjects); logos-module (Qt6 Core; QPluginLoader). Qt-free: the logos-container and logos-module-loader header contracts; logos_container_subprocess (Boost.Process, spdlog); the parent-side logos_module_loader_qt static lib (Boost.Filesystem, spdlog); process-stats; package_manager_lib; liblgx (zlib, ICU 76, libsodium); the logos-cpp-sdk runtime headers (nlohmann only). The local build uses qtbase and qtremoteobjects 6.9.2.
- [C11|high|verified-from-source] Every piece has a standalone CMake build, and the pieces find each other through -D<NAME>_ROOT=<install prefix> variables plus find_package(... PATHS <root>/lib/cmake/... NO_DEFAULT_PATH) or find_library(<root>/lib). The container and loader implementations are found through CMAKE_PREFIX_PATH (find_package(LogosContainerImpl / LogosFormatLoaderImpl)). Building outside Nix with the NDK toolchain adds two problems. First, logos-container-subprocess and logos-module-loader-qt add their tests unconditionally, with a googletest FetchContent fallback, and have no option to turn them off. Second, the NDK's default (legacy) toolchain sets CMAKE_FIND_ROOT_PATH_MODE_PACKAGE/LIBRARY/INCLUDE to ONLY, so every dependency prefix has to go into CMAKE_FIND_ROOT_PATH (inferred).
- [C12|medium|verified-from-source] The liblogos flake has no Android, cross or mobile output. Its systems are aarch64/x86_64 darwin and linux, plus an x86_64-windows packages-only pseudo-system; the devShell is cmake/ninja/pkg-config/qtbase/qtremoteobjects/zstd/spdlog. logos-nix at its local HEAD (commit 5378de5, 2026-09-07) adds an opt-in aarch64-android pseudo-system: Qt 6.11.1 from the nixpkgs-windows pin, API 28, NDK 27.0.12077973, arm64-v8a only. The logos-nix revision liblogos pins (f55bf91) predates it and has no nix/android. The Android Qt module list that set asserts is qtbase/qtdeclarative/qtshadertools/qtsvg, with no qtremoteobjects, which the whole stack needs.
- [C13|critical|verified-from-source] The platform variant is computed at compile time by liblgx's lgx_host_variant(), which has no __ANDROID__ branch. Bionic defines __linux__, so an Android arm64 build answers 'linux-arm64' (x86_64 emulator: 'linux-x86_64'). Only the architecture is aliased (x86_64/amd64, aarch64/arm64); the OS half is matched verbatim. The package manager appends '-dev' to every candidate unless package_manager_lib was built with LGPM_PORTABLE_BUILD. liblogos' own LOGOS_PORTABLE_BUILD define is never read in liblogos source. The only override is the C++ static PackageManagerLib::setPlatformVariantOverride(); there is no liblogos C API for it. Variant names are free-form, so an 'android-arm64' key is possible, but nothing produces or selects one today.
- [C14|high|verified-from-source] Installed module directory: <modulesDir>/<name>/ holds manifest.json (a 'main' map from variant key to file), the plugin <name>_plugin.so, a 'variant' text file, an optional manifest.sig, and bundled private deps flattened beside the plugin (e.g. lez_core ships libwallet_ffi.so). Discovery scans subdirectories for manifest.json, keeps only type 'core', resolves main through lgx_resolve_main against the variant candidates, and refuses a plugin whose embedded metadata name differs from the package name. Metadata is read in the parent with QPluginLoader::metaData(). The child instantiates the plugin with QPluginLoader::instance() from an absolute path. Portable variants are relocated with $ORIGIN RUNPATHs and exclude host-provided Qt*, liblogos_core*, liblogos_sdk*, liblgx*, libz* and ICU libraries.
- [C15|high|inferred] Module plugins link static copies of logos_protocol and logos_qt_host, which gives per-image singletons such as TokenManager and the LogosModeConfig mode. In-process hosts must link the shared liblogos_protocol.so and liblogos_qt_host.so so these types exist once. logos_host already copes with 'two images in one process' by pushing the auth token and host services into the plugin through QObject properties rather than the host's TokenManager. Running several modules in the liblogos_core process would therefore mean several images, each with its own protocol stack (inferred). Upstream has per-identity TokenManager stores for 'a host that loads several modules in one image'.
- [C16|medium|verified-from-source] logos-protocol already has an in-process transport mode, LogosMode::Local ('in-process PluginRegistry (mobile apps, single process)'), backed by QCoreApplication dynamic properties. liblogos does not wire it in, and basecamp's use of it is commented out. The mode is a per-image static that a statically linked plugin's copy does not see, so it cannot simply be switched on for all modules from the host.
- [C17|high|verified-by-experiment] The C API is exactly 20 exported functions: logos_core_init, add_modules_dir, start, cleanup, get_loaded_modules, get_known_modules, load_module(name, LogosLoadDeps), optional_load_report, unload_module, get_module_dependencies, get_module_dependents, get_module_optional_dependencies, get_modules_info, process_module, get_token, get_module_stats, set_persistence_base_path, set_module_transports, set_access_policy, refresh_modules. load_module now takes an enum with values 0/1/2 instead of bool; README.md still shows the bool signature.
- [C18|high|verified-from-source] capability_module is loaded inside logos_core_start if it is found in any modules dir; if it is absent, start continues. Every inter-module call needs it, because LogosAPIClient fetches per-target tokens through capability_module.requestModule. The format loader grants it the host services token_registry,token_delivery by name over argv, so an in-process replacement has to reproduce that grant, which logos_host passes to the plugin as the hostServices property.
- [C19|medium|inferred] process-stats should build on Android: its __linux__ branch only reads /proc/<pid>/stat and /proc/<pid>/status and calls sysconf(_SC_CLK_TCK), all available on bionic, and it returns zeros for pid <= 0, which is what an in-process loader would report. Other Unix-only code in the stack: posix_spawn plus a /proc/self/fd walk (the glibc closefrom_np path is gated to glibc 2.34+) in container-subprocess; setsid/prctl/getppid/sigaltstack/backtrace in logos_host; getgrnam_r (API 24) and chown/chmod socket permissions in logos-protocol. Boost.Process v2 turns on pidfd_open whenever SYS_pidfd_open is defined, which it is on Android; bionic's wrapper is API 31, and whether older app seccomp policies allow it is unknown.
- [C20|medium|verified-by-experiment] Pinned inputs in logos-liblogos/flake.lock: logos-protocol fdc09ff5, logos-plugin-qt 8af5b188, logos-qt-sdk dffe05e2, logos-cpp-sdk fb88c7d5, logos-container 641d2110, default-container (logos-container-subprocess) 697c1805, logos-module-loader 3628b97a, default-module-loader (logos-module-loader-qt) 1d31cd70, logos-module f71d16dd, logos-package-manager d88abaa1, process-stats 3e58e1c9, logos-capability-module 98ff8414, logos-modules-state-module 2370bcb1, logos-nix f55bf91b, which pins nixpkgs e9f00bd8. Several local checkouts are a few commits newer than the lock. The local liblogos build links Boost 1.87, OpenSSL 3.5.1 and spdlog 1.15.2. It uses Qt 6.9.2, the same Qt the Electron POC reported.
- [C21|medium|verified-from-source] The Electron POC is not months old: its commits are dated 2026-09-18 and its Makefile builds against the local ~/src/logos-co/logos-liblogos checkout. What it says about upstream still holds: modules and consumers are plain C, in-process calls need Qt C++, QCoreApplication is required, loads block, and liblogos_qt_host.so / liblogos_protocol.so ship shared. What it leaves out or gets slightly wrong: (a) it never mentions the container/format-loader split or the default-container / default-module-loader slots; (b) NEXT.md attributes LogosAPI to logos-liblogos when the code lives in logos-plugin-qt (logos-qt-host) and liblogos only re-exports the headers; (c) it never examined the in-process LogosMode::Local path or an in-process container. It also does not correct upstream's own stale docs (README's bool load signature, spec.md's init/QCoreApplication claim).
- [C22|high|verified-from-source] On Android, loading plugins in-process from an app-writable directory with dlopen/QPluginLoader is not forbidden by the API 29 W^X change; only execve() of app-home files and write-through modification of dlopen'd text are. So an in-process loader can open module .so files from filesDir, while a subprocess host cannot be exec'd from there.

### Open questions
- Can Qt 6 QtCore on Android construct and run a QCoreApplication inside a non-Qt Kotlin app (without Qt's QtActivity/QtLoader Java side and its JNI_OnLoad expectations)? Can it do so at all in a standalone exec'd native process with no JavaVM, as logos_host_qt would be? This is outside this area; the qt-android task should verify it.
- Does qtremoteobjects (plus the host repc tool) cross-build under logos-nix's aarch64-android overlay? It is not in the asserted Android Qt module list or in QT_ADDITIONAL_HOST_PACKAGES_PREFIX_PATH.
- If several statically linked module plugins are dlopen'd into one Android process (bionic linker namespaces, RTLD_LOCAL from System.loadLibrary, no STB_GNU_UNIQUE in clang output), do their inline statics (LogosModeConfig::modeStorage, TokenManager singletons) stay per-image or get interposed? This decides whether an in-process container needs per-identity token plumbing or works as logos_host does.
- Is the lgx source read from /nix/store/7f6d5ba9jv4hkn2r923kxjxac271i5hn-source exactly the logos-package revision locked by logos-package-manager d88abaa? Several store copies exist, and all that define lgx_host_variant have the same __linux__ logic, but the exact match is not proven. The logos-package repo is not checked out locally.
- Does Boost.Process v2's pidfd_open (raw syscall) pass the untrusted_app seccomp filter on API 28-30 devices? API 34 is presumed fine. BOOST_PROCESS_V2_DISABLE_PIDFD_OPEN is the escape hatch.
- Is a QLocalServer socket under the app cache dir reliably usable from a child process exec'd from nativeLibraryDir (same UID and SELinux domain)? Only relevant to the subprocess route; presumed yes, not verified.
- Do the LEZ module plugins (lez_core with the Rust libwallet_ffi.so) and their Rust cdylibs build for aarch64-linux-android? This is the job of the module-specific task.

### Recommendations
- Prefer an in-process design on Android. Write a new ModuleContainer implementation (for example logos-container-inprocess, shipping LogosContainerImplConfig.cmake and defining LogosCore::makeContainer()). Its launch() parses the argv built by QtPluginFormatLoader (--name/--path/--instance-persistence-path/--transport-set/--host-services), loads the plugin with ModuleLib::LogosModule::loadFromPath in the host process, and repeats module_initializer.cpp's initializeLogosAPI steps (LogosAPI(name, transports), the modulePath/instanceId/authToken/hostServices properties, registerObject, saving the core and capability_module tokens). sendToken() should deliver the token before registerObject; awaitLoad() returns Loaded; pid is -1. Select it at build time via --override-input default-container, or, without rebuilding liblogos, at runtime with ModuleManager::loaders().clearForTests() + registerLoader(...) before logos_core_start (the symbols are exported; copy module_manager.h, module_loader_registry.h and module_loader.h from the pinned liblogos rev).
- If you keep QtPluginFormatLoader with an in-process container, resolveHostBinary() still has to return an existing path or CompositeModuleLoader::load fails. Set LOGOS_HOST_PATH to any existing file (for example the app's own .so), or ship a trivial LogosFormatLoaderImpl as well.
- If the subprocess route is kept as a fallback: ship logos_host_qt inside the APK as jniLibs/arm64-v8a/liblogos_host_qt.so with extractNativeLibs=true (useLegacyPackaging), set LOGOS_HOST_PATH to <nativeLibraryDir>/liblogos_host_qt.so, use minSdk >= 33 (backtrace) or patch execinfo out of logos_host.cpp, and expect phantom-process limits on Android 12+.
- Before anything touches Qt, set TMPDIR=context.cacheDir and HOME=context.filesDir with android.system.Os.setenv, as Qt's QtLoader.java does. Call logos_core_set_persistence_base_path(filesDir/...) before logos_core_start.
- Create the QCoreApplication, call logos_core_init/add_modules_dir/start, and run QCoreApplication::exec() all on one dedicated native thread that owns every Qt object. Route JNI requests onto it with QMetaObject::invokeMethod. The Electron POC's 'dedicated Qt thread fails' result applies only when the Qt objects were created on another thread.
- For module discovery on Android, either write manifests whose main keys are 'linux-arm64-dev' (dev package-manager build) or 'linux-arm64' (LGPM_PORTABLE_BUILD) pointing at NDK-built plugins, which works today because lgx_host_variant() returns linux-arm64 under bionic, or call PackageManagerLib::setPlatformVariantOverride("android-arm64") early and name variants android-arm64. Longer term, propose an __ANDROID__ branch upstream in logos-package's platform_variant.cpp. Do not install glibc linux-* .lgx payloads on the device.
- Plain-CMake cross-build order with the NDK toolchain: Boost 1.87 (process, filesystem, system, context, date_time, atomic), OpenSSL 3, fmt/spdlog, nlohmann_json, CLI11, zlib, ICU and libsodium for liblgx, then logos-package (liblgx), logos-package-manager, Qt 6 Core/Network/RemoteObjects for Android (plus host moc/repc), logos-protocol, logos-plugin-qt/cpp (logos-qt-host), logos-cpp-sdk and logos-qt-sdk (interface), logos-module, process-stats (PROCESS_STATS_BUILD_TESTS=OFF), logos-container, logos-module-loader, logos-container-subprocess or your in-process container, logos-module-loader-qt, then logos-liblogos (LOGOS_BUILD_TESTS=OFF, all -D*_ROOT). Append every prefix to CMAKE_FIND_ROOT_PATH, because the NDK legacy toolchain sets find modes to ONLY. Patch out the unconditional tests/ and FetchContent(googletest) in container-subprocess and module-loader-qt.
- Consider starting from logos-nix HEAD's aarch64-android package set (Qt 6.11.1, API 28, NDK 27.0.12077973) for Qt, but first confirm it can produce qtremoteobjects. A Qt version different from desktop (6.9.2) does not matter on-device, since every QtRO peer is in the same install.
- Do not use LogosMode::Local for the POC. It is per-image, and module plugins carry their own copy. Keep the default LocalSocket/QtRO transport between in-process module instances (sockets under TMPDIR), which is also the transport the Electron POC's in-process LogosAPIClient calls already use.

### Verifier (non-confirmed only)
- [C5] partially-correct: logos_core_init is a no-op and the embedder must create the QCoreApplication. That part is confirmed, and spec.md:255 is stale. The thread claim is not quite right. The owner thread for core's outbound calls is the QCoreApplication's thread (the 'Qt main thread'), not simply whichever thread called logos_core_start(). anchorCoreApi() builds core's LogosAPI with logos::runOnQtMainThread, which runs it inline only when there is no QCoreApplication or the caller is already on the QCoreApplication thread. Otherwise it marshals with Qt::BlockingQueuedConnection. So calling logos_core_start() off the Qt thread blocks until that thread pumps its event loop, and deadlocks if the Qt thread is itself waiting on the caller. runOnOwner() then compares against coreApi().thread(), which is the Qt main thread. The logos_core.h:131-139 wording ('the thread that called logos_core_start()') holds only when start is called from the QCoreApplication thread. For Android: create a dedicated native thread, construct the QCoreApplication on it, call logos_core_start() from it and run exec() on it.
- [C6] partially-correct: The socket naming, the QDir::tempPath() placement, Qt's TMPDIR -> _PATH_TMP -> "/tmp" fallback, bionic having no _PATH_TMP, QtLoader.java setting TMPDIR, and the lazy listen in publishObject are all confirmed. The Android consequence is overstated. Since Android 13 (API 33) the framework itself sets TMPDIR to the app's cache dir in every app process, in ActivityThread, next to java.io.tmpdir. So the /tmp fallback only bites on API 28-32 (28 being the posix_spawn / Qt 6.11 floor) when the app does not use Qt's Java loader. Setting TMPDIR explicitly before any Qt/liblogos call is still the safe, portable choice. Qt does have a compile-time QT_UNIX_TEMP_PATH_OVERRIDE, but Qt's android mkspec qplatformdefs.h does not define it. Separately, logos_host.cpp:386 and qt_app.cpp:49 confirm that a socket leaks as /tmp/logos_<name>_<instance> when a host is killed.
- [C11] partially-correct: The -D<NAME>_ROOT, find_package NO_DEFAULT_PATH and CMAKE_PREFIX_PATH wiring, plus the unconditional GTest/FetchContent and add_subdirectory(tests) in logos-container-subprocess and logos-module-loader-qt, are confirmed. The toolchain conclusion is overstated. The NDK legacy toolchain sets CMAKE_FIND_ROOT_PATH_MODE_{LIBRARY,INCLUDE,PACKAGE}=ONLY only 'if(NOT ...)', so a build can pre-set them (e.g. -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH) instead of adding every prefix to CMAKE_FIND_ROOT_PATH. Adding prefixes to CMAKE_FIND_ROOT_PATH is one option, not a requirement. Two more wrinkles were missed. logos-module-loader-qt uses LOGOS_QT_SDK_ROOT (logos-qt-sdk) while liblogos uses LOGOS_QT_HOST_ROOT (logos-plugin-qt), so both SDK packages must be built. logos-module needs liblgx through LOGOS_PACKAGE_ROOT with find_path/find_library HINTS.
- [C15] partially-correct: The static-archive facts are confirmed. Bundled module plugins do not NEED liblogos_protocol.so or liblogos_qt_host.so, and logos-plugin-qt states that in-process images link the shared library while out-of-process images link the archive. What is imprecise is 'each has its own protocol stack in-process'; whether copies stay separate depends on dynamic symbol binding. The plugins EXPORT their copies with default visibility: capability_module_plugin.so and modules_state_plugin.so each export 43 TokenManager:: symbols and 7 PluginRegistry/LogosModeConfig symbols. On glibc, if liblogos_protocol.so is in the global lookup scope (an executable that links liblogos_core, like logoscore), those references are interposed onto the shared copy ('only ELF's flat namespace collapses them'). On Android, liblogos_core and its deps are loaded by System.loadLibrary into the app's linker namespace (not the global group) and QPluginLoader dlopens plugins RTLD_LOCAL, so the plugin's own copies would stay separate (inferred). This also means the per-image LogosModeConfig / PluginRegistry make LogosMode::Local unusable across such plugins.
- [C22] partially-correct: The status should be 'inferred', not 'verified-from-source'. The Android 10 page forbids execve() on app-home files and write-through modification of dlopen()ed text. It does not say that dlopen from app-home is allowed, and it explicitly says 'Apps should load only the binary code that's embedded within an app's APK file.' Android 14's 'Safer dynamic code loading' (all dynamically loaded files must be read-only) is written around DEX/JAR/APK, and the page does not say whether it covers native .so files. The practical route is to ship module .so files in the APK and load them from nativeLibraryDir. Because of the lib*.so extraction rule, plugins named <name>_plugin.so would need renaming, with manifest.json 'main' changed to match.

Confirmed: C1, C2, C3, C4, C7, C8, C9, C10, C13, C14, C17, C18

### Verifier missed findings
- logos-protocol ships an in-process transport: LogosMode::Local. It is documented as 'Local: Uses in-process PluginRegistry (mobile apps, single process)' and selectable from C with lp_set_mode("local"), which is exported by liblogos_protocol.so. In this mode LocalTransportHost::publishObject only calls PluginRegistry::registerPlugin, and LocalTransportConnection::requestObject returns a LocalLogosObject that calls ModuleProxy::callRemoteMethod directly, with no socket. Upstream says it has no producer: logos_caller_scope.h:70-75 'qt_local (in-process) UNKNOWN ... call m_proxy->callRemoteMethod DIRECTLY ... close a pre-existing cross-image hazard; LogosMode::Local has no in-tree producer today', and basecamp's use is commented out (logos-basecamp/app/main.cpp:86 '//LogosModeConfig::setMode(LogosMode::Local);'). Both the mode and PluginRegistry are per-image statics (logos_mode.h:54 'Per-image, like the mode itself'), so the mode only works if the host and every module image share one liblogos_protocol.so. Evidence: /home/fryorcraken/src/logos-co/logos-protocol/cpp/logos_mode.h:10-16; logos_protocol.cpp:206-218; implementations/qt_local/local_transport.cpp:83-96,189-238; logos_transport_factory.cpp:29-30; ELF check shows 'T lp_set_mode' in liblogos_protocol.so (verify-liblogos-arch-lgx.sh). Status: verified-from-source; whether it works end to end is open.
- Swapping in an in-process ModuleContainer is NOT enough on its own. CompositeModuleLoader::load returns false before container_->launch whenever the format loader cannot resolve a host binary (composite_module_loader.cpp:25-27 'if (host.empty()) return false;'). The default QtPluginFormatLoader returns {} unless an existing logos_host_qt/logos_host file is found (qt_plugin_format_loader.cpp:131-146). So an in-process container paired with the default loader still needs LOGOS_HOST_PATH pointing at an existing file, or a replacement format loader. Also, the logic that actually hosts a module (the loadModule name check, the initializeLogosAPI authToken/hostServices properties, registerObject, and saveToken for core and capability_module) is compiled only into the logos_host_qt EXECUTABLE (logos-module-loader-qt/src/CMakeLists.txt:66-82 LOGOS_HOST_SOURCES; module_initializer.cpp:57-200). No library contains it, so an in-process container must reimplement it. Status: verified-from-source.
- The lp_* C ABI can call a loaded module IN-PROCESS without hand-written Qt C++ (inferred, untested). liblogos_protocol.so is a NEEDED of liblogos_core and exports lp_client_create, lp_invoke, lp_token_* and lp_set_mode (ELF check). logos_protocol.h:436-441 says that for a Qt-affine transport (QtRO / local) 'the client is constructed on the Qt main thread — blocking this call until that thread runs it'. So a JNI shim running in the same process as liblogos_core, with a pumping QCoreApplication, could call modules over the default QtRO LocalSocket through plain C. This challenges the Electron POC's table row 'Call a module in-process | LogosAPI / LogosAPIClient, C++ | no — both are QObjects with no C ABI' (liblogos-electron-poc/README.md:221). The POC's negative lp_* result was for a JS client over the plain TCP transport from another process, where capability_module publishes 0 methods (NEXT.md:155-226). It did not test lp_* over QtRO in-process.
- logos-plugin-qt already provides an in-process consumer identity API, logos::admitConsumer(identity, hostApi, parent). It isolates a token store, mints a credential, registers it with capability_module and adopts it (logos_consumer.h:135-183). It is exported from liblogos_qt_host.so ('T logos::admitConsumer(QString const&, LogosAPI*, QObject*)', ELF check) and basecamp uses it for in-process widget plugins and ui_qml bridges (logos-basecamp/app/PluginLoader.cpp:81-108, 208-271, 304-311). This is the sanctioned way for an Android host to call modules as its own identity instead of borrowing core's ambient token ring (logos-protocol/README.md:36-58). Status: verified-from-source.
- Qt Core for Android cannot be dropped into a plain Kotlin app as just a .so. libQt6Core's JNI_OnLoad calls QtAndroidPrivate::initJNI, which does FindClass("org/qtproject/qt/android/QtNative") and returns JNI_ERR on failure (https://code.qt.io/cgit/qt/qtbase.git/plain/src/corelib/kernel/qjnihelpers.cpp?h=6.9). A non-Qt app must therefore still bundle Qt's Android Java classes and make sure JNI_OnLoad runs; a library loaded only transitively through another .so's NEEDED never gets JNI_OnLoad. Qt's own QtLoader.java also sets HOME, TMPDIR and QT_PLUGIN_PATH, which a custom loader must reproduce. Separately, whether QCoreApplication works in a JVM-less child (logos_host_qt spawned as a raw executable) is open.
- None of the existing .lgx payloads can run on Android. Every module and its private deps must be rebuilt with the NDK. lez_core_plugin.so is 'ELF 64-bit LSB shared object, x86-64, (GNU/Linux)' with NEEDED libc.so.6/ld-linux-x86-64.so.2 and RUNPATH /nix/store/...glibc-2.40-66. libwallet_ffi.so (108 MB) NEEDs libpcsclite.so.1. The bundled capability_module/modules_state plugins likewise carry /nix/store RUNPATHs (verify-liblogos-arch-elf.sh). nix-bundle-lgx only produces linux-*/darwin-*/windows-* variants (nix-bundle-lgx/flake.nix:52-60). Status: verified-by-experiment.
- APK packaging constraints conflict with how the current binaries are named. Android extracts only lib/<abi>/ entries named lib*.so (NativeLibraryHelper.cpp comment). Module plugins are named <name>_plugin.so, and the dependencies carry versioned sonames in NEEDED: libQt6Core.so.6, libssl.so.3, libcrypto.so.3, libboost_*.so.1.87.0, libicuuc.so.76, libsodium.so.26, libspdlog.so.1.15, libfmt.so.10 (ELF checks). The whole stack therefore needs Android-style unversioned sonames, and plugins/manifests need renaming, unless modules are copied to filesDir from assets (inferred).
- liblogos_core pulls in a large native dependency closure that must be cross-built for Android beyond Qt: OpenSSL 3 (directly NEEDED by liblogos_core, liblogos_protocol and liblogos_qt_host), Boost 1.87 (process, context, date_time, filesystem, atomic, system), spdlog/fmt, and through liblgx zlib, ICU 76 and libsodium (verify-liblogos-arch-elf.sh / -lgx.sh). The liblogos flake pins logos-nix 6e0f4a7 (2026-08-10), which has no Android support at all ('git grep -c -i android 6e0f4a7 -- flake.nix' finds nothing). logos-nix HEAD's Android set is Qt 6.11.1 with an API 28 floor, arm64-v8a only, and its checked module list is qtbase/qtdeclarative/qtshadertools/qtsvg, without qtremoteobjects (logos-nix/flake.nix:104-128, 625). Linux stays on Qt 6.9.2.
- Upstream docs overstate what the loader registry can do. module_manager.h:17-22 says frontends can register in-process/Docker loaders that 'compose with the built-in subprocess default' and can be 'pinned per-module via loaderConfig["id"]'. docs/spec.md:321 says 'This already works additively today'. The code contradicts both (see C3), so any design that relies on them will silently fall back to the subprocess container.
- On bionic, logos-container-subprocess falls back to enumerating /proc/self/fd (then /dev/fd, then sysconf(_SC_OPEN_MAX)) to close foreign fds before posix_spawn. The glibc-only posix_spawn_file_actions_addclosefrom_np path is gated on __GLIBC_PREREQ(2,34) (subprocess_container.cpp:30-34, 462-495), and the current Linux build imports posix_spawn_file_actions_addclosefrom_np@GLIBC_2.34 (ELF check). Status: verified-from-source; relevant only if the subprocess route is kept. process-stats already has a __linux__ /proc branch that works on Android and an iOS-aware install rule (process-stats/src/process_stats.cpp:11-25,77-110; CMakeLists.txt:52-56).

---

## Full report

## liblogos architecture as it bears on embedding in Android (task liblogos-arch)

Sources: local checkouts under `/home/fryorcraken/src/logos-co/*`. logos-liblogos is at HEAD `7fee75b` (2026-09-14, shallow clone). Evidence scripts are in `/home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/`: `liblogos-arch-lockrevs.sh`, `liblogos-arch-lgxvariant.sh` and `liblogos-arch-elf.sh`.

### 1. Repository shape, flake and pins

- **What it builds.** `logos-liblogos` builds only `liblogos_core` (a SHARED library) from `src/logos_core/*` and `src/logging/*` (`/home/fryorcraken/src/logos-co/logos-liblogos/src/CMakeLists.txt:175-206`).
  - The host binary moved to logos-module-loader-qt. `nix/bin.nix` re-exports `logos_host_qt` and its `logos_host` symlink from that package (`nix/bin.nix:17-22`).
  - `nix/lib.nix:45-95` stages `libpackage_manager_lib`, `liblgx`, `liblogos_protocol.so` and `liblogos_qt_host.so` beside `liblogos_core.so`, whose RUNPATH starts with `$ORIGIN`.
  - `nix/modules.nix` builds a `modules/` tree holding `capability_module` and `modules_state`. Their `manifest.json` files are hand-written with `main` keys `linux-{x86_64,amd64,arm64,aarch64}-dev` (`nix/modules.nix:61-73`).
- **Flake outputs** (`flake.nix`):
  - Systems are `aarch64-darwin x86_64-darwin aarch64-linux x86_64-linux`, plus an `x86_64-windows` pseudo-system for `packages` only (`flake.nix:42,62-98`).
  - Packages: `logos-liblogos-{bin,lib,include,modules}`, `logos-liblogos`/`default` (a symlinkJoin), `portable` (package manager built portable), and `logos-liblogos-tests` (not on Windows).
  - `checks.tests`. The devShell is cmake, ninja, pkg-config, qtbase, qtremoteobjects, zstd and spdlog (`flake.nix:257-270`).
  - **There is no android, mobile or cross output.**
- **Pins** (`flake.lock`, via `liblogos-arch-lockrevs.sh`):

  | Input | Locked rev |
  | --- | --- |
  | logos-protocol | `fdc09ff5` |
  | logos-plugin-qt | `8af5b188` |
  | logos-qt-sdk | `dffe05e2` |
  | logos-cpp-sdk | `fb88c7d5` |
  | logos-container | `641d2110` |
  | default-container (logos-container-subprocess) | `697c1805` |
  | logos-module-loader | `3628b97a` |
  | default-module-loader (logos-module-loader-qt) | `1d31cd70` |
  | logos-module | `f71d16dd` |
  | logos-package-manager | `d88abaa1` |
  | process-stats | `3e58e1c9` |
  | logos-capability-module | `98ff8414` |
  | logos-modules-state-module | `2370bcb1` |
  | logos-nix | `f55bf91b` |
  | nixpkgs (through logos-nix) | `e9f00bd8` |

  The local checkouts of module-loader-qt, protocol, plugin-qt and qt-sdk are a few commits newer than the lock; the changes are Windows DLL and protocol relocks.
- **What the local build links.** `readelf` on the built `result` shows qtbase and qtremoteobjects **6.9.2**, Boost 1.87, OpenSSL 3.5.1 and spdlog 1.15.2.
- **Android in logos-nix.** logos-nix HEAD (commit `5378de5`, 2026-09-07) adds an opt-in `aarch64-android` pseudo-system: Qt 6.11.1 from the `nixpkgs-windows` pin, API 28, NDK 27.0.12077973, arm64-v8a only (`/home/fryorcraken/src/logos-co/logos-nix/flake.nix:104-192`).
  - The rev liblogos pins (`f55bf91`) has no `nix/android`.
  - The Android Qt modules the flake asserts are `qtbase qtdeclarative qtshadertools qtsvg`. **qtremoteobjects is not among them** (`logos-nix/flake.nix:625`), and the whole Logos stack needs it.

### 2. Public C API (every exported function)

`/home/fryorcraken/src/logos-co/logos-liblogos/src/logos_core/logos_core.h`. `nm -D` on the built library shows exactly these 20:

```c
void   logos_core_init(int argc, char *argv[]);                 // NO-OP (logos_core.cpp:14-17)
void   logos_core_add_modules_dir(const char* modules_dir);
void   logos_core_start();
void   logos_core_cleanup();
char** logos_core_get_loaded_modules();
char** logos_core_get_known_modules();
typedef enum { LOGOS_LOAD_MODULE_ONLY=0, LOGOS_LOAD_REQUIRED_DEPS=1, LOGOS_LOAD_REQUIRED_AND_OPTIONAL=2 } LogosLoadDeps;
int    logos_core_load_module(const char* module_name, LogosLoadDeps deps);
char*  logos_core_optional_load_report(const char* module_name);
int    logos_core_unload_module(const char* module_name, bool with_dependents);
char** logos_core_get_module_dependencies(const char* module_name, bool recursive);
char** logos_core_get_module_dependents(const char* module_name, bool recursive);
char** logos_core_get_module_optional_dependencies(const char* module_name);
char*  logos_core_get_modules_info();
char*  logos_core_process_module(const char* module_path);
char*  logos_core_get_token(const char* key);
char*  logos_core_get_module_stats();
void   logos_core_set_persistence_base_path(const char* path);
void   logos_core_set_module_transports(const char* module_name, const char* transport_set_json);
void   logos_core_set_access_policy(const char* policy_json);
void   logos_core_refresh_modules();
```

- **`load_module` signature.** It now takes an enum. Values 0 and 1 are kept ABI-compatible with the old `bool` (`logos_core.h:64-71`). The README still shows `bool with_dependencies` (`README.md:153`), which is stale.
- **Blocking.** `load_module` blocks until the child reports that its plugin loaded (`logos_core.h:110-116`; `module_manager.cpp:950-973`). The wait is 10 s, dropping to 1 s once a host is seen to stay silent.
- **Exported internals.** `liblogos_core.so` exports about 1032 dynamic symbols, because nothing sets `-fvisibility=hidden` on ELF. They include `ModuleManager::loaders()`, `LogosCore::ModuleLoaderRegistry::{registerLoader,clearForTests,select}`, `LogosCore::makeContainer()` and `SubprocessContainer::launch`.

### 3. How module loading works now

#### Discovery

`logos_core_start()` runs `logos::initLogging(); LogosInstance::id(); anchorCoreApi(); discoverInstalledModules(); initializeCapabilityModule(); initializeModulesState();` (`logos_core.cpp:23-33`).

- **Scanning.** Discovery delegates to `PackageManagerLib::getInstalledModules()`, with the first modules dir as the embedded dir plus the others (`module_registry.cpp:120-128`).
  - It enumerates `<dir>/<name>/manifest.json`, keeps only `type == "core"`, and resolves `main` through `lgx_resolve_main` against `platformVariantsToTry()` (`package_manager_lib.cpp:725-801, 963-969`).
- **Metadata and identity.**
  - Metadata comes from the plugin's embedded Qt metadata through `QPluginLoader::metaData()`, run in the parent (`logos-module/src/module_metadata.cpp:8-11`).
  - The embedded name must equal the package name (`module_registry.cpp:241-246`).
  - Names are checked against `[A-Za-z0-9_-]{1,64}`.

#### Loading

- **Descriptor.** `loadModuleInternal` builds a `ModuleDescriptor` with name, path, `format = "qt-plugin"` (hard-coded), dependencies, modulesDirs, persistence path, transport JSON and raw metadata (`module_manager.cpp:765-823`).
- **Gates.** It applies a protocol-major gate and a dependency version-range gate.
- **Loader selection.** It calls `loaderRegistry().select(desc)`, spawns under `spawnMutex`, mints a UUID token, calls `sendToken`, then `awaitLoad`, `commitLoad`, and `informModuleToken` to capability_module.

#### Container and loader split (new since the monolithic days)

- **Contracts.** Both are Qt-free and header-only.
  - `logos-container`: `ModuleContainer { id, canHandle, launch(desc, hostBinary, args, onTerminated, out), sendToken, awaitLoad, terminate, terminateAll, hasModule, pid, getAllPids }` (`logos-container/src/logos_container/module_container.h:19-60`).
  - `logos-module-loader`: `ModuleFormatLoader { id, canHandle, resolveHostBinary, buildArguments }` (`module_format_loader.h:14-27`). A "format loader" is therefore inherently a host-binary-plus-argv recipe.
- **Composition.** `CompositeModuleLoader::load` resolves the host binary, builds the args and calls `container->launch` (`composite_module_loader.cpp:21-31`).
- **Choosing the default.** It is chosen at link time: `loaderRegistry()` does `call_once { makeContainer(); makeFormatLoader(); registerLoader(Composite) }` (`module_manager.cpp:306-316`).
  - The implementations reach the build through `find_package(LogosContainerImpl)` / `find_package(LogosFormatLoaderImpl)` (`src/CMakeLists.txt:143,163`).
  - Those packages are put on `CMAKE_PREFIX_PATH` by the flake slots `default-container` and `default-module-loader` (`flake.nix:27,32,108-109`).

#### Is each module in its own process?

Yes, by default. `SubprocessContainer` (`logos-container-subprocess/src/subprocess_container.cpp`) works as follows:

- It creates stdin, stdout and stderr pipes and marks them close-on-exec.
- It `posix_spawn`s the host from a leaked, process-lifetime `SpawnRuntime` thread. That thread exists because the host's `PR_SET_PDEATHSIG` follows the spawning thread (`:96-110, 499-576, 887-991`).
- It appends `--token-source stdin`, writes the token and a newline into the child's stdin, then closes it (`:809-811, 993-1047`).
- It parses a load-status line from the child's stdout, relays output lines through spdlog, and waits for exit on one asio io thread (`:67-83, 231-360`).
- Teardown sends SIGTERM, then terminates after 5 s (`:689-737`).
- **Child side.** `logos_host_qt` (`logos-module-loader-qt/src/host/logos_host.cpp`):
  - Calls `setsid()`, `prctl(PR_SET_PDEATHSIG, SIGKILL)` and starts a getppid watchdog thread.
  - Installs a crash handler (sigaltstack + `backtrace()`), creates a `QCoreApplication`, and installs a SIGTERM self-pipe.
  - Reads the token, loads the plugin with `QPluginLoader` (`LogosModule::loadFromPath`), checks `name()`, then `new LogosAPI(name[, transports], plugin)`, sets properties, `registerObject`, reports status, and runs `exec()` (`:320-455`; `module_initializer.cpp:57-200`).

#### Is there an in-process option?

**No implementation exists in any local repo.** A grep for `makeContainer()`, `InProcessContainer` and `inprocess_container` finds only the subprocess implementation. The contract anticipates one: the header says "subprocess, docker, in-process" and `LoadedModuleHandle.pid = -1 // in-proc`. `docs/spec.md:321-322` lists it as Future Work.

**There is also no runtime switch**, for three reasons:
- `desc.format` is always `"qt-plugin"` and `desc.loaderConfig` is never filled, so pinning a loader by id is unreachable from metadata.
- `select()` returns the first `canHandle()`, and `SubprocessContainer::canHandle` is always `true`.
- The default is registered first, lazily.

A loader merely *added* with `registerLoader()` never wins. The practical options are:

- **(a) Build-time.** A new package exposing `LogosContainerImpl::impl` plus `makeContainer()`, passed as `--override-input default-container` (README.md:277-305).
- **(b) Runtime, C++ only.** `ModuleManager::loaders().clearForTests(); registerLoader(myLoader);` before `logos_core_start()`. This is exactly what `tests/test_module_loader_abstraction.cpp:99-100` does. The symbols are exported, but `module_manager.h` and friends are not installed.

Pairing an in-process container with the stock `QtPluginFormatLoader` still requires `resolveHostBinary` to find an existing file (via `LOGOS_HOST_PATH`, the exe directory, or `<modulesDir>/../bin`). Otherwise the composite load fails before the container is called (`composite_module_loader.cpp:25-27`; `qt_plugin_format_loader.cpp:118-149`).

#### The separate SDK-level in-process mode

`logos-protocol` has `LogosMode::Local`, "in-process PluginRegistry (mobile apps, single process)", which keeps objects as `QCoreApplication` properties (`logos_mode.h:7-18`; `plugin_registry.h`; `logos_transport_factory.cpp:26-49`).

- It is a per-image static, and statically linked plugins cannot see the host's setting (`logos_mode.h:80-82`).
- liblogos never sets it, and basecamp has it commented out (`logos-basecamp/app/main.cpp:85-86`).
- It is not a drop-in route for loading modules in-process.

#### Per-image singletons, relevant to any in-process design

- Module plugins link **static** `logos_protocol` and `logos_qt_host`. In-process hosts must link the **shared** ones so that `TokenManager` and `LogosAPIClient` exist once (`logos-plugin-qt/cpp/CMakeLists.txt:97-112`; liblogos `src/CMakeLists.txt:252-255`).
- `readelf` confirms `capability_module_plugin.so` has no `liblogos_protocol.so` in NEEDED.
- The host already bridges images by passing `authToken` and `hostServices` as QObject properties (`module_initializer.cpp:136-184`).
- logos-protocol provides per-identity token stores for "a host that loads several modules in one image" (`logos-protocol/README.md:36-62`).
- An in-process container should repeat `initializeLogosAPI` exactly, including the capability_module host-services grant `token_registry,token_delivery` (`qt_plugin_format_loader.cpp:57-62`).

### 4. Qt dependency map and build wiring

| Component | Build | Qt | Other deps |
| --- | --- | --- | --- |
| liblogos_core (SHARED) | CMake; `-D*_ROOT` + `find_package(LogosContainerImpl/LogosFormatLoaderImpl)` | Core, RemoteObjects (Network also in NEEDED) | Boost (process, filesystem, ...), spdlog/fmt, nlohmann, OpenSSL, package_manager_lib, liblgx |
| logos-protocol (static + shared `liblogos_protocol`) | CMake, exports `logos-protocol::` | Core, RemoteObjects (only the `lp_*` header is Qt-free) | Boost headers/system, OpenSSL, nlohmann |
| logos-plugin-qt/cpp → logos-qt-host (static + shared) | CMake, `find_package(logos-protocol)` | Core, RemoteObjects | protocol |
| logos-qt-sdk | INTERFACE targets over qt-host + protocol + cpp-sdk | Core, RemoteObjects | — |
| logos-cpp-sdk | INTERFACE, header-only | none | nlohmann |
| logos-module (static) | CMake | Qt6 Core (QPluginLoader) | liblgx |
| logos-container, logos-module-loader | header-only | none | nlohmann |
| logos-container-subprocess (static) | CMake + `LogosContainerImplConfig.cmake` | none | Boost.Process, spdlog |
| logos-module-loader-qt: parent lib (static) | CMake + `LogosFormatLoaderImplConfig.cmake` | none | Boost.Filesystem (boost::dll), spdlog |
| logos-module-loader-qt: `logos_host_qt` (exe) | same | Core, Network, RemoteObjects | qt-sdk, protocol, logos-module, CLI11, OpenSSL |
| process-stats (static) | CMake | none | nlohmann |
| package_manager_lib + liblgx | CMake | none | zlib, ICU 76, libsodium (from `readelf`) |

Evidence: the CMakeLists cited in the claims, plus `readelf` NEEDED output.

- **Locating dependencies outside Nix.** Pass `-DLOGOS_CPP_SDK_ROOT`, `LOGOS_PROTOCOL_ROOT`, `LOGOS_QT_HOST_ROOT`, `LOGOS_MODULE_ROOT`, `PROCESS_STATS_ROOT`, `LOGOS_CONTAINER_ROOT`, `LOGOS_MODULE_LOADER_ROOT` and `LOGOS_PACKAGE_MANAGER_ROOT` (`nix/default.nix:71-91`), and put the two implementation prefixes on `CMAKE_PREFIX_PATH`.
- **Test gating.** liblogos has `LOGOS_BUILD_TESTS` and process-stats has `PROCESS_STATS_BUILD_TESTS`. logos-container-subprocess and logos-module-loader-qt add `tests/` and a googletest FetchContent fallback **unconditionally**, so they need a patch or a GTest.
- **NDK find modes.** The NDK r27c default (legacy) toolchain sets `CMAKE_FIND_ROOT_PATH_MODE_{PACKAGE,LIBRARY,INCLUDE}=ONLY` (`android-legacy.toolchain.cmake:302-311`). Every `find_package(... PATHS <root> NO_DEFAULT_PATH)` therefore needs its root on `CMAKE_FIND_ROOT_PATH` (inferred from standard CMake semantics).

#### Linux/glibc-only code to port for bionic

- **logos_host.** `<execinfo.h>` / `backtrace()` (bionic API 33), `prctl(PR_SET_PDEATHSIG)`, `setsid`, the getppid watchdog, `sigaltstack`.
- **Container.** `posix_spawn*` (API 28). The glibc-only `addclosefrom_np` path is gated on glibc 2.34+, so bionic falls back to a `/proc/self/fd` walk (fine).
- **Boost.Process v2.** It enables `pidfd_open` whenever `SYS_pidfd_open` exists (`boost/process/v2/detail/config.hpp:156-163`). Bionic's wrapper is API 31, and whether older app seccomp filters allow the raw syscall is unknown. `BOOST_PROCESS_V2_DISABLE_PIDFD_OPEN` turns it off.
- **logos-protocol.** `getgrnam_r` (API 24) and chown/chmod for the optional socket-permission policy.
- **process-stats.** Portable: its `__linux__` branch reads `/proc/<pid>/stat` and `/status` and calls `sysconf`, which works on bionic, and it returns zeros for pid ≤ 0.
- **Host binary lookup.** `boost::dll::program_location()` would resolve Android's `app_process` (inferred), so it is useless there.

### 5. The lgx format and platform variants

- **Format.** An `.lgx` is a gzipped tar containing `manifest.json`, `variants/<variant>/...` and optional root `assets/` (`nix-bundle-lgx/README.md`; the smoke test uses `tar -tzf`).
- **What producers emit.** nix-bundle-lgx names variants `linux-amd64`, `linux-arm64`, `darwin-amd64`, `darwin-arm64` and `windows-{x86_64,arm64}`, with a `-dev` suffix for the dev bundler (`nix-bundle-lgx/flake.nix:52-60`).
  - Dev payloads resolve their dependencies from `/nix/store`.
  - Portable payloads go through nix-bundle-dir, which rewrites RUNPATHs to `$ORIGIN` and **excludes host-provided** `Qt*`, `liblogos_core*`, `liblogos_sdk*`, `liblgx*`, `libz*` and ICU (`:349-371`).
- **How the variant is chosen.**
  - `lgx_host_variant()` is compile-time: `__APPLE__` gives darwin-*, `__linux__` gives linux-x86_64 / linux-arm64 / linux-x86, `_WIN32` gives windows-*. **There is no `__ANDROID__` branch**, so an Android arm64 build says `linux-arm64` (`/nix/store/7f6d5ba9jv4hkn2r923kxjxac271i5hn-source/src/core/platform_variant.cpp:51-76`).
  - Only the architecture is aliased; the OS half is matched verbatim (`:40-46`).
  - `PackageManagerLib::platformVariantsToTry()` appends `-dev` unless the library was compiled with `LGPM_PORTABLE_BUILD` (`package_manager_lib.cpp:1385-1407`). liblogos' own `LOGOS_PORTABLE_BUILD` define has no consumer in liblogos source.
  - The only override is the static C++ `PackageManagerLib::setPlatformVariantOverride()` (`package_manager_lib.h:361-374`).
- **Adding an Android variant.** An `android-arm64` variant name is legal but nothing emits or selects it. Two ways forward:
  - Write manifests with `linux-arm64[-dev]` keys pointing at NDK-built plugins. This is a hack, but it works because `lgx_host_variant()` returns `linux-arm64` under bionic.
  - Call the override early, or add an `__ANDROID__` branch upstream in logos-package.
- **Installed layout.** `modules/<name>/{manifest.json, <name>_plugin.so, variant, [manifest.sig], private deps...}`, for example lez_core ships `libwallet_ffi.so` (`/home/fryorcraken/src/fryorcraken/liblogos-electron-poc/modules/lez_core/`). lgpm extraction uses `std::filesystem::temp_directory_path()`, which honours TMPDIR.
- **How plugins are opened.** With `QPluginLoader` by absolute path: metadata in the parent, instance in the host (`logos-module/src/logos_module.cpp:95-105`). Plugin-private dependencies resolve through the plugin's RUNPATH (`$ORIGIN` for portable payloads).

### 6. What start and init require of the host process

- **A QCoreApplication created by the embedder.** `logos_core_init` ignores its arguments and creates nothing; `docs/spec.md:255` still claims it does.
- **An event loop on the start thread.** Core's LogosAPI(`"core"`) is anchored to the thread that calls `logos_core_start`, and outbound calls are posted to that thread (`module_manager.cpp:335-366, 1084-1089`; `logos_core.h:131-139`). That thread must pump a Qt event loop. Blocking RPCs spin nested loops.
- **Environment and paths** (none of this is read from config files):
  - `LOGOS_HOST_PATH` locates the host binary.
  - `LOGOS_INSTANCE_ID` is generated and exported with `qputenv` by `LogosInstance::id()`, and children inherit it.
  - `LOGOS_LOG_LEVEL` / `SPDLOG_LEVEL`, `LOGOS_SOCKET_GROUP` / `LOGOS_SOCKET_MODE`, `LOGOS_MOCK_FIXTURE`.
  - The persistence path comes from `logos_core_set_persistence_base_path`.
- **Processes and threads created.**
  - A `logos_host_qt` child for capability_module (if installed) and modules_state (if installed) at start, then one per loaded module.
  - One asio io thread and one spawn thread in the parent, and one watchdog thread per child.
- **Sockets.** Each module host binds a QtRO `QLocalServer` at `local:logos_<module>_<instanceId>`, a relative name, so the file is `QDir::tempPath()/logos_<module>_<id>` (`logos_instance.h:27-29`; `qt_socket_path.h:16-22`). Core binds nothing, because hosts listen lazily on `publishObject` (`remote_transport.cpp:660-677`).
  - Qt's `tempPath()` is `$TMPDIR`, else `_PATH_TMP`, else `/tmp` (qtbase 6.9 `qfilesystemengine_unix.cpp`). Bionic defines no `_PATH_TMP`.
  - Qt's own `QtLoader.java` sets `TMPDIR` to `getCacheDir()`. A Kotlin app not using Qt's Java loader must set TMPDIR itself. Without it the sockets go to `/tmp` and every load fails.
- **Android process rules.**
  - For targetSdk ≥ 29 an app cannot `execve()` files in its home directory, but `dlopen` of app-dir `.so` files is still allowed (Android 10 behavior-changes page).
  - The subprocess route therefore needs `logos_host_qt` in `nativeLibraryDir` plus `LOGOS_HOST_PATH`, minSdk 28 or higher (33 or higher for `backtrace`), and tolerance of the phantom-process limit (32 system-wide on Android 12+).
  - The in-process route avoids all of that.

### 7. The Electron POC compared with today's upstream

The POC's commits are dated **2026-09-18**, and it builds against the local liblogos checkout (`Makefile:38`), so it is about a week old, not months. Its central findings still match today's code:

- Loading uses the plain-C `logos_core_*` ABI.
- Consuming from another process uses the `lp_*` C ABI in `liblogos_protocol`.
- In-process calling needs Qt C++ `LogosAPIClient`.
- The embedder must construct the QCoreApplication.
- `load_module` blocks.
- There is one `logos_host` per module.
- `liblogos_qt_host.so` and `liblogos_protocol.so` ship shared.
- Qt is 6.9.2.

What differs or is missing:

1. It never mentions the container / format-loader abstraction or the `default-container` / `default-module-loader` slots, which is the lever for in-process hosting.
2. `NEXT.md:350` says LogosAPI ships from logos-liblogos. The code lives in logos-plugin-qt (logos-qt-host); liblogos only re-exports the headers (`src/CMakeLists.txt:17-25`, `nix/include.nix:55-87`).
3. It did not look at `LogosMode::Local` or an in-process container.
4. Upstream's own docs drift: README's `bool` signature for `load_module`, and spec.md's claim that init creates the QCoreApplication. The POC does not correct either.

