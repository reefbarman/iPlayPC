// SPDX-License-Identifier: AGPL-3.0-only
//
// See include/ihs_bridge.h.

#include "ihs_bridge.h"
#include "ihs_bridge_pad.h"

#include <ihslib.h>

#include "session/session_pri.h"  // state.activity (patch 0101)

#include <opus.h>

#include <arpa/inet.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// ------------------------------------------------------------------ library

static pthread_once_t lib_once = PTHREAD_ONCE_INIT;
static IHKLogCallback log_cb;
static void *log_user;
static IHKLogLevel log_max = IHK_LOG_INFO;

static void lib_init_once(void) {
    IHS_Init();
}

void ihk_lib_init(void) {
    pthread_once(&lib_once, lib_init_once);
}

void ihk_set_log_callback(IHKLogCallback cb, void *user, IHKLogLevel max_level) {
    log_user = user;
    log_max = max_level;
    log_cb = cb;
}

static void ihk_log_sink(IHS_LogLevel level, const char *tag, const char *message) {
    IHKLogCallback cb = log_cb;
    if (cb == NULL || (int) level > (int) log_max) {
        return;
    }
    cb(log_user, (IHKLogLevel) level, tag ? tag : "", message ? message : "");
}

static void ihk_log(IHKLogLevel level, const char *message) {
    ihk_log_sink((IHS_LogLevel) level, "Bridge", message);
}

static void address_to_string(const IHS_IPAddress *ip, char *out, size_t len) {
    out[0] = '\0';
    if (ip->family == IHS_IPAddressFamilyIPv4) {
        inet_ntop(AF_INET, ip->v4.data, out, (socklen_t) len);
    } else if (ip->family == IHS_IPAddressFamilyIPv6) {
        inet_ntop(AF_INET6, ip->v6.data, out, (socklen_t) len);
    }
}

static bool address_from_string(const char *text, IHS_IPAddress *ip) {
    memset(ip, 0, sizeof(*ip));
    ip->family = IHS_IPAddressFamilyIPv4;
    return text != NULL && inet_pton(AF_INET, text, ip->v4.data) == 1;
}

// -------------------------------------------------------------------- hosts

static void host_from_info(const IHS_HostInfo *info, IHKHost *host) {
    memset(host, 0, sizeof(*host));
    host->host_id = info->clientId;
    host->instance_id = info->instanceId;
    address_to_string(&info->address.ip, host->address, sizeof(host->address));
    host->port = info->address.port;
    strncpy(host->name, info->hostname, sizeof(host->name) - 1);
    host->os_type = info->ostype;
    host->universe = info->universe;
    host->games_running = info->gamesRunning;
}

static bool info_from_host(const IHKHost *host, IHS_HostInfo *info) {
    memset(info, 0, sizeof(*info));
    if (host == NULL || !address_from_string(host->address, &info->address.ip)) {
        return false;
    }
    info->clientId = host->host_id;
    info->instanceId = host->instance_id;
    info->address.port = host->port != 0 ? host->port : 27036;
    strncpy(info->hostname, host->name, sizeof(info->hostname) - 1);
    info->ostype = (IHS_SteamOSType) host->os_type;
    info->universe = host->universe != 0 ? (IHS_SteamUniverse) host->universe : IHS_SteamUniversePublic;
    info->gamesRunning = host->games_running;
    return true;
}

// ------------------------------------------------------------------- client

struct IHKClient {
    IHS_Client *client;
    IHKClientCallbacks cb;
};

static void client_discovered(IHS_Client *client, const IHS_HostInfo *info, void *context) {
    IHKClient *c = context;
    if (c->cb.on_host == NULL) {
        return;
    }
    IHKHost host;
    host_from_info(info, &host);
    c->cb.on_host(c->cb.user, &host);
}

static void client_auth_progress(IHS_Client *client, const IHS_HostInfo *info, void *context) {
    IHKClient *c = context;
    if (c->cb.on_auth_progress == NULL) {
        return;
    }
    IHKHost host;
    host_from_info(info, &host);
    c->cb.on_auth_progress(c->cb.user, &host);
}

