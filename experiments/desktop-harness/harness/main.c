/* desktop-harness: pure C (logos_core.h + logos_protocol.h only), standing in
 * for a Kotlin/JNI shim. The Qt thread is owned by qt_loop.cpp.
 *
 * usage: dh MODULES_DIR PERSIST_DIR MODE [mode args...]
 *   introspect OUTDIR
 *   race TARGET METHOD EXPECTED_JSON worker|qt
 *   block create|sleep sync|async pinger|nopinger [WALLET_DIR]
 *   qtbusy
 *   timeouts
 *   events
 */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "logos_core.h"
#include "logos_protocol.h"

void qtloop_start(const char* modulesDir, const char* persistDir);
void qtloop_stop(void);
void qtloop_block_ms(int ms);
void qtloop_free_core_string(char* s);
unsigned long qtloop_thread_id(void);
int qtloop_load_on_qt(const char* name, int wait);
void qtloop_barrier(void);

/* ------------------------------------------------------------------ util */

static long g_t0;
static unsigned long g_main_tid;
static __thread char t_name[24] = "";

static long mono_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

long harness_rel_ms(void)
{
    return mono_ms() - g_t0;
}
#define rel harness_rel_ms

static const char* tname(void)
{
    unsigned long me = (unsigned long)pthread_self();
    if (t_name[0]) return t_name;
    if (me == g_main_tid) return "main";
    if (me == qtloop_thread_id()) return "qt-thread";
    return "other";
}

#define LOG(...)                                         \
    do {                                                 \
        char _b[4096];                                   \
        snprintf(_b, sizeof _b, __VA_ARGS__);            \
        printf("[%6ld ms][%s] %s\n", rel(), tname(), _b); \
    } while (0)

static void sleep_ms(long ms)
{
    struct timespec ts = {ms / 1000, (ms % 1000) * 1000000L};
    while (nanosleep(&ts, &ts) == -1 && errno == EINTR) {}
}

static void on_alarm(int sig)
{
    (void)sig;
    static const char m[] = "[watchdog] harness exceeded its deadline; _exit(99)\n";
    ssize_t w = write(1, m, sizeof m - 1);
    (void)w;
    _exit(99);
}

static int load_worker(const char* name)
{
    long t = rel();
    int r = logos_core_load_module(name, LOGOS_LOAD_REQUIRED_DEPS);
    LOG("load(%s) from this (non-Qt) thread -> %d in %ld ms", name, r, rel() - t);
    return r;
}

static lp_client* client(const char* target)
{
    long t = rel();
    lp_client* c = lp_client_create(target, "android_host", NULL, NULL);
    LOG("lp_client_create(%s) -> %p in %ld ms", target, (void*)c, rel() - t);
    return c;
}

/* One synchronous lp_invoke, logged. Returns rc; *took_ms and result optional. */
static int invoke(lp_client* c, const char* tag, const char* method, const char* args,
                  int timeout_ms, char** result_out, long* took_ms)
{
    char* out = NULL;
    char* err = NULL;
    long t = rel();
    int rc = lp_invoke(c, method, args, timeout_ms, &out, &err);
    long d = rel() - t;
    LOG("%s: lp_invoke(%s, timeout=%d) start=%ld took=%ld ms rc=%d result=%.240s error=%.300s", tag,
        method, timeout_ms, t, d, rc, out ? out : "(null)", err ? err : "(null)");
    if (took_ms) *took_ms = d;
    if (result_out)
        *result_out = out;
    else
        lp_string_free(out);
    lp_string_free(err);
    return rc;
}

/* ------------------------------------------------------------ async call */

typedef struct {
    pthread_mutex_t mu;
    pthread_cond_t cv;
    const char* tag;
    int done;
    int ok;
    char json[512];
    long t_dispatch;
    long t_dispatch_ret;
    long t_cb;
    unsigned long cb_tid;
} async_t;

