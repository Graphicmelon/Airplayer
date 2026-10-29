// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef AIRPLAYER_REALTIME_H264_H
#define AIRPLAYER_REALTIME_H264_H
#include <CoreVideo/CoreVideo.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct APH264Decoder APH264Decoder;
typedef void (*APH264Output)(void *context, CVPixelBufferRef pixels, uint64_t input_ns, uint64_t decoded_ns);
APH264Decoder *APH264Create(APH264Output output, void *context);
void APH264Destroy(APH264Decoder *decoder);
void APH264Reset(APH264Decoder *decoder);
// Defaults to H.264. Switching codec clears parameter sets and reference frames.
void APH264SetHEVC(APH264Decoder *decoder, bool hevc);
OSStatus APH264Decode(APH264Decoder *decoder, const uint8_t *bytes, size_t length);
bool APH264IsHardware(APH264Decoder *decoder);
#endif
