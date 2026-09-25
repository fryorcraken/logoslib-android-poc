// logos_jni.cpp -- JNI bridge between com.fryorcraken.logoslib.core (Kotlin) and liblogos.
//
// Talks only to the two C ABIs:
//   logos_core.h      (logos-liblogos db45024)      start/discover/load modules
//   logos_protocol.h  (logos-protocol 8bbc027, 0.9)  lp_client / lp_invoke_async / lp_subscribe
// The single Qt-owning piece (QCoreApplication + exec) lives in qt_loop.cpp.
//
// Design (docs/plan.md "Host threading"; experiments/desktop-harness):
//  * JNI_OnLoad is our own: it caches the JavaVM and the callback method IDs, then calls
//    QtCore's JNI_OnLoad(realVM) and ignores its JNI_ERR (no Qt6Android.jar is shipped).
//    Without our own JNI_OnLoad, ART would find QtCore's through DT_NEEDED and fail
//    System.loadLibrary (qt-jvmless run R4).
//  * nativeRun blocks the Kotlin "logos-qt" thread in qtloop_run(); every lp_* callback
//    arrives on that thread and is forwarded to a static Kotlin method, which only hands off.
//  * Calls are lp_invoke_async with the Kotlin call id as user_data and a native
//    id -> pending map: Kotlin forgets an id on timeout (nativeCancelCall) and the late
//    callback is dropped here.
//  * One cached lp_client per target module (creation blocks until the Qt thread runs it),
//    with a per-client subscription status callback.
//  * logos_core_* strings are new[]-allocated (freed with delete[]); lp_* strings with
//    lp_string_free.
//  * Strings cross JNI as UTF-16 (NewString/GetStringRegion), not "modified UTF-8": JSON
//    from modules may contain 4-byte UTF-8, which NewStringUTF rejects under CheckJNI.
#include <jni.h>

#include <android/log.h>

#include <atomic>
#include <cstdint>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "logos_core.h"
#include "logos_protocol.h"
#include "qt_loop.h"
#include "stdio_logcat.h"

#define LOG_TAG "logos-jni"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)

static_assert(sizeof(void*) >= sizeof(jlong), "call/listener ids travel as lp_* user_data pointers");

