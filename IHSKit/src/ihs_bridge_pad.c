// SPDX-License-Identifier: AGPL-3.0-only
//
// The session's virtual controller: an ihslib HID provider with one device that
// Steam sees as a USB Xbox or DualSense pad.
//
// Input always travels as Steam's canonical 48-byte gamepad report (the layout
// ihslib's SDL backend sends). The identity is only the USB ids, the strings and
// the caps feature report, which is what makes Steam show Xbox or PlayStation
// glyphs and offer gyro and touchpad. Steam sends rumble, lightbar and sensor
// requests back as small write commands. The protocol details (report length,
// timestamps, caps layout) follow Steam-Link-PS5's DualSense provider, which is
// verified against current Steam.
//
// Switching identity bumps a generation that is part of the device path: Steam
// re-enumerates, sees a new device, and the old one closes on its next poll.

#include "ihs_bridge_pad.h"

#include <ihslib/enumeration.h>
#include <ihslib/hid.h>

#include "hid/device.h"
#include "hid/provider.h"
#include "session/session_pri.h"  // IHS_SessionLog

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct __attribute__((packed)) {
    int16_t axes[6];      // LX LY RX RY LT RT: SDL convention, Y down, triggers 0...32767
    uint32_t flags;
    uint32_t buttons;     // SDL button numbering
    uint8_t padding[7];
    uint8_t version;      // what Steam asked for with write 0x09
    int16_t gyro[3];
    int16_t accel[3];
    int16_t touch[2][2];  // fingers 0 and 1: x, y across the s16 range, y up
} PadReport;

_Static_assert(sizeof(PadReport) == 48, "Steam's gamepad report is 48 bytes");

enum {
    FLAG_SENSORS = 0x0406,  // gyro (0x402) and accelerometer (0x004)
    FLAG_TOUCH_0 = 0x010,
    FLAG_TOUCH_1 = 0x100,
};

// Steam picks the report length it parses (73 bytes on current Steam); ours is
// zero-padded to it. A shorter report gets every report discarded.
#define REPORT_MAX 128
// The 73-byte report carries a report timestamp (µs) at 0x30 that must change
// between reports, and the IMU sample time (100 ns units) at 0x34.
#define REPORT_STAMP_OFFSET 0x30
#define REPORT_IMU_STAMP_OFFSET 0x34
#define REPORT_STAMPED_LENGTH 0x38
// Motion older than this isn't flagged, so Steam never sees a frozen gyro
#define MOTION_STALE_US 500000

typedef struct {
    uint16_t vendor_id;
    uint16_t product_id;
    uint16_t version;
    const char *vendor;
    const char *product;
    const char *serial;
    int32_t controller_type;  // SDL EControllerType
    uint32_t caps;
} Identity;

static const Identity identities[] = {
    [IHK_PAD_XBOX] = {
        .vendor_id = 0x045e,
        .product_id = 0x0b12,
        .version = 0x0100,
        .vendor = "Microsoft",
        .product = "Xbox Series X Controller",
        .serial = "024950435800",
        .controller_type = 32,  // k_ControllerTypeXBoxOneController
        // Sticks, buttons, triggers, guide, rumble
        .caps = 0x008343ffu,
    },
    [IHK_PAD_DUALSENSE] = {
        .vendor_id = 0x054c,
        .product_id = 0x0ce6,
        .version = 0x0100,
        .vendor = "Sony",
        .product = "DualSense Wireless Controller",
        .serial = "024950435801",
        .controller_type = 45,  // k_ControllerTypePS5Controller
        // As Xbox, plus gyro and accelerometer (0x00040800) and touchpad (0x02001000)
        .caps = 0x008343ffu | 0x00040800u | 0x02001000u,
    },
};

struct IHKPad {
    pthread_mutex_t lock;
    IHS_Session *session;
    IHS_HIDProvider *provider;
    const IHKSessionCallbacks *cb;
    bool connected;
    IHKPadType type;
    uint32_t generation;
    IHKPadState state;
    float gyro[3];
    float accel[3];
    uint64_t motion_us;
    bool sensors;          // Steam asked for motion
    uint8_t version;
    uint64_t rumble_until_us;
};