static void async_cb(int ok, const char* json, void* ud)
{
    async_t* a = (async_t*)ud;
    pthread_mutex_lock(&a->mu);
    a->ok = ok;
    snprintf(a->json, sizeof a->json, "%s", json ? json : "(null)");
    a->t_cb = rel();
    a->cb_tid = (unsigned long)pthread_self();
    a->done = 1;
    pthread_cond_broadcast(&a->cv);
    pthread_mutex_unlock(&a->mu);
}

static void async_start(async_t* a, lp_client* c, const char* tag, const char* method,
                        const char* args, int timeout_ms)
{
    pthread_mutex_init(&a->mu, NULL);
    pthread_cond_init(&a->cv, NULL);
    a->tag = tag;
    a->done = 0;
    a->t_dispatch = rel();
    int rc = lp_invoke_async(c, method, args, timeout_ms, async_cb, a);
    a->t_dispatch_ret = rel();
    LOG("%s: lp_invoke_async(%s, timeout=%d) rc=%d; the dispatch call itself took %ld ms", tag,
        method, timeout_ms, rc, a->t_dispatch_ret - a->t_dispatch);
}

static int async_wait(async_t* a, long max_ms)
{
    long deadline = rel() + max_ms;
    pthread_mutex_lock(&a->mu);
    while (!a->done && rel() < deadline) {
        pthread_mutex_unlock(&a->mu);
        sleep_ms(5);
        pthread_mutex_lock(&a->mu);
    }
    int done = a->done;
    pthread_mutex_unlock(&a->mu);
    if (done)
        LOG("%s: async callback ok=%d after %ld ms (dispatched at %ld) on thread %s json=%.240s", a->tag,
            a->ok, a->t_cb - a->t_dispatch, a->t_dispatch,
            a->cb_tid == qtloop_thread_id() ? "qt-thread" : "NOT-qt-thread", a->json);
    else
        LOG("%s: async callback did NOT fire within %ld ms", a->tag, max_ms);
    return done;
}

/* ------------------------------------------------------------- sync call on a thread */

typedef struct {
    lp_client* c;
    const char* tag;
    const char* method;
    const char* args;
    int timeout_ms;
    int rc;
    long t_start, took;
    pthread_t th;
} callthr_t;

static void* callthr_main(void* p)
{
    callthr_t* x = (callthr_t*)p;
    snprintf(t_name, sizeof t_name, "%s", x->tag);
    x->t_start = rel();
    x->rc = invoke(x->c, x->tag, x->method, x->args, x->timeout_ms, NULL, &x->took);
    return NULL;
}

static void callthr_start(callthr_t* x)
{
    pthread_create(&x->th, NULL, callthr_main, x);
}

/* ------------------------------------------------------------------ pinger */

typedef struct {
    lp_client* c;
    const char* method;
    int interval_ms;
    volatile int stop;
    long count, fails, over100, over1000, max_ms, max_at, sum;
    pthread_t th;
} pinger_t;

static void* pinger_main(void* p)
{
    pinger_t* g = (pinger_t*)p;
    snprintf(t_name, sizeof t_name, "pinger");
    while (!g->stop) {
        char* out = NULL;
        char* err = NULL;
        long t = rel();
        int rc = lp_invoke(g->c, g->method, "[]", 60000, &out, &err);
        long d = rel() - t;
        g->count++;
        g->sum += d;
        if (d > g->max_ms) {
            g->max_ms = d;
            g->max_at = t;
        }
        if (d > 100) g->over100++;
        if (d > 1000) g->over1000++;
        if (rc != 0 || !out || strcmp(out, "null") == 0 || strcmp(out, "\"\"") == 0) g->fails++;
        if (d > 100)
            LOG("slow ping: %s started at %ld took %ld ms rc=%d result=%.80s", g->method, t, d, rc,
                out ? out : "(null)");
        lp_string_free(out);
        lp_string_free(err);
        if (g->interval_ms > 0) sleep_ms(g->interval_ms);
    }
    return NULL;
}

