// SPDX-License-Identifier: GPL-3.0-or-later
// Direct access-unit decoding. Intentionally no display-order queue and no
// kVTDecodeFrame_EnableTemporalProcessing. AirPlay supplies complete Annex-B AUs.
#include "RealtimeH264.h"
#include <CoreMedia/CoreMedia.h>
#include <VideoToolbox/VideoToolbox.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct APH264Decoder {
    VTDecompressionSessionRef session;
    CMVideoFormatDescriptionRef format;
    CFDataRef vps, sps, pps;
    bool hevc;
    bool waiting_idr;
    APH264Output output;
    void *context;
    uint64_t input_ns;
};

static void decoded(void *context, void *frame_context, OSStatus status,
                    VTDecodeInfoFlags flags, CVImageBufferRef pixels, CMTime pts, CMTime duration) {
    (void)frame_context; (void)flags; (void)pts; (void)duration;
    APH264Decoder *decoder = context;
    if (status != noErr) decoder->waiting_idr = true;
    if (status == noErr && pixels && decoder->output)
        decoder->output(decoder->context, pixels, decoder->input_ns,
            clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
}

static void invalidate_session(APH264Decoder *decoder) {
    if (decoder->session) {
        VTDecompressionSessionInvalidate(decoder->session);
        CFRelease(decoder->session);
        decoder->session = NULL;
    }
    if (decoder->format) { CFRelease(decoder->format); decoder->format = NULL; }
    decoder->waiting_idr = true;
}

APH264Decoder *APH264Create(APH264Output output, void *context) {
    APH264Decoder *decoder = calloc(1, sizeof(*decoder));
    if (decoder) { decoder->output = output; decoder->context = context; decoder->waiting_idr = true; }
    return decoder;
}

void APH264Reset(APH264Decoder *decoder) {
    if (!decoder) return;
    invalidate_session(decoder);
    if (decoder->vps) { CFRelease(decoder->vps); decoder->vps = NULL; }
    if (decoder->sps) { CFRelease(decoder->sps); decoder->sps = NULL; }
    if (decoder->pps) { CFRelease(decoder->pps); decoder->pps = NULL; }
}

void APH264SetHEVC(APH264Decoder *decoder, bool hevc) {
    if (!decoder || decoder->hevc == hevc) return;
    APH264Reset(decoder);
    decoder->hevc = hevc;
}

void APH264Destroy(APH264Decoder *decoder) {
    if (decoder) { APH264Reset(decoder); free(decoder); }
}

bool APH264IsHardware(APH264Decoder *decoder) {
    CFTypeRef value = NULL;
    if (!decoder || !decoder->session) return false;
    OSStatus status = VTSessionCopyProperty(decoder->session,
        kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, NULL, &value);
    bool result = status == noErr && value && CFEqual(value, kCFBooleanTrue);
    if (value) CFRelease(value);
    return result;
}

static OSStatus make_session(APH264Decoder *decoder) {
    invalidate_session(decoder);
    if (!decoder->sps || !decoder->pps || (decoder->hevc && !decoder->vps)) return noErr;
    const uint8_t *sets[] = {decoder->vps ? CFDataGetBytePtr(decoder->vps) : NULL,
        CFDataGetBytePtr(decoder->sps), CFDataGetBytePtr(decoder->pps)};
    const size_t sizes[] = {decoder->vps ? (size_t)CFDataGetLength(decoder->vps) : 0,
        (size_t)CFDataGetLength(decoder->sps), (size_t)CFDataGetLength(decoder->pps)};
    OSStatus status = decoder->hevc
        ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(NULL, 3, sets, sizes, 4, NULL, &decoder->format)
        : CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, 2, sets + 1, sizes + 1, 4, &decoder->format);
    if (status != noErr) return status;
    int32_t format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CFNumberRef pixel_format = CFNumberCreate(NULL, kCFNumberSInt32Type, &format);
    CFDictionaryRef empty = CFDictionaryCreate(NULL, NULL, NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *keys[] = {kCVPixelBufferPixelFormatTypeKey, kCVPixelBufferIOSurfacePropertiesKey,
        kCVPixelBufferMetalCompatibilityKey};
    const void *values[] = {pixel_format, empty, kCFBooleanTrue};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 3,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *hardware_key = kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder;
    const void *hardware_value = kCFBooleanTrue;
    CFDictionaryRef spec = CFDictionaryCreate(NULL, &hardware_key, &hardware_value, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    VTDecompressionOutputCallbackRecord callback = {decoded, decoder};
    status = VTDecompressionSessionCreate(NULL, decoder->format, spec, attributes, &callback, &decoder->session);
    CFRelease(spec); CFRelease(attributes); CFRelease(empty); CFRelease(pixel_format);
    if (status == noErr)
        VTSessionSetProperty(decoder->session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    return status;
}

static bool update_set(CFDataRef *slot, const uint8_t *data, size_t length) {
    if (*slot && (size_t)CFDataGetLength(*slot) == length && !memcmp(CFDataGetBytePtr(*slot), data, length))
        return false;
    CFDataRef replacement = CFDataCreate(NULL, data, (CFIndex)length);
    if (!replacement) return false;
    if (*slot) CFRelease(*slot);
    *slot = replacement;
    return true;
}

// Find three- and four-byte start codes without reading outside the buffer.
static size_t start_code(const uint8_t *bytes, size_t length, size_t from, size_t *prefix) {
    for (size_t i = from; i + 2 < length; i++) {
        if (bytes[i] || bytes[i + 1]) continue;
        if (bytes[i + 2] == 1) { *prefix = 3; return i; }
        if (i + 3 < length && !bytes[i + 2] && bytes[i + 3] == 1) { *prefix = 4; return i; }
    }
    return length;
}

OSStatus APH264Decode(APH264Decoder *decoder, const uint8_t *bytes, size_t length) {
    if (!decoder || !bytes || length < 4 || length > 64 * 1024 * 1024) return paramErr;
    decoder->input_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    struct { const uint8_t *bytes; size_t length; } slices[512];
    size_t count = 0, total = 0, prefix = 0;
    bool changed = false, idr = false;
    size_t offset = start_code(bytes, length, 0, &prefix);
    if (offset == length) return paramErr;
    while (offset < length) {
        size_t begin = offset + prefix, next_prefix = 0;
        size_t next = start_code(bytes, length, begin, &next_prefix);
        if (begin < next) {
            if (decoder->hevc && next - begin < 2) return paramErr;
            uint8_t type = decoder->hevc ? (bytes[begin] >> 1) & 0x3f : bytes[begin] & 0x1f;
            if (decoder->hevc && type == 32) changed |= update_set(&decoder->vps, bytes + begin, next - begin);
            else if (type == (decoder->hevc ? 33 : 7)) changed |= update_set(&decoder->sps, bytes + begin, next - begin);
            else if (type == (decoder->hevc ? 34 : 8)) changed |= update_set(&decoder->pps, bytes + begin, next - begin);
            else if (decoder->hevc ? type <= 31 : (type >= 1 && type <= 5)) {
                if (count == 512) return paramErr;
                slices[count].bytes = bytes + begin;
                slices[count++].length = next - begin;
                total += 4 + next - begin;
                idr |= decoder->hevc ? (type >= 16 && type <= 21) : type == 5;
            }
        }
        offset = next;
        prefix = next_prefix;
    }
    if ((changed || !decoder->session) && decoder->sps && decoder->pps && (!decoder->hevc || decoder->vps)) {
        OSStatus status = make_session(decoder);
        if (status != noErr) return status;
    }
    if (!decoder->session || !count || (decoder->waiting_idr && !idr)) return noErr;
    decoder->waiting_idr = false;
    CMBlockBufferRef block = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(NULL, NULL, total, NULL, NULL, 0, total,
        kCMBlockBufferAssureMemoryNowFlag, &block);
    if (status != noErr) return status;
    size_t cursor = 0;
    for (size_t i = 0; i < count; i++) {
        uint32_t size = CFSwapInt32HostToBig((uint32_t)slices[i].length);
        status = CMBlockBufferReplaceDataBytes(&size, block, cursor, 4);
        if (status == noErr) status = CMBlockBufferReplaceDataBytes(slices[i].bytes, block, cursor + 4, slices[i].length);
        if (status != noErr) { CFRelease(block); return status; }
        cursor += slices[i].length + 4;
    }
    CMSampleBufferRef sample = NULL;
    status = CMSampleBufferCreateReady(NULL, block, decoder->format, 1, 0, NULL, 1, &total, &sample);
    CFRelease(block);
    if (status != noErr) return status;
    // Both asynchronous and temporal-processing flags are intentionally clear:
    // VideoToolbox must return this frame before this call returns.
    status = VTDecompressionSessionDecodeFrame(decoder->session, sample, 0, NULL, NULL);
    CFRelease(sample);
    if (status == kVTInvalidSessionErr) invalidate_session(decoder);
    else if (status != noErr) decoder->waiting_idr = true;
    return status;
}