typedef struct {
    IHS_HIDProvider base;
    IHKPad *pad;
} Provider;

typedef struct {
    IHS_HIDDevice base;
    IHKPad *pad;
    uint32_t generation;  // the pad's generation when Steam opened this device
    IHKPadType type;
    uint8_t cur[REPORT_MAX];
    uint8_t prev[REPORT_MAX];
    size_t report_len;
    bool started;         // Steam asked for input reports
} Device;

/// One enumerated device; freed with the enumeration
typedef struct {
    char path[32];
    IHKPadType type;
} Listing;

static uint64_t now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t) ts.tv_sec * 1000000u + (uint64_t) ts.tv_nsec / 1000u;
}

static const Identity *identity_for(IHKPadType type) {
    return &identities[type == IHK_PAD_DUALSENSE ? IHK_PAD_DUALSENSE : IHK_PAD_XBOX];
}

static void pad_rumble(IHKPad *pad, uint16_t low, uint16_t high) {
    if (pad->cb->on_rumble != NULL) {
        pad->cb->on_rumble(pad->cb->user, low, high);
    }
}

// ------------------------------------------------------------------- report

/// Ours is Y up; the wire is Y down
static int16_t wire_y(int16_t up) {
    const int down = -(int) up;
    return (int16_t) (down > 32767 ? 32767 : down);
}

static int16_t wire_trigger(uint8_t value) {
    return (int16_t) ((int) value * 32767 / 255);
}

static int16_t remap(float value, float low, float high) {
    float t = (value - low) / (high - low);
    t = t < 0.f ? 0.f : (t > 1.f ? 1.f : t);
    return (int16_t) (-32768.f + t * 65535.f);
}

static int16_t touch_axis(float unit) {
    unit = unit < 0.f ? 0.f : (unit > 1.f ? 1.f : unit);
    return (int16_t) (unit * 65535.f - 32768.f);
}

/// Under pad->lock
static void fill_report(PadReport *r, const IHKPad *pad, IHKPadType type, uint64_t now) {
    const IHKPadState *s = &pad->state;
    r->axes[0] = s->left_x;
    r->axes[1] = wire_y(s->left_y);
    r->axes[2] = s->right_x;
    r->axes[3] = wire_y(s->right_y);
    r->axes[4] = wire_trigger(s->left_trigger);
    r->axes[5] = wire_trigger(s->right_trigger);
    r->buttons = s->buttons;
    r->version = pad->version;

    // A lifted finger clears its flag and keeps its last position, as Valve's client does
    static const uint32_t finger_flags[2] = {FLAG_TOUCH_0, FLAG_TOUCH_1};
    for (int i = 0; i < 2; i++) {
        if (type == IHK_PAD_DUALSENSE && i < s->touches) {
            r->touch[i][0] = touch_axis(s->touch_x[i]);
            r->touch[i][1] = touch_axis(1.f - s->touch_y[i]);
            r->flags |= finger_flags[i];
        } else {
            r->flags &= ~finger_flags[i];
        }
    }

    if (type == IHK_PAD_DUALSENSE && pad->sensors && pad->motion_us != 0 && now - pad->motion_us < MOTION_STALE_US) {
        // The wire wants m/s² over ±19.6 and rad/s over ±34.9 (ihslib sdl_hid_report.c)
        for (int i = 0; i < 3; i++) {
            r->accel[i] = remap(pad->accel[i] * 9.80665f, -19.6133f, 19.6133f);
            r->gyro[i] = remap(pad->gyro[i], -34.90659f, 34.90659f);
        }
        r->flags |= FLAG_SENSORS;
    } else {
        memset(r->accel, 0, sizeof(r->accel));
        memset(r->gyro, 0, sizeof(r->gyro));
        r->flags &= ~(uint32_t) FLAG_SENSORS;
    }
}

