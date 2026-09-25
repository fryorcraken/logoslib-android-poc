# Experiment: desktop-harness

> Gating experiment, 2026-09-25. Machine-written by the experiment agent; logs and scripts in
> [../../experiments/desktop-harness](../../experiments/desktop-harness); patches in [../../patches](../../patches).
> `.work/` paths refer to local scratch that is not committed.


### Summary
I extended the in-process lp_* harness and ran it on desktop Linux x86_64 against the same liblogos (db45024, /nix/store/7jcna50…) and Qt 6.9.2 that logoscore 6a0a2f4 uses. The module set was lez_core 0.4.2, lez_probe, and a new event-emitting ev_probe module (13 s nix build). I did not patch anything upstream. Results:

(a) PASS. lp_invoke(lez_core, "getPluginMethods", "[]") returns all 40 methods with full signatures, return types and parameter names, in 0-1 ms. getPluginEvents returns [] for lez_core and 1 event for ev_probe. lp_get_methods still returns [].

(b) Race confirmed. When lez_probe is loaded from a non-Qt thread, 13 of 20 fresh processes got a first lez_probe.lez_version answer of "" with rc=0 and no error. Mechanism: capability_module rejects lez_probe's requestModule because core has not registered lez_probe's token yet. Every run was good on the retry 20 ms later. Loading on the Qt thread gave 0/20 bad. A Qt-thread barrier after a worker load reduced it to 1/20 but did not close it. Direct host-to-lez_core calls were good 20/20 on the first try.

(c) lez_core serves one call at a time. version() dispatched 300 ms into create_new (calibration_limit 3 or 20) waited for the rest of it: 1.6-1.8 s at limit 3, 7.9-8.2 s at limit 20. Synchronous lp_invoke runs the whole call inside a nested QEventLoop on the Qt thread. A fast call to an IDLE module whose metacall happened to host a later slow call's dispatch was held for that entire call: 1882 ms, 7886 ms and 6001 ms measured. That happens even with a 500 ms timeout, and a sync call in flight when a load starts on the Qt thread is held for that load too. With lp_invoke_async, the same pinger stayed at 2 ms or less over about 120k calls. When the Qt thread is blocked, or runs logos_core_load_module, every sync lp_invoke and lp_client_create caller wedges for the whole duration. lp_* timeouts do not bound that wait (500 ms timeout: returned after 2900 ms; async callback ok=1 after 2900 ms). Against a busy module the timeouts do work (952 ms for 1000; default 20 s). A timed-out call is not cancelled: the module stays busy until it finishes. Loading from a worker thread does not wedge callers (pinger max 22 ms).

(d) PASS. lp_subscribe delivers events in-process, on the Qt thread, with about 1 ms latency and in order (a 200-event burst arrived within 3 ms). A subscription made before the load armed 232 ms after the load returned, because pending subscriptions are polled on a 250 ms to 5 s backoff. Unload gives LOST, reload gives ARMED at generation 2. Unknown event names are accepted silently. Unsubscribe stops delivery.

Recommended policy: one JVM-attached Qt thread that does nothing else; all module calls via lp_invoke_async with the deadline enforced in Kotlin; one in-flight call per module; loads from Dispatchers.IO; retry the first call until the answer is good; subscribe after load and wait for ARMED.

### Results
- [pass|verified-by-experiment] (a) Does lp_invoke(lez_core, "getPluginMethods", "[]") from the in-process host return the method list, and with signatures?
  rc=0 in 1 ms, 7609 bytes, 40 entries. All 40 have name, signature (Qt types, e.g. "create_new(QString,QString,QString,QString)"), returnType and isInvokable. 26 also have parameters[{name,type}] (e.g. config_path, storage_path, statistics_path, password). The names match the published 0.4.2 lez_core.lidl. getPluginInterface returns the same 40 entries for lez_core. The call is ungated (module_proxy.cpp:97-113), so no token is needed. lp_get_methods(client) still returns [] for every module, because remote_transport.cpp:445-450 does not implement it. capability_module: 5 methods (requestModule, registerRestriction, name, version, lidl). lez_probe: 6. ev_probe: 6 methods, and getPluginInterface also includes the event with type "event".
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/a-introspect.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/out/introspect/lez_core.getPluginMethods.json; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/out/introspect/lez_core.lp_get_methods.json; /home/fryorcraken/src/logos-co/logos-protocol/cpp/module_proxy.cpp:97-113,639-647
- [pass|verified-by-experiment] (a) Does lp_invoke(target, "getPluginEvents", "[]") work?
  lez_core: [] (it has no events; matches module-info). ev_probe: [{"name":"pinged","parameters":[{"name":"data","type":"QString"}],"signature":"pinged(QString)","type":"event"}], 0-1 ms. A Kotlin host can therefore discover both methods and events at runtime.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/out/introspect/ev_probe.getPluginEvents.json; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/out/introspect/lez_core.getPluginEvents.json
