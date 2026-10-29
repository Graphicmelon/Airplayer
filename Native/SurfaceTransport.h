// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef AIRPLAYER_SURFACE_TRANSPORT_H
#define AIRPLAYER_SURFACE_TRANSPORT_H
#include <mach/mach.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct {
    uint32_t kind;
    mach_port_t surface_port;
    uint64_t session;
    uint64_t sequence;
    uint64_t dropped;
    uint64_t input_ns, decoded_ns;
    uint32_t width, height, color_info;
    mach_port_t reply_port;
} APFrameEvent;

mach_port_t APCreateFrameService(const char *name);
mach_port_t APLookupFrameService(const char *name);
void APDestroyFrameService(mach_port_t port);
int APReceiveFrame(mach_port_t port, APFrameEvent *event, uint32_t timeout_ms);
int APSendFrame(mach_port_t service, mach_port_t surface, uint32_t kind,
               uint64_t session, uint64_t sequence, uint64_t dropped);
void APReleasePort(mach_port_t port);
uint64_t APMonotonicTimeNS(void);
int APSendFrameTimed(mach_port_t service, mach_port_t surface, uint64_t session,
    uint64_t sequence, uint64_t dropped, uint64_t input_ns, uint64_t decoded_ns,
    uint32_t width, uint32_t height, uint32_t color_info);
mach_port_t APCreateFrameReplies(void);
bool APReceiveFrameReply(mach_port_t port, uint64_t *sequence);
void APReturnFrame(mach_port_t reply_port, uint64_t sequence);
int APSendFrameLeased(mach_port_t service, mach_port_t surface, mach_port_t reply_port,
    uint64_t session, uint64_t sequence, uint64_t dropped, uint64_t input_ns, uint64_t decoded_ns,
    uint32_t width, uint32_t height, uint32_t color_info);
#endif
