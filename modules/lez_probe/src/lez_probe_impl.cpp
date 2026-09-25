#include "lez_probe_impl.h"

#include <chrono>
#include <iostream>

// Generated at build time: typed callers for every metadata.json dependency.
#include "logos_sdk.h"

namespace {
long long nowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch()).count();
}
}

std::string LezProbeImpl::ping() {
    return "pong";
}

std::string LezProbeImpl::lez_version() {
    std::cerr << "[lez_probe] -> lez_core.version()" << std::endl;
    const std::string v = modules().lez_core.version();
    std::cerr << "[lez_probe] <- lez_core.version() = " << v << std::endl;
    return v;
}

std::string LezProbeImpl::to_base58_via_lez(const std::string& account_id_hex) {
    const long long t0 = nowMs();
    std::cerr << "[lez_probe] -> lez_core.account_id_to_base58(" << account_id_hex << ")" << std::endl;
    const std::string b58 = modules().lez_core.account_id_to_base58(account_id_hex);
    std::cerr << "[lez_probe] <- lez_core.account_id_to_base58 = " << b58
              << " (" << (nowMs() - t0) << " ms)" << std::endl;
    return b58;
}

std::string LezProbeImpl::roundtrip_via_lez(const std::string& account_id_hex) {
    const long long t0 = nowMs();
    const std::string b58 = modules().lez_core.account_id_to_base58(account_id_hex);
    const std::string back = modules().lez_core.account_id_from_base58(b58);
    std::cerr << "[lez_probe] roundtrip via lez_core: " << account_id_hex << " -> " << b58
              << " -> " << back << " (" << (nowMs() - t0) << " ms, 2 cross-module calls)" << std::endl;
    return b58 + " -> " + back;
}