- [fail|verified-by-experiment] (b) Is the first lp_invoke(lez_probe, "lez_version") after a non-Qt-thread load of lez_probe (no warm-up) reliable?
  Over 20 fresh processes, 13 first answers were the JSON string "" with rc=0 and error=(null). That looks like success but is the typed wrapper's default. 7 answered "0.3.0". All 20 were good on attempt 2 (20 ms sleep); time from load return to the first good answer was median 24.5 ms, max 26 ms. Load took 23-30 ms and the first call 1-3 ms. All later calls were ok (3/3). Log mechanism: '[capability_module] ModuleProxy: rejecting unauthorized call to "requestModule" - auth token not recognized', then '[lez_core] rejecting unauthorized call to "version"', then lez_probe logs '<- lez_core.version() = ' (empty). Cause (source): an off-Qt-thread load posts notifyCapabilityModule to the Qt thread, so registration completes asynchronously after logos_core_load_module returns (logos_core.h:131-139; module_manager.cpp:508-527). The sync lp_invoke is processed inside that registration's nested QtRO wait loop.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/b-race.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/b-probe-worker.results; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/b-raw/probe-worker-01.log
- [pass|verified-by-experiment] (b) Is a direct host-to-lez_core call (lp_invoke(lez_core, "version")) right after a non-Qt-thread load reliable?
  20/20 first answers were "0.3.0": first call 0-1 ms, load 11-15 ms. The host presents the root token core saved at load (TokenManager::saveToken happens before notifyCapabilityModule), so capability_module is not involved. The race only affects module-to-module edges.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/b-core-worker.results
- [partial|verified-by-experiment] (b) Mitigations: does loading ON the Qt thread, or a Qt-thread barrier after a worker load, remove the race?
  Loading on the Qt thread (BlockingQueuedConnection, registration inline): 0/20 bad, first call 2-3 ms. The cost is that the Qt thread is blocked for the whole host bring-up (see c/qtbusy). Worker load plus a blocking no-op round trip through the Qt thread: 1/20 still bad (run 14). The barrier can run inside the registration's nested event loop, so it is not a guarantee. Only retry-until-good, or a Qt-thread load, is reliable.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/b-probe-qt.results; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/b2-race-barrier.log
- [fail|verified-by-experiment] (c) Can lez_core answer version() while create_new (timeout 60000, calibration_limit 3 or 20, testnet) runs on another thread?
  No. lez_core dispatches one call at a time, so version() waits for the rest of create_new and finishes 0 ms after it. With B dispatched 300 ms after L:
- sync, cal 3: create_new 1882 ms, version 1582, lez_probe.lez_version (to busy lez_core) 1531, ev_probe.ping (other module) 0.
- async, cal 3: create_new 2052, version 1752, D 1703, C 0.
- sync, cal 20: create_new 8186, version 7886, D 7836, C 1.
- async, cal 20: 8549 / 8249 / 8200 / 0.
The pre-written config (calibration_limit 3 or 20) was honoured, at about 0.37 s per calibration request. After the run, list_accounts returned 2 accounts and get_current_block_height returned 23986-23987 in 725-769 ms. The deterministic variant (ev_probe.sleep_ms(6000)) gave the same result: the same-module ping waited 5701 ms.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/c-block.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/c-raw/01-create-cal3-sync.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/c-raw/03-create-cal20-sync.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/c-raw/04-create-cal20-async.log
- [fail|verified-by-experiment] (c) With synchronous lp_invoke from several JNI-like threads, do calls to OTHER, idle modules stay responsive while a long call is in flight?
  Not reliably. LogosAPIClient::invokeRemoteMethod runs the whole call on the Qt thread (runOnOwnerThread with BlockingQueuedConnection). QRemoteObjectPendingCall::waitForFinished then spins a nested QEventLoop. A slow call dispatched while a fast call's nested loop is active stacks on top of it, and the fast call cannot return until the slow one does (last in, first out). Measured with a tight-loop pinger (sync, timeout 60000) on an idle module:
