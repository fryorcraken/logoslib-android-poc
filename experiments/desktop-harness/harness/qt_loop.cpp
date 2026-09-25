// desktop-harness: the ONLY Qt C++ in the host. A dedicated std::thread owns
// QCoreApplication + liblogos (init/start/exec/cleanup), exactly the shape a
// Kotlin "logos-qt" thread running a blocking JNI nativeRun() would have.
// Extra hooks let the C driver block the Qt thread on purpose and run
// logos_core_load_module ON the Qt thread.
#include <QCoreApplication>
#include <QMetaObject>

#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>

#include <pthread.h>
#include <time.h>

extern "C" {
#include "logos_core.h"
}

extern "C" long harness_rel_ms(void);  // defined in main.c

namespace {
std::thread g_thread;
std::mutex g_mu;
std::condition_variable g_cv;
bool g_ready = false;
unsigned long g_qt_tid = 0;
}  // namespace

extern "C" unsigned long qtloop_thread_id(void)
{
    return g_qt_tid;
}

extern "C" void qtloop_start(const char* modulesDir, const char* persistDir)
{
    std::string m(modulesDir), p(persistDir);
    g_thread = std::thread([m, p]() {
        static int argc = 1;
        static char a0[] = "desktop-harness";
        static char* argv[] = {a0, nullptr};
        QCoreApplication app(argc, argv);
        g_qt_tid = (unsigned long)pthread_self();
        std::printf("[%6ld ms][qt] QCoreApplication created on thread %lu\n", harness_rel_ms(),
                    g_qt_tid);
        logos_core_init(argc, argv);
        logos_core_add_modules_dir(m.c_str());
        logos_core_set_persistence_base_path(p.c_str());
        logos_core_start();
        std::printf("[%6ld ms][qt] logos_core_start() returned\n", harness_rel_ms());
        {
            std::lock_guard<std::mutex> l(g_mu);
            g_ready = true;
        }
        g_cv.notify_all();
        const int rc = app.exec();
        std::printf("[%6ld ms][qt] exec() returned %d; logos_core_cleanup()\n", harness_rel_ms(), rc);
        logos_core_cleanup();
        std::printf("[%6ld ms][qt] cleanup done\n", harness_rel_ms());
    });
    std::unique_lock<std::mutex> l(g_mu);
    g_cv.wait(l, [] { return g_ready; });
}

// Post a task that blocks the Qt thread (no event pumping) for `ms`.
extern "C" void qtloop_block_ms(int ms)
{
    QMetaObject::invokeMethod(
        QCoreApplication::instance(),
        [ms]() {
            std::printf("[%6ld ms][qt] blocking Qt thread for %d ms\n", harness_rel_ms(), ms);
            std::this_thread::sleep_for(std::chrono::milliseconds(ms));
            std::printf("[%6ld ms][qt] unblocked\n", harness_rel_ms());
        },
        Qt::QueuedConnection);
}

// Run logos_core_load_module(name, REQUIRED_DEPS) ON the Qt thread.
// wait != 0: block the caller until it finished and return its result.
// wait == 0: post it and return -1 immediately.
extern "C" int qtloop_load_on_qt(const char* name, int wait)
{
    std::string n(name);
    auto fn = [n]() -> int {
        const long t0 = harness_rel_ms();
        std::printf("[%6ld ms][qt] load(%s) ON the Qt thread: start\n", t0, n.c_str());
        const int r = logos_core_load_module(n.c_str(), LOGOS_LOAD_REQUIRED_DEPS);
        std::printf("[%6ld ms][qt] load(%s) ON the Qt thread -> %d in %ld ms\n", harness_rel_ms(),
                    n.c_str(), r, harness_rel_ms() - t0);
        return r;
    };
    if (wait) {
        int r = -1;
        QMetaObject::invokeMethod(
            QCoreApplication::instance(), [&]() { r = fn(); }, Qt::BlockingQueuedConnection);
        return r;
    }
    QMetaObject::invokeMethod(
        QCoreApplication::instance(), [fn]() { (void)fn(); }, Qt::QueuedConnection);
    return -1;
}

// Round-trip an empty task through the Qt thread's event queue (blocking).
extern "C" void qtloop_barrier(void)
{
    QMetaObject::invokeMethod(QCoreApplication::instance(), []() {}, Qt::BlockingQueuedConnection);
}

// Free a string liblogos returned (allocated with new[]); C cannot delete[].
extern "C" void qtloop_free_core_string(char* s)
{
    delete[] s;
}

extern "C" void qtloop_stop(void)
{
    QMetaObject::invokeMethod(
        QCoreApplication::instance(), []() { QCoreApplication::quit(); }, Qt::QueuedConnection);
    g_thread.join();
}
