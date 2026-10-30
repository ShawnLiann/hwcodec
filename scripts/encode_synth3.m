// Synthetic-frame A/B for the encode path, no screen needed.
//   current : pool BGRA → memcpy to heap (as scrap does) → libyuv ARGBToNV12 → VT(NV12)
//   direct  : pool BGRA → VT(BGRA)                        (nothing copied, nothing converted)
// Also decodes one frame from each path and compares luma/chroma statistics, so a colour-range
// regression in the BGRA path would show up before it reaches a real session.
// usage: ./encode_synth3 <frames> [h264|hevc]
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "libyuv/include/libyuv.h"
#include <math.h>
#include <vector>

static double cpu_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts);
  return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static int W = 1920, H = 1080;

// deterministic, high-entropy-ish, but stable scene: colour bars + gradient + fine noise
// Screen-like content: text rows, a solid panel, a hard edge. Bars overstate how badly low bitrates do.
static void fill_scene_text(uint8_t* p, int stride, int w, int h, int tick) {
  const int row_h = h / 26 > 4 ? h / 26 : 4;
  for (int y = 0; y < h; y++) {
    uint8_t* row = p + y * stride;
    for (int x = 0; x < w; x++) {
      uint8_t v = 246;
      int band = y / row_h;
      int in_text = (y % row_h) > 2 && (y % row_h) < row_h - 2;
      if (in_text && band < 22) {
        // deterministic pseudo-glyphs: every 6 px a stroke, gaps to mimic word spacing
        int cell = x / 7, phase = ((band * 37 + cell * 17) % 11);
        if (phase < 6) v = 24;
      }
      if (x > w * 3 / 4 && y < h / 3) { v = 60; }                       // solid panel
      if (x > w / 2 - 40 && x < w / 2 + 40 && abs(y - h / 2) < 3) v = 200;  // hard edge
      if (tick >= 0 && x >= w - 40 && y >= 30 && y < 30 + 12) v = 210;      // small moving block
      uint8_t* q = row + x * 4;
      // Colour, or the chroma guard has nothing to measure.
      if (x > w * 3 / 4 && y < h / 3) {
        q[0] = 170; q[1] = 90; q[2] = 40; q[3] = 255;        // panel, strongly blue in BGRA terms
      } else if (in_text && band < 22 && (band % 5) == 0 && v < 128) {
        q[0] = 40; q[1] = 40; q[2] = 190; q[3] = 255;        // every fifth text row is red
      } else {
        q[0] = v; q[1] = v; q[2] = v; q[3] = 255;
      }
    }
  }
}

static void fill_scene(uint8_t* p, int stride, int w, int h, int tick) {
  for (int y = 0; y < h; y++) {
    uint8_t* row = p + y * stride;
    for (int x = 0; x < w; x++) {
      int bar = x * 8 / w;
      uint8_t r = (uint8_t)(bar & 1 ? 235 : 16);
      uint8_t g = (uint8_t)(bar & 2 ? 210 : 20);
      uint8_t b = (uint8_t)(bar & 4 ? 190 : 30);
      r = (uint8_t)((r * 3 + x * 255 / w) / 4);
      g = (uint8_t)((g * 3 + y * 255 / h) / 4);
      b = (uint8_t)((b * 3 + ((x + y + tick) & 63) * 4) / 4);
      uint8_t* q = row + x * 4;
      q[0] = b; q[1] = g; q[2] = r; q[3] = 255;
    }
  }
}

// No edges: a difference here means the matrices differ, not the filtering.
static void fill_scene_flat(uint8_t* p, int stride, int w, int h, int tick) {
  (void)tick;
  for (int y = 0; y < h; y++) {
    uint8_t* row = p + y * stride;
    for (int x = 0; x < w; x++) {
      uint8_t* q = row + x * 4;
      q[0] = 170; q[1] = 90; q[2] = 40; q[3] = 255;
    }
  }
}

