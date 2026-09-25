/* Pure C (no Qt headers): drive liblogos via logos_core_* and CALL a loaded
 * module via the lp_* C ABI from a thread that is NOT the Qt thread -- the
 * shape a JNI shim would have on Android (Kotlin worker thread -> JNI -> C). */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "logos_core.h"
#include "logos_protocol.h"

void qtloop_start(const char* modulesDir, const char* persistDir);
void qtloop_stop(void);

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cv = PTHREAD_COND_INITIALIZER;
static int g_done = 0;

static long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

static void on_result(int ok, const char* json, void* ud)
{
    (void)ud;
    printf("[async-cb] on thread %lu ok=%d json=%s\n",
           (unsigned long)pthread_self(), ok, json ? json : "(null)");
    pthread_mutex_lock(&g_mu);
    g_done = 1;
    pthread_cond_signal(&g_cv);
    pthread_mutex_unlock(&g_mu);
}

static void call_once_t(lp_client* c, const char* method, const char* args, int timeout_ms)
{
    char* out = NULL;
    char* err = NULL;
    long t0 = now_ms();
    int rc = lp_invoke(c, method, args, timeout_ms, &out, &err);
    printf("[main] lp_invoke(%s, %s) rc=%d in %ld ms result=%s error=%s\n", method, args,
           rc, now_ms() - t0, out ? out : "(null)", err ? err : "(null)");
    lp_string_free(out);
    lp_string_free(err);
}

static void call_once(lp_client* c, const char* method, const char* args)
{
    call_once_t(c, method, args, 15000);
}

int main(int argc, char** argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s MODULES_DIR PERSIST_DIR TARGET\n", argv[0]);
        return 2;
    }
    const char* modules = argv[1];
    const char* persist = argv[2];
    const char* target = argv[3];
    setvbuf(stdout, NULL, _IONBF, 0);

    printf("[main] main thread %lu\n", (unsigned long)pthread_self());
    qtloop_start(modules, persist);
    printf("[main] runtime up; lp_protocol_version=%s mode=%s\n", lp_protocol_version(),
           lp_get_mode());

    long t0 = now_ms();
    int loaded = logos_core_load_module(target, LOGOS_LOAD_REQUIRED_DEPS);
    printf("[main] logos_core_load_module(%s) from NON-Qt thread -> %d in %ld ms\n", target,
           loaded, now_ms() - t0);

    printf("[main] sockets under TMPDIR while running:\n");
    fflush(stdout);
    system("ls -la \"$TMPDIR\"");

    /* Token presence only (value not printed). Allocated with new[] by
     * liblogos; deliberately leaked here because C cannot delete[]. */
    char* tok = logos_core_get_token(target);
    printf("[main] host TokenManager holds a token for %s: %s\n", target, tok ? "yes" : "no");

    t0 = now_ms();
    lp_client* c = lp_client_create(target, "android_host", NULL, NULL);
    printf("[main] lp_client_create -> %p in %ld ms\n", (void*)c, now_ms() - t0);
    if (!c) {
        qtloop_stop();
        return 1;
    }

    char* methods = lp_get_methods(c);
    if (methods) {
        size_t n = strlen(methods);
        printf("[main] lp_get_methods: %zu bytes: %.400s%s\n", n, methods, n > 400 ? " ..." : "");
        lp_string_free(methods);
    } else {
        printf("[main] lp_get_methods returned NULL\n");
    }

    call_once(c, "version", "[]");
    call_once(c, "name", "[]");
    call_once(c, "account_id_to_base58",
              "[\"0000000000000000000000000000000000000000000000000000000000000001\"]");
    call_once(c, "no_such_method_xyz", "[]");

    g_done = 0;
    int rc = lp_invoke_async(c, "version", "[]", 15000, on_result, NULL);
    printf("[main] lp_invoke_async dispatched rc=%d\n", rc);
    pthread_mutex_lock(&g_mu);
    while (!g_done)
        pthread_cond_wait(&g_cv, &g_mu);
    pthread_mutex_unlock(&g_mu);

    lp_client_destroy(c);

    /* A client for a module that is NOT loaded: what does the caller see? */
    lp_client* c2 = lp_client_create("not_loaded_module", "android_host", NULL, NULL);
    call_once_t(c2, "anything", "[]", 3000);
    lp_client_destroy(c2);

    qtloop_stop();
    printf("[main] done\n");
    return 0;
}