- one ping held 1882 ms, starting exactly when create_new was dispatched (cal 3);
- one held 7886 ms (cal 20);
- one held 6001 ms to IDLE lez_core while ev_probe.sleep_ms(6000) ran;
- one held 3010 ms in the timeouts run.
A sync call dispatched after the slow call nests on top of it and is fast (C: 0-1 ms; a 500 ms-timeout call: 1 ms). Which calls get stuck therefore depends on dispatch order, and it is invisible to callers.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/c-raw/05-sleep-sync.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/c-raw/01-create-cal3-sync.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/c-raw/09-timeouts.log; /home/fryorcraken/src/logos-co/logos-protocol/cpp/logos_api_client.cpp:114-192; /home/fryorcraken/src/logos-co/logos-protocol/cpp/implementations/qt_remote/remote_transport.cpp:173-216
- [pass|verified-by-experiment] (c) Does lp_invoke_async keep the host responsive during a long call?
  With L, B, C and D all issued via lp_invoke_async, a concurrent sync pinger on another module ran 39,799 calls (cal 3), 121,959 (cal 20) and 92,606 (sleep 6 s). Max latency was 2 ms in all three, with none over 100 ms. Each lp_invoke_async dispatch returned in 0 ms. Callbacks fire on the Qt thread. Module-level serialization is unchanged: same-module calls still wait for the long call. A caveat from source: the first async call to a target still does a blocking replica acquire on the Qt thread (logos_api_client.cpp:374-377).
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/c-raw/02-create-cal3-async.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/c-raw/04-create-cal20-async.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/c-raw/06-sleep-async.log
- [fail|verified-by-experiment] (c) When the Qt thread is busy (blocked, or running logos_core_load_module), do JNI-like callers wedge, and do lp_* timeouts bound the wait?
  Callers wedge, and the timeouts do not bound the wait.
- Qt thread blocked 3 s: sync lp_invoke(version, timeout 500) returned after 2900 ms with rc=0.
- Same block: lp_invoke_async(timeout 500) returned in 0 ms, but its callback fired ok=1 after 2900 ms. The timeout timer only starts once the call reaches the Qt thread.
- Qt thread blocked 2 s: lp_client_create took 1902 ms.
- logos_core_load_module(lez_probe) ON the Qt thread, with the host exec delayed 3 s by a wrapper: the load took 3020 ms on the Qt thread. A sync lp_invoke(timeout 500) took 2920 ms, and an in-flight pinger call was held 3020 ms.
Source: awaitLoad is a condition_variable wait, not an event pump (subprocess_container.cpp:845-847), and kLoadVerdictTimeout is 10 s (module_manager.cpp:245).
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/c-raw/08-qtbusy.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/bin/slow_host.sh; /home/fryorcraken/src/logos-co/logos-container-subprocess/src/subprocess_container.cpp:826-854
- [pass|verified-by-experiment] (c) Does a load from a non-Qt thread wedge other callers?
  logos_core_load_module(ev_probe) from the main thread with the same 3 s host delay took 3013 ms. A concurrent sync pinger on lez_core.version ran 47,471 calls with max 22 ms and none over 100 ms. The load blocks only its calling thread.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/c-raw/08-qtbusy.log
- [partial|verified-by-experiment] (c) Do lp_invoke / lp_invoke_async timeouts work against a busy MODULE (Qt thread free), and is a timed-out call cancelled?
  The timeouts fire: with ev_probe busy 5 s, sync lp_invoke(ping, 1000) returned rc=-4 after 952 ms with {"code":"timeout",...}. lp_invoke_async(ping, 1000) called back ok=0 after 951 ms with the same error. The client worked normally afterwards. The default (timeout_ms=0) fired after 19,594 ms ('timed out after 20000ms'); QTimer is coarse, so it fires about 2% early. A timed-out call is NOT cancelled: the module finished sleep_ms(23000) in the background, and the next ping waited 3407 ms.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/c2-timeouts.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/c-raw/09-timeouts.log
- [pass|verified-by-experiment] (d) Does lp_subscribe deliver module events to the in-process host, and on which thread?
  Tested on ev_probe (universal module, logos_events: pinged(std::string)).
