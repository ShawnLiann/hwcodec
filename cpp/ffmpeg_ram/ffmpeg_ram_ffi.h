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
// wants_surface asks this one call for the VideoToolbox surface instead of a
// software frame. The intent is per call and is not remembered: the next call
// with 0 copies to software again. Off macOS the argument is ignored; on macOS
// asking a decoder that is not videotoolbox for a surface returns -1.
int ffmpeg_ram_decode(void *decoder, const uint8_t *data, int length,
                      const void *obj, int wants_surface);
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
// Borrowed surface of the last decode that asked for one, NULL when that
// decode produced a software frame. Valid until the next decode or
// ffmpeg_ram_free_decoder(): CFRetain it to keep it longer.
void *ffmpeg_ram_decode_pixelbuffer(void *decoder);
#endif // __APPLE__ && TARGET_OS_OSX

#endif // FFMPEG_RAM_FFI_H