static void client_auth_success(IHS_Client *client, const IHS_HostInfo *info, uint64_t steam_id, void *context) {
    IHKClient *c = context;
    if (c->cb.on_auth_success == NULL) {
        return;
    }
    IHKHost host;
    host_from_info(info, &host);
    uint8_t key[32];
    IHS_ClientGetSecretKey(client, key);
    c->cb.on_auth_success(c->cb.user, &host, key, steam_id);
}

static void client_auth_failed(IHS_Client *client, const IHS_HostInfo *info, IHS_AuthorizationResult result,
                               void *context) {
    IHKClient *c = context;
    if (c->cb.on_auth_failed == NULL) {
        return;
    }
    IHKHost host;
    host_from_info(info, &host);
    c->cb.on_auth_failed(c->cb.user, &host, (IHKAuthResult) result);
}

static void client_stream_progress(IHS_Client *client, const IHS_HostInfo *info, void *context) {
    IHKClient *c = context;
    if (c->cb.on_stream_progress == NULL) {
        return;
    }
    IHKHost host;
    host_from_info(info, &host);
    c->cb.on_stream_progress(c->cb.user, &host);
}

static void client_stream_success(IHS_Client *client, const IHS_HostInfo *info, const IHS_SocketAddress *address,
                                  const uint8_t *session_key, size_t session_key_len, void *context) {
    IHKClient *c = context;
    if (c->cb.on_stream_success == NULL) {
        return;
    }
    IHKHost host;
    host_from_info(info, &host);
    IHKStreamGrant grant;
    memset(&grant, 0, sizeof(grant));
    address_to_string(&address->ip, grant.address, sizeof(grant.address));
    grant.port = address->port;
    grant.session_key_len = session_key_len < sizeof(grant.session_key) ? session_key_len : sizeof(grant.session_key);
    memcpy(grant.session_key, session_key, grant.session_key_len);
    c->cb.on_stream_success(c->cb.user, &host, &grant);
}

static void client_stream_failed(IHS_Client *client, const IHS_HostInfo *info, IHS_StreamingResult result,
                                 void *context) {
    IHKClient *c = context;
    if (c->cb.on_stream_failed == NULL) {
        return;
    }
    IHKHost host;
    host_from_info(info, &host);
    c->cb.on_stream_failed(c->cb.user, &host, (IHKStreamResult) result);
}

static const IHS_ClientDiscoveryCallbacks discovery_callbacks = {
    .discovered = client_discovered,
};

static const IHS_ClientAuthorizationCallbacks authorization_callbacks = {
    .progress = client_auth_progress,
    .success = client_auth_success,
    .failed = client_auth_failed,
};

static const IHS_ClientStreamingCallbacks streaming_callbacks = {
    .progress = client_stream_progress,
    .success = client_stream_success,
    .failed = client_stream_failed,
};

IHKClient *ihk_client_create(uint64_t device_id, const char *device_name, const uint8_t secret_key[32],
                             const IHKClientCallbacks *callbacks) {
    ihk_lib_init();
    IHKClient *c = calloc(1, sizeof(IHKClient));
    if (c == NULL) {
        return NULL;
    }
    if (callbacks != NULL) {
        c->cb = *callbacks;
    }
    uint8_t key[32] = {0};
    if (secret_key != NULL) {
        memcpy(key, secret_key, sizeof(key));
    }
    IHS_ClientConfig config = {
        .deviceId = device_id,
        .secretKey = key,
        .deviceName = device_name,
    };
    c->client = IHS_ClientCreate(&config);
    if (c->client == NULL) {
        free(c);
        return NULL;
    }
    IHS_ClientSetLogFunction(c->client, ihk_log_sink);
    IHS_ClientSetDiscoveryCallbacks(c->client, &discovery_callbacks, c);
    IHS_ClientSetAuthorizationCallbacks(c->client, &authorization_callbacks, c);
    IHS_ClientSetStreamingCallbacks(c->client, &streaming_callbacks, c);
    return c;
}

