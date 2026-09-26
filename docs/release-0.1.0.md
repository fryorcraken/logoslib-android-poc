# Logos Core Demo 0.1.0 (arm64, proof of concept)

| | |
| --- | --- |
| File | `logoslib-android-poc-0.1.0-arm64-v8a.apk`, 80,178,548 bytes |
| SHA-256 | `d8551d327bceb3dbde51ce3c14a1f6bbcf7c6c6712b132b183c02a900b06e569` |
| App | Logos Core Demo, `com.fryorcraken.logoslib.demo`, version 0.1.0 (code 1), arm64-v8a only |
| Signed with | the Android debug certificate, SHA-256 `07d2725c66a2b08cc489a160135f2f9fed148854686bf467f1ccdf434a01afb4`. This is a POC convention, not a release key |

## What it is

A one-screen Android demo that embeds `liblogos_core`, the Logos Core module host and
loader, through a Kotlin wrapper. It runs four Logos modules, each in its own child process
started from the APK: `capability_module` (started by liblogos), `hello_module` (a test
module that answers `ping` and emits an event), `blockchain_module` (the Logos blockchain
node, which joins the public devnet 0.3.0-rc.4 as a follower and syncs it) and `bc_probe` (a
second module that reads the node's height by calling `blockchain_module` over liblogos's
own transport). It is a developer proof of concept. It holds no keys and no funds, and it
sends no transactions.

## Requirements and test status

- An arm64 (arm64-v8a) phone with Android 14 (API 34) or later.
- About 250 MB of free storage: the 80 MB APK, 24 MB of native libraries, 93 MB of module
  files extracted on the first Start, and the chain database (47 MB was measured at 5,270
  blocks; it grows with the chain).
- Internet, over UDP. The devnet bootstrap peers are at 65.108.203.235 (ports 3000-3002),
  and other peers are discovered from them. NTP uses pool.ntp.org.

Tested on:

- **x86_64 Android 14 emulator, natively**, with an x86_64 build of the same code:
  18/18 hello-module checks and 17/17 blockchain checks at M4/M5, and on 2026-09-26 a
  regression run (18/18) plus a devnet sync from genesis to the tip (6,744 blocks in 40 s).
- **This APK on the same emulator under ARM translation** (Android's `libndk_translation`,
  which runs arm64 code on x86). The hello_module sequence passes. The arm64 node joined
  devnet, synced 6,748 blocks to the tip in 175 s (translation is about 4 times slower than
  native) and served bc_probe. In one of two sync runs it lost its peers and stopped at
  height 6000 (see "Known limits"). The results are in [`android-build.md`](android-build.md),
  "Release APK".
- **Not tested on real arm64 hardware, and not on GrapheneOS.** The GrapheneOS section
  below comes from reading GrapheneOS source code and documentation.

## Install

1. Download `logoslib-android-poc-0.1.0-arm64-v8a.apk` and
   `logoslib-android-poc-0.1.0-arm64-v8a.apk.sha256` from the GitHub release.
2. Check the file. In the download folder, run one of:
   ```sh
   sha256sum -c logoslib-android-poc-0.1.0-arm64-v8a.apk.sha256          # Linux: prints "...apk: OK"
   shasum -a 256 -c logoslib-android-poc-0.1.0-arm64-v8a.apk.sha256      # macOS
   ```
   Or compare the file's SHA-256 with `d8551d32...0b06e569` above by eye.
3. Install it, either:
   - on the phone: open the APK from the browser's downloads or from the Files app. Allow
     that app to install unknown apps when Android asks, then confirm. On GrapheneOS the
     install screen shows a **Network** toggle: leave it on.
   - or from a computer with USB debugging enabled: `adb install logoslib-android-poc-0.1.0-arm64-v8a.apk`.

If an older build of `com.fryorcraken.logoslib.demo` that was signed on another machine is
installed, uninstall it first. Otherwise the install fails with
`INSTALL_FAILED_UPDATE_INCOMPATIBLE`.

## First run

Open **Logos Core Demo** and keep it in the foreground. Press the buttons from top to
bottom:

| Step | Button | What you should see |
| --- | --- | --- |
| 1 | **Start** | `Runtime: RUNNING`, and `Known modules` lists capability_module, blockchain_module, hello_module and bc_probe. The first Start after installing extracts 93 MB of module files, so it can take a few seconds (under 1 s on the emulator). |
| 2 | **Load hello** | `Loaded modules: capability_module, hello_module` |
| 3 | **Ping** | `Ping: pong` |
| 4 | **Fire** | `Last event: tag-1`, then tag-2 and so on: an event sent by the module has reached the app. **Methods** writes hello_module's method list to the log pane. |
| 5 | **Load BC** | `Blockchain: LOADED`. The node module and bc_probe now each run in their own process. |
| 6 | **Config** | `Blockchain: CONFIGURED`. A follower-mode node config is written to the app's storage. |
| 7 | **Start node** | `Blockchain: RUNNING`, and the numbers below it start moving. |

What the Blockchain lines mean:

- `chain 0.3.0-rc.4  mode Bootstrapping`: the devnet the node joined. `Bootstrapping` is
  normal, because follower mode never leaves it. `synced after N s` appears once the node
  reaches the tip.
- `height`: blocks synced so far.
- `tip slot X / now Y (lag Z)`: the slot of the newest block the node has, against the
  current slot (one slot is one second). The node is at the tip when the lag is under 180.
  `LIB slot` stays 0 in follower mode.
- `peers`, `connections`: devnet peers. Expect 3-4 within a few seconds.
- `newBlock events`: one per block the node reports to the app.
- `via bc_probe: height`: the same height, read by the second module calling the node
  module through liblogos. This is the inter-module call.
