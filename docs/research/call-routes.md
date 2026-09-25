# Routes for calling a loaded module

> Research track `call-routes`, 2026-09-25. Written by a research agent and then checked by a
> second, adversarial agent, whose non-confirmed verdicts are listed under "Verifier".
> Claims are tagged verified-from-source / verified-by-experiment / inferred / open.
> Absolute paths point at the author's local checkouts (`~/src/logos-co`,
> `~/src/logos-blockchain`) at the revisions in [../investigation.md](../investigation.md);
> `.work/` paths are local scratch, not committed. The synthesis is in
> [../investigation.md](../investigation.md).


### Summary
Current upstream has no C function in liblogos_core for calling a module: logos_core.h exports 20 lifecycle, query and config functions and no call, invoke, event or provider entry point. The lp_* C ABI in logos-protocol (v0.9.0) does call modules, and it works from inside the process that runs liblogos_core over the default QtRO/LocalSocket transport. It needs no daemon, no core_service, no TCP and no token plumbing, and no LogosAPI C++. The host's TokenManager already holds each loaded module's root token (one shared liblogos_protocol.so), and lp_client_create builds Qt-affine clients on the thread that owns the QCoreApplication. I tested this on Linux x86_64 with the prebuilt liblogos. A pure-C main thread loaded lez_core with logos_core_load_module, then called version, name and account_id_to_base58 through lp_invoke; each round trip took 0-4 ms. The QCoreApplication, logos_core_start() and exec() all ran on one dedicated std::thread, and the lp_invoke_async callback came back on that thread. That thread-plus-lp_* setup is the recommended Android route: a JVM-attached Kotlin thread owns QCoreApplication, logos_core_start and exec(), and JNI worker threads call lp_* and logos_core_*. The only Qt C++ left is a file of about 60 lines that creates the QCoreApplication and runs its loop. Next best is an in-process LogosAPIClient JNI shim in Qt C++, the Electron 0.3.0 route, which uses the same thread model. An in-process core_service does not exist as a library, so it would mean porting about 1,100 lines of Qt C++ from logoscore-cli (about 1,700 with package ops); it is strictly worse than the LogosAPIClient shim. An out-of-process logosctl daemon is the least attractive option on Android. Risks that apply to every route: Qt 6.9's libQt6Core JNI_OnLoad requires the org.qtproject.qt.android.QtNative Java class; TMPDIR must be set because QtRO sockets go in QDir::tempPath(); and every lp_* caller blocks for as long as the Qt thread is busy or stuck.

