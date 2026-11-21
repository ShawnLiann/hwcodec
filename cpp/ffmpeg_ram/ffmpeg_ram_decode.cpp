// https://github.com/FFmpeg/FFmpeg/blob/master/doc/examples/hw_decode.c
// https://github.com/FFmpeg/FFmpeg/blob/master/doc/examples/decode_video.c

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/log.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
}

#include <memory>
#include <stdbool.h>

#define LOG_MODULE "FFMPEG_RAM_DEC"
#include <log.h>
#include <util.h>

#ifdef _WIN32
#include <libavutil/hwcontext_d3d11va.h>
#endif

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#if defined(__APPLE__) && TARGET_OS_OSX
#include <CoreVideo/CoreVideo.h>
#define RAM_DEC_SURFACE 1
#endif

#include "common.h"
#include "system.h"

// #define CFG_PKG_TRACE

namespace {
typedef void (*RamDecodeCallback)(const void *obj, int width, int height,
                                  enum AVPixelFormat pixfmt,
                                  int linesize[AV_NUM_DATA_POINTERS],
                                  uint8_t *data[AV_NUM_DATA_POINTERS], int key);

class FFmpegRamDecoder {
public:
  AVCodecContext *c_ = NULL;
  AVBufferRef *hw_device_ctx_ = NULL;
  AVFrame *sw_frame_ = NULL;
  AVFrame *frame_ = NULL;
  AVPacket *pkt_ = NULL;
  bool hwaccel_ = true;

  std::string name_;
  AVHWDeviceType device_type_ = AV_HWDEVICE_TYPE_NONE;
  int thread_count_ = 1;
  RamDecodeCallback callback_ = NULL;
  DataFormat data_format_;

#ifdef CFG_PKG_TRACE
  int in_ = 0;
  int out_ = 0;
#endif

  FFmpegRamDecoder(const char *name, int device_type, int thread_count,
                   RamDecodeCallback callback) {
    this->name_ = name;
    this->device_type_ = (AVHWDeviceType)device_type;
    this->thread_count_ = thread_count;
    this->callback_ = callback;
  }

  ~FFmpegRamDecoder() {}

#ifdef RAM_DEC_SURFACE
  // The pointer handed out by ffmpeg_ram_decode_surface() is only valid until
  // the next decode, so every decode starts by dropping it.
  void release_last_pb() {
    if (last_pb_) {
      CFRelease(last_pb_);
      last_pb_ = NULL;
    }
  }
#endif

