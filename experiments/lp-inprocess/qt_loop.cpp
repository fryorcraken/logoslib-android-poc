// The ONLY Qt C++ in the lp_* route: own a QCoreApplication on a dedicated
// thread, start liblogos on that same thread, and run exec() there. Mirrors
// what an Android app would do from a Kotlin-created thread via JNI.
#include <QCoreApplication>
#include <QMetaObject>

#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>

#include <pthread.h>

extern "C" {
#include "logos_core.h"
}

namespace {
std::thread g_thread;
std::mutex g_mu;
std::condition_variable g_cv;
bool g_ready = false;
}  // namespace

extern "C" void qtloop_start(const char* modulesDir, const char* persistDir)
{
    std::string m(modulesDir), p(persistDir);
    g_thread = std::thread([m, p]() {
        static int argc = 1;
        static char a0[] = "call-routes-exp";
        static char* argv[] = {a0, nullptr};
        QCoreApplication app(argc, argv);
        std::printf("[qt] QCoreApplication created on thread %lu\n",
                    (unsigned long)pthread_self());
        logos_core_init(argc, argv);
        logos_core_add_modules_dir(m.c_str());
        logos_core_set_persistence_base_path(p.c_str());
        logos_core_start();
        std::printf("[qt] logos_core_start() returned on thread %lu\n",
                    (unsigned long)pthread_self());
        {
            std::lock_guard<std::mutex> l(g_mu);
            g_ready = true;
        }
        g_cv.notify_all();
        const int rc = app.exec();
        std::printf("[qt] exec() returned %d; cleaning up\n", rc);
        logos_core_cleanup();
    });
    std::unique_lock<std::mutex> l(g_mu);
    g_cv.wait(l, [] { return g_ready; });
}

extern "C" void qtloop_stop(void)
{
    QMetaObject::invokeMethod(
        QCoreApplication::instance(), []() { QCoreApplication::quit(); },
        Qt::QueuedConnection);
    g_thread.join();
}
