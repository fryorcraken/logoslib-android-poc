// qt-jvmless: shared helpers for qro_server / qro_client / qrotest_jni.
#pragma once

#include "nojvm_shim.h"

#include <QByteArray>
#include <QCoreApplication>
#include <QString>
#include <QtGlobal>

#include <android/log.h>
#include <dlfcn.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace qjl {

inline const char*& tag()
{
    static const char* t = "qjl";
    return t;
}

// When true, also echo to stdout (executables). The JNI lib only logs to logcat.
inline bool& toStdout()
{
    static bool b = true;
    return b;
}

inline void out(const QString& s)
{
    const QByteArray line = s.toUtf8();
    if (toStdout()) {
        std::fprintf(stdout, "[%s pid=%d] %s\n", tag(), int(::getpid()), line.constData());
        std::fflush(stdout);
    }
    __android_log_print(ANDROID_LOG_INFO, tag(), "[pid=%d] %s", int(::getpid()), line.constData());
}

inline void qtMessageHandler(QtMsgType type, const QMessageLogContext&, const QString& msg)
{
    static const char* names[] = {"debug", "warning", "critical", "fatal", "info"};
    const char* n = (type >= 0 && type <= 4) ? names[type] : "?";
    out(QStringLiteral("qt-%1: %2").arg(QLatin1String(n), msg));
}

// Is there a JavaVM in this process? JNI_GetCreatedJavaVMs is exported by
// libnativehelper (API 31+) / libart; neither is loaded in a plain exec'd binary.
inline QString jvmState()
{
    // Ground truth: is libart.so mapped into this process at all?
    int artMaps = 0;
    if (FILE* f = std::fopen("/proc/self/maps", "re")) {
        char line[1024];
        while (std::fgets(line, sizeof(line), f))
            if (std::strstr(line, "/libart.so")) ++artMaps;
        std::fclose(f);
    }
    const QString maps = QStringLiteral("libart.so mappings in /proc/self/maps=%1").arg(artMaps);
    using Fn = int (*)(void**, int, int*);
    void* sym = ::dlsym(RTLD_DEFAULT, "JNI_GetCreatedJavaVMs");
    if (!sym)
        return maps + QStringLiteral(", JNI_GetCreatedJavaVMs not visible via dlsym(RTLD_DEFAULT)");
    void* vms[1] = {nullptr};
    int n = 0;
    const int rc = reinterpret_cast<Fn>(sym)(vms, 1, &n);
    return maps + QStringLiteral(", JNI_GetCreatedJavaVMs rc=%1 count=%2").arg(rc).arg(n);
}

inline QString envOr(const char* name)
{
    const char* v = std::getenv(name);
    return v ? QString::fromLocal8Bit(v) : QStringLiteral("<unset>");
}

// Must run BEFORE QCoreApplication is constructed.
//   none       : do nothing (reproduces the crash in a JVM-less process)
//   appversion : QCoreApplication::setApplicationVersion() only (skips appVersion()'s JNI call)
//   shim       : give QtCore a fake null-returning JavaVM (see nojvm_shim.h)
inline void applyJvmMode(const QString& mode)
{
    if (mode == QLatin1String("appversion")) {
        QCoreApplication::setApplicationVersion(QStringLiteral("0.0.1"));
        out(QStringLiteral("jvm-mode=appversion: setApplicationVersion done"));
    } else if (mode == QLatin1String("shim")) {
        const int rc = nojvm::primeQtCore(nojvm::fakeVm());
        out(QStringLiteral("jvm-mode=shim: QtCore JNI_OnLoad(fakeVM) returned %1 (JNI_ERR=-1 expected; g_javaVM now set)").arg(rc));
    } else {
        out(QStringLiteral("jvm-mode=%1: no workaround").arg(mode));
    }
}

inline QString jvmModeFromEnv()
{
    const char* v = std::getenv("QJL_JVM_MODE");
    return v && *v ? QString::fromLatin1(v) : QStringLiteral("shim");
}

} // namespace qjl
