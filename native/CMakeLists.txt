# Superbuild: Mbed TLS + libdatachannel (data channels only) as one shared library.
#
# Configured by hook/build.dart; can also be built by hand:
#   cmake -S native -B build/native -G Ninja -DCMAKE_BUILD_TYPE=Release
#   cmake --build build/native
cmake_minimum_required(VERSION 3.16)
project(dart_libp2p_webrtc_native C CXX)

set(THIRD_PARTY ${CMAKE_CURRENT_LIST_DIR}/../third_party)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_POLICY_VERSION_MINIMUM 3.5) # usrsctp/plog declare old minimums

# --- Mbed TLS (static, linked into libdatachannel) ---
set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
set(ENABLE_TESTING OFF CACHE BOOL "" FORCE)
set(MBEDTLS_FATAL_WARNINGS OFF CACHE BOOL "" FORCE)
set(USE_SHARED_MBEDTLS_LIBRARY OFF CACHE BOOL "" FORCE)
set(USE_STATIC_MBEDTLS_LIBRARY ON CACHE BOOL "" FORCE)
# libdatachannel's DTLS transport references the DTLS-SRTP API even without media.
set(MBEDTLS_USER_CONFIG ${CMAKE_CURRENT_LIST_DIR}/mbedtls_user_config.h)
add_compile_definitions(MBEDTLS_USER_CONFIG_FILE="${MBEDTLS_USER_CONFIG}")
add_subdirectory(${THIRD_PARTY}/mbedtls mbedtls EXCLUDE_FROM_ALL)

# libdatachannel skips find_package(MbedTLS) when this target already exists.
add_library(MbedTLS::MbedTLS INTERFACE IMPORTED GLOBAL)
target_link_libraries(MbedTLS::MbedTLS INTERFACE mbedtls mbedx509 mbedcrypto)

# --- libdatachannel ---
set(USE_MBEDTLS ON CACHE BOOL "" FORCE)
set(NO_MEDIA ON CACHE BOOL "" FORCE)
set(NO_WEBSOCKET ON CACHE BOOL "" FORCE)
set(NO_EXAMPLES ON CACHE BOOL "" FORCE)
set(NO_TESTS ON CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)
add_subdirectory(${THIRD_PARTY}/libdatachannel libdatachannel)

# Ship a single unversioned file (libdatachannel.{so,dylib}, datachannel.dll):
# the Dart/Flutter bundlers copy one file and don't follow version symlinks.
set_property(TARGET datachannel PROPERTY VERSION)
set_property(TARGET datachannel PROPERTY SOVERSION)