- lp_subscribe BEFORE load returned a handle, with pending=["ev_probe::pinged"] and generation 0.
- The status callback reported ARMED gen 1 232 ms after the load returned. That delay comes from the pending-subscription poll: 250 ms, backing off to a 5 s cap (logos_api_consumer.cpp:442-447,472-490).
- 5 fires: 5/5 events, latency 0-1 ms, all on the Qt thread (the QCoreApplication thread, not the main or calling thread).
- fire_many(200): 200 events in order within 3 ms of the call returning.
- A second subscription made from a worker thread also received events on the Qt thread.
- lp_subscribe("no_such_event") returned non-NULL, was never pending, and never fires, so it cannot be told apart from a quiet event.
- unload(ev_probe): STATUS LOST gen 1, reason provider_unavailable. Reload: ARMED gen 2 10 ms after the load, and events resumed. Host lp_invoke on the same client also worked after the reload.
- lp_unsubscribe: 0 further events.
  evidence: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/d-events.log; /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/src/ev_probe/src/ev_probe_impl.h; /home/fryorcraken/src/logos-co/logos-protocol/cpp/logos_api_consumer.cpp:429-490
- [not-run|inferred] Do these desktop results carry over to Android (Qt 6.11.1, bionic, JVM-attached Qt thread)?
  Not tested on Android. The mechanisms involved are liblogos, logos-protocol and QtRO code (runOnOwnerThread, the nested QEventLoop in waitForFinished, posted notifyCapabilityModule, the condvar awaitLoad) and are not platform-specific, so they are expected to hold (inferred). The windows will be wider on a phone: host spawn plus a dlopen of about 100 MB libwallet_ffi, slower CPU. The race-retry cap and the cost of any Qt-thread load should be sized accordingly (inferred).
  evidence: 

### Patches
- No upstream repo was modified. Record of the harness changes relative to the previous round: /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/patches/main.c.vs-verify-call-routes.diff
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/patches/qt_loop.cpp.vs-verify-call-routes.diff
- New module (not a patch): /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/src/ev_probe (flake.nix pinning logos-module-builder 6ef42ea, metadata.json, CMakeLists.txt, src/ev_probe_impl.{h,cpp}; methods ping/fire/fire_many/sleep_ms, event pinged)

### Artifacts
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/harness/main.c
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/harness/qt_loop.cpp
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/build/dh
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/build/build.sh
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/bin/slow_host.sh
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/modules (capability_module 1.0.0, lez_core 0.4.2, lez_probe 0.0.1, ev_probe 0.0.1)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/evprobe-lgx -> /nix/store/788qks2i209xkpzgppjm5vbs3b30qb1b-logos-ev_probe-module-lib-lgx-0.0.1
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/out/introspect/
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/a-introspect.log
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/b-race.log
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/b2-race-barrier.log
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/b-raw/
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/c-block.log
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/c2-timeouts.log
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/c-raw/
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/d-events.log
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/build.log
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/logs/evprobe-build.log
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/experiments/desktop-harness/wallets/c1..c4 (throwaway testnet wallets; storage.json holds plaintext keys)
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/desktop-harness-evprobe.sh
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/desktop-harness-build.sh
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/desktop-harness-a.sh
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/desktop-harness-b.sh
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/desktop-harness-b2.sh
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/desktop-harness-c.sh
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/desktop-harness-c2.sh
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/desktop-harness-d.sh
- /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/desktop-harness-diff.sh

### Repro
Run in order. Each script tees its output to .work/experiments/desktop-harness/logs/.
1. bash /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/desktop-harness-evprobe.sh (nix build of ev_probe .lgx, about 13 s, then lgpm install)
2. bash /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/desktop-harness-build.sh (copies capability_module/lez_core/lez_probe from .work/probe/modules, writes bin/slow_host.sh, compiles dh inside `nix develop path:/home/fryorcraken/src/logos-co/logos-liblogos` against /nix/store/7jcna50jgjmzx28nk6a14x5y6f5dwlrb-logos-liblogos + /nix/store/dkfr32yi7p8cdxsnll05q1kax19fl7ay-qtbase-6.9.2)
3. bash /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/desktop-harness-a.sh (introspection)
4. bash /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/desktop-harness-b.sh (3 variants x 20 fresh processes)
5. bash /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/desktop-harness-b2.sh (rebuilds; barrier variant x 20)
6. bash /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/desktop-harness-c.sh (needs HTTPS to testnet.lez.logos.co; 8 runs, about 70 s)
7. bash /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/desktop-harness-c2.sh (rebuilds; timeouts, about 32 s)
8. bash /home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/scripts/desktop-harness-d.sh (events)
Direct invocation: dh MODULES_DIR PERSIST_DIR {introspect OUTDIR | race TARGET METHOD EXPECTED worker|qt|barrier | block create|sleep sync|async pinger|nopinger [WALLET_DIR] | qtbusy | timeouts | events}. Required env: TMPDIR=/home/fryorcraken/src/fryorcraken/logoslib-android-poc/.work/dh/<2-3 chars> (66-67 chars, so sun_path is at most 103 bytes), LOGOS_HOST_PATH=/nix/store/7jcna50jgjmzx28nk6a14x5y6f5dwlrb-logos-liblogos/bin/logos_host (or bin/slow_host.sh for qtbusy), and LD_LIBRARY_PATH unset. No logos_host processes were left over after any run.