static void pinger_start(pinger_t* g, lp_client* c, const char* method, int interval_ms)
{
    memset(g, 0, sizeof *g);
    g->c = c;
    g->method = method;
    g->interval_ms = interval_ms;
    pthread_create(&g->th, NULL, pinger_main, g);
}

static void pinger_stop(pinger_t* g, const char* label)
{
    g->stop = 1;
    pthread_join(g->th, NULL);
    LOG("PINGER %s: %s x%ld, avg %.2f ms, max %ld ms (started at %ld), >100ms: %ld, >1000ms: %ld, "
        "bad results: %ld",
        label, g->method, g->count, g->count ? (double)g->sum / g->count : 0.0, g->max_ms, g->max_at,
        g->over100, g->over1000, g->fails);
}

/* ============================================================== (a) introspect */

static void write_file(const char* dir, const char* target, const char* method, const char* s)
{
    char path[1024];
    snprintf(path, sizeof path, "%s/%s.%s.json", dir, target, method);
    FILE* f = fopen(path, "w");
    if (!f) return;
    fputs(s, f);
    fputc('\n', f);
    fclose(f);
}

static int mode_introspect(const char* outdir)
{
    load_worker("lez_probe"); /* pulls lez_core */
    load_worker("ev_probe");
    const char* targets[] = {"lez_core", "lez_probe", "ev_probe", "capability_module"};
    const char* methods[] = {"getPluginMethods", "getPluginEvents", "getPluginInterface"};
    for (int i = 0; i < 4; i++) {
        lp_client* c = client(targets[i]);
        for (int j = 0; j < 3; j++) {
            char* out = NULL;
            char* err = NULL;
            long t = rel();
            int rc = lp_invoke(c, methods[j], "[]", 10000, &out, &err);
            LOG("INTROSPECT %s.%s rc=%d in %ld ms, %zu bytes: %.200s%s err=%s", targets[i], methods[j],
                rc, rel() - t, out ? strlen(out) : 0, out ? out : "(null)",
                out && strlen(out) > 200 ? " ..." : "", err ? err : "(null)");
            write_file(outdir, targets[i], methods[j], out ? out : (err ? err : "null"));
            lp_string_free(out);
            lp_string_free(err);
        }
        char* m = lp_get_methods(c);
        LOG("INTROSPECT %s lp_get_methods -> %s", targets[i], m ? m : "(null)");
        write_file(outdir, targets[i], "lp_get_methods", m ? m : "null");
        lp_string_free(m);
        lp_client_destroy(c);
    }
    return 0;
}

/* ============================================================== (b) first-call race */

static int mode_race(const char* target, const char* method, const char* expected, const char* loader)
{
    long t_load0 = rel();
    int lr = strcmp(loader, "qt") == 0 ? qtloop_load_on_qt(target, 1) : load_worker(target);
    if (strcmp(loader, "barrier") == 0) {
        long tb = rel();
        qtloop_barrier();
        LOG("Qt-thread barrier took %ld ms", rel() - tb);
    }
    long t_load1 = rel();
    lp_client* c = lp_client_create(target, "android_host", NULL, NULL);

    int attempts = 0, good = 0, first_rc = 0;
    long first_ms = 0, good_at = -1;
    char first_res[256] = "", first_err[256] = "";
    while (rel() - t_load1 < 30000) {
        char* out = NULL;
        char* err = NULL;
        long t = rel();
        int rc = lp_invoke(c, method, "[]", 20000, &out, &err);
        long d = rel() - t;
        attempts++;
        if (attempts == 1) {
            first_rc = rc;
            first_ms = d;
            snprintf(first_res, sizeof first_res, "%s", out ? out : "(null)");
            snprintf(first_err, sizeof first_err, "%s", err ? err : "(null)");
        }
        int ok = rc == 0 && out && strcmp(out, expected) == 0;
        if (!ok || attempts <= 2)
            LOG("attempt %d: rc=%d took %ld ms result=%.120s error=%.200s", attempts, rc, d,
                out ? out : "(null)", err ? err : "(null)");
        lp_string_free(out);
        lp_string_free(err);
        if (ok) {
            good = 1;
            good_at = rel();
            break;
        }
        sleep_ms(20);
    }
    /* confirm it stays good */
    int after_ok = 0;
    for (int i = 0; i < 3; i++) {
        char* out = NULL;
        if (lp_invoke(c, method, "[]", 5000, &out, NULL) == 0 && out && strcmp(out, expected) == 0)
            after_ok++;
        lp_string_free(out);
    }
    printf("RESULT target=%s method=%s loader=%s load_rc=%d load_ms=%ld first_rc=%d first_ms=%ld "
           "first_result=%s first_error=%s good=%d attempts=%d good_after_load_ms=%ld "
           "good_after_start_ms=%ld later_ok=%d/3\n",
           target, method, loader, lr, t_load1 - t_load0, first_rc, first_ms, first_res, first_err,
           good, attempts, good ? good_at - t_load1 : -1, good ? good_at : -1, after_ok);
    lp_client_destroy(c);
    return 0;
}