void ihk_client_destroy(IHKClient *c) {
    if (c == NULL) {
        return;
    }
    IHS_ClientStop(c->client);
    IHS_ClientThreadedJoin(c->client);
    IHS_ClientDestroy(c->client);
    free(c);
}

bool ihk_client_discover(IHKClient *c, const char *address) {
    if (c == NULL) {
        return false;
    }
    IHS_SocketAddress target;
    memset(&target, 0, sizeof(target));
    if (!address_from_string(address, &target.ip)) {
        return false;
    }
    target.port = 27036;
    return IHS_ClientDiscoverAddress(c->client, &target);
}

void ihk_client_set_secret_key(IHKClient *c, const uint8_t secret_key[32]) {
    if (c == NULL || secret_key == NULL) {
        return;
    }
    IHS_ClientSetSecretKey(c->client, secret_key);
}

bool ihk_client_authorize(IHKClient *c, const IHKHost *host, const char *pin) {
    IHS_HostInfo info;
    if (c == NULL || pin == NULL || !info_from_host(host, &info)) {
        ihk_log(IHK_LOG_WARN, "Authorize: invalid host or PIN");
        return false;
    }
    return IHS_ClientAuthorizationRequest(c->client, &info, pin);
}

void ihk_client_cancel_authorization(IHKClient *c) {
    if (c == NULL) {
        return;
    }
    IHS_ClientAuthorizationCancel(c->client);
}

bool ihk_client_request_stream(IHKClient *c, const IHKHost *host, const IHKStreamRequest *request) {
    IHS_HostInfo info;
    if (c == NULL || request == NULL || !info_from_host(host, &info)) {
        ihk_log(IHK_LOG_WARN, "Stream request: invalid host");
        return false;
    }
    IHS_StreamingRequest r;
    memset(&r, 0, sizeof(r));
    r.streamingEnable.video = true;
    r.streamingEnable.audio = true;
    r.streamingEnable.input = true;
    r.maxResolution.x = request->max_width;
    r.maxResolution.y = request->max_height;
    r.audioChannelCount = request->audio_channels > 0 ? request->audio_channels : 2;
    r.streamingInterface = (IHS_StreamInterface) request->streaming_interface;
    return IHS_ClientStreamingRequest(c->client, &info, &r);
}

// ------------------------------------------------------------------ session

// Decoded audio waits here for the render thread: 200 ms of stereo at 48 kHz.
// If playback falls behind past AUDIO_MAX_FRAMES we drop the oldest audio down
// to AUDIO_TRIM_FRAMES so latency can't creep up.
#define AUDIO_RATE 48000
#define AUDIO_RING_FRAMES 9600
#define AUDIO_MAX_FRAMES 4800
#define AUDIO_TRIM_FRAMES 1920
#define OPUS_MAX_FRAMES 5760  // 120 ms, the longest Opus packet

struct IHKSession {
    IHS_Session *session;
    IHKSessionConfig config;
    IHKSessionCallbacks cb;
    char device_name[128];
    uint8_t secret_key[32];
    bool started;
    // ihslib keeps one disconnect timer per session; a second disconnect
    // overwrites it and the first then fires on the freed session
    atomic_bool disconnecting;
    IHKPad *pad;

    OpusDecoder *opus;
    float decoded[OPUS_MAX_FRAMES * 2];
    pthread_mutex_t audio_lock;
    float ring[AUDIO_RING_FRAMES * 2];
    size_t ring_read;   // frame index
    size_t ring_count;  // frames buffered

    uint64_t last_lost_report_ms;
};

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t) ts.tv_sec * 1000 + (uint64_t) ts.tv_nsec / 1000000;
}

static void session_configuring(IHS_Session *session, IHS_SessionConfig *config, void *context) {
    IHKSession *s = context;
    const IHKSessionConfig *c = &s->config;
    config->enableAudio = c->enable_audio;
    config->enableHevc = c->enable_hevc;
    config->maxBitrateKbps = c->max_bitrate_kbps;
    config->quality = c->quality;
    config->maxResolutionX = c->max_width;
    config->maxResolutionY = c->max_height;
    config->refreshRateNum = c->refresh_num;
    config->refreshRateDen = c->refresh_den;
    config->displayWidth = c->display_width;
    config->displayHeight = c->display_height;
}

