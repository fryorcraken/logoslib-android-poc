cmake_minimum_required(VERSION 3.14)
project(HelloModule LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# logos-module-builder's LogosModule.cmake, the one copy every Logos module builds with.
# scripts/android/build-runtime.sh sets LOGOS_MODULE_BUILDER_ROOT to its pinned checkout
# and runs the code generators first (generated_code/ next to this file), the same steps
# the builder's Nix path runs for an `interface: "universal"` module.
if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LogosModule.cmake not found. Set LOGOS_MODULE_BUILDER_ROOT.")
endif()

logos_module(
    NAME hello_module
    SOURCES
        src/hello_module_impl.h
        src/hello_module_impl.cpp
)