### Next steps
- Build the JNI shim around lp_invoke_async, not lp_invoke. Pass a jlong call id as user_data and keep a native map from id to pending call. The callback (on the Qt thread) looks up the id and drops unknown ones, so a Kotlin-side timeout never leaves a dangling pointer.
- Put a readiness helper in the shim for each module-to-module edge (retry a cheap call until the answer is not empty or the default; 20-50 ms backoff, cap about 3-5 s on device). Loading on the Qt thread closes the race but wedges the host for the whole bring-up, so reserve it for a splash-screen startup phase at most.
- Repeat (b) and (c) on the x86_64 API 34 AVD once the Android build exists, to size the race window and the load duration (spawn plus the libwallet_ffi dlopen) there.
- Consider an upstream issue/PR for logos-protocol: sync lp_invoke's nested QEventLoop lets unrelated calls be held for the full duration of a slow call. Also, lp_* timeouts do not start until the call reaches the Qt thread.
- Consider asking upstream to make an off-Qt-thread logos_core_load_module wait for capability registration, or expose a readiness query. The current documented contract (logos_core.h:131-139) pushes this onto every host.
- Optional: re-run (c) against Qt 6.11.1 host libs to confirm QRemoteObjectPendingCall::waitForFinished still nests an event loop (expected, not verified).

---

## Full report

## desktop-harness: host-design questions for the Kotlin/JNI host (desktop Linux x86_64)

**Setup:**
- The harness is `.work/experiments/desktop-harness/harness/{main.c,qt_loop.cpp}`, extended from `.work/verify-call-routes`.
  - `main.c` is pure C (`logos_core.h` and `logos_protocol.h` only) and stands in for the JNI shim.
  - `qt_loop.cpp` is the only Qt C++. A dedicated thread owns `QCoreApplication` and runs `logos_core_init/add_modules_dir/set_persistence_base_path/start`, then `exec()`.
- It is linked against the same liblogos that logoscore 6a0a2f4 uses: `/nix/store/7jcna50…-logos-liblogos` (db45024, protocol 0.9.0), with Qt 6.9.2 from `/nix/store/dkfr32…-qtbase-6.9.2`. Every lib resolves to one Qt copy (checked with ldd).
- Modules: capability_module 1.0.0, lez_core 0.4.2 (825d2a4) and lez_probe 0.0.1, all from `.work/probe`. ev_probe 0.0.1 is new: a universal module with `ping`, `fire(data)`, `fire_many(n)`, `sleep_ms(ms)` and the typed event `pinged(QString)`. It was built with the lez_probe builder rev 6ef42ea in 13 s.
- `TMPDIR=.work/dh/<nn>` (66-67 chars). No upstream code was patched, and no logos_host processes were left over after any run.

### (a) Runtime introspection: PASS (verified-by-experiment)

`lp_invoke(c, "getPluginMethods", "[]")` returns rc=0 in 0-1 ms.

| target | getPluginMethods | getPluginEvents | lp_get_methods |
|---|---|---|---|
| lez_core | **40** entries, 7609 B | `[]` | `[]` |
| lez_probe | 6 | `[]` | `[]` |
| ev_probe | 6 | 1 (`pinged(QString)`, type "event") | `[]` |
| capability_module | 5 (requestModule, registerRestriction, name, version, lidl) | `[]` | `[]` |

