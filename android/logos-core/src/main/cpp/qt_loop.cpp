// qt_loop.cpp -- the ONLY Qt C++ in liblogos_jni.so.
//
// Owns the QCoreApplication on the dedicated Kotlin-created, JVM-attached "logos-qt"
// thread, starts liblogos on that same thread and runs exec() there -- the shape of
// experiments/lp-inprocess/qt_loop.cpp and experiments/desktop-harness/harness/qt_loop.cpp,
// with the JVM-less QtCore priming from experiments/qt-jvmless/src/nojvm_shim.h.
#include "qt_loop.h"

#include <QCoreApplication>
#include <QMetaObject>
#include <QtGlobal>

#include <android/log.h>
#include <dlfcn.h>
#include <jni.h>

#include <atomic>
#include <cstring>
#include <mutex>

#include "logos_core.h"

#define QTLOG(prio, ...) __android_log_print(prio, "logos-qtloop", __VA_ARGS__)

namespace {
std::mutex g_appMu;                    // guards g_app against a concurrent quit request
QCoreApplication* g_app = nullptr;     // non-null between construction and destruction
const qtloop_hooks* g_hooks = nullptr; // valid while qtloop_run() is on the stack
std::atomic<bool> g_running{false};
}  // namespace

extern "C" int qtloop_prime_qtcore(void* java_vm)
{
    // Locate QtCore through a symbol it defines, so this is independent of the
    // ABI-suffixed soname (libQt6Core_<abi>.so) and of our own JNI_OnLoad.
    Dl_info info{};
    if (!::dladdr(reinterpret_cast<void*>(&qVersion), &info) || !info.dli_fname) return -100;
    void* h = ::dlopen(info.dli_fname, RTLD_NOW | RTLD_NOLOAD);
    if (!h) return -100;
    using OnLoad = jint (*)(JavaVM*, void*);
    auto fn = reinterpret_cast<OnLoad>(::dlsym(h, "JNI_OnLoad"));
    if (!fn) return -101;
    const jint rc = fn(static_cast<JavaVM*>(java_vm), nullptr);
    QTLOG(ANDROID_LOG_INFO, "QtCore JNI_OnLoad(realVM) from %s returned %d%s", info.dli_fname, int(rc),
          rc == JNI_ERR ? " (expected without Qt6Android.jar; the VM pointer is stored)" : "");
    return int(rc);
}

extern "C" int qtloop_run(const char* app_name, const char* modules_dir, const char* persist_dir,
                          const qtloop_hooks* hooks)
{
    if (QCoreApplication::instance()) {
        QTLOG(ANDROID_LOG_ERROR, "a QCoreApplication already exists in this process");
        return -1;
    }
    // QCoreApplication keeps references to argc/argv for its whole life.
    static int argc = 1;
    static char arg0[64];
    std::strncpy(arg0, app_name && *app_name ? app_name : "logos-android", sizeof(arg0) - 1);
    static char* argv[] = {arg0, nullptr};

    int rc = 0;
    {
        QCoreApplication app(argc, argv);
        {
            std::lock_guard<std::mutex> l(g_appMu);
            g_app = &app;
            g_hooks = hooks;
        }
        QTLOG(ANDROID_LOG_INFO, "QCoreApplication created (Qt %s); starting liblogos with modules=%s persist=%s",
              qVersion(), modules_dir, persist_dir);

        logos_core_init(argc, argv);  // a no-op in db45024, kept for older/newer cores
        logos_core_add_modules_dir(modules_dir);
        logos_core_set_persistence_base_path(persist_dir);  // must precede logos_core_start()
        logos_core_start();
        QTLOG(ANDROID_LOG_INFO, "logos_core_start() returned; entering exec()");

        if (hooks && hooks->on_ready) {
            QMetaObject::invokeMethod(
                &app, [hooks]() { hooks->on_ready(hooks->ud); }, Qt::QueuedConnection);
        }
        g_running = true;
        rc = app.exec();
        g_running = false;
        QTLOG(ANDROID_LOG_INFO, "exec() returned %d; tearing down", rc);

        if (hooks && hooks->teardown) hooks->teardown(hooks->ud);
        // Deliver anything still queued for this thread (e.g. an lp_client_create that a
        // worker posted just before the quit), so no caller stays blocked on us.
        QCoreApplication::sendPostedEvents();
        logos_core_cleanup();
        QTLOG(ANDROID_LOG_INFO, "logos_core_cleanup() done");

        std::lock_guard<std::mutex> l(g_appMu);
        g_app = nullptr;
        g_hooks = nullptr;
    }
    return rc;
}

extern "C" int qtloop_quit(void)
{
    std::lock_guard<std::mutex> l(g_appMu);
    if (!g_app) return -1;
    const qtloop_hooks* hooks = g_hooks;
    QMetaObject::invokeMethod(
        g_app,
        [hooks]() {
            // Tear the lp_* handles down while the loop still runs (they are owned by
            // this thread), then stop the loop.
            if (hooks && hooks->teardown) hooks->teardown(hooks->ud);
            QCoreApplication::quit();
        },
        Qt::QueuedConnection);
    return 0;
}

extern "C" int qtloop_is_running(void)
{
    return g_running ? 1 : 0;
}

extern "C" const char* qtloop_qt_version(void)
{
    return qVersion();
}
