#ifndef VT_PIXBUF_ENCODE_H
#define VT_PIXBUF_ENCODE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct VTPixbufEncoder VTPixbufEncoder;
typedef void (*vt_out_cb)(const uint8_t* data, int size, int64_t pts, int key, void* obj);
VTPixbufEncoder* vt_pixbuf_new(int width, int height, int codec, int fps, int kbps, int gop,
                               vt_out_cb cb, void* obj);
int vt_pixbuf_encode(VTPixbufEncoder* e, void* cvpixelbuffer, int64_t pts);
void vt_pixbuf_flush(VTPixbufEncoder* e);
void vt_pixbuf_free(VTPixbufEncoder* e);
#ifdef __cplusplus
}
#endif
#endif
