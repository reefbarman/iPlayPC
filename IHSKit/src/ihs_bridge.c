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

static void address_to_string(const IHS_IPAddress *ip, char *out, size_t len) {
    out[0] = '\0';
    if (ip->family == IHS_IPAddressFamilyIPv4) {
        inet_ntop(AF_INET, ip->v4.data, out, (socklen_t) len);
    } else if (ip->family == IHS_IPAddressFamilyIPv6) {
        inet_ntop(AF_INET6, ip->v6.data, out, (socklen_t) len);
    }
}

// ------------------------------------------------------------------- client

struct IHKClient {
    IHS_Client *client;
    IHKHostCallback on_host;
    void *user;
};

static void client_discovered(IHS_Client *client, const IHS_HostInfo *info, void *context) {
    IHKClient *c = context;
    if (c->on_host == NULL) {
        return;
    }
    IHKHost host;
    memset(&host, 0, sizeof(host));
    host.host_id = info->clientId;
    host.instance_id = info->instanceId;
    address_to_string(&info->address.ip, host.address, sizeof(host.address));
    host.port = info->address.port;
    strncpy(host.name, info->hostname, sizeof(host.name) - 1);
    host.os_type = info->ostype;
    host.games_running = info->gamesRunning;
    c->on_host(c->user, &host);
}

static const IHS_ClientDiscoveryCallbacks discovery_callbacks = {
    .discovered = client_discovered,
};

IHKClient *ihk_client_create(uint64_t device_id, const char *device_name, const uint8_t secret_key[32],
                             IHKHostCallback on_host, void *user) {
    ihk_lib_init();
    IHKClient *c = calloc(1, sizeof(IHKClient));
    if (c == NULL) {
        return NULL;
    }
    c->on_host = on_host;
    c->user = user;
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
    if (c == NULL || address == NULL) {
        return false;
    }
    IHS_SocketAddress target;
    memset(&target, 0, sizeof(target));
    target.ip.family = IHS_IPAddressFamilyIPv4;
    if (inet_pton(AF_INET, address, target.ip.v4.data) != 1) {
        return false;
    }
    target.port = 27036;
    return IHS_ClientDiscoverAddress(c->client, &target);
}