  void free_decoder() {
#ifdef RAM_DEC_SURFACE
    release_last_pb();
#endif
    if (frame_)
      av_frame_free(&frame_);
    if (pkt_)
      av_packet_free(&pkt_);
    if (sw_frame_)
      av_frame_free(&sw_frame_);
    if (c_)
      avcodec_free_context(&c_);
    if (hw_device_ctx_)
      av_buffer_unref(&hw_device_ctx_);

    frame_ = NULL;
    pkt_ = NULL;
    sw_frame_ = NULL;
    c_ = NULL;
    hw_device_ctx_ = NULL;
  }
  int reset() {
    if (name_.find("h264") != std::string::npos) {
      data_format_ = DataFormat::H264;
    } else if (name_.find("hevc") != std::string::npos) {
      data_format_ = DataFormat::H265;
    } else {
      LOG_ERROR(std::string("unsupported data format:") + name_);
      return -1;
    }
    free_decoder();
    const AVCodec *codec = NULL;
    hwaccel_ = device_type_ != AV_HWDEVICE_TYPE_NONE;
    int ret;
    if (!(codec = avcodec_find_decoder_by_name(name_.c_str()))) {
      LOG_ERROR(std::string("avcodec_find_decoder_by_name ") + name_ + " failed");
      return -1;
    }
    if (!(c_ = avcodec_alloc_context3(codec))) {
      LOG_ERROR(std::string("Could not allocate video codec context"));
      return -1;
    }

    c_->flags |= AV_CODEC_FLAG_LOW_DELAY;
    c_->thread_count =
        device_type_ != AV_HWDEVICE_TYPE_NONE ? 1 : thread_count_;
    c_->thread_type = FF_THREAD_SLICE;

    if (name_.find("qsv") != std::string::npos) {
      if ((ret = av_opt_set(c_->priv_data, "async_depth", "1", 0)) < 0) {
        LOG_ERROR(std::string("qsv set opt async_depth 1 failed"));
        return -1;
      }
      // https://github.com/FFmpeg/FFmpeg/blob/c6364b711bad1fe2fbd90e5b2798f87080ddf5ea/libavcodec/qsvdec.c#L932
      // for disable warning
      c_->pkt_timebase = av_make_q(1, 30);
    }

    if (hwaccel_) {
      ret =
          av_hwdevice_ctx_create(&hw_device_ctx_, device_type_, NULL, NULL, 0);
      if (ret < 0) {
        LOG_ERROR(std::string("av_hwdevice_ctx_create failed, ret = ") + av_err2str(ret));
        return -1;
      }
      c_->hw_device_ctx = av_buffer_ref(hw_device_ctx_);
      if (!check_support()) {
        LOG_ERROR(std::string("check_support failed"));
        return -1;
      }
      if (!(sw_frame_ = av_frame_alloc())) {
        LOG_ERROR(std::string("av_frame_alloc failed"));
        return -1;
      }
    }

    if (!(pkt_ = av_packet_alloc())) {
      LOG_ERROR(std::string("av_packet_alloc failed"));
      return -1;
    }

    if (!(frame_ = av_frame_alloc())) {
      LOG_ERROR(std::string("av_frame_alloc failed"));
      return -1;
    }

    if ((ret = avcodec_open2(c_, codec, NULL)) != 0) {
      LOG_ERROR(std::string("avcodec_open2 failed, ret = ") + av_err2str(ret));
      return -1;
    }
#ifdef CFG_PKG_TRACE
    in_ = 0;
    out_ = 0;
#endif

    return 0;
  }

#ifdef RAM_DEC_SURFACE
  // Borrowed: the decoder keeps ownership and drops it on the next decode or
  // in free_decoder(). A caller that keeps it longer has to CFRetain it.
  CVPixelBufferRef last_pixelbuffer() const { return last_pb_; }
#endif

  // wants_surface belongs to this call only: nothing on the object remembers
  // it, so the same decoder can copy to software on the next packet.
  int decode(const uint8_t *data, int length, const void *obj,
             bool wants_surface) {
    int ret = -1;
#ifdef CFG_PKG_TRACE
    in_++;
    LOG_DEBUG(std::string("delay DI: in:") + in_ + " out:" + out_);
#endif

#ifdef RAM_DEC_SURFACE
    // One surface per decode, including the calls that decode nothing: a
    // caller must never read the surface an earlier call produced.
    release_last_pb();
#endif
    if (!data || !length) {
      LOG_ERROR(std::string("illegal decode parameter"));
      return -1;
    }
#ifdef RAM_DEC_SURFACE
    if (wants_surface && device_type_ != AV_HWDEVICE_TYPE_VIDEOTOOLBOX) {
      LOG_ERROR(std::string(
          "a surface was asked of a decoder that is not videotoolbox"));
      return -1;
    }
#else
    (void)wants_surface;
#endif
    pkt_->data = (uint8_t *)data;
    pkt_->size = length;
    ret = do_decode(obj, wants_surface);
    return ret;
  }

private:
#ifdef RAM_DEC_SURFACE
  // Retained copy of data[3]: the decoder reuses the AVFrame on the next
  // receive, so the surface has to outlive it.
  CVPixelBufferRef last_pb_ = NULL;
#endif

