// qt_loop.h -- the C interface to the only Qt C++ in liblogos_jni.so (qt_loop.cpp).
//
// Everything else in the shim (logos_jni.cpp) is plain C++ against the two C ABIs
// (logos_core.h, logos_protocol.h) and never includes a Qt header, the shape proven by
// experiments/lp-inprocess and experiments/desktop-harness.
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Hooks run ON the Qt thread.
typedef struct qtloop_hooks {
    // Posted into the loop right before exec(): runs once the loop is actually running.
    void (*on_ready)(void* ud);
    // Runs when a quit is requested (inside the loop, before it stops) and again after
    // exec() returns (before logos_core_cleanup). Must be idempotent.
    void (*teardown)(void* ud);
    void* ud;
} qtloop_hooks;

// Calls QtCore's own exported JNI_OnLoad(java_vm). Without Qt6Android.jar it stores the VM
// (g_javaVM, first statement of QtAndroidPrivate::initJNI), fails FindClass(QtNative),
// clears that exception and returns JNI_ERR (-1), which is expected and harmless. After it,
// QCoreApplication can be constructed (qt-jvmless X2, run R2). Returns -100 if QtCore
// cannot be located, -101 if it has no JNI_OnLoad.
int qtloop_prime_qtcore(void* java_vm);

// On the CALLING thread: construct QCoreApplication, then logos_core_init,
// logos_core_add_modules_dir(modules_dir), logos_core_set_persistence_base_path(persist_dir),
// logos_core_start(), and run exec(). After exec() returns: hooks->teardown, flush posted
// events, logos_core_cleanup(), destroy the QCoreApplication. Returns exec()'s result, or -1
// if a QCoreApplication already exists in this process.
int qtloop_run(const char* app_name, const char* modules_dir, const char* persist_dir,
               const qtloop_hooks* hooks);

// Posts (queued) hooks->teardown + QCoreApplication::quit() to the loop. 0 if posted,
// -1 if no loop is running.
int qtloop_quit(void);

// 1 while exec() is running.
int qtloop_is_running(void);

// qVersion() of the loaded QtCore (static string).
const char* qtloop_qt_version(void);

#ifdef __cplusplus
}
#endif
