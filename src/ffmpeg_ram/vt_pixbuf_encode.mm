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
  vt_out_cb cb;
  void* obj;
};

static void vt_output(VTPixbufEncoder* e, OSStatus st, CMSampleBufferRef sb) {
  if (st != noErr || !sb || !e->cb) return;
  CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
  if (!bb) return;
  size_t len = CMBlockBufferGetDataLength(bb);
  if (!len) return;
  uint8_t* buf = (uint8_t*)malloc(len);
  if (!buf) return;
  if (CMBlockBufferCopyDataBytes(bb, 0, len, buf) != kCMBlockBufferNoErr) {
    free(buf);
    return;
  }
  int64_t pts = (int64_t)CMSampleBufferGetPresentationTimeStamp(sb).value;
  CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, false);
  int key = 1;
  if (atts && CFArrayGetCount(atts) > 0) {
    CFDictionaryRef d = (CFDictionaryRef)CFArrayGetValueAtIndex(atts, 0);
    key = CFDictionaryContainsKey(d, kCMSampleAttachmentKey_NotSync) ? 0 : 1;
  }
  e->cb(buf, (int)len, pts, key, e->obj);
  free(buf);
}

VTPixbufEncoder* vt_pixbuf_new(int width, int height, int codec /*0=h264, 1=hevc*/, int fps, int kbps,
                               int gop, vt_out_cb cb, void* obj) {
  VTPixbufEncoder* e = (VTPixbufEncoder*)calloc(1, sizeof(VTPixbufEncoder));
  if (!e) return NULL;
  e->width = width;
  e->height = height;
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
  OSStatus rc = VTCompressionSessionEncodeFrameWithOutputHandler(
      e->session, pb, CMTimeMake(pts, 1000), kCMTimeInvalid, NULL, NULL,
      ^(OSStatus st, VTEncodeInfoFlags flags, CMSampleBufferRef sb) { vt_output(e, st, sb); });
  return (int)rc;
}

void vt_pixbuf_flush(VTPixbufEncoder* e) {
  if (e && e->session) VTCompressionSessionCompleteFrames(e->session, kCMTimeInvalid);
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