static void session_connected(IHS_Session *session, void *context) {
    IHKSession *s = context;
    if (s->cb.on_connected != NULL) {
        s->cb.on_connected(s->cb.user);
    }
    // Steam opens the controller and asks for its reports
    ihk_pad_connected(s->pad);
}

static void session_disconnected(IHS_Session *session, void *context) {
    IHKSession *s = context;
    ihk_pad_disconnected(s->pad);
    if (s->cb.on_disconnected != NULL) {
        s->cb.on_disconnected(s->cb.user);
    }
}

static int video_start(IHS_Session *session, const IHS_StreamVideoConfig *config, void *context) {
    IHKSession *s = context;
    if (config->codec != IHS_StreamVideoCodecH264 && config->codec != IHS_StreamVideoCodecHEVC) {
        ihk_log(IHK_LOG_ERROR, "Video: unsupported codec");
        return -1;
    }
    if (s->cb.on_video_start != NULL) {
        s->cb.on_video_start(s->cb.user, (IHKVideoCodec) config->codec, config->width, config->height);
    }
    return 0;
}

static IHS_StreamVideoSubmitResult video_submit(IHS_Session *session, IHS_Buffer *data, IHS_StreamVideoFrameFlag flags,
                                                void *context) {
    IHKSession *s = context;
    const bool keyframe = (flags & IHS_StreamVideoFrameKeyFrame) != 0;
    const uint16_t frame_id = IHS_SessionLastSubmittedVideoFrameId(session);
    IHS_SessionReportVideoFrameStage(session, frame_id, IHS_VideoFrameStageDecodeBegin, 0);
    bool ok = true;
    if (s->cb.on_video_frame != NULL) {
        ok = s->cb.on_video_frame(s->cb.user, IHS_BufferPointer(data), data->size, keyframe);
    }
    IHS_SessionReportVideoFrameStage(session, frame_id, IHS_VideoFrameStageDecodeEnd, 0);
    // The host's adaptive bitrate and frame rate key off these reports.
    IHS_SessionReportVideoFrameComplete(session, frame_id,
                                        ok ? IHS_VideoFrameResultDisplayed : IHS_VideoFrameResultDroppedDecodeCorrupt);
    if (ok) {
        return IHS_StreamVideoSubmitOK;
    }
    // Reporting a loss makes ihslib ask for a keyframe. On a lossy link asking
    // every frame snowballs (keyframes are big, so more loss), so ask at most
    // once a second.
    const uint64_t now = now_ms();
    if (!keyframe && now - s->last_lost_report_ms > 1000) {
        s->last_lost_report_ms = now;
        return IHS_StreamVideoSubmitReportLost;
    }
    return IHS_StreamVideoSubmitOK;
}

static void video_stop(IHS_Session *session, void *context) {
    IHKSession *s = context;
    if (s->cb.on_video_stop != NULL) {
        s->cb.on_video_stop(s->cb.user);
    }
}

static void video_target_framerate(IHS_Session *session, uint32_t numerator, uint32_t denominator, uint32_t reasons,
                                   void *context) {
    IHKSession *s = context;
    if (s->cb.on_target_framerate != NULL) {
        s->cb.on_target_framerate(s->cb.user, numerator, denominator);
    }
}

static void video_target_bitrate(IHS_Session *session, int32_t bitrate, void *context) {
    IHKSession *s = context;
    if (s->cb.on_target_bitrate != NULL) {
        s->cb.on_target_bitrate(s->cb.user, bitrate);
    }
}

static void audio_reset(IHKSession *s) {
    pthread_mutex_lock(&s->audio_lock);
    s->ring_read = 0;
    s->ring_count = 0;
    pthread_mutex_unlock(&s->audio_lock);
}