  int do_decode(const void *obj, bool wants_surface) {
#ifndef RAM_DEC_SURFACE
    (void)wants_surface;
#endif
    int ret;
    AVFrame *tmp_frame = NULL;
    bool decoded = false;

    ret = avcodec_send_packet(c_, pkt_);
    if (ret < 0) {
      LOG_ERROR(std::string("avcodec_send_packet failed, ret = ") + av_err2str(ret));
      return ret;
    }
    auto start = util::now();
    while (ret >= 0 && util::elapsed_ms(start) < ENCODE_TIMEOUT_MS) {
      if ((ret = avcodec_receive_frame(c_, frame_)) != 0) {
        if (ret != AVERROR(EAGAIN)) {
          LOG_ERROR(std::string("avcodec_receive_frame failed, ret = ") + av_err2str(ret));
        }
        goto _exit;
      }

      if (hwaccel_) {
        if (!frame_->hw_frames_ctx) {
          LOG_ERROR(std::string("hw_frames_ctx is NULL"));
          goto _exit;
        }
#ifdef RAM_DEC_SURFACE
        // VideoToolbox decodes straight into a CVPixelBufferRef carried in
        // data[3]. When the caller asked for a surface, hand that out instead
        // of copying it to RAM; the software transfer below stays the only
        // path for every other decoder.
        if (wants_surface) {
          // One decode, one contract: a caller that asked for a surface cannot
          // read a software frame, so a fallback is an error, not a silent
          // hand-over to a callback that is not listening.
          if (frame_->format != AV_PIX_FMT_VIDEOTOOLBOX || !frame_->data[3]) {
            LOG_ERROR(std::string("wants a surface, decoded a software frame"));
            goto _exit;
          }
          // The contract above says one packet yields at most one surface.
          // Enforce it instead of quietly keeping only the last frame: the
          // entry guard cleared last_pb_, so a non-NULL slot here means this
          // packet already produced a surface.
          if (last_pb_) {
            LOG_ERROR(std::string(
                "one packet produced more than one surface; the surface path "
                "hands out at most one per packet"));
            goto _exit;
          }
          CVPixelBufferRef pb = (CVPixelBufferRef)frame_->data[3];
          // Drop ours first, then retain this one: ffmpeg's frame_ still holds
          // the buffer for the rest of this call, so releasing before
          // retaining stays safe even if the pool handed the same address
          // back. One packet yields one frame, so the slot is empty here in
          // practice and this is just the ordered form of the same pair.
          release_last_pb();
          CFRetain(pb);
          last_pb_ = pb;
          decoded = true;
#ifdef CFG_PKG_TRACE
          out_++;
          LOG_DEBUG(std::string("delay DO: in:") + in_ + " out:" + out_);
#endif
          continue;
        }
#endif
        if ((sw_frame_->width != 0 || sw_frame_->height != 0) &&
            (sw_frame_->width != frame_->width ||
             sw_frame_->height != frame_->height)) {
          av_frame_unref(sw_frame_);
        }
        if ((ret = av_hwframe_transfer_data(sw_frame_, frame_, 0)) < 0) {
          LOG_ERROR(std::string("av_hwframe_transfer_data failed, ret = ") +
                    av_err2str(ret));
          goto _exit;
        }

        tmp_frame = sw_frame_;
      } else {
        tmp_frame = frame_;
      }
      decoded = true;
#ifdef CFG_PKG_TRACE
      out_++;
      LOG_DEBUG(std::string("delay DO: in:") + in_ + " out:" + out_);
#endif
#if FF_API_FRAME_KEY
      int key_frame = frame_->flags & AV_FRAME_FLAG_KEY;
#else
      int key_frame = frame_->key_frame;
#endif

      callback_(obj, tmp_frame->width, tmp_frame->height,
                (AVPixelFormat)tmp_frame->format, tmp_frame->linesize,
                tmp_frame->data, key_frame);
    }
  _exit:
    av_packet_unref(pkt_);
    return decoded ? 0 : -1;
  }

  bool check_support() {
#ifdef _WIN32
    if (device_type_ == AV_HWDEVICE_TYPE_D3D11VA) {
      if (!c_->hw_device_ctx) {
        LOG_ERROR(std::string("hw_device_ctx is NULL"));
        return false;
      }
      AVHWDeviceContext *deviceContext =
          (AVHWDeviceContext *)hw_device_ctx_->data;
      if (!deviceContext) {
        LOG_ERROR(std::string("deviceContext is NULL"));
        return false;
      }
      AVD3D11VADeviceContext *d3d11vaDeviceContext =
          (AVD3D11VADeviceContext *)deviceContext->hwctx;
      if (!d3d11vaDeviceContext) {
        LOG_ERROR(std::string("d3d11vaDeviceContext is NULL"));
        return false;
      }
      ID3D11Device *device = d3d11vaDeviceContext->device;
      if (!device) {
        LOG_ERROR(std::string("device is NULL"));
        return false;
      }
      std::unique_ptr<NativeDevice> native_ = std::make_unique<NativeDevice>();
      if (!native_) {
        LOG_ERROR(std::string("Failed to create native device"));
        return false;
      }
      if (!native_->Init(0, (ID3D11Device *)device, 0)) {
        LOG_ERROR(std::string("Failed to init native device"));
        return false;
      }
      if (!native_->support_decode(data_format_)) {
        LOG_ERROR(std::string("Failed to check support ") + name_);
        return false;
      }
      return true;
    } else {
      return true;
    }
#else
    return true;
#endif
  }
};

} // namespace

