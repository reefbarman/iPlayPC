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

// ------------------------------------------------------------------ session

typedef enum {
    IHK_VIDEO_H264 = 4,
    IHK_VIDEO_HEVC = 5,
} IHKVideoCodec;

/// What we ask the host for. Zeros keep ihslib's defaults.
typedef struct {
    bool enable_audio;
    bool enable_hevc;
    int32_t max_bitrate_kbps;  // cap on the host's bitrate
    int32_t quality;           // 0 Balanced, 1 Fast, 2 Beautiful
    int32_t max_width;         // cap on the stream resolution; the host scales to fit
    int32_t max_height;
    int32_t refresh_num;       // the display's refresh rate as a fraction, e.g. 120/1
    int32_t refresh_den;
    int32_t display_width;     // the display's own resolution
    int32_t display_height;
    /// Tell the host this client has a microphone (only negotiated at connect).
    /// The host then opens a mic channel; push audio with ihk_session_push_mic.
    bool enable_microphone;
    /// Ask for HDR10 (needs enable_hevc). The host only sends it from an HDR display
    /// with a hardware encoder; the decoded frames' colour tags say what came.
    bool enable_hdr;
} IHKSessionConfig;

/// All optional. They fire on ihslib's session threads; never destroy the
/// session from inside one.
typedef struct {
    void (*on_connected)(void *user);
    /// The stream ended (host closed it, network lost, or ihk_session_stop). host_closed:
    /// the host sent Disconnect, so it meant to end it.
    void (*on_disconnected)(void *user, bool host_closed);
    void (*on_video_start)(void *user, IHKVideoCodec codec, uint32_t width, uint32_t height);
    /// One Annex-B access unit (parameter sets arrive in band). Decode it
    /// synchronously and return whether it worked; a failure asks the host for
    /// a keyframe (at most once a second).
    bool (*on_video_frame)(void *user, const uint8_t *data, size_t length, bool keyframe);
    void (*on_video_stop)(void *user);
    /// Audio is decoded inside the bridge; read it with ihk_session_read_audio.
    void (*on_audio_start)(void *user, uint32_t channels, uint32_t sample_rate);
    void (*on_audio_stop)(void *user);
    /// The host changed its target frame rate or bitrate (bits/s). Informational.
    void (*on_target_framerate)(void *user, uint32_t numerator, uint32_t denominator);
    void (*on_target_bitrate)(void *user, int32_t bitrate);
    /// The game's rumble for the controller, 0...65535 per motor (low = heavy
    /// left motor). The bridge sends 0, 0 when the game's duration runs out.
    void (*on_rumble)(void *user, uint16_t low, uint16_t high);
    /// The game's lightbar colour (DualSense).
    void (*on_lightbar)(void *user, uint8_t r, uint8_t g, uint8_t b);
    /// A text field on the host wants typing: bring up the phone's keyboard.
    void (*on_show_keyboard)(void *user);
    /// The host opened (true) or closed (false) its microphone channel.
    void (*on_microphone)(void *user, bool active);
    void *user;
} IHKSessionCallbacks;

typedef struct IHKSession IHKSession;

/// Builds a session from a stream grant. secret_key is the host's pairing key;
/// device_id and device_name must match the client that requested the stream.
/// config and callbacks are copied.
IHKSession *ihk_session_create(uint64_t device_id, const char *device_name, const uint8_t secret_key[32],
                               const IHKStreamGrant *grant, const IHKSessionConfig *config,
                               const IHKSessionCallbacks *callbacks);

/// Connects and returns at once; the session runs on its own threads.
bool ihk_session_start(IHKSession *session);

/// Asks the host to end the stream. on_disconnected follows.
void ihk_session_stop(IHKSession *session);

/// Whether Steam last said a game is in front (not the desktop or Big Picture).
bool ihk_session_game_running(IHKSession *session);

/// Closes the game in front: presses Alt+F4, or Cmd+Q when mac_host. Does
/// nothing unless ihk_session_game_running. Blocks for about 200 ms (the keys
/// are spaced out), so call it off the main thread. Keys are queued like any
/// input, so give them a moment to go out before ihk_session_stop. Returns whether it pressed them.
/// (Steam ignores k_EStreamControlQuitRequest from a client, so keys it is.)
bool ihk_session_quit_game(IHKSession *session, bool mac_host);

/// Stops, waits for ihslib's threads and frees. No callbacks after this returns.
/// Don't call it from a session callback.
void ihk_session_destroy(IHKSession *session);

/// Pulls up to frames of interleaved stereo float audio at 48 kHz. Returns how
/// many it wrote; the rest is the caller's to fill with silence. Safe on the
/// audio render thread.
size_t ihk_session_read_audio(IHKSession *session, float *out, size_t frames);

