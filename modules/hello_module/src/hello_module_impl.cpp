#include "hello_module_impl.h"

std::string HelloModuleImpl::ping() {
    return "pong";
}

std::string HelloModuleImpl::echo(const std::string& text) {
    return text;
}

int64_t HelloModuleImpl::add(int64_t a, int64_t b) {
    return a + b;
}

bool HelloModuleImpl::fire(const std::string& tag) {
    hello(tag);
    return true;
}