#ifdef RAM_DEC_SURFACE
// The only way to ask for a surface, and it answers in the same call: the
// pointer comes out here instead of through a second exported symbol. The
// surface stays owned by the decoder, released on the next decode or in
// ffmpeg_ram_free_decoder(); retain it to keep it longer.
extern "C" int ffmpeg_ram_decode_surface(FFmpegRamDecoder *decoder,
                                         const uint8_t *data, int length,
                                         const void *obj,
                                         void **surface_out) {
  if (!surface_out)
    return HWCODEC_ERR_COMMON;
  *surface_out = NULL;
  if (!decoder)
    return HWCODEC_ERR_COMMON;
  try {
    int ret = decoder->decode(data, length, obj, true);
    if (DataFormat::H265 == decoder->data_format_ &&
        util_decode::has_flag_could_not_find_ref_with_poc()) {
      return HWCODEC_ERR_HEVC_COULD_NOT_FIND_POC;
    }
    if (ret != 0)
      return HWCODEC_ERR_COMMON;
    *surface_out = decoder->last_pixelbuffer();
    // A success without a surface would be the empty contract this function
    // exists to avoid, so it is reported as an error.
    return *surface_out ? HWCODEC_SUCCESS : HWCODEC_ERR_COMMON;
  } catch (const std::exception &e) {
    LOG_ERROR(std::string("ffmpeg_ram_decode_surface exception:") + e.what());
  } catch (...) {
    LOG_ERROR("ffmpeg_ram_decode_surface: unknown exception");
  }
  return HWCODEC_ERR_COMMON;
}
#endif

extern "C" void ffmpeg_ram_free_decoder(FFmpegRamDecoder *decoder) {
  try {
    if (!decoder)
      return;
    decoder->free_decoder();
    delete decoder;
    decoder = NULL;
  } catch (const std::exception &e) {
    LOG_ERROR(std::string("ffmpeg_ram_free_decoder exception:") + e.what());
  } catch (...) {
    LOG_ERROR("ffmpeg_ram_free_decoder: unknown exception");
  }
}

extern "C" FFmpegRamDecoder *
ffmpeg_ram_new_decoder(const char *name, int device_type, int thread_count,
                       RamDecodeCallback callback) {
  FFmpegRamDecoder *decoder = NULL;
  try {
    decoder = new FFmpegRamDecoder(name, device_type, thread_count, callback);
    if (decoder) {
      if (decoder->reset() == 0) {
        return decoder;
      }
    }
  } catch (std::exception &e) {
    LOG_ERROR(std::string("new decoder exception:") + e.what());
  } catch (...) {
    LOG_ERROR("ffmpeg_ram_new_decoder: unknown exception");
  }
  if (decoder) {
    decoder->free_decoder();
    delete decoder;
    decoder = NULL;
  }
  return NULL;
}

extern "C" int ffmpeg_ram_decode(FFmpegRamDecoder *decoder, const uint8_t *data,
                                 int length, const void *obj) {
  try {
    int ret = decoder->decode(data, length, obj, false);
    if (DataFormat::H265 == decoder->data_format_ && util_decode::has_flag_could_not_find_ref_with_poc()) {
      return HWCODEC_ERR_HEVC_COULD_NOT_FIND_POC;
    } else {
      return ret == 0 ? HWCODEC_SUCCESS : HWCODEC_ERR_COMMON;
    }
  } catch (const std::exception &e) {
    LOG_ERROR(std::string("ffmpeg_ram_decode exception:") + e.what());
  } catch (...) {
    LOG_ERROR("ffmpeg_ram_decode: unknown exception");
  }
  return HWCODEC_ERR_COMMON;
}
