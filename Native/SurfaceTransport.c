// SPDX-License-Identifier: GPL-3.0-or-later
#include "SurfaceTransport.h"
#include <servers/bootstrap.h>
#include <string.h>
#include <time.h>

#define AP_MESSAGE_ID 0x41505633
typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t surface;
    uint32_t kind;
    uint64_t session, sequence, dropped;
    uint64_t input_ns, decoded_ns;
    uint32_t width, height, color_info;
} APWireMessage;

mach_port_t APCreateFrameService(const char *name) {
    mach_port_t port = MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS)
        return MACH_PORT_NULL;
    if (mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) {
        mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
        return MACH_PORT_NULL;
    }
    // An anonymous, randomly named, unsandboxed development-app service. Using
    // the bootstrap rendezvous avoids insecure globally discoverable surfaces.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    kern_return_t registered = bootstrap_register(bootstrap_port, (char *)name, port);
#pragma clang diagnostic pop
    if (registered != KERN_SUCCESS) {
        APDestroyFrameService(port);
        return MACH_PORT_NULL;
    }
    // A bounded kernel queue is part of the frame backpressure policy.
    mach_port_limits_t limits = {.mpl_qlimit = 4};
    mach_port_set_attributes(mach_task_self(), port, MACH_PORT_LIMITS_INFO,
        (mach_port_info_t)&limits, MACH_PORT_LIMITS_INFO_COUNT);
    return port;
}

mach_port_t APLookupFrameService(const char *name) {
    mach_port_t port = MACH_PORT_NULL;
    if (bootstrap_look_up(bootstrap_port, (char *)name, &port) != KERN_SUCCESS)
        return MACH_PORT_NULL;
    return port;
}

void APDestroyFrameService(mach_port_t port) {
    if (port) {
        mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
        mach_port_deallocate(mach_task_self(), port);
    }
}
void APReleasePort(mach_port_t port) {
    if (port) mach_port_deallocate(mach_task_self(), port);
}

uint64_t APMonotonicTimeNS(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static int send_event(mach_port_t service, mach_port_t surface, uint32_t kind,
    uint64_t session, uint64_t sequence, uint64_t dropped, uint64_t input_ns,
    uint64_t decoded_ns, uint32_t width, uint32_t height, uint32_t color_info, mach_port_t reply_port) {
    APWireMessage message = {0};
    message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,
        reply_port ? MACH_MSG_TYPE_MAKE_SEND : 0) | MACH_MSGH_BITS_COMPLEX;
    message.header.msgh_local_port = reply_port;
    message.header.msgh_size = sizeof(message);
    message.header.msgh_remote_port = service;
    message.header.msgh_id = AP_MESSAGE_ID;
    message.body.msgh_descriptor_count = surface ? 1 : 0;
    message.surface.name = surface;
    message.surface.disposition = MACH_MSG_TYPE_COPY_SEND;
    message.surface.type = MACH_MSG_PORT_DESCRIPTOR;
    message.kind = kind;
    message.session = session;
    message.sequence = sequence;
    message.dropped = dropped;
    message.input_ns = input_ns;
    message.decoded_ns = decoded_ns;
    message.width = width;
    message.height = height;
    message.color_info = color_info;
    mach_msg_return_t result = mach_msg(&message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
        sizeof(message), 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
    return result == MACH_MSG_SUCCESS ? 0 : (result == MACH_SEND_TIMED_OUT ? 1 : -1);
}

int APSendFrame(mach_port_t service, mach_port_t surface, uint32_t kind,
               uint64_t session, uint64_t sequence, uint64_t dropped) {
    return send_event(service, surface, kind, session, sequence, dropped, 0, 0, 0, 0, 0, 0);
}

int APSendFrameTimed(mach_port_t service, mach_port_t surface, uint64_t session,
    uint64_t sequence, uint64_t dropped, uint64_t input_ns, uint64_t decoded_ns,
    uint32_t width, uint32_t height, uint32_t color_info) {
    return send_event(service, surface, 1, session, sequence, dropped,
        input_ns, decoded_ns, width, height, color_info, 0);
}

int APSendFrameLeased(mach_port_t service, mach_port_t surface, mach_port_t reply_port,
    uint64_t session, uint64_t sequence, uint64_t dropped, uint64_t input_ns, uint64_t decoded_ns,
    uint32_t width, uint32_t height, uint32_t color_info) {
    return send_event(service, surface, 1, session, sequence, dropped,
        input_ns, decoded_ns, width, height, color_info, reply_port);
}

mach_port_t APCreateFrameReplies(void) {
    mach_port_t port = MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS) return 0;
    mach_port_limits_t limits = {.mpl_qlimit = 16};
    mach_port_set_attributes(mach_task_self(), port, MACH_PORT_LIMITS_INFO,
        (mach_port_info_t)&limits, MACH_PORT_LIMITS_INFO_COUNT);
    return port;
}