// ------------------------------------------------------------------- device

static IHS_HIDDevice *device_alloc(const IHS_HIDDeviceClass *cls) {
    Device *d = calloc(1, sizeof(Device));
    d->base.cls = cls;
    return &d->base;
}

static void device_free(IHS_HIDDevice *device) {
    free(device);
}

static void device_opened(IHS_HIDDevice *device) {
    Device *d = (Device *) device;
    memset(d->cur, 0, sizeof(d->cur));
    memset(d->prev, 0, sizeof(d->prev));
    d->report_len = sizeof(PadReport);
    d->started = false;
}

static void device_close(IHS_HIDDevice *device) {
    Device *d = (Device *) device;
    IHKPad *pad = d->pad;
    pthread_mutex_lock(&pad->lock);
    const bool current = d->generation == pad->generation;
    if (current) {
        pad->rumble_until_us = 0;
    }
    pthread_mutex_unlock(&pad->lock);
    // A device being replaced leaves the motors to the new one
    if (current) {
        pad_rumble(pad, 0, 0);
    }
}

// Steam's commands to the pad (ihslib sdl_hid_write.c layout)
static int device_write(IHS_HIDDevice *device, const uint8_t *data, size_t length) {
    Device *d = (Device *) device;
    IHKPad *pad = d->pad;
    if (length < 1) {
        return -1;
    }
    switch (data[0]) {
        case 0x01: {  // rumble: u16 low, u16 high, u32 duration ms
            if (length < 9) {
                return -1;
            }
            uint16_t low, high;
            uint32_t duration_ms;
            memcpy(&low, data + 1, 2);
            memcpy(&high, data + 3, 2);
            memcpy(&duration_ms, data + 5, 4);
            pthread_mutex_lock(&pad->lock);
            // We stop the motors ourselves when the duration ends, so a lost
            // "stop" never leaves the controller buzzing
            pad->rumble_until_us = (low || high) && duration_ms > 0 ? now_us() + (uint64_t) duration_ms * 1000u : 0;
            pthread_mutex_unlock(&pad->lock);
            pad_rumble(pad, low, high);
            return 0;
        }
        case 0x05:  // LED r, g, b
            if (length < 4) {
                return -1;
            }
            if (pad->cb->on_lightbar != NULL) {
                pad->cb->on_lightbar(pad->cb->user, data[1], data[2], data[3]);
            }
            return 0;
        case 0x08:  // sensors on/off
            if (length < 2) {
                return -1;
            }
            pthread_mutex_lock(&pad->lock);
            pad->sensors = data[1] != 0;
            pthread_mutex_unlock(&pad->lock);
            IHS_SessionLog(pad->session, IHS_LogLevelInfo, "Pad", "Sensors %s", data[1] ? "on" : "off");
            return 0;
        case 0x09:  // report version
            if (length < 2) {
                return -1;
            }
            pthread_mutex_lock(&pad->lock);
            pad->version = data[1];
            pthread_mutex_unlock(&pad->lock);
            return 0;
        default:  // trigger rumble, PlayStation enhanced mode, player index
            return 0;
    }
}

static int device_read(IHS_HIDDevice *device, IHS_Buffer *dest, size_t length, uint32_t timeout_ms) {
    (void) device;
    (void) timeout_ms;
    // Steam reads for liveness only; input goes as pushed reports. Failing the
    // read makes Steam drop the controller.
    uint8_t *pointer = IHS_BufferPointerForAppend(dest, length);
    memset(pointer, 0, length);
    return (int) length;
}

static int device_send_feature_report(IHS_HIDDevice *device, const uint8_t *data, size_t length) {
    (void) device;
    (void) data;
    (void) length;
    return -1;
}