/// Stereo frames waiting to be read.
size_t ihk_session_audio_buffered(IHKSession *session);

/// Video frames the host sent that never arrived, since the session was created
/// (gaps in the frame numbers). Any thread.
uint64_t ihk_session_lost_frames(IHKSession *session);

/// Milliseconds since the last packet from the host, 0 before the first. Any thread.
/// The host answers our 10 s keepalive, so even a still screen hears back that often.
uint64_t ihk_session_ms_since_receive(IHKSession *session);

/// Microphone audio: 48 kHz mono float, any number of frames, any thread. The
/// bridge cuts it into 10 ms frames, encodes them with Opus and sends them while
/// the host's mic channel is open. Returns false (and drops the audio) otherwise.
bool ihk_session_push_mic(IHKSession *session, const float *samples, size_t frames);

// Input. All return false if the session isn't connected.

typedef enum {
    IHK_MOUSE_LEFT = 1,
    IHK_MOUSE_RIGHT = 2,
    IHK_MOUSE_MIDDLE = 16,
    IHK_MOUSE_X1 = 32,
    IHK_MOUSE_X2 = 64,
} IHKMouseButton;

typedef enum {
    IHK_WHEEL_UP = 1,
    IHK_WHEEL_DOWN = 2,
    IHK_WHEEL_LEFT = 3,
    IHK_WHEEL_RIGHT = 4,
} IHKWheelDirection;

/// Absolute position, 0...1 across the stream.
bool ihk_session_mouse_position(IHKSession *session, float x, float y);
bool ihk_session_mouse_move(IHKSession *session, int32_t dx, int32_t dy);
bool ihk_session_mouse_button(IHKSession *session, IHKMouseButton button, bool down);
bool ihk_session_mouse_wheel(IHKSession *session, IHKWheelDirection direction);
/// USB HID usage scancode (what UIKeyboardHIDUsage gives you).
bool ihk_session_key(IHKSession *session, uint32_t scancode, bool down);
bool ihk_session_text(IHKSession *session, const char *utf8);

typedef enum {
    IHK_TOUCH_DOWN = 0,
    IHK_TOUCH_MOVE = 1,
    IHK_TOUCH_UP = 2,
} IHKTouchPhase;

/// Touchscreen finger at 0...1 across the stream.
bool ihk_session_touch(IHKSession *session, uint64_t finger, IHKTouchPhase phase, float x, float y);

// Controller. Every session has one virtual controller that Steam sees as a
// USB pad; Steam Input on the PC handles glyphs, gyro, touchpad and rumble.

typedef enum {
    IHK_PAD_XBOX = 0,
    IHK_PAD_DUALSENSE = 1,
} IHKPadType;

/// Buttons in SDL GameController numbering, which is what Steam's report uses.
enum {
    IHK_PAD_A = 1u << 0,
    IHK_PAD_B = 1u << 1,
    IHK_PAD_X = 1u << 2,
    IHK_PAD_Y = 1u << 3,
    IHK_PAD_BACK = 1u << 4,
    IHK_PAD_GUIDE = 1u << 5,
    IHK_PAD_START = 1u << 6,
    IHK_PAD_LEFT_STICK = 1u << 7,
    IHK_PAD_RIGHT_STICK = 1u << 8,
    IHK_PAD_LEFT_SHOULDER = 1u << 9,
    IHK_PAD_RIGHT_SHOULDER = 1u << 10,
    IHK_PAD_DPAD_UP = 1u << 11,
    IHK_PAD_DPAD_DOWN = 1u << 12,
    IHK_PAD_DPAD_LEFT = 1u << 13,
    IHK_PAD_DPAD_RIGHT = 1u << 14,
    IHK_PAD_TOUCHPAD = 1u << 20,
};

typedef struct {
    uint32_t buttons;           // IHK_PAD_*
    int16_t left_x, left_y;     // -32768...32767, up is positive
    int16_t right_x, right_y;
    uint8_t left_trigger;       // 0...255
    uint8_t right_trigger;
    uint8_t touches;            // fingers on the touchpad, 0...2
    float touch_x[2];           // 0...1 left to right
    float touch_y[2];           // 0...1 top to bottom
} IHKPadState;

/// Which controller Steam sees. Changing it mid-stream unplugs the old one and
/// plugs in the new one. Xbox until set.
void ihk_session_set_pad_type(IHKSession *session, IHKPadType type);

void ihk_session_send_pad(IHKSession *session, const IHKPadState *state);

/// Motion for Steam Input gyro (DualSense only, and only once Steam turns the
/// sensors on). gyro in rad/s: x right (pitch), y up (yaw), z towards the
/// player (roll). accel in g, reading +1 on y when held flat at rest.
void ihk_session_send_motion(IHKSession *session, const float gyro[3], const float accel[3]);

#ifdef __cplusplus
}
#endif

#endif