/* ============================================================== (c) blocking */

static int mode_block(const char* kind, const char* style, const char* pingmode, const char* wdir)
{
    const int is_create = strcmp(kind, "create") == 0;
    const int is_async = strcmp(style, "async") == 0;
    const int with_pinger = strcmp(pingmode, "pinger") == 0;

    load_worker("lez_probe");
    load_worker("ev_probe");
    lp_client* core = client("lez_core");
    lp_client* probe = client("lez_probe");
    lp_client* ev = client("ev_probe");

    /* Warm up every edge so this measures blocking, not the first-call race. */
    invoke(core, "warmup", "version", "[]", 5000, NULL, NULL);
    invoke(ev, "warmup", "ping", "[]", 5000, NULL, NULL);
    for (int i = 0; i < 100; i++) {
        char* out = NULL;
        invoke(probe, "warmup", "lez_version", "[]", 5000, &out, NULL);
        int ok = out && strcmp(out, "\"0.3.0\"") == 0;
        lp_string_free(out);
        if (ok) break;
        sleep_ms(50);
    }

    /* long call L, same-module short call B, other-module short call C,
     * inter-module call D (lez_probe -> lez_core), pinger E on the other module */
    char largs[2048];
    lp_client *lc, *other;
    const char *lmethod, *bmethod, *cmethod, *emethod;
    if (is_create) {
        snprintf(largs, sizeof largs, "[\"%s/wallet_config.json\",\"%s/storage.json\",\"%s/statistics.json\",\"pw\"]",
                 wdir, wdir, wdir);
        lc = core;
        lmethod = "create_new";
        bmethod = "version";
        other = ev;
        cmethod = "ping";
        emethod = "ping";
    } else {
        snprintf(largs, sizeof largs, "[6000]");
        lc = ev;
        lmethod = "sleep_ms";
        bmethod = "ping";
        other = core;
        cmethod = "version";
        emethod = "version";
    }
    LOG("BLOCK kind=%s style=%s pinger=%s: L=%s%s B=same-module %s C=other-module %s D=lez_probe.lez_version",
        kind, style, pingmode, lmethod, largs, bmethod, cmethod);

    pinger_t E;
    if (with_pinger) {
        pinger_start(&E, other, emethod, 0);
        sleep_ms(500);
    }

    long tL = rel();
    callthr_t L = {lc, "L", lmethod, largs, 60000};
    callthr_t B = {lc, "B", bmethod, "[]", 60000};
    callthr_t D = {probe, "D", "lez_version", "[]", 60000};
    callthr_t C = {other, "C", cmethod, "[]", 60000};
    async_t aL, aB, aC, aD;
    if (is_async) {
        async_start(&aL, lc, "L", lmethod, largs, 60000);
        sleep_ms(300);
        async_start(&aB, lc, "B", bmethod, "[]", 60000);
        sleep_ms(50);
        async_start(&aD, probe, "D", "lez_version", "[]", 60000);
        sleep_ms(50);
        async_start(&aC, other, "C", cmethod, "[]", 60000);
        async_wait(&aC, 70000);
        async_wait(&aB, 70000);
        async_wait(&aD, 70000);
        async_wait(&aL, 70000);
        LOG("SUMMARY async: L %ld ms | B %ld ms | D %ld ms | C %ld ms (callback - dispatch)",
            aL.t_cb - aL.t_dispatch, aB.t_cb - aB.t_dispatch, aD.t_cb - aD.t_dispatch,
            aC.t_cb - aC.t_dispatch);
        LOG("SUMMARY async: B finished %ld ms after L finished; D %ld ms; C finished %ld ms BEFORE L",
            aB.t_cb - aL.t_cb, aD.t_cb - aL.t_cb, aL.t_cb - aC.t_cb);
    } else {
        callthr_start(&L);
        sleep_ms(300);
        callthr_start(&B);
        sleep_ms(50);
        callthr_start(&D);
        sleep_ms(50);
        callthr_start(&C);
        pthread_join(C.th, NULL);
        pthread_join(B.th, NULL);
        pthread_join(D.th, NULL);
        pthread_join(L.th, NULL);
        LOG("SUMMARY sync: L %ld ms | B %ld ms | D %ld ms | C %ld ms", L.took, B.took, D.took, C.took);
        LOG("SUMMARY sync: L end=%ld B end=%ld D end=%ld C end=%ld", L.t_start + L.took,
            B.t_start + B.took, D.t_start + D.took, C.t_start + C.took);
    }
    if (with_pinger) {
        sleep_ms(500);
        pinger_stop(&E, "during-L");
        LOG("(L was dispatched at %ld ms)", tL);
    }
    if (is_create) {
        invoke(core, "post", "list_accounts", "[]", 10000, NULL, NULL);
        invoke(core, "post", "get_current_block_height", "[]", 20000, NULL, NULL);
    }
    lp_client_destroy(core);
    lp_client_destroy(probe);
    lp_client_destroy(ev);
    return 0;
}

