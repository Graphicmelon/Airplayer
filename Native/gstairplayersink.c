/* SPDX-License-Identifier: GPL-3.0-or-later
 * Private IOSurface transport from UxPlay to the native Metal window.
 * No network listener is exposed by this plugin.
 */
#include <gst/video/gstvideosink.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <IOSurface/IOSurface.h>
#include "SurfaceTransport.h"
#include "RealtimeH264.h"
#include <CoreVideo/CoreVideo.h>

#define PACKAGE "airplayer"

typedef struct {
    GstVideoSink parent;
    int fd;
    mach_port_t service;
    uint64_t session, sequence, dropped;
    gboolean sent_frame;
    gboolean hevc;
    gboolean logged_decoder;
    APH264Decoder *decoder;
    CVPixelBufferRef held[8];
    uint64_t held_sequence[8];
    mach_port_t replies;
} AirplayerSink;
typedef struct { GstVideoSinkClass parent; } AirplayerSinkClass;

G_DEFINE_TYPE(AirplayerSink, airplayer_sink, GST_TYPE_VIDEO_SINK)

static void decoded_frame(void *context, CVPixelBufferRef pixels, uint64_t input_ns, uint64_t decoded_ns) {
    AirplayerSink *self = context;
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixels);
    if (!surface) { self->dropped++; return; }
    int available = -1;
    uint64_t returned;
    while (APReceiveFrameReply(self->replies, &returned)) {
        for (int i = 0; i < 8; i++) {
            if (self->held[i] && self->held_sequence[i] == returned) {
                CVPixelBufferRelease(self->held[i]); self->held[i] = NULL;
            }
        }
    }
    for (int i = 0; i < 8; i++) {
        if (!self->held[i]) available = i;
    }
    if (available < 0) { self->dropped++; return; }
    if (!self->logged_decoder) {
        g_printerr("DECODER name=VideoToolbox hardware=%s codec=%s temporal_processing=false pixel_format=NV12\n",
            APH264IsHardware(self->decoder) ? "true" : "false", self->hevc ? "HEVC" : "H264");
        self->logged_decoder = TRUE;
    }
    uint32_t color = 1; // Matrix: 1=709, 2=601, 3=2020. Transfer: bit 8=709.
    CFTypeRef matrix = CVBufferCopyAttachment(pixels, kCVImageBufferYCbCrMatrixKey, NULL);
    if (matrix) {
        if (CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4)) color = 2;
        else if (CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020)) color = 3;
        CFRelease(matrix);
    }
    CFTypeRef transfer = CVBufferCopyAttachment(pixels, kCVImageBufferTransferFunctionKey, NULL);
    if (transfer) {
        if (CFEqual(transfer, kCVImageBufferTransferFunction_ITU_R_709_2)) color |= 256;
        CFRelease(transfer);
    }
    mach_port_t port = IOSurfaceCreateMachPort(surface);
    if (!port) { self->dropped++; return; }
    int result = APSendFrameLeased(self->service, port, self->replies, self->session, self->sequence, self->dropped,
        input_ns, decoded_ns, (uint32_t)CVPixelBufferGetWidth(pixels), (uint32_t)CVPixelBufferGetHeight(pixels), color);
    APReleasePort(port);
    if (result != 0) self->dropped++;
    else {
        // Hold the pixel-buffer lease until the consumer's Mach/GPU references
        // are gone, so VideoToolbox cannot recycle it while it is displayed.
        self->held[available] = CVPixelBufferRetain(pixels);
        self->held_sequence[available] = self->sequence;
        self->sent_frame = TRUE;
    }
}

static gboolean send_all(int fd, const void *buffer, size_t count) {
    const uint8_t *cursor = buffer;
    while (count) {
        ssize_t written = send(fd, cursor, count, 0);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return FALSE;
        cursor += written;
        count -= (size_t)written;
    }
    return TRUE;
}