### Claims
- [C1|critical|verified-from-source] liblogos_core's public C ABI (logos_core.h) exports 20 functions (init/add_modules_dir/start/cleanup, get_loaded/known_modules, load/unload_module, optional_load_report, get_module_dependencies/dependents/optional_dependencies, get_modules_info, process_module, get_token, get_module_stats, set_persistence_base_path, set_module_transports, set_access_policy, refresh_modules). None calls a module method, subscribes to events, or registers a provider.
- [C2|high|verified-from-source] The old C call entry points (logos_core_call_plugin_method_async, logos_core_register_event_listener, logos_core_process_events, logos_core_exec, logos_core_set_mode) no longer exist in liblogos. Only stale consumers still reference them: logos-nim-sdk (last commit 2026-03-25) and logos-basecamp/qt-ios.
- [C3|high|verified-from-source] logos_core_init() is now a no-op. The embedder must create a QCoreApplication itself before logos_core_start(). docs/spec.md:255 still says logos_core_init creates one, which is stale. No C function creates or pumps a Qt event loop.
- [C4|critical|verified-by-experiment] logos-protocol's lp_* C ABI (v0.9.0) is the language-neutral call path. It has 36 exported functions: lp_client_create/destroy, lp_invoke (blocking, default 20s timeout), lp_invoke_async (callback on the client's owner thread), lp_subscribe/lp_unsubscribe, per-target subscription status/generation/options/rearm, lp_get_methods, the lp_token_* family, lp_grant_host_services, lp_inform_module_token(_to) and lp_provider_*. The data model is JSON in UTF-8 strings, and returned strings are freed with lp_string_free. The header has no includes, so no Qt headers are needed. liblogos_protocol.so itself still links Qt6Core, Qt6Network and Qt6RemoteObjects.
- [C5|critical|verified-from-source] Threading model of lp_* on a Qt-affine transport (the default LocalSocket/QtRO, or 'local' mode): the client is constructed on the QCoreApplication's thread no matter which thread calls. Every later call is marshalled there with a BlockingQueuedConnection. Async result, event and status callbacks fire on that owner thread. The plain tcp/tcp_ssl and mock transports keep the calling thread and need no Qt loop.
- [C6|critical|verified-by-experiment] In the process that runs liblogos_core, lp_* calls to a loaded module are authorized with no handshake and no capability_module round trip. After each load, core saves the module's freshly minted root token in TokenManager::instance() under the module's name. LogosAPIClient presents a cached token before it ever mints one. The module treats that root token as its own host-issued credential and authorizes the caller as the host anchor.
- [C7|high|verified-by-experiment] There is exactly one TokenManager per process. liblogos_core does not define TokenManager; it NEEDS the shared liblogos_protocol.so, which is the only image defining TokenManager::instance(). So a JNI shim that links the same liblogos_protocol.so and calls lp_* sees core's token store.
- [C8|critical|verified-by-experiment] End-to-end experiment on Linux x86_64 with the prebuilt liblogos (Qt 6.9.2, protocol 0.9.0). One dedicated std::thread created the QCoreApplication, called logos_core_init/add_modules_dir/set_persistence_base_path/logos_core_start and then exec(). A pure-C main thread (no Qt headers) called logos_core_load_module("lez_core"), which returned 1 in 23-28 ms. It then called lp_client_create, which took 0 ms, and lp_invoke for version ("0.3.0"), name ("lez_core") and account_id_to_base58(0x00..01) ("11111111111111111111111111111112"), each in 0-4 ms. The lp_invoke_async callback fired on the Qt thread's id. No 'not created in main() thread' warning appeared.
- [C9|critical|verified-by-experiment] The Electron POC found that 'a dedicated Qt thread does NOT work'. That applies only when the Qt objects are created on a different thread from the one running exec(). If QCoreApplication, logos_core_start (which anchors core's LogosAPI) and exec() all run on one dedicated thread, and lp_* clients are auto-constructed on the QCoreApplication thread, a dedicated thread works.
- [C10|high|verified-by-experiment] The QtRO LocalSocket transport creates filesystem Unix sockets named logos_<module>_<instanceId> under QDir::tempPath(), which is $TMPDIR or /tmp. An Android host that is not a Qt app must therefore set TMPDIR to an app-private directory, such as the cache dir, before starting liblogos. Module subprocesses inherit it.
- [C11|medium|verified-by-experiment] lp_* limitations relevant to a Kotlin host: (1) lp_subscribe refuses an empty event name, so there is no wildcard subscription; LogosAPIClient::onEventWhenAvailable, which the Electron POC used, does accept one. (2) An unknown method name returns LP_OK with 'null', indistinguishable from a legitimate null. (3) lp_get_methods returned '[]' for the lez_core 0.4.1 package, so introspection cannot be relied on and names must come from the module's header or .lidl. (4) A module that is not loaded gives rc=-4 with code 'object_unavailable' after the timeout.
- [C12|medium|verified-from-source] The lp_provider_* API (C provider registration, the Electron inventory §7.5 ask) is still groundwork. lp_provider_register returns LP_OK but only stores the callbacks and opens no socket. lp_provider_emit_event and lp_provider_save_token return LP_ERR_UNSUPPORTED. A Kotlin app therefore cannot yet publish itself as a module through the C ABI.
- [C13|medium|verified-from-source] The plain (TCP) transport still publishes only ModuleProxy objects and rejects the '<module>__handshake' surface with the same 'for now' warning the Electron POC hit. Upstream has not changed the plain-transport limitation behind the logos-js-sdk hangs.
- [C14|high|verified-from-source] core_service is not part of liblogos. CoreServiceImpl and its dispatch are compiled only into the logosctl and logoscore executables. It is Qt C++: it includes logos_api.h and QCoreApplication/QEventLoop and depends on package_ops. The daemon hosts it as LogosAPI("core_service", transports) plus provider->registerObject, with a TokenStore validator. Each boot it issues an 'auto' token (local_only), saves it as INBOUND for 'cli_client' and writes it to client/auto.json. Clients save it outbound under 'cli_client' and 'core_service'. No liblogos config flag or API enables core_service in an embedding process.
- [C15|high|verified-from-source] None of the non-C++ SDKs gives an embedding host an in-process, daemon-free C call path. logos-logoscore-py spawns a 'logoscore <subcommand> --json' subprocess per call. logos-rust-sdk is a module-side consumer: its lp_* calls resolve against the protocol archive inside a module plugin, and callerBuildSupport only links liblogos_protocol for out-of-plugin binaries. logos-js-sdk is an out-of-process, plain-transport lp_* consumer with no Qt loop and no liblogos_core. logos-nim-sdk binds removed symbols. All the live ones do call modules through lp_*, the same ABI recommended here.
- [C16|high|verified-by-experiment] Core's own outbound work, such as the capability registration after a load, runs on the thread that called logos_core_start(). A load from another thread returns once the module is up, and that registration completes asynchronously on the owner thread, which must be running its event loop. Loading from a JNI worker thread while the Qt thread runs exec() works.
- [C17|high|inferred] Marshalling onto the owner thread uses BlockingQueuedConnection with no timeout, and timeout_ms applies only inside the marshalled lambda. If the Qt thread is blocked, for example by a synchronous logos_core_load_module run on it or by a Kotlin callback doing slow work, every JNI caller of lp_client_create or lp_invoke waits. A wedged Qt thread hangs them indefinitely.
- [C18|high|verified-from-source] On Android, Qt 6.9's libQt6Core defines JNI_OnLoad, which calls QtAndroidPrivate::initJNI. That does FindClass("org/qtproject/qt/android/QtNative") and returns JNI_ERR if the class is missing. A plain Kotlin app that System.loadLibrary's Qt Core without Qt's Java classes will fail to load it. Loading Qt Core only as a transitive dlopen dependency skips JNI_OnLoad and leaves Qt's JavaVM unset. This affects every in-process route (a', b, c) equally.
- [C19|high|verified-from-source] On Android, Qt itself runs its event loop on a dedicated thread (qtMainLoopThread) separate from the Android UI thread. A dedicated, JVM-attached native thread that owns QCoreApplication and exec() matches Qt's own design, and a Looper-driven pump is not needed.
- [C20|medium|inferred] An out-of-process daemon (logosctl as a child process) is the least attractive route on Android. It needs an Android build of logoscore-cli, a second copy of the runtime, a binary shipped in nativeLibraryDir because execve from the app's writable home is blocked for targetSdk>=29, token rotation per boot, TCP ports and insecure_tcp, and supervision of a process Android may kill. The Electron POC also hit daemon-lifecycle bugs: 'daemon stop' cannot stop a tcp-only daemon, a silent death with local+tcp, and stale-token hangs.
- [C21|medium|verified-from-source] liblogos_core's C string returns (char** and char*) are allocated with new[] and must be released with delete[], not free(). lp_* strings are released with lp_string_free, which calls std::free. The JNI shim should therefore be C++ (Qt headers not required) so it can delete[] correctly.

### Open questions
- Can libQt6Core (Qt 6.9) be loaded in a plain Kotlin app? Its JNI_OnLoad needs org.qtproject.qt.android.QtNative with static activity() and service() methods. Is shipping Qt's Android Java classes enough when activity() returns null, or must Qt Core load without JNI_OnLoad, and which QtCore/QtRO features then break? This affects every in-process route; the Qt-on-Android research should answer it.
- Event delivery through lp_subscribe in the liblogos process was not exercised against a real emitting module (lez_core emits no events). It wraps the same onEventWhenAvailable the Electron exp_event verified. Confirm with a module that emits, such as delivery_module after createNode, or a logos-test-modules module with events.
- Does Android SELinux allow an untrusted_app to create and connect filesystem Unix sockets for QtRO under its cache dir? And can the logos_host subprocesses, launched from nativeLibraryDir, reach them?
- Inter-module communication demo: liblogos_lez_rln_module 2.1.0 depends on lez_core, but the current v3 source dropped that dependency (logos-rln-modules/logos-lez-rln-module/rust-lib/liblogos_lez_rln_module.lidl:12-13). lez-programs token_module and amm_module declare dependencies ["lez_core"] and are the likely candidates; which of their methods call lez_core without network is unverified.
- Which origin should the host use in lp_client_create? On the normal path the cached root token authorizes whatever the origin is. On the token-miss or reject fallback (requestModule via capability_module) under an 'enforce' access policy, an unknown origin like 'android_host' may be refused, while 'core_service' is in kTrustedCallers. This was not tested.
- Would a plain-TCP lp_* client that calls a module directly with a pre-seeded root token (lp_token_save) work on protocol 0.9.0? The Electron hang was measured against an earlier build. This only matters for routes (b) and (d).
- lp_get_methods returned [] for lez_core 0.4.1. Is that a property of that build's generated glue or a general gap for universal (cpp-generator) modules?

### Recommendations
- Adopt route (a'): call modules in-process through the lp_* C ABI over the default QtRO/LocalSocket transport. Do not use LogosAPI C++, core_service, TCP or a daemon. It was verified end to end on Linux (experiment C8); next, reproduce it on the arm64 AVD.
- Thread model: in Kotlin, create one long-lived Thread named 'logos-qt'. It calls a blocking JNI nativeRun() that does setenv TMPDIR/LOGOS_HOST_PATH, new QCoreApplication, logos_core_init, logos_core_add_modules_dir, logos_core_set_persistence_base_path, logos_core_start, signals ready, runs QCoreApplication::exec(), and calls logos_core_cleanup() after exec returns. Create no Qt object on any other thread before this, and ideally load the native libraries from this thread too, so it becomes Qt's main thread.
- Make every other JNI entry point callable from Kotlin coroutines on Dispatchers.IO, never from the Android main thread: logos_core_load_module, lp_client_create, lp_invoke, lp_invoke_async, lp_subscribe and lp_unsubscribe. Stop by posting QCoreApplication::quit with a queued QMetaObject::invokeMethod.
- Callbacks from lp_invoke_async, lp_subscribe and the status callback arrive on the Qt thread. That thread is JVM-attached because Kotlin created it. Hand each result straight to a CompletableDeferred or a Channel/SharedFlow.tryEmit, and never block or re-enter lp_invoke synchronously inside a callback.
- Write the shim as C++ with extern "C" JNI functions, so logos_core_* returns can be released with delete[] and lp_* returns with lp_string_free. Keep Qt headers confined to a roughly 60-line qt_loop.cpp that only includes <QCoreApplication>. Estimate about 350-450 native lines plus about 200 Kotlin lines; the experiment used 187 lines of native code for the whole call path.
- Use lp_client_create(module, "core_service", NULL, NULL). Cache one lp_client per target module, since construction is cheap and blocks on the Qt thread. Pass explicit timeout_ms. Treat rc=LP_ERR_UNAVAILABLE with code 'object_unavailable' as 'not loaded'. Take method and event names from module headers or .lidl, not from lp_get_methods.
- Set TMPDIR to context.cacheDir, a short path well under the 108-byte sun_path limit, before any Qt or liblogos call. Ship Qt's Android Java QtNative class, or otherwise resolve libQt6Core's JNI_OnLoad requirement; this needs a spike first.
- Keep route (c), an in-process LogosAPI/LogosAPIClient Qt C++ JNI shim with the same thread model, only as a fallback: for wildcard event subscription, or if lp_* shows a gap on Android. It adds the liblogos_qt_host C++ ABI coupling and the nlohmann 3.11.x ABI pin.
- Do not pursue route (b), in-process core_service with lp_* over loopback. It is not a liblogos feature and would mean porting about 1,100 lines of Qt C++ from logos-logoscore-cli (about 1,700 with package_ops) on top of route (c). Do not pursue route (d), a logosctl child process, on Android.
- For the inter-module demo, have the Kotlin host call a method on a LEZ program module (token_module or amm_module, both with dependencies ["lez_core"]) that internally calls lez_core over liblogos' QtRO transport. The host glue stays the same generic lp_invoke.

### Verifier (non-confirmed only)
- [C2] partially-correct: The removed entry points really are gone from liblogos. The list of stale consumers is incomplete, though. /home/fryorcraken/src/logos-co/logos-irc-module/example/main.cpp:22,31,285 also declares and calls logos_core_exec and logos_core_call_plugin_method_async. The legacy /home/fryorcraken/src/logos-co/logos-core-poc tree (its own logos-liblogos, logos-js-sdk and logos-nim-sdk copies, plus examples) still defines and uses them too. A further point: logos-nim-sdk resolves these with requireSym, so it would fail at load time against the current liblogos_core.so.
- [C10] partially-correct: The mechanism is right, but the claim leaves out a hard constraint that was verified by experiment. The full socket path, TMPDIR + '/logos_<module>_<12-hex instanceId>', must fit in sun_path (108 bytes including the NUL). With TMPDIR=/home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/verify-call-routes/t (82 chars), capability_module's path is 118 bytes. QtRO listen then fails with 'QRemoteObjectNode::ListenFailed', the module subprocess CRASHES with SIGSEGV, and logos_core_load_module returns 0. With a 62-character TMPDIR everything works. So the Android TMPDIR has to be both app-private and SHORT: a cache dir such as /data/user/0/<pkg>/cache is fine for typical package and module names, but the budget should be asserted in the shim. Also, without TMPDIR, Qt 6.9 falls back to nativeTempPath() (qfilesystemengine_unix.cpp), not necessarily /tmp. Neither is app-writable on Android. Qt-based Android apps get TMPDIR from Qt's Java loader, which a plain Kotlin app lacks.

Confirmed: C1, C3, C4, C5, C6, C7, C8, C9, C14, C15, C16, C17, C18, C19

### Verifier missed findings
- The sun_path limit kills modules when TMPDIR is long (verified by experiment). QtRO socket paths are TMPDIR + '/logos_<module>_<12hex>'. With an 82-character TMPDIR the capability_module path came to 118 bytes, which is more than UNIX_PATH_MAX 108 (NDK linux/un.h:10). The result was 'QRemoteObjectNode::ListenFailed', then the module subprocess crashed with SIGSEGV ('FATAL: module 'capability_module' crashed (signal 11)'), and logos_core_load_module returned 0 in 134 ms. The log is .work/verify-call-routes/run-longtmpdir.log from verify-call-routes-exp.sh. The Android shim should assert len(TMPDIR) + 19 + len(longest module name) < 108.
- On the recommended in-process QtRO route, lp_get_methods always returns '[]'. /home/fryorcraken/src/logos-co/logos-protocol/cpp/implementations/qt_remote/remote_transport.cpp:445-450 reads 'Remote introspection not implemented — callers should use the local module inspection tools (lm) instead.' Verified: both lez_core and capability_module return '[]' over LocalSocket while calls to them succeed. The Kotlin host therefore cannot discover method names at runtime; it has to take them from metadata, LIDL or lm. This also undercuts the Electron POC's diagnosis (NEXT.md:211-226) that 'capability_module publishes 0 methods' explains the hangs: 0 methods from getMethods is not evidence that nothing is published.
- Unknown method names are indistinguishable from a null result. lp_invoke returns LP_OK with 'null' (/home/fryorcraken/src/logos-co/logos-protocol/cpp/logos_protocol.h:461-462, 490-495 'an unknown method name ... answers ... with a bare null'). The researcher's own log (.work/exp-call-routes/run.log:22) shows 'lp_invoke(no_such_method_xyz, []) rc=0 ... result=null'. The JNI layer has to validate method names itself.
- The lp_provider_* surface is a non-functional stub. lp_provider_register opens no socket, and lp_provider_emit_event and lp_provider_save_token return LP_ERR_UNSUPPORTED (/home/fryorcraken/src/logos-co/logos-protocol/cpp/logos_protocol.cpp:953-988; /home/fryorcraken/src/logos-co/logos-js-sdk/README.md:94,102-104 'logos-protocol#12 is still open'). The Android host can consume modules but cannot expose itself as a module through any C ABI. Inter-module communication has to be between loaded modules, or go through LogosAPIProvider in Qt C++.
- In-process host calls carry host-anchor authority for ANY origin string. A client with origin 'totally_arbitrary_origin' called lez_core successfully (verify-call-routes run.log: 'other-origin lp_invoke(name) rc=0 in 1 ms'), because all non-isolated origins share TokenManager::instance(), which holds every module's root token (logos_protocol.h:751-760). The access policy set by logos_core_set_access_policy is enforced only by capability_module at token minting (logos_core.h:252-256), so it does not constrain the Kotlin host. Per-origin restriction would need lp_token_isolate_identity plus lp_token_adopt_credential.
- A pure-C JNI shim cannot correctly free logos_core_* results. liblogos allocates them with new[] and new char*[], so delete[] is required and free() is undefined behaviour (/nix/store/p3h34m6qaz8962fqwp1bsc0grh2klg3l-logos-cpp-sdk-lib-0.2.0/include/logos_host_core.h:16-20,131-155; module_manager.cpp:326-331). The researcher's main.c:80-82 deliberately leaks. The shim needs a small C++ helper (as in .work/verify-call-routes/qt_loop.cpp qtloop_free_core_string) or can use logos::host::LogosCore. lp_* strings, by contrast, are freed with lp_string_free.
- liblogos_core.so itself directly NEEDs libQt6Core, libQt6Network, libQt6RemoteObjects, boost_process/context/filesystem/date_time/atomic/system, spdlog, fmt, ssl/crypto, liblgx.so and libpackage_manager_lib.so (readelf in verify-call-routes-elf.sh). Every route, (a) through (c), has to cross-compile and ship this whole closure for arm64-v8a, not only liblogos_protocol and Qt Core.
- A Qt-free lp client needs BOTH transports to be plain. qtAffine = needsQtEventLoop(target) || needsQtEventLoop(capability) (/home/fryorcraken/src/logos-co/logos-protocol/cpp/logos_protocol.cpp:288-289). A tcp target with a NULL capability transport, under the LocalSocket default, is still marshalled to the Qt thread.
- Upstream design guidance for the JNI shim: never hold a lock across lp_client_create on a Qt-affine transport. Construct outside any lock and publish with a CAS, because the Qt thread may be waiting on that same lock (/nix/store/p3h34m6qaz8962fqwp1bsc0grh2klg3l-logos-cpp-sdk-lib-0.2.0/include/logos_lp_client.h:476-500). lp_client_destroy off the owner thread defers deletion with deleteLater and leaks if the loop has already stopped (logos_protocol.cpp:343-351).
- The experiment's lez_core is the Electron POC's prebuilt package (manifest version 0.4.1, metadata logos_protocol_version 0.2.0), running against a 0.9.0 host and capability_module. The run shows cross-minor interop within MAJOR 0. It did not test a lez_core rebuilt from current logos-execution-zone-module source, and its 'version' method returns "0.3.0", not the manifest's 0.4.1 (verify-call-routes run.log).
- The only module container that exists is SubprocessContainer (/home/fryorcraken/src/logos-co/logos-container-subprocess/src/subprocess_container.h:14). 'In-process' containers are only mentioned as a possibility in /home/fryorcraken/src/logos-co/logos-liblogos/src/logos_core/module_manager.h:17-22, and registering one needs the unexported C++ ModuleManager::loaders(). Every Android call route therefore still dials a logos_host child process over a LocalSocket. The earlier mobile port, logos-basecamp/qt-ios/main.cpp:72, used the removed logos_core_set_mode(1) local mode, which has no current equivalent in liblogos.

---

## Full report

## Call routes for a Kotlin/JNI host: how an Android app should call a module loaded by liblogos_core

### TL;DR

- **liblogos_core has no C function for calling a module.** `logos_core.h` has 20 functions covering lifecycle, queries and config. None of them calls a method, subscribes to events or registers a provider (`/home/fryorcraken/src/logos-co/logos-liblogos/src/logos_core/logos_core.h:37-263`; confirmed with `nm -D`). The old C call functions (`logos_core_call_plugin_method_async`, `logos_core_process_events`, `logos_core_exec`) are gone. Only stale consumers still reference them: `logos-nim-sdk/logos_api.nim:30-42` and `logos-basecamp/qt-ios/main.cpp:178`.
- **The C call path that does exist is logos-protocol's `lp_*` ABI (v0.9.0).** It also works inside the process that runs liblogos_core, over the default QtRO/LocalSocket transport:
  - no daemon, no core_service, no TCP;
  - no token plumbing;
  - no `LogosAPI` C++.

  I verified this by experiment on Linux x86_64 against the prebuilt liblogos (Qt 6.9.2). A pure-C thread loaded `lez_core` and called `version`, `name` and `account_id_to_base58` with `lp_invoke`, in 0-4 ms each. The Qt event loop ran on a separate dedicated thread.
- **Recommended Android route:**
  - One JVM-attached Kotlin thread creates `QCoreApplication`, calls `logos_core_start()`, then runs `exec()`.
  - JNI worker threads call `logos_core_*` and `lp_*`.
  - The only Qt C++ left is a ~60-line loop file.

### 1. Current public C ABIs

#### 1.1 liblogos_core (`logos_core.h`)

**What it exports.** `nm -D` on `/nix/store/vv8n977yf0bfz9309rmfz9abyvms4km2-logos-liblogos-bin-0.1.0/lib/liblogos_core.so` lists exactly these 20 functions:

- lifecycle: `init`, `add_modules_dir`, `start`, `cleanup`
- queries: `get_loaded_modules`, `get_known_modules`, `get_module_dependencies`, `get_module_dependents`, `get_module_optional_dependencies`, `get_modules_info`, `get_module_stats`, `optional_load_report`
- module control: `load_module` (takes a `LogosLoadDeps` enum), `unload_module`, `process_module`, `refresh_modules`
- tokens: `get_token`
- config: `set_persistence_base_path`, `set_module_transports`, `set_access_policy`

**Qt requirement.** No Qt headers are needed to call these. The process still needs a `QCoreApplication`:

- `logos_core_init` is a no-op (`logos_core.cpp:14-17`).
- The doctest says the embedder must create the `QCoreApplication` ("QCoreApplication should no longer be needed but it's pending some changes", `doctests/liblogos-as-a-library.test.yaml:8`).
- `docs/spec.md:255` still claims `logos_core_init` creates one. That is stale.
- The same doctest says plainly: "The C API loads and manages modules; it does not call their methods" (`:346-347`).

**Threading contract** (`logos_core.h:118-139`):

- Loads of different modules may run concurrently.
- Core's outbound calls run on the thread that called `logos_core_start()`: inline on that thread, posted to it otherwise.
- A load made from another thread finishes its capability registration asynchronously, and needs the owner thread to be running its event loop.
- `logos_core_start()` anchors core's own `LogosAPI("core")` on the Qt main thread (`module_manager.cpp:343-346, 1084-1089`).

**Memory.** Strings returned by `logos_core_*` are allocated with `new[]` and must be freed with `delete[]`, not `free()` (`logos-cpp-sdk/cpp/logos_host_core.h:16-20,131-155`; `logos_core.cpp:114`). Write the JNI shim in C++ for that reason. It does not need Qt headers.

#### 1.2 logos-protocol (`logos_protocol.h`, liblogos_protocol.so)

**Scope.** This is the "one seam every Logos SDK builds on" (`logos_protocol.h:4-59`). `nm` shows 36 exported `lp_*` symbols. Data is JSON in UTF-8 strings, and bytes travel as `{"_bytes":"<base64url>"}`. Returned strings are freed with `lp_string_free` (which calls `std::free`).

**Consumer functions:**

- `lp_client_create(target, origin, target_transport_json, capability_transport_json)` and `lp_client_destroy`
- `lp_invoke(client, method, args_json, timeout_ms, &out, &err)`: blocks; `timeout_ms <= 0` means the 20 s default
- `lp_invoke_async(..., lp_result_cb, user_data)`: the callback fires exactly once, on the client's owner thread
- `lp_subscribe` and `lp_unsubscribe`
- Per-target subscription state: `lp_client_set_subscription_status_cb` (ARMED / LOST / HELD / ABANDONED), `lp_client_subscription_generation`, `lp_client_set_subscription_options`, `lp_client_rearm_subscriptions`
- `lp_pending_subscriptions`, `lp_get_methods`
- `lp_set_mode("remote"|"local"|"mock")`, `lp_set_default_transport(json)`

**Tokens** (`lp_token_*`):

- the outbound store: `lp_token_get` and `lp_token_save`
- the inbound door `lp_token_save_inbound` (added in 0.8)
- per-identity stores: `lp_token_isolate_identity`, `lp_token_get_for`, `lp_token_save_for`, `lp_token_reset_identity`, `lp_token_adopt_credential`
- host-service-gated functions: `lp_token_keys`, `lp_inform_module_token`, `lp_inform_module_token_to`, `lp_grant_host_services`

**Provider functions (`lp_provider_*`) are still groundwork.**

- `lp_provider_register` returns `LP_OK` but only stores the callbacks and opens no socket.
- `lp_provider_emit_event` and `lp_provider_save_token` return `LP_ERR_UNSUPPORTED` (`logos_protocol.cpp:953-988`; the logos-js-sdk README at `:102-104` says the same).
- So the "C ABI for provider registration" asked for in inventory §7.5 exists as a header, but nothing behind it serves a module yet.

**Threading and callback model** (`logos_protocol.h:26-43, 436-441`; `logos_protocol.cpp:288-309`; `logos_thread_marshal.h:32-74`):

- On a Qt-affine transport (the default LocalSocket/QtRO, or `local` mode; see `logos_transport_factory.cpp:89-101`), the client is built on the `QCoreApplication`'s thread whichever thread calls `lp_client_create`.
- Every call from another thread is marshalled there with `Qt::BlockingQueuedConnection` and blocks until it answers.
- Async, event and status callbacks fire on that owner thread.
- Plain `tcp`/`tcp_ssl` and `mock` transports are served by the library's own Boost.Asio workers and need no Qt loop.
- Qt defines the main thread as "the thread in which QCoreApplication was created … not necessarily" the thread that ran `main()` (https://doc.qt.io/qt-6/qthread.html).
- Upstream has a regression test for exactly the worker-thread-caller shape: `logos-protocol/tests/protocol/test_lp_client_owner_thread.cpp:132-199`.

**Qt requirement.** No Qt headers: the header has no includes. The library still links `Qt6Core`, `Qt6Network` and `Qt6RemoteObjects` (readelf `NEEDED`).

#### 1.3 Other C ABIs

- **logos-cpp-sdk.** `logos_host_core.h` only mirrors `logos_core.h`; `logos_lp_client.h` is a C++ wrapper over `lp_*`.
- **logos_module_impl.h** (`logos_module_dispatch`, `_get_methods`, `_accept_token`, and so on) is the ABI a module cdylib exports to its own generated glue. It is not a way for a host to call a module.
- **No public C ABI** in logos-qt-sdk, logos-plugin-qt, logos-module-loader(-qt), logos-container or logos-container-subprocess. Their `extern "C"` uses are signal handlers, `environ` and tests.

### 2. Why in-process `lp_*` works with no token plumbing

Six facts from the source explain it:

1. **Core caches every module's root token.** After each load, core mints a UUID root token, sends it to the child, and saves it in the host image with `TokenManager::instance().saveToken(name, authToken)` (`module_manager.cpp:927-931, 986`).
2. **There is one TokenManager per process.** liblogos_core does not define it; it `NEEDS` the shared `liblogos_protocol.so` (`src/CMakeLists.txt:43-52`). With `nm -DC`, `TokenManager::instance()` is defined only in `liblogos_protocol.so`, not in `liblogos_core.so` or `liblogos_qt_host.so`. A JNI shim linking the same `.so` sees core's store.
3. **Clients present a cached token before minting one.** `LogosAPIClient::invokeRemoteMethod` calls `getToken(objectName)` first and only runs `capability_module.requestModule` when that is empty (`logos_api_client.cpp:124-159`).
4. **Modules accept that root token as the host's credential.** The module stores the host token under `core` and `capability_module` (`logos-plugin-qt/cpp/logos_api_provider.cpp:183-190`). `ModuleProxy::authorize` accepts a match on that credential and reports the caller as the host anchor (`module_proxy.cpp:349-359, 555-560`).
5. **The Electron POC's "no token needed" observation is this mechanism** (`0.3.0-inventory.md:239-243`).
6. **The plain TCP limitation is unchanged.** `PlainTransportHost::publishObject` still rejects the handshake surface "for now" (`plain_transport_host.cpp:313-321`). That limitation only affects Qt-free, out-of-process clients.

#### Experiment: in-process call on Linux

**How to run it.** `bash .work/scripts/call-routes-exp.sh`. Sources are `.work/exp-call-routes/{main.c,qt_loop.cpp}` (187 lines in total). It uses the prebuilt liblogos from the Electron POC and copies of the `capability_module` and `lez_core` packages.

**Setup:**

- `qt_loop.cpp` starts a `std::thread`. On that thread it creates the `QCoreApplication`, calls `logos_core_init`, `add_modules_dir`, `set_persistence_base_path` and `logos_core_start`, then runs `exec()`.
- `main.c` is pure C and includes only `logos_core.h` and `logos_protocol.h`. It runs on the process main thread.

**Output:**

```
[qt] QCoreApplication created on thread 140028664612544
[logos] Module loaded: capability_module
[main] logos_core_load_module(lez_core) from NON-Qt thread -> 1 in 23 ms
[main] sockets under TMPDIR: logos_capability_module_feb241afd8ec, logos_lez_core_feb241afd8ec
[main] lp_invoke(version, []) rc=0 in 0 ms result="0.3.0"
[main] lp_invoke(account_id_to_base58, ["00…01"]) rc=0 in 3 ms result="11111111111111111111111111111112"
[main] lp_invoke(no_such_method_xyz, []) rc=0 result=null
[async-cb] on thread 140028664612544 ok=1 json="0.3.0"
[main] lp_invoke(anything) on a not-loaded module: rc=-4 in 3085 ms {"code":"object_unavailable",…}
```

**What it shows:**

- **Loads work off the Qt thread.** `logos_core_load_module` returned 1 when called from the non-Qt main thread.
- **Calls work from a non-Qt thread through the C ABI**, and they do real module work in `lez_core`, a LEZ module.
- **Callbacks come back on the Qt thread.** The async callback's thread id matches the `QCoreApplication` thread.
- **The QtRO sockets land in `$TMPDIR`**, not `/tmp`. See `qt_socket_path.h:13-21` and the QDir doc: "TMPDIR … or /tmp".
- **No "QApplication was not created in the main() thread" warning** appeared on Linux.

**How this squares with the Electron POC.** Electron recorded that "a dedicated Qt thread does NOT work" (`addon.cc:228-231`; inventory §1 `:90-98`). That failure was specific: the Qt objects were created on the JS thread while `exec()` ran on another thread. In this layout the `QCoreApplication`, core's anchored `LogosAPI` and every lp client all live on the thread that runs `exec()`, so a dedicated thread works.

**`lp_*` limitations the experiment and source surfaced:**

- **No wildcard subscription.** `lp_subscribe` rejects an empty event name (`logos_protocol.cpp:450-451`). `LogosAPIClient::onEventWhenAvailable` does accept one.
- **Unknown method names return success.** They come back as `LP_OK` with `null` (`logos_protocol.h:490-494`).
- **Introspection returned nothing.** `lp_get_methods` returned `[]` for `lez_core` 0.4.1.
- **Take method and event names from the module's header or `.lidl`.** For example `logos-execution-zone-module/src/lez_core_module.h:32-104`.

### 3. The core_service gateway today

**Where it lives.** core_service is in logos-logoscore-cli, not liblogos. `CoreServiceImpl`, its dispatch, call envelope and package ops are compiled straight into the `logosctl` and `logoscore` executables (`logos-logoscore-cli/CMakeLists.txt:201-212`). It is Qt C++: it includes `logos_api.h`, `QCoreApplication`, `QEventLoop` and `package_ops.h` (`core_service_impl.cpp:2-12`).

**How the daemon hosts it** (`daemon.cpp:571-634`):

- `new LogosAPI("core_service", coreTransports)` plus `new CoreServiceImpl()`, then `provider->registerObject("core_service", …)`.
- A `setTokenValidator` backed by `TokenStore`, which accepts operator-issued tokens.
- A per-boot `auto` token (`local_only`), saved as INBOUND for `cli_client` and written to `client/auto.json`.
- The client saves that token outbound under both `cli_client` and `core_service` (`client/client.cpp:126-127`).

**Gateway methods** (`core_service_dispatch.cpp:68-119`): `loadModule`, `unloadModule`, `reloadModule`, `refreshModules`, the package operations, `listModules`, `getStatus`, `getModuleInfo`, `getModuleStats`, `callModuleMethod`, `watchModuleEvents`, `shutdown`.

**Transport config.** Daemon YAML such as `modules: core_service: [{protocol: tcp, host, port, codec}]` with `insecure_tcp: true`, as in the Electron POC's `scripts/daemon-node.yaml:8-34`.

**Can the Android app run it in-process?** Only by re-implementing daemon steps 7-8 in the app, meaning Qt C++ `LogosAPI` plus porting `CoreServiceImpl`. No liblogos flag or API turns it on.

**Would it avoid a second process?** Yes. The app could then reach itself over loopback TCP with `lp_*`: `lp_token_save("core_service", tok)` plus an inbound token via `lp_token_save_inbound` or `TokenManager`. But that is strictly more work than calling `LogosAPIClient` directly, and it adds a TCP port and cleartext tokens. **Not recommended.**

### 4. How the non-C++ SDKs call modules today

| SDK | How it calls modules | In-process, daemon-free? |
|---|---|---|
| logos-logoscore-py | "Each method spawns a fresh `logoscore <subcommand> --json` subprocess" (`src/logoscore/client.py:3`) | No |
| logos-rust-sdk | Module-side consumer; `lp_*` resolves against the protocol archive inside a module plugin (`README.md:3,11`). `lib.callerBuildSupport` links `liblogos_protocol` for out-of-plugin binaries that must call `set_module_origin` (`flake.nix:180-200`, `README.md:193-199`) | Not an embedding host |
| logos-js-sdk | "Qt-free … no embedded Qt host and no Qt event loop … does not use liblogos_core"; consumer over plain TCP/TLS; provider side blocked on logos-protocol#12 (`README.md:3-9, 91-108`) | No |
| logos-nim-sdk | Binds removed symbols (`logos_api.nim:30-42`) | Stale |

None of them already implements the route recommended here. The in-process `lp_*`-over-QtRO path has upstream precedent in the owner-thread regression test and in how module plugins call each other.

### 5. Revisiting the Electron findings

**Still true:**

- The plain transport does not publish the handshake surface (`plain_transport_host.cpp:319`).
- `lp_provider_*` does not serve.

**Changed or newly relevant:**

- There is a documented, tested owner-thread marshal for `lp_*` on Qt-affine transports.
- liblogos_core now shares one `liblogos_protocol.so` and one `TokenManager` with everything in the process, instead of absorbing static copies.

Together these mean the C ABI alone is enough to call modules from inside the runtime process. What the Electron 0.3.0 addon did in C++ (`LogosAPI("core_service")` → `getClient` → `invokeRemoteMethod`, `onEventWhenAvailable`) is what `lp_client_create`, `lp_invoke` and `lp_subscribe` wrap (`logos_protocol.cpp:295-309, 381, 475`). The addon's `tick()` pump is not needed: a thread blocked in `exec()` services the objects.

### 6. Ranked recommendation for Android

#### 1. Route (a′): in-process `lp_*` over the default QtRO transport, with a dedicated Qt thread (recommended)

A pure C ABI inside liblogos (route (a)) does not exist, so this hybrid is the closest thing to it.

**Functions:**

- Qt thread: `QCoreApplication` (C++), `logos_core_init`, `logos_core_add_modules_dir`, `logos_core_set_persistence_base_path`, `logos_core_start`, `QCoreApplication::exec`, then `logos_core_cleanup` once `exec()` returns.
- Worker threads: `logos_core_load_module`, `lp_client_create(module, "core_service", NULL, NULL)`, `lp_invoke` / `lp_invoke_async`, `lp_subscribe` with `lp_client_set_subscription_status_cb`, `lp_unsubscribe`, `lp_client_destroy`.
- Stop: a queued `QMetaObject::invokeMethod(qApp, quit)`.

**Qt:** the runtime is needed. Headers appear in one ~60-line file only. There is no dependency on the LogosAPI or liblogos_qt_host C++ ABI, and `lp_*` is a versioned C ABI where minor versions are additive.

**Android thread model:**

- Kotlin creates the "logos-qt" `Thread`, so it is JVM-attached and callbacks can call into Java directly.
- That thread runs a blocking JNI `nativeRun()` and becomes Qt's main thread. This mirrors Qt's own qtMainLoopThread design on Android (https://doc.qt.io/qt-6/android-how-it-works.html).
- All other JNI calls come from coroutines on `Dispatchers.IO`. Blocking calls must stay off the UI thread to avoid ANRs.
- Callbacks run on the Qt thread and must only hand results over (`CompletableDeferred`, `SharedFlow.tryEmit`).
- Driving Qt from Android's main Looper (the Electron "tick" pump) is not recommended. It would need `QCoreApplication` and `logos_core_start` on the UI thread, polling costs battery, and blocking calls would still have to move elsewhere.

**Risks:**

- Qt 6.9's `libQt6Core` `JNI_OnLoad` needs Qt's `org.qtproject.qt.android.QtNative` Java class and returns `JNI_ERR` without it (`qjnihelpers.cpp` 6.9). This applies to every in-process route.
- `TMPDIR` must point at the app cache dir.
- Owner-thread marshalling uses `BlockingQueuedConnection` with no timeout, so a busy or wedged Qt thread stalls every caller (`logos_thread_marshal.h:41-48`).
- No wildcard events. `null` does not distinguish unknown methods. Introspection is unreliable.
- SELinux policy for app-private Unix sockets is unverified.

**Estimated glue:**

- ~350-450 native lines: a C++ JNI shim plus `qt_loop.cpp`. The experiment covered the whole call path in 187 lines, and the sibling `delivery_jni.c` is 489 lines for a similar surface.
- ~200 Kotlin lines.

#### 2. Route (c): in-process `LogosAPIClient` through a Qt C++ JNI shim (the Electron 0.3.0 route)

**Use it only as a fallback**, for example when wildcard event subscription is needed or if `lp_*` shows a gap on Android.

**Functions:** `LogosAPI("core_service")` constructed on the Qt thread after `logos_core_start`, `getClient(module)->invokeRemoteMethod(..., Timeout, &CallError)`, `onEventWhenAvailable` (empty name for every event), and the `nlohmannArgsToQVariantList` / `qvariantToNlohmann` converters.

**Thread model:** the same as route (a′). Build `LogosAPI` on the Qt thread and call from workers; `invokeRemoteMethod` marshals.

**Qt:** yes, C++ headers throughout the shim.

**Risks:**

- C++ ABI coupling to `liblogos_qt_host` and `logos_api.h` (inventory §5.9).
- nlohmann 3.11.x ABI pin (`gyp-config.js:62-65`).
- The same Qt/Android loading issues as route (a′).

**Estimated glue:** ~450-600 native lines. The call and event core came to about 190 lines in Electron (inventory §6); JNI plumbing and conversions are extra.

#### 3. Route (b): in-process core_service plus `lp_*` over loopback

**Functions:** everything in route (c), plus `CoreServiceImpl`, `registerObject`, a token validator and an inbound token, then `lp_set_default_transport` / `lp_client_create("core_service", …tcp json…)` and `lp_invoke("callModuleMethod", [module, method, args])`.

**Qt:** yes, a lot of it.

**Risks:**

- core_service is not a liblogos feature.
- It needs a TCP port and `insecure_tcp`, and carries tokens in cleartext.
- It inherits the daemon quirks recorded in NEXT.md.

**Estimated glue:** ~1,100 lines ported from logoscore-cli (`core_service_impl.cpp` 695, `.h` 99, dispatch 228, envelope 106), plus `package_ops` 606 because the impl includes it, plus the route (a′) shim. It is strictly worse than route (c).

#### 4. Route (d): out-of-process daemon (logosctl child process)

**Least attractive.** It needs:

- an Android arm64 build of logoscore-cli and its Qt closure;
- to ship the binary as a `lib*.so` in `nativeLibraryDir`, because targetSdk 29+ blocks `execve` from the app home directory (https://developer.android.com/about/versions/10/behavior-changes-10);
- a second copy of the runtime (the Electron AppImage grew from 315 MB to 426 MB);
- the per-boot `auto.json` token handoff, TCP ports and daemon supervision.

Electron also hit `daemon stop` failing on a tcp-only daemon, silent death with a `local`+`tcp` config, and stale-token hangs (NEXT.md `:64-78, 466-501`). Android 12's phantom-process killer adds more exposure (https://issuetracker.google.com/issues/205156966). Note that liblogos's subprocess container spawns a `logos_host` per module in every route anyway.

**Glue:** Kotlin process supervision (~300 lines) plus either the `lp_*` TCP shim or shelling out to `logosctl call --json` for each call.

### 7. Inter-module communication

**No extra host glue.** Once the host calls a module with `lp_invoke`, any calls that module makes to its dependencies go over liblogos's own QtRO transport. The tokens for those calls are minted by `capability_module`, which core informs on the owner thread after each load (`module_manager.cpp:508-527`).

**Candidate demo pair.** `token_module` and `amm_module` in lez-programs declare `dependencies: ["lez_core"]` (`lez-programs/modules/{token,amm}/metadata.json`). `liblogos_lez_rln_module` v3 dropped its `lez_core` dependency (`liblogos_lez_rln_module.lidl:12-13`), so it is no longer suitable.
