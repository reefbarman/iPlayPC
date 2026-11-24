// SPDX-License-Identifier: AGPL-3.0-only
//
// See include/ihs_bridge.h.

#include "ihs_bridge.h"

#include <ihslib.h>

#include <arpa/inet.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

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
