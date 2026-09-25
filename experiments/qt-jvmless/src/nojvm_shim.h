// qt-jvmless: make the official Qt-for-Android QtCore usable in a process that
// has NO JavaVM (a helper executable exec'd from nativeLibraryDir).
//
// Problem (verified on emulator): QCoreApplication's constructor on Android
// unconditionally reaches QJniEnvironment::getJniEnv(), which dereferences
// QtAndroidPrivate::javaVM() without a null check:
//   QCoreApplicationPrivate::init()
//     -> appVersion()            (qcoreapplication.cpp:202, skipped if setApplicationVersion() was called)
//     -> QLoggingRegistry::initializeRules() (qcoreapplication.cpp:827, unconditional on Android)
//          -> QStandardPaths::locateAll(GenericConfigLocation) -> getFilesDir() -> QJniObject
//
// Shim: hand QtCore a fake JavaVM whose JNIEnv function table returns 0/NULL
// for every call. We call QtCore's own exported JNI_OnLoad with it; initJNI()
// stores g_javaVM = vm as its first statement, then fails (FindClass -> NULL)
// and returns JNI_ERR, which we ignore. From then on every Qt JNI path sees
// "no context / invalid object" and degrades to empty results instead of crashing.
#pragma once

#include <QtGlobal>

#include <jni.h>

#include <dlfcn.h>

#include <cstddef>

namespace qjl {
namespace nojvm {

inline void* nullStub() { return nullptr; }

inline JNIEnv* fakeEnv();
inline JavaVM* fakeVm();

inline jint JNICALL vmDestroy(JavaVM*) { return JNI_OK; }
inline jint JNICALL vmAttach(JavaVM*, JNIEnv** env, void*) { *env = fakeEnv(); return JNI_OK; }
inline jint JNICALL vmDetach(JavaVM*) { return JNI_OK; }
inline jint JNICALL vmGetEnv(JavaVM*, void** env, jint) { *env = fakeEnv(); return JNI_OK; }
inline jint JNICALL envGetJavaVM(JNIEnv*, JavaVM** vm) { *vm = fakeVm(); return JNI_OK; }

inline JNIEnv* fakeEnv()
{
    static void* table[sizeof(JNINativeInterface) / sizeof(void*)];
    static _JNIEnv env;
    static bool init = false;
    if (!init) {
        for (auto& slot : table) slot = reinterpret_cast<void*>(&nullStub);
        auto* fns = reinterpret_cast<JNINativeInterface*>(table);
        fns->GetJavaVM = &envGetJavaVM;
        env.functions = fns;
        init = true;
    }
    return &env;
}

inline JavaVM* fakeVm()
{
    static JNIInvokeInterface iface = {nullptr, nullptr, nullptr,
                                       &vmDestroy, &vmAttach, &vmDetach, &vmGetEnv, &vmAttach};
    static _JavaVM vm;
    vm.functions = &iface;
    return &vm;
}

// Calls QtCore's JNI_OnLoad(vm) directly. Returns QtCore's return value
// (JNI_ERR is expected and harmless: g_javaVM is already stored), or -100/-101
// if QtCore / its JNI_OnLoad could not be found. QtCore is located via dladdr()
// on qVersion(), so this is independent of the ABI-suffixed soname
// (libQt6Core_<abi>.so) and of the caller defining its own JNI_OnLoad.
inline int primeQtCore(JavaVM* vm)
{
    Dl_info info{};
    if (!::dladdr(reinterpret_cast<void*>(&qVersion), &info) || !info.dli_fname) return -100;
    void* h = ::dlopen(info.dli_fname, RTLD_NOW | RTLD_NOLOAD);
    if (!h) return -100;
    using OnLoad = jint (*)(JavaVM*, void*);
    auto fn = reinterpret_cast<OnLoad>(::dlsym(h, "JNI_OnLoad"));
    if (!fn) return -101;
    return fn(vm, nullptr);
}

} // namespace nojvm
} // namespace qjl