/* ============================================================== (c') Qt thread busy */

static int mode_qtbusy(void)
{
    load_worker("lez_core");
    lp_client* core = client("lez_core");
    invoke(core, "warmup", "version", "[]", 5000, NULL, NULL);

    LOG("--- (i) Qt thread blocked 3000 ms; sync lp_invoke(version, timeout=500)");
    qtloop_block_ms(3000);
    sleep_ms(100);
    long took = 0;
    invoke(core, "qt-blocked-sync", "version", "[]", 500, NULL, &took);
    sleep_ms(500);

    LOG("--- (ii) Qt thread blocked 3000 ms; lp_invoke_async(version, timeout=500)");
    qtloop_block_ms(3000);
    sleep_ms(100);
    async_t a;
    async_start(&a, core, "qt-blocked-async", "version", "[]", 500);
    async_wait(&a, 10000);
    sleep_ms(500);

    LOG("--- (iii) Qt thread blocked 2000 ms; lp_client_create + lp_client_destroy");
    qtloop_block_ms(2000);
    sleep_ms(100);
    lp_client* c2 = client("lez_core");
    lp_client_destroy(c2);
    sleep_ms(500);

    LOG("--- (iv) logos_core_load_module(lez_probe) ON the Qt thread (host start delayed by the "
        "SLOW wrapper) while a JNI-like thread pings lez_core.version");
    pinger_t E;
    pinger_start(&E, core, "version", 0);
    sleep_ms(300);
    qtloop_load_on_qt("lez_probe", 0);
    sleep_ms(100);
    invoke(core, "during-qt-load-sync", "version", "[]", 500, NULL, &took);
    async_t a2;
    async_start(&a2, core, "during-qt-load-async", "version", "[]", 500);
    async_wait(&a2, 20000);
    sleep_ms(500);
    pinger_stop(&E, "during-load-on-qt-thread");

    LOG("--- (v) logos_core_load_module(ev_probe) from a NON-Qt thread (same SLOW wrapper) while "
        "a JNI-like thread pings lez_core.version");
    pinger_start(&E, core, "version", 0);
    sleep_ms(300);
    load_worker("ev_probe");
    sleep_ms(300);
    pinger_stop(&E, "during-load-off-qt-thread");
    lp_client* ev = client("ev_probe");
    invoke(ev, "after-worker-load", "ping", "[]", 5000, NULL, NULL);
    lp_client_destroy(ev);
    lp_client_destroy(core);
    return 0;
}

