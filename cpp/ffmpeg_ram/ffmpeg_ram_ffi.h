#ifndef FFMPEG_RAM_FFI_H
#define FFMPEG_RAM_FFI_H

#include <stdint.h>

#define AV_NUM_DATA_POINTERS 8

typedef void (*RamDecodeCallback)(const void *obj, int width, int height,
                                  int pixfmt,
                                  int linesize[AV_NUM_DATA_POINTERS],
                                  uint8_t *data[AV_NUM_DATA_POINTERS], int key);
typedef void (*RamEncodeCallback)(const uint8_t *data, int len, int64_t pts,
                                  int key, const void *obj);

void *ffmpeg_ram_new_encoder(const char *name, const char *mc_name, int width,
                             int height, int pixfmt, int align, int fps,
                             int gop, int rc, int quality, int kbs, int q,
                             int thread_count, int gpu, int *linesize,
                             int *offset, int *length,
                             RamEncodeCallback callback);
void *ffmpeg_ram_new_decoder(const char *name, int device_type,
                             int thread_count, RamDecodeCallback callback);
int ffmpeg_ram_encode(void *encoder, const uint8_t *data, int length,
                      const void *obj, int64_t ms);
int ffmpeg_ram_decode(void *decoder, const uint8_t *data, int length,
                      const void *obj);
void ffmpeg_ram_free_encoder(void *encoder);
void ffmpeg_ram_free_decoder(void *decoder);
int ffmpeg_ram_get_linesize_offset_length(int pix_fmt, int width, int height,
                                          int align, int *linesize, int *offset,
                                          int *length);
int ffmpeg_ram_set_bitrate(void *encoder, int kbs);

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#if defined(__APPLE__) && TARGET_OS_OSX
// The one way to ask a decoder for the VideoToolbox surface instead of a
// software frame. The wish belongs to this call: nothing on the decoder
// remembers it, so the next call -- through this function or through
// ffmpeg_ram_decode() -- is free to want the other thing.
//
// One call, one surface: HWCODEC_SUCCESS always carries a surface in
// *surface_out, and asking a decoder that is not videotoolbox, or decoding a
// software frame, is an error rather than an empty success. One packet yields
// at most one surface: a packet carrying several frames is rejected rather
// than silently keeping only the last one. We could not construct a packet
// that produced more than one frame (2..120 access units all yielded exactly
// one), so this guard is defensive and should not fire in practice; the
// software path above would deliver every frame it received.
//
// `obj` is kept only so this signature matches ffmpeg_ram_decode(); the
// surface path never calls the callback and does not read it.
//
// The surface is borrowed. It stays valid until the next call to this decoder
// -- including a call that decodes nothing, such as a rejected packet -- or
// until ffmpeg_ram_free_decoder(); CFRetain it to keep it longer.
//
// A rejected packet returns the same -1 ffmpeg_ram_decode() already uses for
// both "the decoder is broken" and "this packet has not produced a frame yet";
// the caller cannot tell those two apart, and this function does not change it.
int ffmpeg_ram_decode_surface(void *decoder, const uint8_t *data, int length,
                              const void *obj, void **surface_out);
#endif // __APPLE__ && TARGET_OS_OSX

#endif // FFMPEG_RAM_FFI_H