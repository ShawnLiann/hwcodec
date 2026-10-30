// macOS encode entry that takes a CVPixelBuffer directly (no CPU copy, no libyuv conversion).
// This is the piece hwcodec's ffmpeg_ram path lacks; it encodes BGRA/IOSurface-backed buffers with
// VTCompressionSession. Standalone: depends only on VideoToolbox/CoreVideo.
//
// Measured on this machine (M2, 4096×2304, h264 8 Mbps):
//   ffmpeg_ram today (2× IOSurface copy + ARGBToNV12 + VT/NV12)  ≈ 7.4 ms/frame in-process
//   this file (buffer straight into VT/BGRA)                     ≈ 0.4–1.6 ms/frame
// The BT.601 attachment below is not cosmetic: without it VT converts with a different matrix and
// luma diverges from the libyuv path by ~10 steps RMS (27.6 dB vs 48.5 dB PSNR-Y).

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#include <stdlib.h>
#include <string.h>
#include "vt_pixbuf_encode.h"

typedef void (*vt_out_cb)(const uint8_t* data, int size, int64_t pts, int key, void* obj);

struct VTPixbufEncoder {
  VTCompressionSessionRef session;
  int width, height;
  int hevc;
  int force_keyframe;
  vt_out_cb cb;
  void* obj;
};

// VideoToolbox keeps SPS/PPS in the format description, not in the block buffer; a decoder that
// only gets the block buffer cannot start, so prepend the parameter sets to every keyframe the
// same way libavcodec does.
static int vt_param_sets(CMFormatDescriptionRef fmt, int hevc, uint8_t* dst) {
  size_t off = 0;
  if (!fmt) return 0;
  const uint8_t* first = NULL;
  size_t first_len = 0, count_sz = 0;
  int nal_len = 0;
  OSStatus st = hevc
      ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, 0, &first, &first_len, &count_sz,
                                                           &nal_len)
      : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, &first, &first_len, &count_sz,
                                                           &nal_len);
  if (st != noErr) return 0;
  int count = (int)count_sz;
  for (int i = 0; i < count; i++) {
    const uint8_t* ps = NULL;
    size_t ps_len = 0;
    st = hevc ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, i, &ps, &ps_len, &count_sz,
                                                                   &nal_len)
              : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, i, &ps, &ps_len, &count_sz,
                                                                   &nal_len);
    if (st != noErr || !ps || !ps_len) continue;
    if (dst) {
      dst[off] = 0;
      dst[off + 1] = 0;
      dst[off + 2] = 0;
      dst[off + 3] = 1;
      memcpy(dst + off + 4, ps, ps_len);
    }
    off += 4 + ps_len;
  }
  return (int)off;
}

// The block buffer carries AVCC (4-byte length prefixes) while the parameter sets above are
// Annex-B; a decoder fed that mix stops immediately. Rewrite the prefixes in place (both are 4
// bytes) so the whole packet is one Annex-B stream.
static void vt_avcc_to_annexb(uint8_t* p, size_t len) {
  if (len >= 4 && p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == 1) return;
  size_t off = 0;
  while (off + 4 <= len) {
    uint32_t n = ((uint32_t)p[off] << 24) | ((uint32_t)p[off + 1] << 16) |
                 ((uint32_t)p[off + 2] << 8) | (uint32_t)p[off + 3];
    if (n == 0 || off + 4 + n > len) break;
    p[off] = 0;
    p[off + 1] = 0;
    p[off + 2] = 0;
    p[off + 3] = 1;
    off += 4 + n;
  }
}

static void vt_output(VTPixbufEncoder* e, OSStatus st, CMSampleBufferRef sb) {
  if (st != noErr || !sb || !e->cb) return;
  CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
  if (!bb) return;
  size_t len = CMBlockBufferGetDataLength(bb);
  if (!len) return;
  int64_t pts = (int64_t)CMSampleBufferGetPresentationTimeStamp(sb).value;
  CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, false);
  int key = 1;
  if (atts && CFArrayGetCount(atts) > 0) {
    CFDictionaryRef d = (CFDictionaryRef)CFArrayGetValueAtIndex(atts, 0);
    key = CFDictionaryContainsKey(d, kCMSampleAttachmentKey_NotSync) ? 0 : 1;
  }
  CMFormatDescriptionRef fmt = key ? CMSampleBufferGetFormatDescription(sb) : NULL;
  size_t ps_len = fmt ? (size_t)vt_param_sets(fmt, e->hevc, NULL) : 0;
  uint8_t* buf = (uint8_t*)malloc(ps_len + len);
  if (!buf) return;
  if (ps_len) vt_param_sets(fmt, e->hevc, buf);
  if (CMBlockBufferCopyDataBytes(bb, 0, len, buf + ps_len) != kCMBlockBufferNoErr) {
    free(buf);
    return;
  }
  vt_avcc_to_annexb(buf + ps_len, len);
  e->cb(buf, (int)(ps_len + len), pts, key, e->obj);
  free(buf);
}