/* ============================================================== (c'') timeouts vs a busy MODULE */

static int mode_timeouts(void)
{
    load_worker("lez_core");
    load_worker("ev_probe");
    lp_client* core = client("lez_core");
    lp_client* ev = client("ev_probe");
    invoke(core, "warmup", "version", "[]", 5000, NULL, NULL);
    invoke(ev, "warmup", "ping", "[]", 5000, NULL, NULL);

    LOG("--- (1) ev_probe busy 5 s (async sleep_ms); sync lp_invoke(ev_probe.ping, timeout=1000)");
    async_t L1;
    async_start(&L1, ev, "L1", "sleep_ms", "[5000]", 60000);
    sleep_ms(200);
    invoke(ev, "busy-module-sync", "ping", "[]", 1000, NULL, NULL);
    LOG("--- (2) same, lp_invoke_async(ev_probe.ping, timeout=1000)");
    async_t a2;
    async_start(&a2, ev, "busy-module-async", "ping", "[]", 1000);
    async_wait(&a2, 10000);
    async_wait(&L1, 10000);
    LOG("--- (3) after the module is free again: does the client still work?");
    invoke(ev, "after-timeouts", "ping", "[]", 5000, NULL, NULL);

    LOG("--- (4) nested-loop inversion with SHORT timeouts: pinger lp_invoke(lez_core.version, "
        "timeout 60000) while another thread runs a sync ev_probe.sleep_ms(3000); then a sync "
        "lp_invoke(lez_core.version, timeout=500) issued while the Qt thread is inside that call");
    pinger_t E;
    pinger_start(&E, core, "version", 0);
    sleep_ms(200);
    callthr_t S = {ev, "S", "sleep_ms", "[3000]", 60000};
    callthr_start(&S);
    sleep_ms(300);
    invoke(core, "short-timeout-during-nested", "version", "[]", 500, NULL, NULL);
    pthread_join(S.th, NULL);
    sleep_ms(200);
    pinger_stop(&E, "during-sync-sleep");

    LOG("--- (5) default timeout: sync lp_invoke(ev_probe.sleep_ms(23000), timeout_ms=0)");
    long took = 0;
    invoke(ev, "default-timeout", "sleep_ms", "[23000]", 0, NULL, &took);
    LOG("--- (6) the module finishes the timed-out call in the background; next call waits for it");
    invoke(ev, "after-default-timeout", "ping", "[]", 10000, NULL, NULL);

    lp_client_destroy(core);
    lp_client_destroy(ev);
    return 0;
}

/* ============================================================== (d) events */

typedef struct {
    pthread_mutex_t mu;
    long count;
    long lat_sum, lat_max;
    long on_qt, off_qt;
    char last[256];
} evstats_t;

static evstats_t g_ev1 = {PTHREAD_MUTEX_INITIALIZER};
static evstats_t g_ev2 = {PTHREAD_MUTEX_INITIALIZER};

static void ev_record(evstats_t* s, const char* tag, const char* name, const char* data)
{
    long now = rel();
    long lat = -1;
    const char* at = strchr(data, '@');
    if (at) lat = now - atol(at + 1);
    pthread_mutex_lock(&s->mu);
    s->count++;
    if (lat >= 0) {
        s->lat_sum += lat;
        if (lat > s->lat_max) s->lat_max = lat;
    }
    if ((unsigned long)pthread_self() == qtloop_thread_id())
        s->on_qt++;
    else
        s->off_qt++;
    snprintf(s->last, sizeof s->last, "%s", data);
    long n = s->count;
    pthread_mutex_unlock(&s->mu);
    if (n <= 8)
        LOG("EVENT[%s] #%ld %s %s latency=%ld ms", tag, n, name, data, lat);
}

