// SPDX-License-Identifier: GPL-3.0-or-later
// Real H.264/HEVC access units verify immediate output, codec changes and reset.
// Reported timings cover local decoding only.
#include "RealtimeH264.h"
#include <VideoToolbox/VideoToolbox.h>
#include <unistd.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define FRAME_COUNT 64
static bool test_hevc = false;
static int test_width = 1920, test_height = 1080;
typedef struct { CFDataRef packets[FRAME_COUNT]; } Encoded;
typedef struct {
    atomic_int pushed, output;
    int first_after_inputs;
    uint64_t sent[FRAME_COUNT];
    double latency[FRAME_COUNT];
    char decoder[128];
} Measurement;

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static void check(bool ok, const char *message) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static void compressed(void *context, void *frame_context, OSStatus status,
                       VTEncodeInfoFlags flags, CMSampleBufferRef sample) {
    (void)flags;
    check(status == noErr && sample, "encode video sample");
    int index = (int)(uintptr_t)frame_context - 1;
    Encoded *encoded = context;
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    size_t size = CMBlockBufferGetDataLength(block);
    uint8_t *avcc = malloc(size), *annex = malloc(size + 8192);
    check(avcc && annex, "allocate encoded test packet");
    check(CMBlockBufferCopyDataBytes(block, 0, size, avcc) == noErr, "copy encoded test sample");
    size_t cursor = 0;
    const uint8_t start[] = {0, 0, 0, 1};
    for (size_t i = 0; i < (test_hevc ? 3u : 2u); i++) {
        const uint8_t *set = NULL;
        size_t length = 0;
        check((test_hevc ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, i, &set, &length, NULL, NULL)
            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, i, &set, &length, NULL, NULL)) == noErr,
            "read encoder parameter sets");
        check(cursor + 4 + length < 8192, "parameter set size bounded");
        memcpy(annex + cursor, start, 4); cursor += 4;
        memcpy(annex + cursor, set, length); cursor += length;
    }
    for (size_t offset = 0; offset + 4 <= size;) {
        uint32_t length;
        memcpy(&length, avcc + offset, 4); length = CFSwapInt32BigToHost(length);
        offset += 4;
        check(length > 0 && offset + length <= size, "valid encoder NAL length");
        memcpy(annex + cursor, start, 4); cursor += 4;
        memcpy(annex + cursor, avcc + offset, length); cursor += length;
        offset += length;
    }
    encoded->packets[index] = CFDataCreate(NULL, annex, (CFIndex)cursor);
    free(avcc); free(annex);
}

static void make_packets(Encoded *encoded) {
    VTCompressionSessionRef session = NULL;
    check(VTCompressionSessionCreate(NULL, test_width, test_height, test_hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
        NULL, NULL, NULL, compressed, encoded, &session) == noErr, "create video encoder");
    VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel, test_hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel);
    int fps = 60;
    CFNumberRef rate = CFNumberCreate(NULL, kCFNumberIntType, &fps);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, rate);
    CFRelease(rate);
    check(VTCompressionSessionPrepareToEncodeFrames(session) == noErr, "prepare encoder");
    CVPixelBufferRef pixels = NULL;
    check(CVPixelBufferCreate(NULL, test_width, test_height, kCVPixelFormatType_32BGRA, NULL, &pixels) == noErr,
        "allocate source pixels");
    CVPixelBufferLockBaseAddress(pixels, 0);
    memset(CVPixelBufferGetBaseAddress(pixels), 127, CVPixelBufferGetBytesPerRow(pixels) * test_height);
    CVPixelBufferUnlockBaseAddress(pixels, 0);
    for (int i = 0; i < FRAME_COUNT; i++) {
        check(VTCompressionSessionEncodeFrame(session, pixels, CMTimeMake(i, 60), CMTimeMake(1, 60),
            NULL, (void *)(uintptr_t)(i + 1), NULL) == noErr, "encode video frame");
    }
    check(VTCompressionSessionCompleteFrames(session, kCMTimeInvalid) == noErr, "finish encoding");
    CVPixelBufferRelease(pixels);
    VTCompressionSessionInvalidate(session); CFRelease(session);
    for (int i = 0; i < FRAME_COUNT; i++) check(encoded->packets[i] != NULL, "all test packets encoded");
}

