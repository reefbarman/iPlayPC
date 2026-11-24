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

/// A Steam host. Filled in by discovery; pass it back unchanged (or rebuilt
/// from saved fields) to authorize or request a stream.
typedef struct {
    uint64_t host_id;      // Steam's client id for the host: stable, use it to key pairing
    uint64_t instance_id;
    char address[64];      // dotted IPv4 the answer came from
    uint16_t port;         // discovery port the host answered from (27036)
    char name[64];         // the PC's hostname
    int32_t os_type;       // EOSType
    int32_t universe;      // Steam universe, 1 = public (pairing picks its key by this)
    bool games_running;    // busy: something is already running or streaming
} IHKHost;

/// Mirrors ihslib's IHS_AuthorizationResult
typedef enum {
    IHK_AUTH_SUCCESS = 0,
    IHK_AUTH_DENIED = 1,
    IHK_AUTH_NOT_LOGGED_IN = 2,
    IHK_AUTH_OFFLINE = 3,
    IHK_AUTH_BUSY = 4,
    IHK_AUTH_IN_PROGRESS = 5,
    IHK_AUTH_TIMED_OUT = 6,
    IHK_AUTH_FAILED = 7,
    IHK_AUTH_CANCELED = 8,
} IHKAuthResult;

/// Mirrors ihslib's IHS_StreamingResult
typedef enum {
    IHK_STREAM_SUCCESS = 0,
    IHK_STREAM_UNAUTHORIZED = 1,
    IHK_STREAM_SCREEN_LOCKED = 2,
    IHK_STREAM_FAILED = 3,
    IHK_STREAM_BUSY = 4,
    IHK_STREAM_IN_PROGRESS = 5,
    IHK_STREAM_CANCELED = 6,
    IHK_STREAM_DRIVERS_NOT_INSTALLED = 7,
    IHK_STREAM_DISABLED = 8,
    IHK_STREAM_BROADCASTING_ACTIVE = 9,
    IHK_STREAM_VR_ACTIVE = 10,
    IHK_STREAM_PIN_REQUIRED = 11,
    IHK_STREAM_TRANSPORT_UNAVAILABLE = 12,
    IHK_STREAM_INVISIBLE = 13,
    IHK_STREAM_GAME_LAUNCH_FAILED = 14,
    IHK_STREAM_TIMEOUT = -1,
} IHKStreamResult;

typedef enum {
    IHK_INTERFACE_DEFAULT = 0,
    IHK_INTERFACE_RECENT_GAMES = 1,
    IHK_INTERFACE_BIG_PICTURE = 2,
    IHK_INTERFACE_DESKTOP = 3,
} IHKStreamInterface;

typedef struct {
    int32_t max_width;     // ceiling; Steam decides the real size
    int32_t max_height;
    int32_t audio_channels;
    IHKStreamInterface streaming_interface;
} IHKStreamRequest;

/// What a successful stream request hands back: where to connect the session and its key.
typedef struct {
    char address[64];
    uint16_t port;
    uint8_t session_key[32];
    size_t session_key_len;
} IHKStreamGrant;

/// All optional. They fire on ihslib's client thread.
typedef struct {
    /// Every discovery answer, so expect repeats.
    void (*on_host)(void *user, const IHKHost *host);
    /// The PC is showing the PIN dialog.
    void (*on_auth_progress)(void *user, const IHKHost *host);
    /// Paired. secret_key is this host's key: store it and set it before streaming from the host.
    void (*on_auth_success)(void *user, const IHKHost *host, const uint8_t secret_key[32], uint64_t steam_id);
    void (*on_auth_failed)(void *user, const IHKHost *host, IHKAuthResult result);
    /// Steam is starting the stream.
    void (*on_stream_progress)(void *user, const IHKHost *host);
    void (*on_stream_success)(void *user, const IHKHost *host, const IHKStreamGrant *grant);
    void (*on_stream_failed)(void *user, const IHKHost *host, IHKStreamResult result);
    void *user;
} IHKClientCallbacks;

typedef struct IHKClient IHKClient;

/// device_id identifies this phone to Steam (random, persisted). device_name is
/// what the PC shows ("Tristan's iPhone"). secret_key is the 32-byte key to start
/// with (NULL for zeros; it only matters once paired, see ihk_client_set_secret_key).
/// callbacks is copied.
IHKClient *ihk_client_create(uint64_t device_id, const char *device_name, const uint8_t secret_key[32],
                             const IHKClientCallbacks *callbacks);

/// Stops the worker and frees. No callbacks after this returns.
void ihk_client_destroy(IHKClient *client);

/// Sends one discovery request to an IPv4 address (port 27036). Use it to sweep
/// the subnet and to probe a manually entered address; iOS can't broadcast.
/// Returns false if it couldn't be sent (bad address, or the socket isn't open yet).
bool ihk_client_discover(IHKClient *client, const char *address);

/// Switches to the key stored for the host you're about to stream from.
void ihk_client_set_secret_key(IHKClient *client, const uint8_t secret_key[32]);

/// Starts pairing: the PC asks the player to type pin (4 digits, shown by the app).
/// Returns false if pairing is already running or the host is invalid.
bool ihk_client_authorize(IHKClient *client, const IHKHost *host, const char *pin);

/// Cancels a running pairing.
void ihk_client_cancel_authorization(IHKClient *client);

/// Asks the host to start streaming. Set the host's key first. Returns false if a
/// request is already running or the host is invalid.
bool ihk_client_request_stream(IHKClient *client, const IHKHost *host, const IHKStreamRequest *request);

#ifdef __cplusplus
}
#endif

#endif
