// Smoke test for vt_pixbuf_encode.mm: feeds BGRA CVPixelBuffers straight into the wrapper.
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "vt_pixbuf_encode.h"

static int g_frames = 0, g_bytes = 0, g_keys = 0;
static void on_out(const uint8_t* data, int size, int64_t pts, int key, void* obj) {
  g_frames++;
  g_bytes += size;
  if (key) g_keys++;
}
static double cpu_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts);
  return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

int main(int argc, char** argv) {
  int w = argc > 1 ? atoi(argv[1]) : 1920, h = argc > 2 ? atoi(argv[2]) : 1080;
  int n = 60, codec = argc > 3 ? atoi(argv[3]) : 0;
  VTPixbufEncoder* e = vt_pixbuf_new(w, h, codec, 30, 8000, 60, on_out, NULL);
  if (!e) { printf("encoder create failed\n"); return 2; }
  NSDictionary* a = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                       (id)kCVPixelBufferIOSurfacePropertiesKey : @{} };
  CVPixelBufferRef pb = NULL;
  if (CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)a, &pb) != 0)
    { printf("pixel buffer create failed\n"); return 3; }
  size_t stride = CVPixelBufferGetBytesPerRow(pb);
  double enc_cpu = 0;
  for (int f = 0; f < n; f++) {
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t* p = (uint8_t*)CVPixelBufferGetBaseAddress(pb);
    for (int y = 0; y < h; y++)
      for (int x = 0; x < w; x++) {
        uint8_t* q = p + y * stride + x * 4;
        q[0] = (uint8_t)(x + f * 3); q[1] = (uint8_t)(y + f * 5); q[2] = (uint8_t)((x ^ y) + f * 7);
        q[3] = 255;
      }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    double t = cpu_ms();
    int rc = vt_pixbuf_encode(e, pb, f * 33);
    enc_cpu += cpu_ms() - t;
    if (rc != 0) printf("encode rc=%d at frame %d\n", rc, f);
  }
  vt_pixbuf_flush(e);
  double cpu = enc_cpu;
  printf("%dx%d codec=%s frames=%d keys=%d bytes=%d  cpu %.3f ms/frame  %.1f kB/frame\n", w, h,
         codec ? "hevc" : "h264", g_frames, g_keys, g_bytes, cpu / n, g_bytes / (double)n / 1000.0);
  vt_pixbuf_free(e);
  return g_frames == 0 ? 4 : 0;
}