- Every entry has `name`, `signature` (Qt types, e.g. `create_new(QString,QString,QString,QString)`), `returnType` and `isInvokable`.
- 26 of lez_core's 40 entries also have `parameters:[{name,type}]`.
- `getPluginInterface` returns methods plus events.
- These calls are ungated (`module_proxy.cpp:97-113`), so no token is needed.
- `lp_get_methods` is still `[]` because remote introspection is unimplemented.

Full JSON is in `out/introspect/`.

### (b) First-call race (verified-by-experiment)

20 fresh processes per variant. Each run loads the module and then immediately calls it, with no warm-up, retrying every 20 ms until the answer is good.

| variant | first answer bad | kind | eventually good | load ms | load-return → good (ms) |
|---|---|---|---|---|---|
| load lez_probe from a non-Qt thread → `lez_probe.lez_version` | **13/20** | `""`, rc=0, err=null | 20/20 on attempt 2 | 23-30 | med 24.5, max 26 |
| load lez_core from a non-Qt thread → `lez_core.version` | 0/20 | - | 20/20 | 11-15 | 0-2 |
| load lez_probe ON the Qt thread → `lez_version` | 0/20 | - | 20/20 | 23-31 | 2-4 |
| non-Qt load + blocking no-op round trip via the Qt thread | 1/20 | `""` | 20/20 | 23-28 | - |

**Mechanism, seen in the logs:**
1. `[capability_module] rejecting unauthorized call to "requestModule" - auth token not recognized`
2. `[lez_core] rejecting unauthorized call to "version"`
3. lez_probe returns `""`.

After an off-Qt-thread load, core registers the new module's token with capability_module later, via a post to the Qt thread (`logos_core.h:131-139`, `module_manager.cpp:508-527`). The first call is serviced inside that registration's nested QtRO wait, so a barrier does not reliably order after it.

Host-to-module calls are unaffected because the host presents the root token.

### (c) Single-threaded blocking (verified-by-experiment)

**lez_core create_new on the testnet.** The pre-written `wallet_config.json` was honoured. L is create_new. B (`lez_core.version`), D (`lez_probe.lez_version`, which calls into the busy lez_core) and C (`ev_probe.ping`) were dispatched 300, 350 and 400 ms after L.

| run | create_new | version (B) | D | C (other module) | pinger on other module, max |
|---|---|---|---|---|---|
| cal 3, sync | 1882 | **1582** | 1531 | 0 | **1882** (started at L dispatch) |
| cal 3, async | 2052 | 1752 | 1703 | 0 | **2** (39,799 calls) |
| cal 20, sync | 8186 | **7886** | 7836 | 1 | **7886** |
| cal 20, async | 8549 | 8249 | 8200 | 0 | **2** (121,959 calls) |

- lez_core dispatches one call at a time: B finishes 0 ms after L every time.
- Calibration costs about 0.37 s per request.
- After the run, `list_accounts` returned 2 accounts and `get_current_block_height` returned 23986 in about 750 ms.

**Deterministic variant.** L is `ev_probe.sleep_ms(6000)`. The pinger targets the idle lez_core.
- sync: one `lez_core.version` call was held **6001 ms**.
- async: max 2 ms over 92,606 calls.
- The same-module ping waited 5701 ms in both styles. Calls to other modules dispatched after L took 1 ms.

**Why sync calls get held.** Sync `lp_invoke` runs the whole call on the Qt thread (`runOnOwnerThread` with `BlockingQueuedConnection`), and `QRemoteObjectPendingCall::waitForFinished` spins a nested `QEventLoop`. A slow call dispatched inside a fast call's nested loop sits on top of it, so the fast call cannot return until the slow one does. This applies even to calls to idle modules, and a short timeout does not rescue them.

**Qt thread busy (`qtbusy`):**
- Qt thread blocked 3 s: sync `lp_invoke(version, timeout=500)` took **2900 ms** with rc=0.
- Same block: `lp_invoke_async(timeout=500)` returned in 0 ms, but the callback fired ok=1 after **2900 ms**. The lp timer starts on the Qt thread.
- Qt thread blocked 2 s: `lp_client_create` took **1902 ms**.
- `logos_core_load_module(lez_probe)` **on the Qt thread**, with the host exec delayed 3 s: the load took 3020 ms. Sync `lp_invoke(timeout 500)` took **2920 ms** and an in-flight pinger call was held **3020 ms**. `awaitLoad` is a condvar wait with no event pumping.
- The same slow load **from a worker thread**: pinger max 22 ms, no wedge.

