# liblogos_jni.so -- the JNI shim of :logos-core.
#
# Built by scripts/android/build-jni.sh (NOT by Gradle) with Qt's Android toolchain file:
#   cmake -S android/logos-core/src/main/cpp -B build/android/<abi>/jni-build \
#     -DCMAKE_TOOLCHAIN_FILE=<Qt>/android_<abi>/lib/cmake/Qt6/qt.toolchain.cmake \
#     -DQT_HOST_PATH=<Qt>/gcc_64 -DANDROID_NDK_ROOT=<ndk> -DANDROID_PLATFORM=android-34 \
#     -DANDROID_STL=c++_shared -DLOGOS_PREFIX=build/android/<abi>/prefix
#
# Inputs (cache variables):
#   LOGOS_PREFIX                the Android prefix built by build-deps.sh/build-runtime.sh
#                               (lib/liblogos_core.so, lib/liblogos_protocol.so, headers)
#   LOGOS_CORE_INCLUDE_DIR      directory containing logos_core.h      (default: searched in LOGOS_PREFIX)
#   LOGOS_PROTOCOL_INCLUDE_DIR  directory containing logos_protocol.h  (default: searched in LOGOS_PREFIX)
#   LOGOS_JNI_COMPILE_ONLY      ON: compile the objects only (syntax check before the runtime exists)
# Output: liblogos_jni.so (SONAME liblogos_jni.so), 16 KB page-aligned.
cmake_minimum_required(VERSION 3.21)
project(logos_jni LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(LOGOS_PREFIX "" CACHE PATH "Android prefix with liblogos_core / liblogos_protocol")
set(LOGOS_CORE_INCLUDE_DIR "" CACHE PATH "Directory containing logos_core.h")
set(LOGOS_PROTOCOL_INCLUDE_DIR "" CACHE PATH "Directory containing logos_protocol.h")
option(LOGOS_JNI_COMPILE_ONLY "Only compile (no liblogos to link against yet)" OFF)

find_package(Qt6 6.11 REQUIRED COMPONENTS Core)

# The Qt/NDK toolchains re-root find_* into their sysroots; the prefix is searched as-is.
set(_logos_hdr_suffixes include include/logos include/logos_core include/liblogos include/logos-protocol
    include/logos_protocol include/logos-liblogos)
# (find_path skips a variable that is already defined, even as "", hence the _found vars.)
if(LOGOS_CORE_INCLUDE_DIR)
    set(_logos_core_inc "${LOGOS_CORE_INCLUDE_DIR}")
else()
    find_path(_logos_core_inc_found logos_core.h PATHS "${LOGOS_PREFIX}" PATH_SUFFIXES ${_logos_hdr_suffixes}
              NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH)
    set(_logos_core_inc "${_logos_core_inc_found}")
endif()
if(LOGOS_PROTOCOL_INCLUDE_DIR)
    set(_logos_protocol_inc "${LOGOS_PROTOCOL_INCLUDE_DIR}")
else()
    find_path(_logos_protocol_inc_found logos_protocol.h PATHS "${LOGOS_PREFIX}" PATH_SUFFIXES ${_logos_hdr_suffixes}
              NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH)
    set(_logos_protocol_inc "${_logos_protocol_inc_found}")
endif()
if(NOT _logos_core_inc OR NOT EXISTS "${_logos_core_inc}/logos_core.h")
    message(FATAL_ERROR "logos_core.h not found (LOGOS_PREFIX='${LOGOS_PREFIX}', LOGOS_CORE_INCLUDE_DIR='${LOGOS_CORE_INCLUDE_DIR}')")
endif()
if(NOT _logos_protocol_inc OR NOT EXISTS "${_logos_protocol_inc}/logos_protocol.h")
    message(FATAL_ERROR "logos_protocol.h not found (LOGOS_PREFIX='${LOGOS_PREFIX}', LOGOS_PROTOCOL_INCLUDE_DIR='${LOGOS_PROTOCOL_INCLUDE_DIR}')")
endif()
message(STATUS "logos_core.h from ${_logos_core_inc}")
message(STATUS "logos_protocol.h from ${_logos_protocol_inc}")

add_library(logos_jni_obj OBJECT
    logos_jni.cpp
    qt_loop.cpp
    stdio_logcat.cpp
)
set_target_properties(logos_jni_obj PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_include_directories(logos_jni_obj PRIVATE "${_logos_core_inc}" "${_logos_protocol_inc}")
target_compile_options(logos_jni_obj PRIVATE -Wall -Wextra -Wno-unused-parameter -fvisibility=hidden)
target_link_libraries(logos_jni_obj PRIVATE Qt6::Core)  # usage requirements (includes, defines)

if(LOGOS_JNI_COMPILE_ONLY)
    message(STATUS "LOGOS_JNI_COMPILE_ONLY: building objects only")
    return()
endif()

find_library(LOGOS_CORE_LIB NAMES logos_core PATHS "${LOGOS_PREFIX}/lib" NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH)
find_library(LOGOS_PROTOCOL_LIB NAMES logos_protocol PATHS "${LOGOS_PREFIX}/lib" NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH)
if(NOT LOGOS_CORE_LIB OR NOT LOGOS_PROTOCOL_LIB)
    message(FATAL_ERROR "liblogos_core.so / liblogos_protocol.so not found in ${LOGOS_PREFIX}/lib "
                        "(core='${LOGOS_CORE_LIB}' protocol='${LOGOS_PROTOCOL_LIB}')")
endif()

add_library(logos_jni SHARED $<TARGET_OBJECTS:logos_jni_obj>)
target_link_libraries(logos_jni PRIVATE "${LOGOS_CORE_LIB}" "${LOGOS_PROTOCOL_LIB}" Qt6::Core log dl)
# 16 KB pages for Android 15+ devices; also refuse unresolved symbols at link time.
target_link_options(logos_jni PRIVATE -Wl,-z,max-page-size=16384 -Wl,--no-undefined)
set_target_properties(logos_jni PROPERTIES OUTPUT_NAME logos_jni)
install(TARGETS logos_jni LIBRARY DESTINATION lib)
