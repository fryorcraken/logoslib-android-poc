cmake_minimum_required(VERSION 3.21)
project(qt_jvmless LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.11 REQUIRED COMPONENTS Core Network RemoteObjects)

# Trivial Qt plugin (stands in for a Logos module plugin).
add_library(echoplugin MODULE echo_plugin.cpp echo_plugin.h echo_iface.h)
target_link_libraries(echoplugin PRIVATE Qt6::Core)

# Plain add_executable (NOT qt_add_executable, which on Android makes a .so app lib).
add_executable(qro_server qro_server.cpp echo_object.h echo_iface.h common.h)
target_link_libraries(qro_server PRIVATE Qt6::Core Qt6::Network Qt6::RemoteObjects log dl)
set_target_properties(qro_server PROPERTIES POSITION_INDEPENDENT_CODE ON)

add_executable(qro_client qro_client.cpp client_core.h common.h)
target_link_libraries(qro_client PRIVATE Qt6::Core Qt6::RemoteObjects log dl)
set_target_properties(qro_client PROPERTIES POSITION_INDEPENDENT_CODE ON)

add_library(qrotest_jni SHARED qrotest_jni.cpp client_core.h common.h)
target_link_libraries(qrotest_jni PRIVATE Qt6::Core Qt6::RemoteObjects log dl)

add_library(qrotest_jni_noonload SHARED qrotest_jni.cpp client_core.h common.h)
target_compile_definitions(qrotest_jni_noonload PRIVATE QROTEST_NO_ONLOAD)
target_link_libraries(qrotest_jni_noonload PRIVATE Qt6::Core Qt6::RemoteObjects log dl)
