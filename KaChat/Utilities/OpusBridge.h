#pragma once

#include <stdint.h>

#if __has_include(<opus/opus.h>)
#include <opus/opus.h>
#elif __has_include(<opus.h>)
#include <opus.h>
#elif __has_include(<YbridOpus/opus.h>)
#include <YbridOpus/opus.h>
#else
typedef int opus_int32;
typedef struct OpusEncoder OpusEncoder;
typedef struct OpusDecoder OpusDecoder;
#define OPUS_APPLICATION_VOIP 2048
#define OPUS_OK 0
#define OPUS_BAD_ARG -1
#endif

#ifdef __cplusplus
extern "C" {
#endif

int opus_encoder_set_bitrate(OpusEncoder *encoder, int32_t bitrate);
int opus_encoder_set_vbr(OpusEncoder *encoder, int vbr);
int opus_encoder_get_lookahead(OpusEncoder *encoder, int32_t *lookahead);

#ifdef __cplusplus
}
#endif