namespace {

constexpr const char* kBridgeClass = "com/fryorcraken/logoslib/core/internal/LogosNative";
constexpr jint kErrNotRunning = -100;  // LogosNative.ERR_NOT_RUNNING
constexpr jint kErrNoClient = -101;    // LogosNative.ERR_NO_CLIENT

JavaVM* g_vm = nullptr;
jclass g_bridge = nullptr;  // global ref, resolved in JNI_OnLoad (app class loader)
jmethodID g_onReady = nullptr;
jmethodID g_onInvokeResult = nullptr;
jmethodID g_onEvent = nullptr;
jmethodID g_onSubscriptionStatus = nullptr;
int g_qtcorePrimeRc = 0;

std::atomic<bool> g_accepting{false};  // true between "ready" and the quit request

std::mutex g_originMu;
std::string g_origin = "android_host";

struct ClientEntry {
    std::string module;
    lp_client* client = nullptr;
};
std::mutex g_clientsMu;
std::map<std::string, std::unique_ptr<ClientEntry>> g_clients;

struct PendingCall {
    std::string module;
    std::string method;
};
std::mutex g_pendingMu;
std::unordered_map<jlong, PendingCall> g_pending;

struct Listener {
    lp_subscription* sub = nullptr;
    std::string module;
    std::string event;
};
std::mutex g_subsMu;
std::unordered_map<jlong, Listener> g_subs;

// ------------------------------------------------------------------ strings

void appendUtf8(std::string& out, uint32_t cp)
{
    if (cp < 0x80) {
        out.push_back(char(cp));
    } else if (cp < 0x800) {
        out.push_back(char(0xC0 | (cp >> 6)));
        out.push_back(char(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        out.push_back(char(0xE0 | (cp >> 12)));
        out.push_back(char(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(char(0x80 | (cp & 0x3F)));
    } else {
        out.push_back(char(0xF0 | (cp >> 18)));
        out.push_back(char(0x80 | ((cp >> 12) & 0x3F)));
        out.push_back(char(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(char(0x80 | (cp & 0x3F)));
    }
}

// Java String (UTF-16) -> standard UTF-8. Lone surrogates become U+FFFD.
std::string toUtf8(JNIEnv* env, jstring s)
{
    if (!s) return {};
    const jsize len = env->GetStringLength(s);
    std::vector<jchar> buf(size_t(len) + 1);
    env->GetStringRegion(s, 0, len, buf.data());
    std::string out;
    out.reserve(size_t(len) + 8);
    for (jsize i = 0; i < len; ++i) {
        uint32_t cp = buf[size_t(i)];
        if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < len && buf[size_t(i) + 1] >= 0xDC00 &&
            buf[size_t(i) + 1] <= 0xDFFF) {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (buf[size_t(i) + 1] - 0xDC00);
            ++i;
        } else if (cp >= 0xD800 && cp <= 0xDFFF) {
            cp = 0xFFFD;
        }
        appendUtf8(out, cp);
    }
    return out;
}

// UTF-8 -> Java String. Invalid sequences become U+FFFD (never aborts under CheckJNI).
jstring toJString(JNIEnv* env, const char* s)
{
    if (!s) return nullptr;
    const auto* p = reinterpret_cast<const unsigned char*>(s);
    const size_t n = std::strlen(s);
    std::vector<jchar> out;
    out.reserve(n);
    size_t i = 0;
    while (i < n) {
        const unsigned char c = p[i];
        uint32_t cp = 0xFFFD;
        size_t need = 0;
        if (c < 0x80) {
            cp = c;
        } else if ((c & 0xE0) == 0xC0) {
            cp = c & 0x1F;
            need = 1;
        } else if ((c & 0xF0) == 0xE0) {
            cp = c & 0x0F;
            need = 2;
        } else if ((c & 0xF8) == 0xF0) {
            cp = c & 0x07;
            need = 3;
        } else {
            out.push_back(0xFFFD);
            ++i;
            continue;
        }
        bool ok = i + need < n;  // every continuation byte i+1..i+need is in range
        for (size_t k = 1; ok && k <= need; ++k) {
            if ((p[i + k] & 0xC0) != 0x80) {
                ok = false;
            } else {
                cp = (cp << 6) | (p[i + k] & 0x3F);
            }
        }
        static const uint32_t kMin[4] = {0, 0x80, 0x800, 0x10000};
        if (!ok || cp < kMin[need] || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
            out.push_back(0xFFFD);
            ++i;  // resynchronise on the next byte
            continue;
        }
        if (cp >= 0x10000) {
            cp -= 0x10000;
            out.push_back(jchar(0xD800 + (cp >> 10)));
            out.push_back(jchar(0xDC00 + (cp & 0x3FF)));
        } else {
            out.push_back(jchar(cp));
        }
        i += need + 1;
    }
    static const jchar kEmpty = 0;
    return env->NewString(out.empty() ? &kEmpty : out.data(), jsize(out.size()));
}

// ------------------------------------------------------------------ JNIEnv for callbacks

// lp_* callbacks normally run on the (JVM-attached) logos-qt thread, but logos_protocol.h
// allows "an internal protocol thread": attach for the duration of the callback then.
// A local frame keeps the long-running nativeRun frame from accumulating local refs.
class CallbackEnv {
public:
    CallbackEnv()
    {
        if (!g_vm) return;
        const jint rc = g_vm->GetEnv(reinterpret_cast<void**>(&env_), JNI_VERSION_1_6);
        if (rc == JNI_EDETACHED) {
            JavaVMAttachArgs args{JNI_VERSION_1_6, const_cast<char*>("logos-cb"), nullptr};
            if (g_vm->AttachCurrentThread(&env_, &args) == JNI_OK) {
                attached_ = true;
            } else {
                env_ = nullptr;
            }
        } else if (rc != JNI_OK) {
            env_ = nullptr;
        }
        if (env_ && env_->PushLocalFrame(8) != JNI_OK) {
            env_->ExceptionClear();
            framed_ = false;
        } else if (env_) {
            framed_ = true;
        }
    }
    ~CallbackEnv()
    {
        if (env_) {
            if (env_->ExceptionCheck()) {
                env_->ExceptionDescribe();
                env_->ExceptionClear();
            }
            if (framed_) env_->PopLocalFrame(nullptr);
        }
        if (attached_) g_vm->DetachCurrentThread();
    }
    JNIEnv* get() const { return env_; }

private:
    JNIEnv* env_ = nullptr;
    bool attached_ = false;
    bool framed_ = false;
};

bool ready_for_calls(JNIEnv*)
{
    return g_accepting.load() && g_bridge;
}

// ------------------------------------------------------------------ lp_* callbacks

void on_result(int ok, const char* json, void* ud)
{
    const jlong id = static_cast<jlong>(reinterpret_cast<intptr_t>(ud));
    {
        std::lock_guard<std::mutex> l(g_pendingMu);
        auto it = g_pending.find(id);
        if (it == g_pending.end()) {
            LOGD("late result for call %lld dropped", static_cast<long long>(id));
            return;
        }
        g_pending.erase(it);
    }
    CallbackEnv ce;
    JNIEnv* env = ce.get();
    if (!env) return;
    jstring j = toJString(env, json ? json : "null");
    env->CallStaticVoidMethod(g_bridge, g_onInvokeResult, id, jboolean(ok ? JNI_TRUE : JNI_FALSE), j);
}

void on_event(const char* event_name, const char* data_json, void* ud)
{
    const jlong id = static_cast<jlong>(reinterpret_cast<intptr_t>(ud));
    CallbackEnv ce;
    JNIEnv* env = ce.get();
    if (!env) return;
    jstring jn = toJString(env, event_name ? event_name : "");
    jstring jd = toJString(env, data_json ? data_json : "[]");
    env->CallStaticVoidMethod(g_bridge, g_onEvent, id, jn, jd);
}

void on_status(int state, unsigned long long generation, const char* reason, void* ud)
{
    const auto* entry = static_cast<const ClientEntry*>(ud);
    CallbackEnv ce;
    JNIEnv* env = ce.get();
    if (!env || !entry) return;
    jstring jm = toJString(env, entry->module.c_str());
    jstring jr = reason ? toJString(env, reason) : nullptr;
    env->CallStaticVoidMethod(g_bridge, g_onSubscriptionStatus, jm, jint(state), jlong(generation), jr);
}

// ------------------------------------------------------------------ clients

// Returns the cached client for `module`, creating it on first use. Creation blocks until
// the Qt thread has run it, so the map lock is NOT held across lp_client_create (the Qt
// thread takes it during teardown).
lp_client* client_for(const std::string& module)
{
    {
        std::lock_guard<std::mutex> l(g_clientsMu);
        auto it = g_clients.find(module);
        if (it != g_clients.end()) return it->second->client;
    }
    std::string origin;
    {
        std::lock_guard<std::mutex> l(g_originMu);
        origin = g_origin;
    }
    auto entry = std::make_unique<ClientEntry>();
    entry->module = module;
    entry->client = lp_client_create(module.c_str(), origin.c_str(), nullptr, nullptr);
    if (!entry->client) {
        LOGE("lp_client_create(%s) returned NULL", module.c_str());
        return nullptr;
    }
    lp_client_set_subscription_status_cb(entry->client, &on_status, entry.get());

    std::unique_ptr<ClientEntry> loser;
    lp_client* result = nullptr;
    {
        std::lock_guard<std::mutex> l(g_clientsMu);
        auto it = g_clients.find(module);
        if (it != g_clients.end() || !g_accepting.load()) {
            // Lost a creation race, or the runtime is shutting down.
            loser = std::move(entry);
            result = it != g_clients.end() ? it->second->client : nullptr;
        } else {
            result = entry->client;
            g_clients.emplace(module, std::move(entry));
        }
    }
    if (loser) {
        lp_client_set_subscription_status_cb(loser->client, nullptr, nullptr);
        lp_client_destroy(loser->client);
    }
    if (result) LOGI("lp client for %s ready (origin %s)", module.c_str(), origin.c_str());
    return result;
}

// Runs on the Qt thread: when a quit is requested (loop still running) and again after
// exec() returned. Idempotent.
void teardown_hook(void*)
{
    g_accepting = false;
    std::vector<lp_subscription*> subs;
    {
        std::lock_guard<std::mutex> l(g_subsMu);
        for (auto& kv : g_subs) subs.push_back(kv.second.sub);
        g_subs.clear();
    }
    for (lp_subscription* s : subs) lp_unsubscribe(s);

    std::map<std::string, std::unique_ptr<ClientEntry>> clients;
    {
        std::lock_guard<std::mutex> l(g_clientsMu);
        clients.swap(g_clients);
    }
    for (auto& kv : clients) {
        lp_client_set_subscription_status_cb(kv.second->client, nullptr, nullptr);
        lp_client_destroy(kv.second->client);
    }
    size_t dropped = 0;
    {
        std::lock_guard<std::mutex> l(g_pendingMu);
        dropped = g_pending.size();
        g_pending.clear();
    }
    if (!subs.empty() || !clients.empty() || dropped)
        LOGI("teardown: %zu subscription(s), %zu client(s), %zu pending call(s) dropped", subs.size(),
             clients.size(), dropped);
}

void ready_hook(void*)
{
    g_accepting = true;
    LOGI("Qt loop running; liblogos ready");
    CallbackEnv ce;
    if (JNIEnv* env = ce.get()) env->CallStaticVoidMethod(g_bridge, g_onReady);
}

jobjectArray to_string_array(JNIEnv* env, char** arr)
{
    std::vector<std::string> names;
    if (arr) {
        for (char** p = arr; *p; ++p) {
            names.emplace_back(*p);
            delete[] *p;  // logos_core_* strings are new[]-allocated
        }
        delete[] arr;
    }
    jclass stringClass = env->FindClass("java/lang/String");
    jobjectArray out = env->NewObjectArray(jsize(names.size()), stringClass, nullptr);
    for (size_t i = 0; i < names.size(); ++i) {
        jstring s = toJString(env, names[i].c_str());
        env->SetObjectArrayElement(out, jsize(i), s);
        env->DeleteLocalRef(s);
    }
    env->DeleteLocalRef(stringClass);
    return out;
}

}  // namespace

// ====================================================================== JNI_OnLoad

extern "C" JNIEXPORT jint JNI_OnLoad(JavaVM* vm, void*)
{
    g_vm = vm;
    JNIEnv* env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;

    jclass local = env->FindClass(kBridgeClass);
    if (!local) {
        env->ExceptionClear();
        LOGE("JNI_OnLoad: class %s not found", kBridgeClass);
        return JNI_ERR;
    }
    g_bridge = static_cast<jclass>(env->NewGlobalRef(local));
    env->DeleteLocalRef(local);
    g_onReady = env->GetStaticMethodID(g_bridge, "onReady", "()V");
    g_onInvokeResult = env->GetStaticMethodID(g_bridge, "onInvokeResult", "(JZLjava/lang/String;)V");
    g_onEvent = env->GetStaticMethodID(g_bridge, "onEvent", "(JLjava/lang/String;Ljava/lang/String;)V");
    g_onSubscriptionStatus =
        env->GetStaticMethodID(g_bridge, "onSubscriptionStatus", "(Ljava/lang/String;IJLjava/lang/String;)V");
    if (!g_onReady || !g_onInvokeResult || !g_onEvent || !g_onSubscriptionStatus) {
        env->ExceptionClear();
        LOGE("JNI_OnLoad: callback methods missing on %s", kBridgeClass);
        return JNI_ERR;
    }

    // Give QtCore the real JavaVM before anything constructs a QCoreApplication (its
    // constructor dereferences the VM on Android). JNI_ERR is expected: no Qt6Android.jar.
    g_qtcorePrimeRc = qtloop_prime_qtcore(vm);
    if (env->ExceptionCheck()) env->ExceptionClear();
    LOGI("JNI_OnLoad: liblogos_jni loaded; QtCore JNI_OnLoad(realVM) -> %d; lp protocol %s",
         g_qtcorePrimeRc, lp_protocol_version());
    return JNI_VERSION_1_6;
}

// ====================================================================== lifecycle

#define JNI_FN(name) Java_com_fryorcraken_logoslib_core_internal_LogosNative_##name

extern "C" JNIEXPORT jint JNICALL JNI_FN(nativeRun)(JNIEnv* env, jclass, jstring jModulesDir, jstring jPersistDir,
                                                      jstring jAppName, jstring jOrigin)
{
    const std::string modulesDir = toUtf8(env, jModulesDir);
    const std::string persistDir = toUtf8(env, jPersistDir);
    const std::string appName = toUtf8(env, jAppName);
    {
        std::lock_guard<std::mutex> l(g_originMu);
        g_origin = toUtf8(env, jOrigin);
        if (g_origin.empty()) g_origin = "android_host";
    }
    qtloop_hooks hooks{&ready_hook, &teardown_hook, nullptr};
    LOGI("nativeRun: modules=%s persist=%s", modulesDir.c_str(), persistDir.c_str());
    const int rc = qtloop_run(appName.c_str(), modulesDir.c_str(), persistDir.c_str(), &hooks);
    g_accepting = false;
    LOGI("nativeRun: returning %d", rc);
    return rc;
}

extern "C" JNIEXPORT jboolean JNICALL JNI_FN(nativeStop)(JNIEnv*, jclass)
{
    g_accepting = false;  // no new clients/calls from now on
    return qtloop_quit() == 0 ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL JNI_FN(nativeIsRunning)(JNIEnv*, jclass)
{
    return qtloop_is_running() ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL JNI_FN(nativeRedirectStdio)(JNIEnv* env, jclass, jstring jTag)
{
    const std::string tag = toUtf8(env, jTag);
    return stdio_logcat_start(tag.c_str()) ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jint JNICALL JNI_FN(nativeQtCorePrimeResult)(JNIEnv*, jclass)
{
    return g_qtcorePrimeRc;
}

extern "C" JNIEXPORT jstring JNICALL JNI_FN(nativeQtVersion)(JNIEnv* env, jclass)
{
    return toJString(env, qtloop_qt_version());
}

extern "C" JNIEXPORT jstring JNICALL JNI_FN(nativeProtocolVersion)(JNIEnv* env, jclass)
{
    return toJString(env, lp_protocol_version());  // static string: not freed
}

// ====================================================================== logos_core_*

extern "C" JNIEXPORT jobjectArray JNICALL JNI_FN(nativeKnownModules)(JNIEnv* env, jclass)
{
    return to_string_array(env, logos_core_get_known_modules());
}

extern "C" JNIEXPORT jobjectArray JNICALL JNI_FN(nativeLoadedModules)(JNIEnv* env, jclass)
{
    return to_string_array(env, logos_core_get_loaded_modules());
}

extern "C" JNIEXPORT jstring JNICALL JNI_FN(nativeModulesInfo)(JNIEnv* env, jclass)
{
    char* s = logos_core_get_modules_info();
    jstring out = s ? toJString(env, s) : nullptr;
    delete[] s;
    return out;
}

extern "C" JNIEXPORT jint JNICALL JNI_FN(nativeLoadModule)(JNIEnv* env, jclass, jstring jName, jint deps)
{
    const std::string name = toUtf8(env, jName);
    if (name.empty()) return 0;  // logos_core_load_module aborts on NULL; refuse "" too
    LogosLoadDeps d = LOGOS_LOAD_REQUIRED_DEPS;
    if (deps == 0) d = LOGOS_LOAD_MODULE_ONLY;
    if (deps == 2) d = LOGOS_LOAD_REQUIRED_AND_OPTIONAL;
    LOGI("load_module(%s, deps=%d) ...", name.c_str(), int(deps));
    const int rc = logos_core_load_module(name.c_str(), d);
    LOGI("load_module(%s) -> %d", name.c_str(), rc);
    return rc;
}

extern "C" JNIEXPORT jint JNICALL JNI_FN(nativeUnloadModule)(JNIEnv* env, jclass, jstring jName,
                                                               jboolean withDependents)
{
    const std::string name = toUtf8(env, jName);
    if (name.empty()) return 0;
    return logos_core_unload_module(name.c_str(), withDependents == JNI_TRUE);
}

// ====================================================================== lp_*

extern "C" JNIEXPORT jint JNICALL JNI_FN(nativeInvokeAsync)(JNIEnv* env, jclass, jstring jModule, jstring jMethod,
                                                              jstring jArgs, jint timeoutMs, jlong callId)
{
    if (!ready_for_calls(env)) return kErrNotRunning;
    const std::string module = toUtf8(env, jModule);
    const std::string method = toUtf8(env, jMethod);
    const std::string args = jArgs ? toUtf8(env, jArgs) : std::string("[]");
    lp_client* c = client_for(module);
    if (!c) return g_accepting.load() ? kErrNoClient : kErrNotRunning;
    {
        std::lock_guard<std::mutex> l(g_pendingMu);
        g_pending[callId] = PendingCall{module, method};
    }
    // The callback may fire (on the Qt thread) before this returns: the id is registered first.
    const int rc = lp_invoke_async(c, method.c_str(), args.c_str(), int(timeoutMs), &on_result,
                                   reinterpret_cast<void*>(static_cast<intptr_t>(callId)));
    if (rc != LP_OK) {
        std::lock_guard<std::mutex> l(g_pendingMu);
        g_pending.erase(callId);  // not dispatched: the callback will not fire
        LOGW("lp_invoke_async(%s.%s) rc=%d", module.c_str(), method.c_str(), rc);
    }
    return rc;
}

extern "C" JNIEXPORT jboolean JNICALL JNI_FN(nativeCancelCall)(JNIEnv*, jclass, jlong callId)
{
    std::lock_guard<std::mutex> l(g_pendingMu);
    return g_pending.erase(callId) ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jint JNICALL JNI_FN(nativeSubscribe)(JNIEnv* env, jclass, jstring jModule, jstring jEvent,
                                                            jlong listenerId)
{
    if (!ready_for_calls(env)) return kErrNotRunning;
    const std::string module = toUtf8(env, jModule);
    const std::string event = toUtf8(env, jEvent);
    lp_client* c = client_for(module);
    if (!c) return g_accepting.load() ? kErrNoClient : kErrNotRunning;
    lp_subscription* sub =
        lp_subscribe(c, event.c_str(), &on_event, reinterpret_cast<void*>(static_cast<intptr_t>(listenerId)));
    if (!sub) return LP_ERR_INVALID_ARG;
    {
        std::lock_guard<std::mutex> l(g_subsMu);
        g_subs[listenerId] = Listener{sub, module, event};
    }
    LOGI("subscribed %s::%s (listener %lld)", module.c_str(), event.c_str(), static_cast<long long>(listenerId));
    return 0;
}

extern "C" JNIEXPORT void JNICALL JNI_FN(nativeUnsubscribe)(JNIEnv*, jclass, jlong listenerId)
{
    lp_subscription* sub = nullptr;
    {
        std::lock_guard<std::mutex> l(g_subsMu);
        auto it = g_subs.find(listenerId);
        if (it == g_subs.end()) return;
        sub = it->second.sub;
        g_subs.erase(it);
    }
    // Synchronous part: after this returns the callback no longer fires. Never called from
    // inside an event callback (Kotlin callbacks only trySend), so no self-wait.
    lp_unsubscribe(sub);
}

extern "C" JNIEXPORT jstring JNICALL JNI_FN(nativePendingSubscriptions)(JNIEnv* env, jclass, jstring jModule)
{
    const std::string module = toUtf8(env, jModule);
    lp_client* c = nullptr;
    {
        std::lock_guard<std::mutex> l(g_clientsMu);
        auto it = g_clients.find(module);
        if (it != g_clients.end()) c = it->second->client;
    }
    if (!c) return nullptr;
    char* s = lp_pending_subscriptions(c);
    jstring out = s ? toJString(env, s) : nullptr;
    lp_string_free(s);
    return out;
}
