#pragma once

#include <string>

#include <logos_module_context.h>

// desktop-probe module. Keep every method declaration on ONE line (the generator
// parses this header line by line).
class LezProbeImpl : public LogosModuleContext {
public:
    LezProbeImpl() = default;
    ~LezProbeImpl() = default;

    std::string ping();
    std::string to_base58_via_lez(const std::string& account_id_hex);
    std::string roundtrip_via_lez(const std::string& account_id_hex);
    std::string lez_version();
};