static int audio_start(IHS_Session *session, const IHS_StreamAudioConfig *config, void *context) {
    IHKSession *s = context;
    if (config->codec != IHS_StreamAudioCodecOpus) {
        ihk_log(IHK_LOG_ERROR, "Audio: unsupported codec");
        return -1;
    }
    if (s->opus != NULL) {
        opus_decoder_destroy(s->opus);
        s->opus = NULL;
    }
    // Always decode to 48 kHz stereo: Opus resamples and up/downmixes for us.
    int error = 0;
    s->opus = opus_decoder_create(AUDIO_RATE, 2, &error);
    if (s->opus == NULL || error != OPUS_OK) {
        ihk_log(IHK_LOG_ERROR, "Audio: Opus decoder failed");
        s->opus = NULL;
        return -1;
    }
    audio_reset(s);
    if (s->cb.on_audio_start != NULL) {
        s->cb.on_audio_start(s->cb.user, config->channels, config->frequency);
    }
    return 0;
}

static int audio_submit(IHS_Session *session, IHS_Buffer *data, void *context) {
    IHKSession *s = context;
    if (s->opus == NULL) {
        return 0;
    }
    const int frames = opus_decode_float(s->opus, IHS_BufferPointer(data), (opus_int32) data->size, s->decoded,
                                         OPUS_MAX_FRAMES, 0);
    if (frames <= 0) {
        return 0;
    }
    pthread_mutex_lock(&s->audio_lock);
    for (int i = 0; i < frames; i++) {
        if (s->ring_count == AUDIO_RING_FRAMES) {
            s->ring_read = (s->ring_read + 1) % AUDIO_RING_FRAMES;
            s->ring_count--;
        }
        const size_t at = (s->ring_read + s->ring_count) % AUDIO_RING_FRAMES;
        s->ring[at * 2] = s->decoded[i * 2];
        s->ring[at * 2 + 1] = s->decoded[i * 2 + 1];
        s->ring_count++;
    }
    if (s->ring_count > AUDIO_MAX_FRAMES) {
        const size_t drop = s->ring_count - AUDIO_TRIM_FRAMES;
        s->ring_read = (s->ring_read + drop) % AUDIO_RING_FRAMES;
        s->ring_count -= drop;
    }
    pthread_mutex_unlock(&s->audio_lock);
    return 0;
}

static void audio_stop(IHS_Session *session, void *context) {
    IHKSession *s = context;
    audio_reset(s);
    if (s->cb.on_audio_stop != NULL) {
        s->cb.on_audio_stop(s->cb.user);
    }
}

static bool input_set_cursor(IHS_Session *session, uint64_t cursor_id, void *context) {
    // We draw no host cursor; saying we have it stops ihslib asking for images.
    return true;
}

static void input_show_keyboard(IHS_Session *session, void *context) {
    IHKSession *s = context;
    if (s->cb.on_show_keyboard != NULL) {
        s->cb.on_show_keyboard(s->cb.user);
    }
}

static const IHS_StreamSessionCallbacks session_callbacks = {
    .configuring = session_configuring,
    .connected = session_connected,
    .disconnected = session_disconnected,
};

static const IHS_StreamVideoCallbacks video_callbacks = {
    .start = video_start,
    .submit = video_submit,
    .stop = video_stop,
    .setTargetFramerate = video_target_framerate,
    .setTargetBitrate = video_target_bitrate,
};

static const IHS_StreamAudioCallbacks audio_callbacks = {
    .start = audio_start,
    .submit = audio_submit,
    .stop = audio_stop,
};

static const IHS_StreamInputCallbacks input_callbacks = {
    .setCursor = input_set_cursor,
    .showOnScreenKeyboard = input_show_keyboard,
};