static void ev_cb1(const char* name, const char* data, void* ud)
{
    (void)ud;
    ev_record(&g_ev1, "sub1", name, data);
}

static void ev_cb2(const char* name, const char* data, void* ud)
{
    (void)ud;
    ev_record(&g_ev2, "sub2", name, data);
}

static volatile int g_armed = 0;
static volatile unsigned long long g_gen = 0;

static void status_cb(int state, unsigned long long gen, const char* reason, void* ud)
{
    (void)ud;
    static const char* names[] = {"?", "ARMED", "LOST", "ABANDONED", "HELD"};
    LOG("STATUS %s generation=%llu reason=%s", state >= 1 && state <= 4 ? names[state] : "?", gen,
        reason ? reason : "(null)");
    if (state == LP_SUB_ARMED) {
        g_armed = 1;
        g_gen = gen;
    } else {
        g_armed = 0;
    }
}

static int wait_armed(long max_ms)
{
    long t = rel();
    while (!g_armed && rel() - t < max_ms) sleep_ms(10);
    LOG("wait_armed: armed=%d after %ld ms (generation %llu)", g_armed, rel() - t, g_gen);
    return g_armed;
}

static void fire(lp_client* ev, const char* tag)
{
    char args[128];
    snprintf(args, sizeof args, "[\"%s@%ld\"]", tag, rel());
    invoke(ev, "fire", "fire", args, 5000, NULL, NULL);
}

typedef struct {
    lp_client* c;
    lp_subscription* sub;
} subarg_t;

static void* sub2_thread_real(void* p)
{
    snprintf(t_name, sizeof t_name, "sub2-thread");
    subarg_t* s = (subarg_t*)p;
    s->sub = lp_subscribe(s->c, "pinged", ev_cb2, NULL);
    LOG("lp_subscribe(pinged) from a worker thread -> %p", (void*)s->sub);
    return NULL;
}