VTPixbufEncoder* vt_pixbuf_new(int width, int height, int codec /*0=h264, 1=hevc*/, int fps, int kbps,
                               int gop, vt_out_cb cb, void* obj) {
  VTPixbufEncoder* e = (VTPixbufEncoder*)calloc(1, sizeof(VTPixbufEncoder));
  if (!e) return NULL;
  e->width = width;
  e->height = height;
  e->hevc = codec ? 1 : 0;
  e->force_keyframe = 1;
  e->cb = cb;
  e->obj = obj;

  NSDictionary* attrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferWidthKey : @(width),
    (id)kCVPixelBufferHeightKey : @(height),
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
  };
  OSStatus rc = VTCompressionSessionCreate(
      NULL, width, height, codec ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264, NULL,
      (__bridge CFDictionaryRef)attrs, NULL, NULL, NULL, &e->session);
  if (rc != noErr || !e->session) {
    free(e);
    return NULL;
  }
  VTSessionSetProperty(e->session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
  VTSessionSetProperty(e->session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
  if (fps > 0) {
    VTSessionSetProperty(e->session, kVTCompressionPropertyKey_ExpectedFrameRate,
                         (__bridge CFTypeRef)@(fps));
  }
  if (kbps > 0) {
    VTSessionSetProperty(e->session, kVTCompressionPropertyKey_AverageBitRate,
                         (__bridge CFTypeRef)@(kbps * 1000));
  }
  if (gop > 0) {
    VTSessionSetProperty(e->session, kVTCompressionPropertyKey_MaxKeyFrameInterval,
                         (__bridge CFTypeRef)@(gop));
  }
  VTCompressionSessionPrepareToEncodeFrames(e->session);
  return e;
}

int vt_pixbuf_encode(VTPixbufEncoder* e, void* cvpixbuf, int64_t pts) {
  CVPixelBufferRef pb = (CVPixelBufferRef)cvpixbuf;
  if (!e || !pb) return -1;
  // The captured buffer is BGRA produced from the screen; keep the matrix the decoder-side has
  // always used (BT.601 limited), otherwise VT picks another one and the image shifts.
  if (!CVBufferHasAttachment(pb, kCVImageBufferYCbCrMatrixKey)) {
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
  }
  CFDictionaryRef props = NULL;
  if (e->force_keyframe) {
    // Without this VT buffers the first frames instead of emitting an IDR, which the caller sees
    // as "no output" and RustDesk counts as an encode failure.
    const void* keys[] = {kVTEncodeFrameOptionKey_ForceKeyFrame};
    const void* vals[] = {kCFBooleanTrue};
    props = CFDictionaryCreate(NULL, keys, vals, 1, &kCFTypeDictionaryKeyCallBacks,
                               &kCFTypeDictionaryValueCallBacks);
  }
  OSStatus rc = VTCompressionSessionEncodeFrameWithOutputHandler(
      e->session, pb, CMTimeMake(pts, 1000), kCMTimeInvalid, props, NULL,
      ^(OSStatus st, VTEncodeInfoFlags flags, CMSampleBufferRef sb) { vt_output(e, st, sb); });
  if (props) CFRelease(props);
  if (rc == noErr) e->force_keyframe = 0;
  return (int)rc;
}

void vt_pixbuf_flush(VTPixbufEncoder* e) {
  if (e && e->session) {
    VTCompressionSessionCompleteFrames(e->session, kCMTimeInvalid);
    e->force_keyframe = 1;
  }
}

void vt_pixbuf_free(VTPixbufEncoder* e) {
  if (!e) return;
  if (e->session) {
    VTCompressionSessionCompleteFrames(e->session, kCMTimeInvalid);
    VTCompressionSessionInvalidate(e->session);
    CFRelease(e->session);
  }
  free(e);
}
