#include "bc_probe_impl.h"

#include <chrono>
#include <iostream>

#include <nlohmann/json.hpp>

// Generated at build time: typed callers for every metadata.json dependency.
#include "logos_sdk.h"

namespace {
long long nowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch()).count();
}

// blockchain_module methods return `result` ({success, value, error}); the generated
// std client hands back a StdLogosResult. Flatten it to one JSON string for the CLI.
template <typename R>
std::string flatten(const char* what, const R& r, long long t0) {
    nlohmann::json out;
    out["success"] = r.success;
    out["value"] = r.value;
    out["error"] = r.error;
    out["ms"] = nowMs() - t0;
    std::cerr << "[bc_probe] <- blockchain_module." << what << " " << out.dump() << std::endl;
    return out.dump();
}
}  // namespace

std::string BcProbeImpl::ping() {
    return "pong";
}

std::string BcProbeImpl::chain_info_via_bc() {
    const long long t0 = nowMs();
    std::cerr << "[bc_probe] -> blockchain_module.get_cryptarchia_info()" << std::endl;
    return flatten("get_cryptarchia_info", modules().blockchain_module.get_cryptarchia_info(), t0);
}

std::string BcProbeImpl::height_via_bc() {
    const auto r = modules().blockchain_module.get_cryptarchia_info();
    if (!r.success) return "error: " + r.error;
    // value is the module's JSON text ({"height":..,"slot":..,"tip":..,"lib":..,"mode":..})
    const nlohmann::json v = r.value.is_string() ? nlohmann::json::parse(r.value.template get<std::string>(), nullptr, false) : r.value;
    if (v.is_discarded() || !v.contains("height")) return "unparsed: " + r.value.dump();
    return std::to_string(v["height"].template get<long long>());
}

std::string BcProbeImpl::time_info_via_bc() {
    const long long t0 = nowMs();
    return flatten("get_time_info", modules().blockchain_module.get_time_info(), t0);
}

std::string BcProbeImpl::network_info_via_bc() {
    const long long t0 = nowMs();
    return flatten("get_network_info", modules().blockchain_module.get_network_info(), t0);
}