typedef struct { mach_msg_header_t header; uint64_t sequence; } APReply;

void APReturnFrame(mach_port_t reply_port, uint64_t sequence) {
    if (!reply_port) return;
    APReply reply = {0};
    reply.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    reply.header.msgh_remote_port = reply_port;
    reply.header.msgh_size = sizeof(reply);
    reply.header.msgh_id = AP_MESSAGE_ID + 1;
    reply.sequence = sequence;
    mach_msg(&reply.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(reply), 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
    APReleasePort(reply_port);
}

bool APReceiveFrameReply(mach_port_t port, uint64_t *sequence) {
    struct { APReply reply; uint8_t trailer[MAX_TRAILER_SIZE]; } buffer = {0};
    if (mach_msg(&buffer.reply.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0,
        sizeof(buffer), port, 0, MACH_PORT_NULL) != MACH_MSG_SUCCESS) return false;
    if (buffer.reply.header.msgh_id != AP_MESSAGE_ID + 1 ||
        buffer.reply.header.msgh_size != sizeof(APReply) ||
        (buffer.reply.header.msgh_bits & MACH_MSGH_BITS_COMPLEX)) {
        mach_msg_destroy(&buffer.reply.header);
        return false;
    }
    *sequence = buffer.reply.sequence;
    return true;
}

int APReceiveFrame(mach_port_t port, APFrameEvent *event, uint32_t timeout_ms) {
    struct { APWireMessage message; uint8_t trailer[MAX_TRAILER_SIZE]; } buffer = {0};
    mach_msg_return_t result = mach_msg(&buffer.message.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
        0, sizeof(buffer), port, timeout_ms, MACH_PORT_NULL);
    if (result == MACH_RCV_TIMED_OUT) return 1;
    if (result != MACH_MSG_SUCCESS) return -1;
    APWireMessage *message = &buffer.message;
    int frame = message->kind == 1 && message->body.msgh_descriptor_count == 1 &&
        message->surface.type == MACH_MSG_PORT_DESCRIPTOR && message->surface.name != MACH_PORT_NULL;
    int clear = message->kind == 2 && message->body.msgh_descriptor_count == 0;
    if (message->header.msgh_id != AP_MESSAGE_ID || message->header.msgh_size != sizeof(*message) ||
        !(message->header.msgh_bits & MACH_MSGH_BITS_COMPLEX) || (!frame && !clear)) {
        mach_msg_destroy(&message->header);
        return 1;
    }
    event->kind = message->kind;
    event->surface_port = frame ? message->surface.name : MACH_PORT_NULL;
    event->session = message->session;
    event->sequence = message->sequence;
    event->dropped = message->dropped;
    event->input_ns = message->input_ns;
    event->decoded_ns = message->decoded_ns;
    event->width = message->width;
    event->height = message->height;
    event->color_info = message->color_info;
    event->reply_port = message->header.msgh_remote_port;
    // Ownership of the received IOSurface send right passes to the caller.
    return 0;
}