static int mode_events(void)
{
    LOG("thread ids: main=%lu qt=%lu", g_main_tid, qtloop_thread_id());
    lp_client* ev = client("ev_probe"); /* BEFORE the module is loaded */
    lp_client_set_subscription_status_cb(ev, status_cb, NULL);
    lp_subscription* sub1 = lp_subscribe(ev, "pinged", ev_cb1, NULL);
    char* pend = lp_pending_subscriptions(ev);
    LOG("lp_subscribe(pinged) before load -> %p; pending=%s generation=%llu", (void*)sub1,
        pend ? pend : "(null)", lp_client_subscription_generation(ev));
    lp_string_free(pend);

    long tl = rel();
    load_worker("ev_probe");
    wait_armed(15000);
    LOG("armed %ld ms after the load started", rel() - tl);
    pend = lp_pending_subscriptions(ev);
    LOG("pending after arm=%s", pend ? pend : "(null)");
    lp_string_free(pend);

    for (int i = 0; i < 5; i++) {
        char tag[16];
        snprintf(tag, sizeof tag, "e%d", i);
        fire(ev, tag);
        sleep_ms(50);
    }
    sleep_ms(500);
    LOG("after 5 fires: sub1 got %ld events, avg latency %.1f ms, max %ld ms, on qt-thread %ld, "
        "elsewhere %ld",
        g_ev1.count, g_ev1.count ? (double)g_ev1.lat_sum / g_ev1.count : 0.0, g_ev1.lat_max,
        g_ev1.on_qt, g_ev1.off_qt);

    /* burst */
    long before = g_ev1.count;
    invoke(ev, "burst", "fire_many", "[200]", 10000, NULL, NULL);
    long tb = rel();
    while (g_ev1.count - before < 200 && rel() - tb < 5000) sleep_ms(10);
    LOG("burst: fire_many(200) delivered %ld events (last=%s) within %ld ms of the call returning",
        g_ev1.count - before, g_ev1.last, rel() - tb);

    /* a second subscription from a worker thread */
    subarg_t s2 = {ev, NULL};
    pthread_t th;
    pthread_create(&th, NULL, sub2_thread_real, &s2);
    pthread_join(th, NULL);
    sleep_ms(300);
    fire(ev, "two-subs");
    sleep_ms(500);
    LOG("after two-subs fire: sub1 total %ld, sub2 total %ld (sub2 on qt-thread %ld, elsewhere %ld)",
        g_ev1.count, g_ev2.count, g_ev2.on_qt, g_ev2.off_qt);

    /* unknown event name: accepted? */
    lp_subscription* bogus = lp_subscribe(ev, "no_such_event", ev_cb1, NULL);
    pend = lp_pending_subscriptions(ev);
    LOG("lp_subscribe(no_such_event) -> %p; pending=%s", (void*)bogus, pend ? pend : "(null)");
    lp_string_free(pend);

    /* provider restart: unload + reload ev_probe */
    long c1 = g_ev1.count;
    long tu = rel();
    int ur = logos_core_unload_module("ev_probe", false);
    LOG("unload(ev_probe) -> %d in %ld ms", ur, rel() - tu);
    sleep_ms(1500);
    load_worker("ev_probe");
    wait_armed(15000);
    sleep_ms(300);
    fire(ev, "after-reload");
    sleep_ms(800);
    LOG("after reload: sub1 got %ld new events (generation now %llu)", g_ev1.count - c1,
        lp_client_subscription_generation(ev));

    lp_unsubscribe(bogus);
    lp_unsubscribe(s2.sub);
    lp_unsubscribe(sub1);
    long c2 = g_ev1.count;
    fire(ev, "after-unsubscribe");
    sleep_ms(500);
    LOG("after unsubscribe: sub1 got %ld further events (expect 0)", g_ev1.count - c2);
    lp_client_destroy(ev);
    return 0;
}

/* ================================================================== main */

int main(int argc, char** argv)
{
    g_t0 = mono_ms();
    g_main_tid = (unsigned long)pthread_self();
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc < 4) {
        fprintf(stderr, "usage: %s MODULES_DIR PERSIST_DIR MODE [args]\n", argv[0]);
        return 2;
    }
    signal(SIGALRM, on_alarm);
    alarm(getenv("DH_WATCHDOG_S") ? atoi(getenv("DH_WATCHDOG_S")) : 240);

    const char* mode = argv[3];
    LOG("desktop-harness mode=%s TMPDIR=%s LOGOS_HOST_PATH=%s", mode,
        getenv("TMPDIR") ? getenv("TMPDIR") : "(unset)",
        getenv("LOGOS_HOST_PATH") ? getenv("LOGOS_HOST_PATH") : "(unset)");
    long ts = rel();
    qtloop_start(argv[1], argv[2]);
    LOG("runtime up in %ld ms; protocol=%s mode=%s; qt thread=%lu", rel() - ts, lp_protocol_version(),
        lp_get_mode(), qtloop_thread_id());

    int rc = 2;
    if (strcmp(mode, "introspect") == 0 && argc >= 5)
        rc = mode_introspect(argv[4]);
    else if (strcmp(mode, "race") == 0 && argc >= 8)
        rc = mode_race(argv[4], argv[5], argv[6], argv[7]);
    else if (strcmp(mode, "block") == 0 && argc >= 7)
        rc = mode_block(argv[4], argv[5], argv[6], argc >= 8 ? argv[7] : "");
    else if (strcmp(mode, "qtbusy") == 0)
        rc = mode_qtbusy();
    else if (strcmp(mode, "events") == 0)
        rc = mode_events();
    else if (strcmp(mode, "timeouts") == 0)
        rc = mode_timeouts();
    else
        fprintf(stderr, "bad mode/args\n");

    long tq = rel();
    qtloop_stop();
    LOG("done (rc=%d); shutdown took %ld ms", rc, rel() - tq);
    return rc;
}
