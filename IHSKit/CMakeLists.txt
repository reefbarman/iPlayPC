# iOS build of ihslib (Steam Remote Play) for iPlayPC.
#
# Builds a patched copy of ihslib + mbedTLS 3.6 + Opus + the protobuf-c runtime
# + our bridge as static libraries for one Apple platform slice.
# scripts/build-ihskit.sh merges the slices into IHSKit.xcframework.
#
# Differences from upstream's CMake (which wants pkg-config, SDL2 and a system
# protobuf-c):
# - vendor/ihslib/{src,include} are copied into the build directory and
#   patches/*.patch are applied to the copy in order (vendor/ihslib stays
#   untouched). A rejected hunk fails the configure step. See PATCHES.md.
# - Sources are an explicit list: everything under src/ except the SDL backends
#   (hid/sdl, ihs_thread_sdl.c, ihs_udp_sdl.c) and the OpenSSL crypto. Threads
#   come from src/ihs_thread_posix.c (pthreads).
# - mbedTLS uses its default config, which has everything impl_mbedtls.c needs
#   (SHA-256, AES, RSA OAEP, Curve25519, CTR-DRBG, PK parsing).
# - Opus isn't used by ihslib; the bridge decodes audio and encodes the mic.

cmake_minimum_required(VERSION 3.20)
project(IHSKit C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS OFF)

get_filename_component(ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)

# ------------------------------------------------------------- mbedtls 3.6 LTS
set(ENABLE_TESTING OFF CACHE BOOL "" FORCE)
set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
set(USE_SHARED_MBEDTLS_LIBRARY OFF CACHE BOOL "" FORCE)
set(USE_STATIC_MBEDTLS_LIBRARY ON CACHE BOOL "" FORCE)
set(MBEDTLS_FATAL_WARNINGS OFF CACHE BOOL "" FORCE)
add_subdirectory("${ROOT}/vendor/mbedtls" mbedtls EXCLUDE_FROM_ALL)

# ------------------------------------------------------------------------ opus
set(OPUS_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
add_subdirectory("${ROOT}/vendor/opus" opus EXCLUDE_FROM_ALL)

# ---------------------------------------------------------- protobuf-c runtime
add_library(protobufc STATIC "${ROOT}/vendor/protobuf-c/protobuf-c/protobuf-c.c")
target_include_directories(protobufc PUBLIC "${ROOT}/vendor/protobuf-c")
target_compile_options(protobufc PRIVATE -w)

# ------------------------------------------------------------ patched ihslib
set(IHS_LIB "${CMAKE_BINARY_DIR}/ihslib")
file(GLOB IHS_PATCHES "${CMAKE_CURRENT_SOURCE_DIR}/patches/*.patch")
list(SORT IHS_PATCHES)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${IHS_PATCHES})
file(REMOVE_RECURSE "${IHS_LIB}")
file(COPY "${ROOT}/vendor/ihslib/src" "${ROOT}/vendor/ihslib/include" DESTINATION "${IHS_LIB}")
foreach(PATCH_FILE ${IHS_PATCHES})
	execute_process(
		COMMAND patch -p1 --forward --batch --no-backup-if-mismatch -i "${PATCH_FILE}"
		WORKING_DIRECTORY "${IHS_LIB}"
		RESULT_VARIABLE PATCH_RESULT
		OUTPUT_VARIABLE PATCH_OUTPUT
		ERROR_VARIABLE PATCH_OUTPUT)
	if(NOT PATCH_RESULT EQUAL 0)
		message(FATAL_ERROR "Applying ${PATCH_FILE} to ihslib failed:\n${PATCH_OUTPUT}")
	endif()
endforeach()
file(GLOB_RECURSE IHS_REJECTS "${IHS_LIB}/*.rej")
if(IHS_REJECTS)
	message(FATAL_ERROR "ihslib patches left rejects: ${IHS_REJECTS}")
endif()
list(LENGTH IHS_PATCHES IHS_PATCH_COUNT)
message(STATUS "Applied ${IHS_PATCH_COUNT} ihslib patches")

# Every ihslib source except the SDL backends and the OpenSSL crypto. The list
# is sorted so builds are reproducible.
file(GLOB_RECURSE IHS_SOURCES "${IHS_LIB}/src/*.c")
list(FILTER IHS_SOURCES EXCLUDE REGEX "/src/hid/sdl/")
list(FILTER IHS_SOURCES EXCLUDE REGEX "/ihs_thread_sdl\\.c$")
list(FILTER IHS_SOURCES EXCLUDE REGEX "/ihs_udp_sdl\\.c$")
list(FILTER IHS_SOURCES EXCLUDE REGEX "/impl_openssl\\.c$")
list(SORT IHS_SOURCES)

add_library(ihslib STATIC
	${IHS_SOURCES}
	"${CMAKE_CURRENT_SOURCE_DIR}/src/ihs_thread_posix.c")
target_include_directories(ihslib
	PUBLIC "${IHS_LIB}/include"
	PRIVATE "${IHS_LIB}/src")
target_compile_options(ihslib PRIVATE -w)
target_link_libraries(ihslib PUBLIC mbedcrypto protobufc)

# ---------------------------------------------------------------------- bridge
add_library(ihsbridge STATIC
	"${CMAKE_CURRENT_SOURCE_DIR}/src/ihs_bridge.c")
target_include_directories(ihsbridge
	PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include"
	PRIVATE "${IHS_LIB}/src" "${ROOT}/vendor/opus/include")
target_compile_options(ihsbridge PRIVATE -Wall -Wextra -Wno-unused-parameter)
target_link_libraries(ihsbridge PUBLIC ihslib opus)

add_custom_target(ihskit_all ALL DEPENDS ihsbridge ihslib protobufc mbedtls mbedx509 mbedcrypto opus)