static gboolean sink_start(GstBaseSink *base) {
    AirplayerSink *self = (AirplayerSink *)base;
    const char *path = g_getenv("AIRPLAYER_FRAME_SOCKET");
    const char *service_name = g_getenv("AIRPLAYER_FRAME_SERVICE");
    struct sockaddr_un address = {0};
    if (!path || strlen(path) >= sizeof(address.sun_path)) {
        GST_ELEMENT_ERROR(self, RESOURCE, OPEN_WRITE,
                          ("Airplayer frame socket is missing or too long"), (NULL));
        return FALSE;
    }
    self->service = service_name ? APLookupFrameService(service_name) : MACH_PORT_NULL;
    if (!self->service) return FALSE;
    self->fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (self->fd < 0) { APReleasePort(self->service); self->service = 0; return FALSE; }
    int enabled = 1;
    setsockopt(self->fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
    struct timeval timeout = { .tv_sec = 2, .tv_usec = 0 };
    setsockopt(self->fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    address.sun_family = AF_UNIX;
    g_strlcpy(address.sun_path, path, sizeof(address.sun_path));
    if (connect(self->fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        GST_ELEMENT_ERROR(self, RESOURCE, OPEN_WRITE,
                          ("Cannot connect to the Airplayer window"), ("%s", g_strerror(errno)));
        close(self->fd);
        self->fd = -1;
        APReleasePort(self->service);
        self->service = 0;
        return FALSE;
    }
    self->session = ((uint64_t)g_random_int() << 32) | g_random_int();
    if (!self->session) self->session = 1;
    self->sequence = self->dropped = 0;
    uint32_t magic[] = {GUINT32_TO_LE(0x32435041), GUINT32_TO_LE(1)};
    uint64_t session = GUINT64_TO_LE(self->session);
    if (!send_all(self->fd, magic, sizeof(magic)) || !send_all(self->fd, &session, sizeof(session))) {
        close(self->fd); self->fd = -1;
        APReleasePort(self->service); self->service = 0;
        return FALSE;
    }
    self->sent_frame = FALSE;
    self->logged_decoder = FALSE;
    self->decoder = APH264Create(decoded_frame, self);
    self->replies = APCreateFrameReplies();
    if (!self->decoder || !self->replies) {
        APH264Destroy(self->decoder); self->decoder = NULL;
        if (self->replies) mach_port_mod_refs(mach_task_self(), self->replies, MACH_PORT_RIGHT_RECEIVE, -1);
        self->replies = 0;
        close(self->fd); self->fd = -1;
        APReleasePort(self->service); self->service = 0;
        return FALSE;
    }
    return TRUE;
}

static gboolean sink_stop(GstBaseSink *base) {
    AirplayerSink *self = (AirplayerSink *)base;
    APH264Destroy(self->decoder);
    self->decoder = NULL;
    if (self->replies) mach_port_mod_refs(mach_task_self(), self->replies, MACH_PORT_RIGHT_RECEIVE, -1);
    self->replies = 0;
    for (int i = 0; i < 8; i++) {
        if (self->held[i]) { CVPixelBufferRelease(self->held[i]); self->held[i] = NULL; }
    }
    if (self->fd >= 0) {
        if (self->sent_frame) APSendFrame(self->service, 0, 2, self->session, self->sequence, self->dropped);
        shutdown(self->fd, SHUT_RDWR);
        close(self->fd);
        self->fd = -1;
    }
    APReleasePort(self->service);
    self->service = 0;
    self->sent_frame = FALSE;
    return TRUE;
}

static gboolean sink_set_caps(GstBaseSink *base, GstCaps *caps) {
    AirplayerSink *self = (AirplayerSink *)base;
    self->hevc = gst_structure_has_name(gst_caps_get_structure(caps, 0), "video/x-h265");
    if (!self->hevc && !gst_structure_has_name(gst_caps_get_structure(caps, 0), "video/x-h264")) return FALSE;
    APH264SetHEVC(self->decoder, self->hevc);
    self->logged_decoder = FALSE;
    return TRUE;
}

static GstFlowReturn sink_show_frame(GstVideoSink *video, GstBuffer *buffer) {
    AirplayerSink *self = (AirplayerSink *)video;
    self->sequence++;
    GstMapInfo map;
    if (!gst_buffer_map(buffer, &map, GST_MAP_READ)) return GST_FLOW_ERROR;
    OSStatus status = APH264Decode(self->decoder, map.data, map.size);
    gst_buffer_unmap(buffer, &map);
    if (status != noErr) {
        self->dropped++;
        if (self->dropped <= 3) g_printerr("DECODE_ERROR status=%d; waiting for keyframe\n", (int)status);
    }
    return GST_FLOW_OK;
}

static gboolean sink_event(GstBaseSink *base, GstEvent *event) {
    AirplayerSink *self = (AirplayerSink *)base;
    if (GST_EVENT_TYPE(event) == GST_EVENT_FLUSH_STOP && self->decoder) APH264Reset(self->decoder);
    if (GST_EVENT_TYPE(event) == GST_EVENT_EOS && self->sent_frame) {
        APSendFrame(self->service, 0, 2, self->session, self->sequence, self->dropped);
        self->sent_frame = FALSE;
    }
    return GST_BASE_SINK_CLASS(airplayer_sink_parent_class)->event(base, event);
}

static void airplayer_sink_class_init(AirplayerSinkClass *klass) {
    GstElementClass *element = GST_ELEMENT_CLASS(klass);
    GstBaseSinkClass *base = GST_BASE_SINK_CLASS(klass);
    GstVideoSinkClass *video = GST_VIDEO_SINK_CLASS(klass);
    gst_element_class_set_static_metadata(element, "Airplayer window sink",
        "Sink/Video", "Shared IOSurface frames for the native Metal window", "Airplayer contributors");
    GstCaps *caps = gst_caps_from_string(
        "video/x-h264,stream-format=byte-stream,alignment=au; "
        "video/x-h265,stream-format=byte-stream,alignment=au");
    gst_element_class_add_pad_template(element,
        gst_pad_template_new("sink", GST_PAD_SINK, GST_PAD_ALWAYS, caps));
    gst_caps_unref(caps);
    base->start = sink_start;
    base->stop = sink_stop;
    base->set_caps = sink_set_caps;
    base->event = sink_event;
    video->show_frame = sink_show_frame;
}

static void airplayer_sink_init(AirplayerSink *self) {
    self->fd = -1;
    self->sent_frame = FALSE;
    /* Render only once, when playing; preroll must not duplicate a frame. */
    g_object_set(self, "enable-last-sample", FALSE, "show-preroll-frame", FALSE, NULL);
}

static gboolean plugin_init(GstPlugin *plugin) {
    return gst_element_register(plugin, "airplayerh264sink", GST_RANK_NONE, airplayer_sink_get_type()) &&
        gst_element_register(plugin, "airplayerh265sink", GST_RANK_NONE, airplayer_sink_get_type());
}

GST_PLUGIN_DEFINE(GST_VERSION_MAJOR, GST_VERSION_MINOR, airplayer,
    "Native Airplayer frame transport", plugin_init, "0.1.0", "GPL",
    "Airplayer", "https://github.com/FDH2/UxPlay")
