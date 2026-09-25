#pragma once

#include <cstdint>
#include <string>

#include <logos_module_context.h>

// desktop-harness module. Keep every declaration on ONE line (the generator
// parses this header line by line).
class EvProbeImpl : public LogosModuleContext {
public:
    EvProbeImpl() = default;
    ~EvProbeImpl() = default;

    std::string ping();
    bool fire(const std::string& data);
    int64_t fire_many(int64_t count);
    int64_t sleep_ms(int64_t ms);

logos_events:
    void pinged(const std::string& data);
};
