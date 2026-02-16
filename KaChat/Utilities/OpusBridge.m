#import "OpusBridge.h"
#if __has_include(<YbridOpus/YbridOpus.h>)
@import YbridOpus;
#elif __has_include(<opus/opus.h>)
#include <opus/opus.h>
#elif __has_include(<opus.h>)
#include <opus.h>
#endif

int opus_encoder_set_bitrate(OpusEncoder *encoder, opus_int32 bitrate) {
    return opus_encoder_ctl(encoder, OPUS_SET_BITRATE(bitrate));
}

int opus_encoder_set_vbr(OpusEncoder *encoder, int vbr) {
    return opus_encoder_ctl(encoder, OPUS_SET_VBR(vbr));
}

int opus_encoder_get_lookahead(OpusEncoder *encoder, opus_int32 *lookahead) {
    return opus_encoder_ctl(encoder, OPUS_GET_LOOKAHEAD(lookahead));
}