static int device_get_feature_report(IHS_HIDDevice *device, const uint8_t *report_number, size_t report_number_length,
                                     IHS_Buffer *dest, size_t length) {
    (void) length;
    Device *d = (Device *) device;
    const Identity *id = identity_for(d->type);
    if (report_number_length < 1) {
        return -1;
    }
    switch (report_number[0]) {
        case 0x07:  // serial
            IHS_BufferWriteMem(dest, 0, report_number, 1);
            IHS_BufferWriteMem(dest, 1, (const uint8_t *) id->serial, strlen(id->serial) + 1);
            return 0;
        case 0x02: {  // power level: unknown
            const uint8_t level = 0xff;
            IHS_BufferWriteMem(dest, 0, report_number, 1);
            IHS_BufferWriteMem(dest, 1, &level, 1);
            return 0;
        }
        case 0x04: {  // caps, as Steam parses it
            struct __attribute__((packed)) {
                bool valid;
                bool xinput;
                int32_t controller_type;
                uint8_t player_index;
                uint8_t reserved1[3];
                // Not hidapi: with true Steam asks for its native DualSense
                // reports instead of the gamepad report
                bool hid;
                int32_t reserved2;
                uint32_t caps;  // non-zero replaces the device info caps
                uint8_t reserved3;
            } caps;
            _Static_assert(sizeof(caps) == 20, "caps report is 20 bytes");
            memset(&caps, 0, sizeof(caps));
            caps.valid = true;
            caps.controller_type = id->controller_type;
            caps.caps = id->caps;
            IHS_BufferWriteMem(dest, 0, report_number, 1);
            IHS_BufferWriteMem(dest, 1, (const uint8_t *) &caps, sizeof(caps));
            return 0;
        }
        default:
            return -1;
    }
}

static int device_string(IHS_Buffer *out, const char *text) {
    IHS_BufferWriteMem(out, 0, (const uint8_t *) text, strlen(text) + 1);
    return 0;
}

static int device_vendor_string(IHS_HIDDevice *device, IHS_Buffer *out) {
    return device_string(out, identity_for(((Device *) device)->type)->vendor);
}

static int device_product_string(IHS_HIDDevice *device, IHS_Buffer *out) {
    return device_string(out, identity_for(((Device *) device)->type)->product);
}

static int device_serial_string(IHS_HIDDevice *device, IHS_Buffer *out) {
    return device_string(out, identity_for(((Device *) device)->type)->serial);
}

static void device_refresh(Device *d) {
    IHKPad *pad = d->pad;
    pthread_mutex_lock(&pad->lock);
    fill_report((PadReport *) d->cur, pad, d->type, now_us());
    pthread_mutex_unlock(&pad->lock);
}

static int device_start_input_reports(IHS_HIDDevice *device, size_t length) {
    Device *d = (Device *) device;
    d->report_len = length < sizeof(PadReport) ? sizeof(PadReport) : (length > REPORT_MAX ? REPORT_MAX : length);
    IHS_SessionLog(d->pad->session, IHS_LogLevelInfo, "Pad", "Steam wants %zu-byte reports, sending %zu", length,
                   d->report_len);
    d->started = true;
    device_refresh(d);
    IHS_HIDDeviceReportAddFull(device, d->cur, d->report_len);
    memcpy(d->prev, d->cur, REPORT_MAX);
    return 0;
}

static int device_request_full_report(IHS_HIDDevice *device) {
    Device *d = (Device *) device;
    IHS_HIDDeviceReportAddFull(device, d->cur, d->report_len);
    memcpy(d->prev, d->cur, REPORT_MAX);
    return 0;
}

static int device_request_disconnect(IHS_HIDDevice *device, int method, const uint8_t *data, size_t length) {
    (void) device;
    (void) method;
    (void) data;
    (void) length;
    return 0;
}

