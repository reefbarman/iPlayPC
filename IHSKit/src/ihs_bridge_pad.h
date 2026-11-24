// SPDX-License-Identifier: AGPL-3.0-only
//
// The session's virtual controller (bridge-internal). See ihs_bridge_pad.c.

#ifndef IHS_BRIDGE_PAD_H
#define IHS_BRIDGE_PAD_H

#include "ihs_bridge.h"

#include <ihslib.h>

typedef struct IHKPad IHKPad;

/// Registers the controller with the session. callbacks must outlive the pad.
IHKPad *ihk_pad_create(IHS_Session *session, const IHKSessionCallbacks *callbacks);

/// The stream is up: tell Steam the controller exists.
void ihk_pad_connected(IHKPad *pad);

/// The stream ended: stop announcing changes.
void ihk_pad_disconnected(IHKPad *pad);

/// Frees the pad. Only after IHS_SessionDestroy, which lets go of the provider.
void ihk_pad_destroy(IHKPad *pad);

void ihk_pad_set_type(IHKPad *pad, IHKPadType type);
void ihk_pad_send(IHKPad *pad, const IHKPadState *state);
void ihk_pad_send_motion(IHKPad *pad, const float gyro[3], const float accel[3]);

#endif
