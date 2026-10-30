// Smoke test for vt_pixbuf_encode.mm: feeds BGRA CVPixelBuffers straight into the wrapper.
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "vt_pixbuf_encode.h"

static int g_frames = 0, g_bytes = 0, g_keys = 0, g_key_ps = 0, g_nals = 0, g_bad = 0;
static int g_hevc = 0;

// A packet must be one Annex-B stream: every NAL starts with 00 00 00 01 and the start codes tile
// the buffer exactly. VideoToolbox hands back AVCC (4-byte length prefixes), and mixing that with
// Annex-B parameter sets is what left the peer asking for a refresh every second with no encode
// error in the host log, so an AVCC packet has to fail here.
static int annexb_scan(const uint8_t* d, int n, int hevc, int* has_ps) {
  int off = 0, nals = 0, ps = 0;
  while (off + 4 <= n) {
    if (!(d[off] == 0 && d[off + 1] == 0 && d[off + 2] == 0 && d[off + 3] == 1)) return 0;
    int start = off + 4, next = start;
    while (next + 4 <= n &&
           !(d[next] == 0 && d[next + 1] == 0 && d[next + 2] == 0 && d[next + 3] == 1))
      next++;
    int end = next + 4 <= n ? next : n;
    if (end == start) return 0;
    int type = hevc ? ((d[start] >> 1) & 0x3f) : (d[start] & 0x1f);
    if (hevc ? (type >= 32 && type <= 34) : (type == 7 || type == 8)) ps = 1;
    nals++;
    off = end;
  }
  if (off != n) return 0;
  *has_ps = ps;
  return nals;
}

static void on_out(const uint8_t* data, int size, int64_t pts, int key, void* obj) {
  g_frames++;
  g_bytes += size;
  if (key) g_keys++;
  int ps = 0, nals = annexb_scan(data, size, g_hevc, &ps);
  if (nals <= 0) {
    g_bad++;
    return;
  }
  g_nals += nals;
  if (key && ps) g_key_ps++;
}
static double cpu_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts);
  return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

int main(int argc, char** argv) {
  int w = argc > 1 ? atoi(argv[1]) : 1920, h = argc > 2 ? atoi(argv[2]) : 1080;
  int n = 60, codec = argc > 3 ? atoi(argv[3]) : 0;
  g_hevc = codec;
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
  printf("%dx%d codec=%s frames=%d keys=%d bytes=%d  cpu %.3f ms/frame  %.1f kB/frame"
         "  nals=%d annexb=%d keyps=%d\n",
         w, h, codec ? "hevc" : "h264", g_frames, g_keys, g_bytes, cpu / n,
         g_bytes / (double)n / 1000.0, g_nals, g_bad == 0, g_key_ps);
  vt_pixbuf_free(e);
  return g_frames == 0 ? 4 : 0;
}