// Every 8 ms from ihslib's HID tick, device lock held. >0 data, 0 nothing, <0 gone.
static int device_poll(IHS_HIDDevice *device) {
    Device *d = (Device *) device;
    IHKPad *pad = d->pad;
    const uint64_t now = now_us();
    bool stop_rumble = false;

    pthread_mutex_lock(&pad->lock);
    if (d->generation != pad->generation) {
        pthread_mutex_unlock(&pad->lock);
        return -1;  // replaced by a controller of the other kind
    }
    if (pad->rumble_until_us != 0 && now >= pad->rumble_until_us) {
        pad->rumble_until_us = 0;
        stop_rumble = true;
    }
    PadReport *report = (PadReport *) d->cur;
    fill_report(report, pad, d->type, now);
    const uint64_t motion_us = pad->motion_us;
    pthread_mutex_unlock(&pad->lock);

    if (stop_rumble) {
        pad_rumble(pad, 0, 0);
    }
    if (memcmp(d->cur, d->prev, sizeof(PadReport)) == 0) {
        return 0;
    }
    if (d->report_len >= REPORT_STAMPED_LENGTH) {
        const uint32_t stamp = (uint32_t) now;
        memcpy(d->cur + REPORT_STAMP_OFFSET, &stamp, sizeof(stamp));
        if (report->flags & FLAG_SENSORS) {
            const uint32_t imu = (uint32_t) (motion_us * 10u);
            memcpy(d->cur + REPORT_IMU_STAMP_OFFSET, &imu, sizeof(imu));
        }
    }
    // Nothing goes out until Steam starts input reports: early reports made it
    // ignore the controller for good (seen by Steam-Link-PS5)
    if (!d->started) {
        memcpy(d->prev, d->cur, REPORT_MAX);
        return 0;
    }
    IHS_HIDDeviceReportAddDelta(device, d->prev, d->cur, d->report_len);
    memcpy(d->prev, d->cur, REPORT_MAX);
    return 1;
}

static const IHS_HIDDeviceClass device_class = {
    .alloc = device_alloc,
    .free = device_free,
    .opened = device_opened,
    .close = device_close,
    .write = device_write,
    .read = device_read,
    .sendFeatureReport = device_send_feature_report,
    .getFeatureReport = device_get_feature_report,
    .getVendorString = device_vendor_string,
    .getProductString = device_product_string,
    .getSerialNumberString = device_serial_string,
    .startInputReports = device_start_input_reports,
    .requestFullReport = device_request_full_report,
    .requestDisconnect = device_request_disconnect,
    .poll = device_poll,
};

// ----------------------------------------------------------------- provider

#define PATH_PREFIX "ihk://pad/"

static IHS_HIDProvider *provider_alloc(const IHS_HIDProviderClass *cls) {
    Provider *p = calloc(1, sizeof(Provider));
    p->base.cls = cls;
    return &p->base;
}

static void provider_free(IHS_HIDProvider *provider) {
    free(provider);
}

static bool provider_supports_device(IHS_HIDProvider *provider, const char *path) {
    (void) provider;
    return strncmp(path, PATH_PREFIX, strlen(PATH_PREFIX)) == 0;
}

static IHS_HIDDevice *provider_open_device(IHS_HIDProvider *provider, const char *path) {
    IHKPad *pad = ((Provider *) provider)->pad;
    unsigned generation = 0;
    if (sscanf(path + strlen(PATH_PREFIX), "%u", &generation) != 1) {
        return NULL;
    }
    pthread_mutex_lock(&pad->lock);
    const bool current = generation == pad->generation;
    const IHKPadType type = pad->type;
    pthread_mutex_unlock(&pad->lock);
    if (!current) {
        return NULL;
    }
    Device *d = (Device *) IHS_HIDDeviceCreate(&device_class);
    d->pad = pad;
    d->generation = generation;
    d->type = type;
    IHS_SessionLog(pad->session, IHS_LogLevelInfo, "Pad", "Steam opened the %s",
                   identity_for(type)->product);
    return &d->base;
}

static bool provider_has_change(IHS_HIDProvider *provider) {
    (void) provider;
    return false;  // changes are announced with IHS_SessionHIDNotifyDeviceChange
}

