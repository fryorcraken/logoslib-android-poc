#pragma once

#include <cstdint>
#include <string>

#include <logos_module_context.h>

// hello_module: the smallest useful universal module. It proves the Android wrapper
// (docs/plan.md M3/M4) before a real module is loaded: a call with no arguments, a
// string round trip, integer arguments, and one event emitted on demand.
//
// The generator derives the module's LIDL contract from this header line by line:
// keep every declaration on ONE line and put no trailing comment on it.
class HelloModuleImpl : public LogosModuleContext {
public:
    HelloModuleImpl() = default;
    ~HelloModuleImpl() = default;

    // Always "pong".
    std::string ping();

    // Returns `text` unchanged.
    std::string echo(const std::string& text);

    // Returns a + b.
    int64_t add(int64_t a, int64_t b);

    // Emits the event `hello` with `tag` as its only argument, then returns true.
    bool fire(const std::string& tag);

logos_events:
    void hello(const std::string& tag);
};