- `host pid / cpu / rss`: the node's process.

Expect the first peer within about 3 s and the tip within about a minute. The emulator
takes 40 s for today's 6,744 blocks, and a phone is likely to be somewhat slower. The
sync keeps one CPU core busy; after it, the node uses under 1 %. Data: roughly 50-60 MB of
chain database on disk. Network traffic was not measured, but should be of the same order.

**Stop node** stops the node and leaves its module loaded. **Start node** starts it again,
and the app waits up to 10 minutes while the node first replays the whole stored chain.
That took 21 s for 5,270 blocks natively on the emulator; it takes longer on a phone and
grows with the chain. The screen shows `Blockchain: STARTING (busy)` until the replay is
done.

**Stop** stops the node, if it is running, and then everything else. The runtime cannot be
restarted in the same process, so swipe the app away and open it again to start over.

## GrapheneOS

This section covers GrapheneOS 2026091900 (Android 17) on the Pixel 10a. It is based on
GrapheneOS source code and documentation, not on a test.

**With the default settings, nothing the app does is blocked:**

- Page size: GrapheneOS on the Pixel 10a uses 4 KB pages. Every library is also 16 KB-aligned.
- Dynamic code loading via storage is allowed by default. The app needs it: module plugins
  are loaded from the app's own files.
- Network is on by default, and the module processes share the app's Network permission.
- Memory tagging (MTE) is off by default for this app. It is a user-installed app, and it
  declares no `memtagMode`. v0.1.0 deliberately leaves that alone. Declaring `memtagMode`
  would force MTE on, and this native code has never run under MTE.
- hardened_malloc is on by default, for the app and for every module process. It is
  stricter than Android's standard allocator (Scudo), and this code has not run under it yet.
- Secure app spawning and native code debugging make no difference to the app.

**Settings that matter.** Per-app settings are in Settings > Apps > Logos Core Demo, and the
global defaults are in Settings > Security & privacy > Exploit protection.

| Setting | When it bites | What you see | Fix |
| --- | --- | --- | --- |
| Dynamic code loading via storage | Restricted for this app, or restricted by default for all user apps | Start or a module load fails, and module processes die. The notification says "Logos Core Demo tried to perform DCL via storage" and names a file under `files/modules/`. | Allow it for Logos Core Demo, then reopen the app. |
| Network | Turned off for the app | `peers 0` and the height stays 0. The node logs network errors, and its process may die (`Blockchain: DIED`). | Turn Network on for the app, then reopen it. |
| Memory tagging | Turned on for this app, or for all user-installed apps | Only the app process is tagged; the module processes never are. If the app's native code has a latent memory bug, the app crashes with the notification "Memory tagging detected an error in Logos Core Demo" (a `SIGSEGV` with `SEGV_MTEAERR` or `SEGV_MTESERR` in the crash log). | Turn Memory tagging off for Logos Core Demo, and please send the crash log. |
| hardened_malloc (on by default) | A latent memory bug in the app or in a module | The app crashes with "hardened_malloc detected an error in Logos Core Demo", or a module process dies (`Blockchain: DIED`, `HOST DIED` in the log). | Turn on **Exploit protection compatibility mode** for Logos Core Demo. It switches the app and its module processes to the standard allocator (and turns off memory tagging for the app). Please report it. |
| Background limits (Android) | Leaving the app during the first sync | Android may kill module processes of a background app that use a lot of CPU. It checks every 5 minutes. | Keep the app open while it syncs. Developer options > Disable child process restrictions turns the check off. |

## Known limits

- Never run on arm64 hardware (see "Requirements and test status").
- Devnet 0.3.0-rc.4 only. Each devnet release candidate changes protocol names, so the next
  devnet will leave this build behind.
- Follower only. The node never proposes blocks, so its last irreversible block stays at
  genesis, and every node restart replays the whole stored chain.
- If the node loses all its peers during the first sync, it may stop downloading and stay at
  the same height. This was seen once, under ARM translation on the emulator. **Stop node**
  then **Start node**, or reopening the app, is the thing to try.
- The node runs only while the app runs. There is no foreground service, so keep the app
  open.
- Stop is final for the process: reopen the app to start again.
- The APK is signed with the debug key, as are all builds of this POC, so treat it as a
  test build. It gets no automatic updates.
- Minify is off, and there is no crash reporter and no in-app log export.

## If it fails: logs

1. Take a screenshot of the app. The log pane at the bottom shows the last 500 lines.
2. With USB debugging on (Developer options) and `adb` on a computer:
   ```sh
   adb logcat -d -v threadtime -s LogosDemo LogosCore logos-jni logos-qtloop logos-stdio AndroidRuntime DEBUG libc > logos-demo.txt
   adb logcat -d -b crash > logos-demo-crash.txt
   ```
   `logos-stdio` carries liblogos's own log, and the output of every module process,
   including the node's. For a native crash, the full tombstone is in a bug report:
   `adb bugreport`, or Developer options > Take bug report. The release build is not
   debuggable, so `adb shell run-as` does not work on it.
3. On GrapheneOS, a crash caught by memory tagging or hardened_malloc raises a notification.
   Tap it to see the details.

## Disclaimer

This is an independent community project intended to demonstrate some of the
capabilities and potential uses of the Logos technology stack. It has been
developed independently by its contributor(s) and is not built for, on behalf
of, or as part of the work of Logos or the Institute of Free Technology. It has
not been reviewed, audited, approved, or endorsed by Logos or the Institute of
Free Technology. The project, including its code, documentation, views, and
functionality, is the sole responsibility of its contributor(s) and should not
be attributed to Logos or the Institute of Free Technology.