IHKSession *ihk_session_create(uint64_t device_id, const char *device_name, const uint8_t secret_key[32],
                               const IHKStreamGrant *grant, const IHKSessionConfig *config,
                               const IHKSessionCallbacks *callbacks) {
    ihk_lib_init();
    if (grant == NULL || secret_key == NULL) {
        return NULL;
    }
    IHKSession *s = calloc(1, sizeof(IHKSession));
    if (s == NULL) {
        return NULL;
    }
    pthread_mutex_init(&s->audio_lock, NULL);
    if (config != NULL) {
        s->config = *config;
    }
    if (callbacks != NULL) {
        s->cb = *callbacks;
    }
    if (device_name != NULL) {
        strncpy(s->device_name, device_name, sizeof(s->device_name) - 1);
    }
    memcpy(s->secret_key, secret_key, sizeof(s->secret_key));

    IHS_ClientConfig client_config = {
        .deviceId = device_id,
        .secretKey = s->secret_key,
        .deviceName = s->device_name,
    };
    IHS_SessionInfo info;
    memset(&info, 0, sizeof(info));
    if (!address_from_string(grant->address, &info.address.ip)) {
        ihk_log(IHK_LOG_ERROR, "Session: bad address");
        pthread_mutex_destroy(&s->audio_lock);
        free(s);
        return NULL;
    }
    info.address.port = grant->port;
    info.sessionKeyLen = grant->session_key_len;
    memcpy(info.sessionKey, grant->session_key, grant->session_key_len);
    info.steamId = 0;

    s->session = IHS_SessionCreate(&client_config, &info);
    if (s->session == NULL) {
        pthread_mutex_destroy(&s->audio_lock);
        free(s);
        return NULL;
    }
    IHS_SessionSetLogFunction(s->session, ihk_log_sink);
    IHS_SessionSetSessionCallbacks(s->session, &session_callbacks, s);
    IHS_SessionSetVideoCallbacks(s->session, &video_callbacks, s);
    IHS_SessionSetAudioCallbacks(s->session, &audio_callbacks, s);
    IHS_SessionSetInputCallbacks(s->session, &input_callbacks, s);
    s->pad = ihk_pad_create(s->session, &s->cb);
    return s;
}

bool ihk_session_start(IHKSession *s) {
    if (s == NULL || s->started) {
        return false;
    }
    s->started = IHS_SessionConnect(s->session);
    return s->started;
}

static void session_disconnect_once(IHKSession *s) {
    if (!atomic_exchange(&s->disconnecting, true)) {
        IHS_SessionDisconnect(s->session);
    }
}

void ihk_session_stop(IHKSession *s) {
    if (s == NULL || !s->started) {
        return;
    }
    session_disconnect_once(s);
}

bool ihk_session_game_running(IHKSession *s) {
    return s != NULL && s->started && s->session->state.activity == k_EStreamActivityGame;
}

// USB HID usages
#define HID_KEY_Q 0x14
#define HID_KEY_F4 0x3D
#define HID_KEY_LEFT_ALT 0xE2
#define HID_KEY_LEFT_GUI 0xE3

bool ihk_session_quit_game(IHKSession *s, bool mac_host) {
    if (!ihk_session_game_running(s) || atomic_load(&s->disconnecting)) {
        ihk_log(IHK_LOG_INFO, "Session: no game in front to quit");
        return false;
    }
    const uint32_t modifier = mac_host ? HID_KEY_LEFT_GUI : HID_KEY_LEFT_ALT;
    const uint32_t key = mac_host ? HID_KEY_Q : HID_KEY_F4;
    // Spaced out like real typing: sent back to back, a Mac host misses the
    // modifier and the game sees a plain Q
    const struct timespec gap = {.tv_sec = 0, .tv_nsec = 60 * 1000 * 1000};
    bool sent = IHS_SessionSendKeyDown(s->session, modifier);
    nanosleep(&gap, NULL);
    sent = IHS_SessionSendKeyDown(s->session, key) && sent;
    nanosleep(&gap, NULL);
    sent = IHS_SessionSendKeyUp(s->session, key) && sent;
    nanosleep(&gap, NULL);
    sent = IHS_SessionSendKeyUp(s->session, modifier) && sent;
    char line[96];
    snprintf(line, sizeof(line), "Session: %s game %u with %s", sent ? "quit" : "couldn't quit",
             (unsigned) s->session->state.activityAppId, mac_host ? "Cmd+Q" : "Alt+F4");
    ihk_log(IHK_LOG_INFO, line);
    return sent;
}