**Timeouts against a busy module (Qt thread free):**
- sync timeout 1000: returned rc=-4 `{"code":"timeout"}` after 952 ms.
- async timeout 1000: ok=0 after 951 ms.
- Default timeout (`timeout_ms=0`): fired after 19,594 ms ("20000ms").
- A timed-out call is **not cancelled**: the module stays busy, and the next call waited 3407 ms.

### (d) Events: PASS (verified-by-experiment)

- `lp_subscribe` before the load returned a handle, pending `["ev_probe::pinged"]`.
- ARMED gen 1 arrived **232 ms after the load returned**. Pending subscriptions are polled on a 250 ms to 5 s backoff (`logos_api_consumer.cpp:442-490`).
- 5 of 5 events arrived with 0-1 ms latency, all on the **Qt thread**.
- A 200-event burst arrived in order within 3 ms.
- A second subscription made from a worker thread also worked; its callbacks also ran on the Qt thread.
- `lp_subscribe("no_such_event")` returned non-NULL and silently never fires.
- Unload gave LOST gen 1 (`provider_unavailable`). Reload gave ARMED gen 2 10 ms after the load, and events resumed. Host calls on the same client also kept working.
- After `lp_unsubscribe`, 0 events arrived.

### Recommended Kotlin/JNI threading and timeout policy

This follows from the numbers above. The Android-specific parts are inferred.

1. **One dedicated JVM-attached `logos-qt` thread.** A Kotlin `Thread` runs a blocking JNI `nativeRun()` that does `QCoreApplication`, `logos_core_*` start and `exec()`. Nothing else ever runs there: no loads, no sync lp calls, no blocking work in callbacks. Every lp callback (results, events, status) arrives on it and must only hand off, for example `CompletableDeferred.complete` or `Channel.trySend`.
2. **All module calls via `lp_invoke_async`.** Dispatch never blocks (0 ms), and it avoids the nested-loop hold of up to 8 s. `user_data` is a jlong call id kept in a native map. Kotlin wraps it as `suspend fun call()` using `suspendCancellableCoroutine` plus `withTimeout`. On timeout or cancellation, drop the id so the late callback is ignored.
3. **Two timeouts.**
   - Enforce the real deadline in Kotlin (`withTimeout`), because lp timeouts do not start until the Qt thread picks up the call.
   - Also pass an explicit lp `timeout_ms` of at least the Kotlin deadline, since the default 20 s is too short for create_new or open at the default calibration (about 35 s).
   - Suggested budgets (inferred): local calls (name, version, base58, list/create accounts, labels) 5 s; network reads (block height, balance, account) 30 s; save 15 s; create_new/open 120 s, and always write `calibration_limit` ≤ 5 first; sync, restore and transfers long (300 s) with UI progress.
4. **One in-flight call per module.** Use a Kotlin `Mutex` or a single-consumer queue per target. The module serializes calls anyway, and a timed-out call keeps it busy. Queueing in Kotlin keeps deadlines honest and lets the UI show "busy" instead of stacking calls behind create_new.
5. **Load from `Dispatchers.IO`, never on the Qt thread.** A Qt-thread load wedges every caller, `lp_client_create` included, for the whole host bring-up. Create and cache `lp_client`s once, off the UI thread; creation blocks while the Qt thread is busy.
6. **Retry the first call after every load.** For module-to-module edges, retry a cheap edge-exercising call until it returns the expected non-empty value: 20-50 ms backoff, cap 3-5 s on device. Treat `""` or `null` with rc=0 as not-ready, never as success. Direct host-to-module calls need no retry.
7. **Events.** Subscribe after the load returns. Install `lp_client_set_subscription_status_cb` first and wait for `LP_SUB_ARMED` before triggering event-producing work (arming takes up to 250 ms, or up to 5 s if the subscription sat pending for a long time). Treat LOST followed by ARMED(gen+1) as "refetch state".
8. **Validate names.** At startup, check method and event names against `getPluginMethods` / `getPluginEvents`. Unknown methods return `null` with rc=0, and unknown events are silently accepted.

**Still unknown:**
- Nothing here was run on Android or on Qt 6.11.1. The mechanisms are protocol code, not platform code, so they should carry over (inferred).
- On-device durations are unmeasured: the race window, and load time with the libwallet_ffi dlopen.
- The first async call to a new target still does a blocking replica acquire on the Qt thread. Its size is not measured.

