// qt-jvmless: JNI bridge. On the calling (dedicated Java) thread it constructs a
// QCoreApplication once, then runs the QtRO client against the helper process.
//
// Built twice:
//   libqrotest_jni.so          defines its own JNI_OnLoad, so the JVM never calls
//                              Qt Core's JNI_OnLoad (unless Kotlin loads Qt6Core itself).
//   libqrotest_jni_noonload.so no JNI_OnLoad: bionic dlsym(handle) walks DT_NEEDED,
//                              so the JVM would find and run libQt6Core's JNI_OnLoad.
//
// jvmMode (applied before QCoreApplication is constructed):
//   none       nothing
//   realvm     call QtCore's JNI_OnLoad(<this process's real JavaVM>) ourselves
//              (for a no-Qt-jar app: initJNI stores the VM, then fails on
//              FindClass(QtNative) with JNI_ERR, which we ignore)
//   appversion QCoreApplication::setApplicationVersion only
//   shim       fake null JavaVM (nojvm_shim.h)
#include "client_core.h"

#include <QCoreApplication>
#include <QJniEnvironment>
#include <QThread>

#include <jni.h>

#include <spawn.h>
#include <unistd.h>

#include <string>
#include <vector>

namespace {
QCoreApplication* s_app = nullptr;
int s_argc = 1;
char s_arg0[] = "qrotest";
char* s_argv[] = {s_arg0, nullptr};

jstring toJ(JNIEnv* env, const QString& s)
{
    return env->NewStringUTF(s.toUtf8().constData());
}

QString ptr(const void* p)
{
    return QStringLiteral("0x%1").arg(quintptr(p), 0, 16);
}
} // namespace

#ifndef QROTEST_NO_ONLOAD
extern "C" JNIEXPORT jint JNI_OnLoad(JavaVM* vm, void*)
{
    qjl::tag() = "qrotest_jni";
    qjl::toStdout() = false;
    qjl::out(QStringLiteral("jni: libqrotest_jni own JNI_OnLoad called (vm=%1); QtCore g_javaVM=%2")
                 .arg(ptr(vm), ptr(QJniEnvironment::javaVM())));
    return JNI_VERSION_1_6;
}
#endif

// posix_spawn the helper from native code with the process environ inherited
// (as logos-container-subprocess does), instead of java.lang.ProcessBuilder.
// Returns the child pid, or -errno.
extern "C" JNIEXPORT jint JNICALL
Java_org_logos_qrotest_NativeBridge_spawnHelper(JNIEnv* env, jclass, jobjectArray jargv)
{
    qjl::tag() = "qrotest_jni";
    qjl::toStdout() = false;
    const jsize n = env->GetArrayLength(jargv);
    std::vector<std::string> args;
    for (jsize i = 0; i < n; ++i) {
        auto s = static_cast<jstring>(env->GetObjectArrayElement(jargv, i));
        const char* c = env->GetStringUTFChars(s, nullptr);
        args.emplace_back(c);
        env->ReleaseStringUTFChars(s, c);
        env->DeleteLocalRef(s);
    }
    std::vector<char*> argv;
    for (auto& a : args) argv.push_back(a.data());
    argv.push_back(nullptr);
    pid_t pid = -1;
    const int rc = ::posix_spawn(&pid, argv[0], nullptr, nullptr, argv.data(), environ);
    qjl::out(QStringLiteral("jni: posix_spawn(%1) rc=%2 pid=%3 (env inherited: TMPDIR=%4 LD_LIBRARY_PATH=%5)")
                 .arg(QString::fromStdString(args[0])).arg(rc).arg(int(pid))
                 .arg(qjl::envOr("TMPDIR"), qjl::envOr("LD_LIBRARY_PATH")));
    return rc == 0 ? jint(pid) : jint(-rc);
}

extern "C" JNIEXPORT jstring JNICALL
Java_org_logos_qrotest_NativeBridge_runClient(JNIEnv* env, jclass, jstring jurl, jint timeoutMs, jstring jmode)
{
    qjl::tag() = "qrotest_jni";
    qjl::toStdout() = false;
    auto str = [env](jstring s) {
        const char* c = env->GetStringUTFChars(s, nullptr);
        const QString r = QString::fromUtf8(c);
        env->ReleaseStringUTFChars(s, c);
        return r;
    };
    const QString url = str(jurl);
    const QString mode = str(jmode);

    if (!s_app) {
        JavaVM* realVm = nullptr;
        env->GetJavaVM(&realVm);
        qInstallMessageHandler(qjl::qtMessageHandler);
        qjl::out(QStringLiteral("jni: tid=%1 TMPDIR=%2 %3 realVm=%4 QtCore g_javaVM(before)=%5 mode=%6")
                     .arg(qint64(::gettid())).arg(qjl::envOr("TMPDIR"), qjl::jvmState(), ptr(realVm),
                          ptr(QJniEnvironment::javaVM()), mode));
        if (mode == QLatin1String("realvm")) {
            const int rc = qjl::nojvm::primeQtCore(realVm);
            qjl::out(QStringLiteral("jni: QtCore JNI_OnLoad(realVm) returned %1; g_javaVM(after)=%2")
                         .arg(rc).arg(ptr(QJniEnvironment::javaVM())));
        } else {
            qjl::applyJvmMode(mode);
        }
        qjl::out(QStringLiteral("jni: constructing QCoreApplication"));
        s_app = new QCoreApplication(s_argc, s_argv);
        qjl::out(QStringLiteral("jni: QCoreApplication OK, Qt %1, isMainThread=%2, applicationVersion='%3'")
                     .arg(QString::fromLatin1(qVersion()))
                     .arg(QThread::currentThread() == s_app->thread())
                     .arg(QCoreApplication::applicationVersion()));
    }
    const QString r = qjl::runClientOnce(url, int(timeoutMs));
    qjl::out(QStringLiteral("jni: RESULT %1").arg(r));
    return toJ(env, r);
}