static void received(Measurement *measurement, int index) {
    int output = atomic_fetch_add(&measurement->output, 1);
    if (output == 0) measurement->first_after_inputs = atomic_load(&measurement->pushed);
    if (index >= 0 && index < FRAME_COUNT && measurement->sent[index])
        measurement->latency[index] = (double)(now_ns() - measurement->sent[index]) / 1000000.0;
}

static void native_output(void *context, CVPixelBufferRef pixels, uint64_t input, uint64_t decoded) {
    (void)input; (void)decoded;
    Measurement *measurement = context;
    check(CVPixelBufferGetWidth(pixels) == (size_t)test_width && CVPixelBufferGetHeight(pixels) == (size_t)test_height,
        "direct decoder preserves dimensions");
    received(measurement, atomic_load(&measurement->pushed) - 1);
}
static int compare_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y ? 1 : 0;
}
static void report(const char *path, Measurement *measurement) {
    double values[FRAME_COUNT]; int count = 0;
    for (int i = 8; i < FRAME_COUNT - 8; i++) if (measurement->latency[i] > 0) values[count++] = measurement->latency[i];
    check(count > 0, "decoder produced steady-state measurements");
    qsort(values, (size_t)count, sizeof(double), compare_double);
    printf("%s decoder=%s first_output_after_inputs=%d output_frames=%d p50_ms=%.2f p95_ms=%.2f\n",
        path, measurement->decoder, measurement->first_after_inputs,
        atomic_load(&measurement->output), values[count / 2], values[(int)((double)(count - 1) * .95)]);
}
int APDecoderTestsMain(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "--hevc-2160")) { test_hevc = true; test_width = 3840; test_height = 2160; }
    printf("TEST codec=%s size=%dx%d\n", test_hevc ? "HEVC" : "H264", test_width, test_height);
    Encoded encoded = {0};
    make_packets(&encoded);
    Measurement direct = {0};
    APH264Decoder *decoder = APH264Create(native_output, &direct);
    check(decoder != NULL, "create direct VT decoder");
    APH264SetHEVC(decoder, test_hevc);
    const uint8_t invalid[] = {1, 2, 3, 4};
    check(APH264Decode(decoder, invalid, sizeof(invalid)) != noErr, "malformed input rejected");
    for (int i = 0; i < FRAME_COUNT; i++) {
        direct.sent[i] = now_ns(); atomic_store(&direct.pushed, i + 1);
        check(APH264Decode(decoder, CFDataGetBytePtr(encoded.packets[i]),
            (size_t)CFDataGetLength(encoded.packets[i])) == noErr, "direct decode succeeds");
        check(atomic_load(&direct.output) == i + 1, "every frame delivered before decode returns");
        usleep(16667);
    }
    snprintf(direct.decoder, sizeof(direct.decoder), "VideoToolbox-hardware=%s", APH264IsHardware(decoder) ? "true" : "false");
    report("decoder", &direct);
    APH264Reset(decoder);
    int old = atomic_load(&direct.output);
    check(APH264Decode(decoder, CFDataGetBytePtr(encoded.packets[0]),
        (size_t)CFDataGetLength(encoded.packets[0])) == noErr && atomic_load(&direct.output) == old + 1,
        "decoder reset accepts a new keyframe");
    APH264SetHEVC(decoder, !test_hevc);
    APH264SetHEVC(decoder, test_hevc);
    old = atomic_load(&direct.output);
    check(APH264Decode(decoder, CFDataGetBytePtr(encoded.packets[0]),
        (size_t)CFDataGetLength(encoded.packets[0])) == noErr && atomic_load(&direct.output) == old + 1,
        "codec switch clears old parameter sets and decodes new keyframe");
    APH264Destroy(decoder);
    for (int i = 0; i < FRAME_COUNT; i++) CFRelease(encoded.packets[i]);
    puts("PASS: direct decoder first frame, no look-ahead, dimensions, malformed input, reset.");
    return 0;
}