static void fill_any(uint8_t* p, int stride, int w, int h, int tick) {
  const char* scene = getenv("SCENE");
  if (scene && strcmp(scene, "text") == 0) fill_scene_text(p, stride, w, h, tick);
  else if (scene && strcmp(scene, "flat") == 0) fill_scene_flat(p, stride, w, h, tick);
  else fill_scene(p, stride, w, h, tick);
}

typedef struct {
  double cpu_total, cpu_copy, cpu_conv, cpu_submit;
  int frames;
} Stat;

int main(int argc, char** argv) {
  setvbuf(stdout, NULL, _IONBF, 0);
  int frames = argc > 1 ? atoi(argv[1]) : 120;
  if (argc > 3) { W = atoi(argv[3]); H = atoi(argv[4]); }
  int mbps = argc > 5 ? atoi(argv[5]) : 8;
  const char* matrix = argc > 6 ? argv[6] : "none";  // none | 601 | 709
  int hevc = !(argc > 2 && strcmp(argv[2], "h264") == 0);
  CMVideoCodecType codec = hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264;

  NSDictionary* attrs = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                           (id)kCVPixelBufferWidthKey : @(W),
                           (id)kCVPixelBufferHeightKey : @(H),
                           (id)kCVPixelBufferIOSurfacePropertiesKey : @{} };
  CVPixelBufferRef bgra = NULL;
  CVReturn rcb = CVPixelBufferCreate(NULL, W, H, kCVPixelFormatType_32BGRA,
                                     (__bridge CFDictionaryRef)attrs, &bgra);
  printf("bgra create rc=%d (buf=%p)\n", (int)rcb, (void*)bgra);
  if (!bgra) return 5;
  if (strcmp(matrix, "601") == 0 || strcmp(matrix, "709") == 0) {
    CFStringRef m = strcmp(matrix, "601") == 0 ? kCVImageBufferYCbCrMatrix_ITU_R_601_4
                                               : kCVImageBufferYCbCrMatrix_ITU_R_709_2;
    CVBufferSetAttachment(bgra, kCVImageBufferYCbCrMatrixKey, m, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(bgra, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(bgra, kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
  }
  CVPixelBufferRef nv12 = NULL;
  CVPixelBufferCreate(NULL, W, H, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, NULL, &nv12);
  CVPixelBufferLockBaseAddress(nv12, 0);
  uint8_t* nv_y = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(nv12, 0);
  uint8_t* nv_uv = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(nv12, 1);
  size_t nv_y_stride = CVPixelBufferGetBytesPerRowOfPlane(nv12, 0);
  size_t nv_uv_stride = CVPixelBufferGetBytesPerRowOfPlane(nv12, 1);
  if (!nv_y || !nv_uv) { printf("nv12 buffers unavailable\n"); return 2; }

  // two sessions: one advertised NV12, one advertised BGRA
  VTCompressionSessionRef s_nv12 = NULL, s_bgra = NULL;
  NSDictionary* a1 = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                        (id)kCVPixelBufferIOSurfacePropertiesKey : @{} };
  NSDictionary* a2 = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                        (id)kCVPixelBufferIOSurfacePropertiesKey : @{} };
  VTCompressionSessionCreate(NULL, W, H, codec, NULL, (__bridge CFDictionaryRef)a1, NULL, NULL, NULL, &s_nv12);
  VTCompressionSessionCreate(NULL, W, H, codec, NULL, (__bridge CFDictionaryRef)a2, NULL, NULL, NULL, &s_bgra);
  for (int i = 0; i < 2; i++) {
    VTCompressionSessionRef s = i ? s_bgra : s_nv12;
    VTSessionSetProperty(s, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(s, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(mbps * 1000000));
    VTSessionSetProperty(s, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(60));
    VTCompressionSessionPrepareToEncodeFrames(s);
  }

  size_t stride = CVPixelBufferGetBytesPerRow(bgra);
  printf("bgra stride=%zu\n", stride);
  uint8_t* heap_bgra = (uint8_t*)malloc(stride * H);
  Stat cur = {0}, dir = {0};
  __block uint8_t* first_cur = NULL; __block size_t first_cur_len = 0;
  __block CMSampleBufferRef sb_cur = NULL, sb_dir = NULL;
  __block uint8_t* first_dir = NULL; __block size_t first_dir_len = 0;

  for (int f = 0; f < frames; f++) {
    if (f == 0) printf("loop start\n");
    CVPixelBufferLockBaseAddress(bgra, 0);
    fill_any((uint8_t*)CVPixelBufferGetBaseAddress(bgra), (int)stride, W, H, f);
    CVPixelBufferUnlockBaseAddress(bgra, 0);
    CMTime ts = CMTimeMake(f, 30);

    if (f == 0) printf("scene filled, stride=%zu\n", stride);
    // --- current path
    double t0 = cpu_ms();
    CVPixelBufferLockBaseAddress(bgra, kCVPixelBufferLock_ReadOnly);
    const uint8_t* src = (const uint8_t*)CVPixelBufferGetBaseAddress(bgra);
    memcpy(heap_bgra, src, stride * H);  // stands in for scrap's saved_raw_data copy
    double t1 = cpu_ms();
    libyuv::ARGBToNV12(heap_bgra, (int)stride, nv_y, (int)nv_y_stride, nv_uv, (int)nv_uv_stride,
                       W, H);
    CVPixelBufferUnlockBaseAddress(bgra, kCVPixelBufferLock_ReadOnly);
    double t2 = cpu_ms();
    __block uint8_t* out = NULL; __block size_t outlen = 0;
    VTCompressionSessionEncodeFrameWithOutputHandler(
        s_nv12, nv12, ts, kCMTimeInvalid, NULL, NULL,
        ^(OSStatus st, VTEncodeInfoFlags fl, CMSampleBufferRef sb) {
          if (st == noErr && sb && !sb_cur) {
            CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
            if (!bb) return;
            sb_cur = (CMSampleBufferRef)CFRetain(sb);
            size_t len = CMBlockBufferGetDataLength(bb);
            uint8_t* p = (uint8_t*)malloc(len);
            CMBlockBufferCopyDataBytes(bb, 0, len, p);
            first_cur = p; first_cur_len = len;
          }
          (void)out; (void)outlen;
        });
    double t3 = cpu_ms();
    cur.cpu_copy += t1 - t0; cur.cpu_conv += t2 - t1; cur.cpu_submit += t3 - t2; cur.cpu_total += t3 - t0;

    if (f == 0) printf("current path ok\n");
    // --- direct path
    double d0 = cpu_ms();
    VTCompressionSessionEncodeFrameWithOutputHandler(
        s_bgra, bgra, ts, kCMTimeInvalid, NULL, NULL,
        ^(OSStatus st, VTEncodeInfoFlags fl, CMSampleBufferRef sb) {
          if (st == noErr && sb && !sb_dir) {
            CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
            if (!bb) return;
            sb_dir = (CMSampleBufferRef)CFRetain(sb);
            size_t len = CMBlockBufferGetDataLength(bb);
            uint8_t* p = (uint8_t*)malloc(len);
            CMBlockBufferCopyDataBytes(bb, 0, len, p);
            first_dir = p; first_dir_len = len;
          }
        });
    double d1 = cpu_ms();
    dir.cpu_total += d1 - d0; dir.cpu_submit += d1 - d0;

    // VideoToolbox is created with an expected rate of 30 fps and silently drops frames when it is
    // fed faster, so an unpaced run measures the drop policy rather than the encoder. Set
    // FRAME_DELAY_US=33333 to submit at the natural rate.
    {
      const char* delay = getenv("FRAME_DELAY_US");
      if (delay) usleep((useconds_t)atoi(delay));
    }

    if (f == frames / 2) { VTCompressionSessionCompleteFrames(s_nv12, kCMTimeInvalid);
                           VTCompressionSessionCompleteFrames(s_bgra, kCMTimeInvalid); }
  }
  cur.frames = dir.frames = frames;
  VTCompressionSessionCompleteFrames(s_nv12, kCMTimeInvalid);
  VTCompressionSessionCompleteFrames(s_bgra, kCMTimeInvalid);

  printf("frames=%d %dx%d codec=%s %d Mbps matrix=%s\n", frames, W, H, hevc ? "hevc" : "h264", mbps, matrix);
  printf("current  %.3f ms/frame  (copy %.3f + libyuv %.3f + submit %.3f)\n",
         cur.cpu_total / frames, cur.cpu_copy / frames, cur.cpu_conv / frames, cur.cpu_submit / frames);
  printf("direct   %.3f ms/frame  (submit %.3f)\n", dir.cpu_total / frames, dir.cpu_submit / frames);
  // Parameter sets live in the format description, so dump them separately as Annex-B.
  const char* dump_ps = getenv("DUMP");
  if (dump_ps) {
    for (int k = 0; k < 2; k++) {
      CMSampleBufferRef sb = k ? sb_dir : sb_cur;
      if (!sb) continue;
      CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
      char name[512];
      snprintf(name, sizeof(name), "%s-%s-ps.h264", dump_ps, k ? "direct" : "current");
      FILE* f = fopen(name, "wb");
      if (!f) continue;
      size_t count = 0; int nal_len = 0;
      if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, 0, NULL, NULL, &count, &nal_len) == noErr)
        for (size_t i = 0; i < count; i++) {
          const uint8_t* ps = NULL; size_t ps_len = 0;
          if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, (int)i, &ps, &ps_len, NULL, NULL) == noErr) {
            const uint8_t sc[4] = {0, 0, 0, 1};
            fwrite(sc, 1, 4, f);
            fwrite(ps, 1, ps_len, f);
          }
        }
      fclose(f);
    }
  }

  // First packet of each arm, on request.
  const char* dump = getenv("DUMP");
  if (dump) {
    char name[512];
    snprintf(name, sizeof(name), "%s-current.h264", dump);
    FILE* f = fopen(name, "wb");
    if (f) { fwrite(first_cur, 1, first_cur_len, f); fclose(f); }
    snprintf(name, sizeof(name), "%s-direct.h264", dump);
    f = fopen(name, "wb");
    if (f) { fwrite(first_dir, 1, first_dir_len, f); fclose(f); }
    printf("dumped %s-{current,direct}.h264\n", dump);
  }

  printf("bitstream bytes: current %zu, direct %zu (same target bitrate, %.2f%% diff)\n", first_cur_len,
         first_dir_len, first_dir_len ? 100.0 * (dir.cpu_total - cur.cpu_total) / cur.cpu_total : 0);
  printf("save %.3f ms/frame (%.0f%%)\n", (cur.cpu_total - dir.cpu_total) / frames,
         100.0 * (cur.cpu_total - dir.cpu_total) / cur.cpu_total);

  // decode one frame from each path and compare plane statistics: a range/BT.601-vs-709 mistake in
  // the BGRA path shows up here as a large luma or chroma difference.
  for (int k = 0; k < 2; k++) {
    CMSampleBufferRef sb = k ? sb_dir : sb_cur;
    const char* name = k ? "direct" : "current";
    if (!sb) { printf("%s: no sample buffer\n", name); continue; }
    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
    VTDecompressionSessionRef ds = NULL;
    VTDecompressionSessionCreate(NULL, fd, NULL, NULL, NULL, &ds);
    __block CVPixelBufferRef out = NULL;
    VTDecompressionSessionDecodeFrameWithOutputHandler(
        ds, sb, 0, NULL,
        ^(OSStatus st, VTDecodeInfoFlags fl, CVImageBufferRef img, CMTime a, CMTime b) {
          if (st == noErr && img) out = (CVPixelBufferRef)CFRetain(img);
        });
    VTDecompressionSessionWaitForAsynchronousFrames(ds);
    if (!out) { printf("%s: decode failed\n", name); CFRelease(sb); continue; }
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
    int tick = (int)pts.value;
    CVPixelBufferLockBaseAddress(bgra, 0);
    fill_any((uint8_t*)CVPixelBufferGetBaseAddress(bgra), (int)stride, W, H, tick);
    std::vector<uint8_t> ref_buf((size_t)W * H * 3 / 2);
    libyuv::ARGBToNV12((uint8_t*)CVPixelBufferGetBaseAddress(bgra), (int)stride, ref_buf.data(), W,
                       ref_buf.data() + (size_t)W * H, W, W, H);
    CVPixelBufferUnlockBaseAddress(bgra, 0);
    const uint8_t* ref_y = ref_buf.data();
    CVPixelBufferLockBaseAddress(out, kCVPixelBufferLock_ReadOnly);
    int pw = (int)CVPixelBufferGetWidth(out), ph = (int)CVPixelBufferGetHeight(out);
    size_t ys = CVPixelBufferGetBytesPerRowOfPlane(out, 0);
    uint8_t* yp = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(out, 0);
    double sum = 0; int mn = 255, mx = 0;
    for (int y = 0; y < ph; y++)
      for (int x = 0; x < pw; x++) {
        int v = yp[y * ys + x];
        sum += v; if (v < mn) mn = v; if (v > mx) mx = v;
      }
    double u = 0, v2 = 0; int n = 0;
    // Luma PSNR cannot see a matrix mistake; the error shows up on the colour planes.
    double se_u = 0, se_v = 0; int cn = 0;
    const uint8_t* ref_uv = ref_buf.data() + (size_t)W * H;
    if (CVPixelBufferGetPlaneCount(out) > 1) {
      size_t uvs = CVPixelBufferGetBytesPerRowOfPlane(out, 1);
      uint8_t* up = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(out, 1);
      int cw = pw / 2, ch = ph / 2;
      for (int y = 0; y < ch; y++)
        for (int x = 0; x < cw; x++) {
          int iu = up[y * uvs + 2 * x], iv = up[y * uvs + 2 * x + 1];
          u += iu; v2 += iv; n++;
          if (pw == W && ph == H) {
            double du = (double)iu - ref_uv[(size_t)y * W + 2 * x];
            double dv = (double)iv - ref_uv[(size_t)y * W + 2 * x + 1];
            se_u += du * du; se_v += dv * dv; cn++;
          }
        }
      u /= n; v2 /= n;
      if (cn) { se_u /= cn; se_v /= cn; }
    }
    double se = 0;
    if (pw == W && ph == H) {
      for (int y = 0; y < ph; y++)
        for (int x = 0; x < pw; x++) {
          double d = (double)yp[y * ys + x] - ref_y[(size_t)y * W + x];
          se += d * d;
        }
      se /= (double)pw * ph;
    }
    printf("%-8s frame %d decoded %dx%d  luma mean %.2f  min %d max %d  cb %.2f cr %.2f  pixfmt %u  PSNR-Y %.2f dB  PSNR-U %.2f  PSNR-V %.2f\n",
           name, tick, pw, ph, sum / (pw * (double)ph), mn, mx, u, v2,
           (unsigned)CVPixelBufferGetPixelFormatType(out), se > 0 ? 10 * log10(255.0 * 255.0 / se) : 99.0,
           se_u > 0 ? 10 * log10(255.0 * 255.0 / se_u) : 99.0,
           se_v > 0 ? 10 * log10(255.0 * 255.0 / se_v) : 99.0);
    CVPixelBufferUnlockBaseAddress(out, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferRelease(out);
    CFRelease(sb);
    VTDecompressionSessionInvalidate(ds);
    CFRelease(ds);
  }
  return 0;
}