void ihk_session_destroy(IHKSession *s) {
    if (s == NULL) {
        return;
    }
    if (s->started) {
        session_disconnect_once(s);
        IHS_SessionThreadedJoin(s->session);
    }
    IHS_SessionDestroy(s->session);
    ihk_pad_destroy(s->pad);
    if (s->opus != NULL) {
        opus_decoder_destroy(s->opus);
    }
    pthread_mutex_destroy(&s->audio_lock);
    free(s);
}

size_t ihk_session_read_audio(IHKSession *s, float *out, size_t frames) {
    if (s == NULL || out == NULL) {
        return 0;
    }
    pthread_mutex_lock(&s->audio_lock);
    const size_t n = frames < s->ring_count ? frames : s->ring_count;
    for (size_t i = 0; i < n; i++) {
        const size_t at = (s->ring_read + i) % AUDIO_RING_FRAMES;
        out[i * 2] = s->ring[at * 2];
        out[i * 2 + 1] = s->ring[at * 2 + 1];
    }
    s->ring_read = (s->ring_read + n) % AUDIO_RING_FRAMES;
    s->ring_count -= n;
    pthread_mutex_unlock(&s->audio_lock);
    return n;
}

size_t ihk_session_audio_buffered(IHKSession *s) {
    if (s == NULL) {
        return 0;
    }
    pthread_mutex_lock(&s->audio_lock);
    const size_t n = s->ring_count;
    pthread_mutex_unlock(&s->audio_lock);
    return n;
}

bool ihk_session_mouse_position(IHKSession *s, float x, float y) {
    return s != NULL && IHS_SessionSendMousePosition(s->session, x, y);
}

bool ihk_session_mouse_move(IHKSession *s, int32_t dx, int32_t dy) {
    return s != NULL && IHS_SessionSendMouseMovement(s->session, dx, dy);
}

bool ihk_session_mouse_button(IHKSession *s, IHKMouseButton button, bool down) {
    if (s == NULL) {
        return false;
    }
    return down ? IHS_SessionSendMouseDown(s->session, (IHS_StreamInputMouseButton) button)
                : IHS_SessionSendMouseUp(s->session, (IHS_StreamInputMouseButton) button);
}

bool ihk_session_mouse_wheel(IHKSession *s, IHKWheelDirection direction) {
    return s != NULL && IHS_SessionSendMouseWheel(s->session, (IHS_StreamInputMouseWheelDirection) direction);
}

bool ihk_session_key(IHKSession *s, uint32_t scancode, bool down) {
    if (s == NULL) {
        return false;
    }
    return down ? IHS_SessionSendKeyDown(s->session, scancode) : IHS_SessionSendKeyUp(s->session, scancode);
}

bool ihk_session_text(IHKSession *s, const char *utf8) {
    return s != NULL && utf8 != NULL && IHS_SessionSendText(s->session, utf8);
}

void ihk_session_set_pad_type(IHKSession *s, IHKPadType type) {
    if (s != NULL && s->pad != NULL) {
        ihk_pad_set_type(s->pad, type);
    }
}

void ihk_session_send_pad(IHKSession *s, const IHKPadState *state) {
    if (s != NULL && s->pad != NULL && state != NULL) {
        ihk_pad_send(s->pad, state);
    }
}

void ihk_session_send_motion(IHKSession *s, const float gyro[3], const float accel[3]) {
    if (s != NULL && s->pad != NULL && gyro != NULL && accel != NULL) {
        ihk_pad_send_motion(s->pad, gyro, accel);
    }
}

bool ihk_session_touch(IHKSession *s, uint64_t finger, IHKTouchPhase phase, float x, float y) {
    if (s == NULL) {
        return false;
    }
    switch (phase) {
    case IHK_TOUCH_DOWN:
        return IHS_SessionSendTouchDown(s->session, finger, x, y);
    case IHK_TOUCH_MOVE:
        return IHS_SessionSendTouchMotion(s->session, finger, x, y);
    case IHK_TOUCH_UP:
        return IHS_SessionSendTouchUp(s->session, finger, x, y);
    }
    return false;
}
