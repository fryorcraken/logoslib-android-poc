#include "ev_probe_impl.h"

#include <chrono>
#include <iostream>
#include <thread>

std::string EvProbeImpl::ping() {
    return "pong";
}

bool EvProbeImpl::fire(const std::string& data) {
    std::cerr << "[ev_probe] emitting pinged(" << data << ")" << std::endl;
    pinged(data);
    return true;
}

int64_t EvProbeImpl::fire_many(int64_t count) {
    for (int64_t i = 0; i < count; ++i)
        pinged("many-" + std::to_string(i));
    return count;
}

// Blocks this module's dispatch thread: a deterministic stand-in for a slow
// wallet call (create_new / open / sync) that needs no network.
int64_t EvProbeImpl::sleep_ms(int64_t ms) {
    std::this_thread::sleep_for(std::chrono::milliseconds(ms));
    return ms;
}
