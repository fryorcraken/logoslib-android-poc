// stdio_logcat.cpp -- see stdio_logcat.h.
#include "stdio_logcat.h"

#include <android/log.h>
#include <fcntl.h>
#include <pthread.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>

namespace {
std::mutex g_mu;
bool g_started = false;
char g_tag[32] = "logos-stdio";

void pump(int fd)
{
    pthread_setname_np(pthread_self(), "logos-stdio");
    std::string line;
    char buf[4096];
    for (;;) {
        const ssize_t n = ::read(fd, buf, sizeof buf);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        for (ssize_t i = 0; i < n; ++i) {
            if (buf[i] == '\n') {
                __android_log_write(ANDROID_LOG_INFO, g_tag, line.c_str());
                line.clear();
            } else {
                line.push_back(buf[i]);
                if (line.size() >= 3900) {  // logcat truncates around 4 KB per entry
                    __android_log_write(ANDROID_LOG_INFO, g_tag, line.c_str());
                    line.clear();
                }
            }
        }
    }
    if (!line.empty()) __android_log_write(ANDROID_LOG_INFO, g_tag, line.c_str());
}
}  // namespace

extern "C" int stdio_logcat_start(const char* tag)
{
    std::lock_guard<std::mutex> l(g_mu);
    if (g_started) return 1;
    if (tag && *tag) std::strncpy(g_tag, tag, sizeof(g_tag) - 1);

    int fds[2];
    // Read end close-on-exec: children must not hold it. dup2() below gives fds 1/2 without
    // FD_CLOEXEC, so posix_spawn()ed module hosts inherit the write end and log here too
    // (unless their spawner redirects them).
    if (::pipe2(fds, O_CLOEXEC) != 0) {
        __android_log_print(ANDROID_LOG_WARN, g_tag, "pipe2 failed: %s", std::strerror(errno));
        return 0;
    }
    std::fflush(stdout);
    std::fflush(stderr);
    if (::dup2(fds[1], STDOUT_FILENO) < 0 || ::dup2(fds[1], STDERR_FILENO) < 0) {
        __android_log_print(ANDROID_LOG_WARN, g_tag, "dup2 failed: %s", std::strerror(errno));
        ::close(fds[0]);
        ::close(fds[1]);
        return 0;
    }
    ::close(fds[1]);
    std::setvbuf(stdout, nullptr, _IOLBF, 0);
    std::setvbuf(stderr, nullptr, _IONBF, 0);
    std::thread(pump, fds[0]).detach();
    g_started = true;
    return 1;
}