static IHS_Enumeration *provider_enumerate(IHS_HIDProvider *provider) {
    IHKPad *pad = ((Provider *) provider)->pad;
    Listing *listing = calloc(1, sizeof(Listing));
    pthread_mutex_lock(&pad->lock);
    snprintf(listing->path, sizeof(listing->path), PATH_PREFIX "%u", pad->generation);
    listing->type = pad->type;
    pthread_mutex_unlock(&pad->lock);
    return IHS_EnumerationArrayCreate(listing, sizeof(Listing), 1, free);
}

static void provider_device_info(IHS_HIDProvider *provider, IHS_Enumeration *enumeration, IHS_HIDDeviceInfo *info) {
    (void) provider;
    const Listing *listing = enumeration->cls->get(enumeration);
    if (listing == NULL) {
        return;
    }
    const Identity *id = identity_for(listing->type);
    info->path = listing->path;
    info->product_string = id->product;
    info->serial_number = id->serial;
    info->vendor_id = id->vendor_id;
    info->product_id = id->product_id;
    info->product_version = id->version;
}

static const IHS_HIDProviderClass provider_class = {
    .alloc = provider_alloc,
    .free = provider_free,
    .supportsDevice = provider_supports_device,
    .openDevice = provider_open_device,
    .hasChange = provider_has_change,
    .enumerateDevices = provider_enumerate,
    .deviceInfo = provider_device_info,
};

// --------------------------------------------------------------------- pad

IHKPad *ihk_pad_create(IHS_Session *session, const IHKSessionCallbacks *callbacks) {
    IHKPad *pad = calloc(1, sizeof(IHKPad));
    if (pad == NULL) {
        return NULL;
    }
    pthread_mutex_init(&pad->lock, NULL);
    pad->session = session;
    pad->cb = callbacks;
    pad->type = IHK_PAD_XBOX;
    pad->generation = 1;
    pad->provider = IHS_SessionHIDProviderCreate(&provider_class);
    ((Provider *) pad->provider)->pad = pad;
    IHS_SessionHIDAddProvider(session, pad->provider);
    return pad;
}

void ihk_pad_connected(IHKPad *pad) {
    pthread_mutex_lock(&pad->lock);
    pad->connected = true;
    pthread_mutex_unlock(&pad->lock);
    IHS_SessionHIDNotifyDeviceChange(pad->session);
}

void ihk_pad_disconnected(IHKPad *pad) {
    pthread_mutex_lock(&pad->lock);
    pad->connected = false;
    pthread_mutex_unlock(&pad->lock);
}

void ihk_pad_destroy(IHKPad *pad) {
    if (pad == NULL) {
        return;
    }
    IHS_SessionHIDProviderDestroy(pad->provider);
    pthread_mutex_destroy(&pad->lock);
    free(pad);
}

void ihk_pad_set_type(IHKPad *pad, IHKPadType type) {
    pthread_mutex_lock(&pad->lock);
    if (pad->type == type) {
        pthread_mutex_unlock(&pad->lock);
        return;
    }
    pad->type = type;
    pad->generation++;
    pad->rumble_until_us = 0;
    const bool connected = pad->connected;
    pthread_mutex_unlock(&pad->lock);
    IHS_SessionLog(pad->session, IHS_LogLevelInfo, "Pad", "Controller is now a %s", identity_for(type)->product);
    if (connected) {
        IHS_SessionHIDNotifyDeviceChange(pad->session);
    }
}

void ihk_pad_send(IHKPad *pad, const IHKPadState *state) {
    pthread_mutex_lock(&pad->lock);
    pad->state = *state;
    if (pad->state.touches > 2) {
        pad->state.touches = 2;
    }
    pthread_mutex_unlock(&pad->lock);
}

void ihk_pad_send_motion(IHKPad *pad, const float gyro[3], const float accel[3]) {
    pthread_mutex_lock(&pad->lock);
    memcpy(pad->gyro, gyro, sizeof(pad->gyro));
    memcpy(pad->accel, accel, sizeof(pad->accel));
    pad->motion_us = now_us();
    pthread_mutex_unlock(&pad->lock);
}
