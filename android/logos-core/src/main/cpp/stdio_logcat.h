// stdio_logcat.h -- route this process' stdout/stderr (and, by inheritance, the module
// host children's) into logcat. Android discards an app process' stdio by default, and
// liblogos logs through spdlog to stdout.
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Replaces fds 1 and 2 with a pipe whose reader thread writes each line to logcat under
// `tag`. Idempotent; returns 1 when redirection is active, 0 on failure.
int stdio_logcat_start(const char* tag);

#ifdef __cplusplus
}
#endif
