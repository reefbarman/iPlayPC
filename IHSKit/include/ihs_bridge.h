// SPDX-License-Identifier: AGPL-3.0-only
//
// Small, Swift-friendly C API over ihslib (Steam Remote Play).
//
// ihslib's own types never reach Swift: everything here is opaque handles,
// plain value structs and C callbacks. Callbacks fire on ihslib's threads; the
// caller hops to the right queue.

#ifndef IHS_BRIDGE_H
#define IHS_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ------------------------------------------------------------------ library

/// Call once before anything else.
void ihk_lib_init(void);

typedef enum {
    IHK_LOG_FATAL = 0,
    IHK_LOG_ERROR = 1,
    IHK_LOG_WARN = 2,
    IHK_LOG_INFO = 3,
    IHK_LOG_DEBUG = 4,
    IHK_LOG_VERBOSE = 5,
} IHKLogLevel;

typedef void (*IHKLogCallback)(void *user, IHKLogLevel level, const char *tag, const char *message);

/// Global log sink for every client and session. Messages above max_level are dropped.
void ihk_set_log_callback(IHKLogCallback cb, void *user, IHKLogLevel max_level);

// ------------------------------------------------------------------- client

/// A Steam host that answered discovery.
typedef struct {
    uint64_t host_id;      // Steam's client id for the host: stable, use it to key pairing
    uint64_t instance_id;
    char address[64];      // dotted IPv4 (or IPv6) the answer came from
    uint16_t port;
    char name[64];         // the PC's hostname
    int32_t os_type;       // EOSType
    bool games_running;    // busy: something is already running or streaming
} IHKHost;

typedef void (*IHKHostCallback)(void *user, const IHKHost *host);

typedef struct IHKClient IHKClient;

/// device_id identifies this phone to Steam (random, persisted). device_name is
/// what the PC shows ("Tristan's iPhone"). secret_key is the 32-byte key to start
/// with (any value before pairing). on_host fires for every discovery answer, so
/// expect repeats.
IHKClient *ihk_client_create(uint64_t device_id, const char *device_name, const uint8_t secret_key[32],
                             IHKHostCallback on_host, void *user);

/// Stops the worker and frees. No callbacks after this returns.
void ihk_client_destroy(IHKClient *client);

/// Sends one discovery request to an IPv4 address (port 27036). Use it to sweep
/// the subnet and to probe a manually entered address; iOS can't broadcast.
/// Returns false if it couldn't be sent (bad address, or the socket isn't open yet).
bool ihk_client_discover(IHKClient *client, const char *address);

#ifdef __cplusplus
}
#endif

#endif
