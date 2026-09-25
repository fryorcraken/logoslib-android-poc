#pragma once

#include <string>

#include <logos_module_context.h>

// bc-desktop probe module. Keep every method declaration on ONE line (the generator
// parses this header line by line). All methods are read-only calls into blockchain_module.
class BcProbeImpl : public LogosModuleContext {
public:
    BcProbeImpl() = default;
    ~BcProbeImpl() = default;

    std::string ping();
    std::string chain_info_via_bc();
    std::string height_via_bc();
    std::string time_info_via_bc();
    std::string network_info_via_bc();
};
