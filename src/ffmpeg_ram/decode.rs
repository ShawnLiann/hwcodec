#[cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))]
use super::Priority;
use crate::common::TEST_TIMEOUT_MS;
use crate::ffmpeg::{init_av_log, AVHWDeviceType::*};

#[cfg(target_os = "macos")]
use crate::ffmpeg_ram::{
    ffmpeg_ram_set_pixelbuffer_callback,
    pixelbuffer::{
        is_direct_deliverable, PixelBufferFrame, PIXELBUFFER_ACCEPTED, PIXELBUFFER_REJECTED,
    },
    FfiPixelBufferFrame,
};
use crate::{
    common::DataFormat::*,
    ffmpeg::{AVHWDeviceType, AVPixelFormat},
    ffmpeg_ram::{
        ffmpeg_ram_decode, ffmpeg_ram_free_decoder, ffmpeg_ram_new_decoder, CodecInfo,
        AV_NUM_DATA_POINTERS,
    },
};
use log::error;
use std::{
    ffi::{c_void, CString},
    os::raw::c_int,
    slice::from_raw_parts,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Instant,
    vec,
};

#[derive(Debug, Clone)]
pub struct DecodeContext {
    pub name: String,
    pub device_type: AVHWDeviceType,
    pub thread_count: i32,
}

pub struct DecodeFrame {
    pub pixfmt: AVPixelFormat,
    pub width: i32,
    pub height: i32,
    pub data: Vec<Vec<u8>>,
    pub linesize: Vec<i32>,
    pub key: bool,
}

impl std::fmt::Display for DecodeFrame {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut s = String::from("data:");
        for data in self.data.iter() {
            s.push_str(format!("{} ", data.len()).as_str());
        }
        s.push_str(", linesize:");
        for linesize in self.linesize.iter() {
            s.push_str(format!("{} ", linesize).as_str());
        }

        write!(
            f,
            "fixfmt:{}, width:{}, height:{},key:{}, {}",
            self.pixfmt as i32, self.width, self.height, self.key, s,
        )
    }
}

/// Everything one `decode()` call produced.
///
/// Returned by value, so the caller owns the frames and the pixel buffer: there
/// is no shared context object parked on the decoder, and no window in which a
/// previous call's output can still be read.
pub struct DecodedFrames {
    pub frames: Vec<DecodeFrame>,
    #[cfg(target_os = "macos")]
    pub pixelbuffer: Option<PixelBufferFrame>,
}

/// The `obj` pointer the C decoder sees for the duration of one call.
///
/// It is created inside `decode()`, lives on that call's stack and dies with it:
/// the C side may use it inside a callback and must never retain it. That is the
/// whole lifetime contract, and it is why the two callbacks no longer share a
/// long-lived allocation.
struct DecodeCall<'a> {
    frames: Vec<DecodeFrame>,
    #[cfg(target_os = "macos")]
    pixelbuffer: Option<PixelBufferFrame>,
    /// Borrow of the decoder's own "can you present GPU frames" flag, so the
    /// answer can change between calls -- or between frames -- without the
    /// caller touching the decoder.
    ///
    /// `None` means the caller never asked for GPU frames, and the callback then
    /// rejects every frame: delivery is opt-in, because accepting one makes the
    /// decoder skip the software transfer for that frame.
    ///
    /// Present on every platform so the struct keeps one shape; only the macOS
    /// pixel-buffer callback reads it.
    #[allow(dead_code)]
    wanted: Option<&'a AtomicBool>,
}

impl<'a> DecodeCall<'a> {
    fn new(wanted: Option<&'a AtomicBool>) -> Self {
        Self {
            frames: vec![],
            #[cfg(target_os = "macos")]
            pixelbuffer: None,
            wanted,
        }
    }

    fn finish(self) -> DecodedFrames {
        DecodedFrames {
            frames: self.frames,
            #[cfg(target_os = "macos")]
            pixelbuffer: self.pixelbuffer,
        }
    }

    /// A software frame wins over a GPU frame of the same call: the caller must
    /// not present an older surface over the frame it just decoded.
    fn software_frame_wins(&mut self) {
        #[cfg(target_os = "macos")]
        {
            self.pixelbuffer = None;
        }
    }
}

pub struct Decoder {
    codec: *mut c_void,
    /// The caller's switch, kept here instead of in a shared output object; each
    /// decode call borrows it for the length of that call.
    #[cfg(target_os = "macos")]
    pixelbuffer_wanted: Option<Arc<AtomicBool>>,
    pub ctx: DecodeContext,
}

unsafe impl Send for Decoder {}
unsafe impl Sync for Decoder {}

impl Decoder {
    pub fn new(ctx: DecodeContext) -> Result<Self, ()> {
        init_av_log();
        unsafe {
            let codec = ffmpeg_ram_new_decoder(
                CString::new(ctx.name.as_str()).map_err(|_| ())?.as_ptr(),
                ctx.device_type as _,
                ctx.thread_count,
                Some(Decoder::callback),
            );

            if codec.is_null() {
                return Err(());
            }

            #[cfg(target_os = "macos")]
            ffmpeg_ram_set_pixelbuffer_callback(codec, Some(Decoder::pixelbuffer_callback));

            Ok(Decoder {
                codec,
                #[cfg(target_os = "macos")]
                pixelbuffer_wanted: None,
                ctx,
            })
        }
    }

    /// Decode one packet. The returned [`DecodedFrames`] belongs to the caller:
    /// this call drops every reference to it before returning, so nothing from
    /// this call can be read once the value is gone.
    ///
    /// `obj` is this call's stack context. The C side calls the callbacks
    /// synchronously while `ffmpeg_ram_decode` runs, so no reference derived from
    /// it outlives the call; the callbacks only borrow through the raw pointer
    /// for the length of a statement, which is why no `&mut` is kept alive across
    /// the FFI boundary.
    pub fn decode(&mut self, packet: &[u8]) -> Result<DecodedFrames, i32> {
        #[cfg(target_os = "macos")]
        let mut call = DecodeCall::new(self.pixelbuffer_wanted.as_deref());
        #[cfg(not(target_os = "macos"))]
        let mut call = DecodeCall::new(None);
        unsafe {
            let ret = ffmpeg_ram_decode(
                self.codec,
                packet.as_ptr(),
                packet.len() as c_int,
                &mut call as *mut DecodeCall as *mut c_void,
            );

            if ret < 0 {
                Err(ret)
            } else {
                Ok(call.finish())
            }
        }
    }

    unsafe extern "C" fn callback(
        obj: *const c_void,
        width: c_int,
        height: c_int,
        pixfmt: c_int,
        linesizes: *mut c_int,
        datas: *mut *mut u8,
        key: c_int,
    ) {
        // A panic here aborts the process: the release profile is `panic = "abort"`,
        // so `catch_unwind` would be inert and this callback has to be non-panicking
        // by construction. That means validating every pointer and length the C side
        // hands over before building a slice from it -- `from_raw_parts` on a null
        // pointer, or on a negative linesize cast to usize, is undefined behaviour
        // rather than a panic, and no unwinding story would catch it either.
        if obj.is_null() || datas.is_null() || linesizes.is_null() {
            error!("decode callback got a null object or plane array");
            return;
        }
        if width <= 0 || height <= 0 {
            error!(
                "decode callback got a non-positive frame size {}x{}",
                width, height
            );
            return;
        }

        let call = &mut *(obj as *mut DecodeCall);
        let datas = from_raw_parts(datas, AV_NUM_DATA_POINTERS as _);
        let linesizes = from_raw_parts(linesizes, AV_NUM_DATA_POINTERS as _);

        // Every plane this format reads is dereferenced below, so validate the
        // pointer and the stride first: a null plane or a non-positive stride is a
        // producer bug, and dropping the frame beats reading unmapped memory.
        let planes = if pixfmt == AVPixelFormat::AV_PIX_FMT_YUV420P as c_int {
            3
        } else if pixfmt == AVPixelFormat::AV_PIX_FMT_NV12 as c_int {
            2
        } else {
            0
        };
        for i in 0..planes {
            if datas[i].is_null() {
                error!("decode callback got a null plane {}", i);
                return;
            }
            if linesizes[i] <= 0 {
                error!(
                    "decode callback got a non-positive linesize {} on plane {}",
                    linesizes[i], i
                );
                return;
            }
        }

        let mut frame = DecodeFrame {
            pixfmt: std::mem::transmute(pixfmt),
            width,
            height,
            data: vec![],
            linesize: vec![],
            key: key != 0,
        };

        if pixfmt == AVPixelFormat::AV_PIX_FMT_YUV420P as c_int {
            let y = from_raw_parts(datas[0], (linesizes[0] * height) as usize).to_vec();
            let u = from_raw_parts(datas[1], (linesizes[1] * height / 2) as usize).to_vec();
            let v = from_raw_parts(datas[2], (linesizes[2] * height / 2) as usize).to_vec();

            frame.data.push(y);
            frame.data.push(u);
            frame.data.push(v);

            frame.linesize.push(linesizes[0]);
            frame.linesize.push(linesizes[1]);
            frame.linesize.push(linesizes[2]);

            // A software frame wins over a GPU frame of the same call.
            call.software_frame_wins();
            call.frames.push(frame);
        } else if pixfmt == AVPixelFormat::AV_PIX_FMT_NV12 as c_int {
            let y = from_raw_parts(datas[0], (linesizes[0] * height) as usize).to_vec();
            let uv = from_raw_parts(datas[1], (linesizes[1] * height / 2) as usize).to_vec();

            frame.data.push(y);
            frame.data.push(uv);

            frame.linesize.push(linesizes[0]);
            frame.linesize.push(linesizes[1]);

            // A software frame wins over a GPU frame of the same call.
            call.software_frame_wins();
            call.frames.push(frame);
        } else {
            error!("unsupported pixfmt {}", pixfmt as i32);
        }
    }

    /// Share the caller's "can you present GPU frames" flag with this decoder.
    ///
    /// The C++ decoder only skips its software transfer when the pixel buffer
    /// callback accepts a frame *during* the decode call, so the decision has to
    /// be taken there rather than after the fact: a frame accepted here and
    /// dropped further up leaves the renderer with neither a GPU frame nor a
    /// software one.  Rejecting here makes the decoder fall back to the software
    /// transfer on that very frame.
    ///
    /// Taking the flag by reference (instead of a plain bool) means the caller
    /// can flip it at any time, e.g. when the user switches the render path, and
    /// the change applies from the next decoded frame.
    #[cfg(target_os = "macos")]
    pub fn set_pixelbuffer_wanted(&mut self, wanted: Arc<AtomicBool>) {
        self.pixelbuffer_wanted = Some(wanted);
    }

    /// Borrowed-descriptor callback from the decoder.
    ///
    /// Accepting means "retained and stored"; rejecting means "nothing kept",
    /// so the decoder delivers the same decoded frame through the software
    /// path. This must never panic: a panic across the FFI boundary aborts the
    /// process in release builds (`panic = "abort"`).
    #[cfg(target_os = "macos")]
    unsafe extern "C" fn pixelbuffer_callback(
        obj: *mut c_void,
        frame: *const FfiPixelBufferFrame,
    ) -> c_int {
        if obj.is_null() || frame.is_null() {
            return PIXELBUFFER_REJECTED;
        }
        let call = &mut *(obj as *mut DecodeCall);
        // Rejecting here is what makes the C++ side fall back to its software
        // transfer on this very frame, so the renderer never has a frame taken
        // away from it.
        //
        // Delivery is opt-in: a decoder the caller never configured keeps
        // producing software frames, exactly like before this API existed.
        let Some(wanted) = call.wanted else {
            return PIXELBUFFER_REJECTED;
        };
        if !wanted.load(Ordering::Relaxed) {
            return PIXELBUFFER_REJECTED;
        }
        let frame = &*frame;
        if !is_direct_deliverable(frame.pixfmt) || frame.pixel_buffer.is_null() {
            return PIXELBUFFER_REJECTED;
        }
        match PixelBufferFrame::retain_from_borrowed(frame) {
            Some(pixelbuffer) => {
                call.pixelbuffer = Some(pixelbuffer);
                PIXELBUFFER_ACCEPTED
            }
            None => PIXELBUFFER_REJECTED,
        }
    }

    pub fn available_decoders() -> Vec<CodecInfo> {
        use log::debug;

        #[allow(unused_mut)]
        let mut codecs: Vec<CodecInfo> = vec![];
        // windows disable nvdec to avoid gpu stuck
        #[cfg(target_os = "linux")]
        {
            let (nv, _, _) = crate::common::supported_gpu(false);
            debug!("Linux GPU support detected - NV: {}", nv);
            if nv {
                codecs.push(CodecInfo {
                    name: "h264".to_owned(),
                    format: H264,
                    hwdevice: AV_HWDEVICE_TYPE_CUDA,
                    priority: Priority::Good as _,
                    ..Default::default()
                });
                codecs.push(CodecInfo {
                    name: "hevc".to_owned(),
                    format: H265,
                    hwdevice: AV_HWDEVICE_TYPE_CUDA,
                    priority: Priority::Good as _,
                    ..Default::default()
                });
            }
        }

        #[cfg(target_os = "windows")]
        {
            codecs.append(&mut vec![
                CodecInfo {
                    name: "h264".to_owned(),
                    format: H264,
                    hwdevice: AV_HWDEVICE_TYPE_D3D11VA,
                    priority: Priority::Best as _,
                    ..Default::default()
                },
                CodecInfo {
                    name: "hevc".to_owned(),
                    format: H265,
                    hwdevice: AV_HWDEVICE_TYPE_D3D11VA,
                    priority: Priority::Best as _,
                    ..Default::default()
                },
            ]);
        }

        #[cfg(target_os = "linux")]
        {
            codecs.append(&mut vec![
                CodecInfo {
                    name: "h264".to_owned(),
                    format: H264,
                    hwdevice: AV_HWDEVICE_TYPE_VAAPI,
                    priority: Priority::Good as _,
                    ..Default::default()
                },
                CodecInfo {
                    name: "hevc".to_owned(),
                    format: H265,
                    hwdevice: AV_HWDEVICE_TYPE_VAAPI,
                    priority: Priority::Good as _,
                    ..Default::default()
                },
            ]);
        }

        #[cfg(target_os = "macos")]
        {
            let (_, _, h264, h265) = crate::common::get_video_toolbox_codec_support();
            debug!(
                "VideoToolbox decode support - H264: {}, H265: {}",
                h264, h265
            );
            if h264 {
                codecs.push(CodecInfo {
                    name: "h264".to_owned(),
                    format: H264,
                    hwdevice: AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                    priority: Priority::Best as _,
                    ..Default::default()
                });
            }
            if h265 {
                codecs.push(CodecInfo {
                    name: "hevc".to_owned(),
                    format: H265,
                    hwdevice: AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                    priority: Priority::Best as _,
                    ..Default::default()
                });
            }
        }

        let mut res = Vec::<CodecInfo>::new();
        let buf264 = &crate::common::DATA_H264_720P[..];
        let buf265 = &crate::common::DATA_H265_720P[..];

        for codec in codecs {
            // Skip if this format already exists in results
            if res
                .iter()
                .any(|existing: &CodecInfo| existing.format == codec.format)
            {
                continue;
            }

            debug!(
                "Testing decoder: {} (hwdevice: {:?})",
                codec.name, codec.hwdevice
            );

            let c = DecodeContext {
                name: codec.name.clone(),
                device_type: codec.hwdevice,
                thread_count: 4,
            };

            match Decoder::new(c) {
                Ok(mut decoder) => {
                    debug!("Decoder {} created successfully", codec.name);
                    let data = match codec.format {
                        H264 => buf264,
                        H265 => buf265,
                        _ => {
                            log::error!("Unsupported format: {:?}, skipping", codec.format);
                            continue;
                        }
                    };

                    let start = Instant::now();

                    match decoder.decode(data) {
                        Ok(_) => {
                            let elapsed = start.elapsed().as_millis();

                            if elapsed < TEST_TIMEOUT_MS as _ {
                                debug!("Decoder {} test passed", codec.name);
                                res.push(codec);
                            } else {
                                debug!(
                                    "Decoder {} test failed - timeout: {}ms",
                                    codec.name, elapsed
                                );
                            }
                        }
                        Err(err) => {
                            debug!("Decoder {} test failed with error: {}", codec.name, err);
                        }
                    }
                }
                Err(_) => {
                    debug!("Failed to create decoder {}", codec.name);
                }
            }
        }

        let soft = CodecInfo::soft();
        if let Some(c) = soft.h264 {
            res.push(c);
        }
        if let Some(c) = soft.h265 {
            res.push(c);
        }

        res
    }
}

impl Drop for Decoder {
    fn drop(&mut self) {
        unsafe {
            // Remove the callback first: after this no callback can reach the
            // decoder, so freeing it below cannot race a decode. No per-call
            // state to free any more -- each decode call owns its own output.
            #[cfg(target_os = "macos")]
            ffmpeg_ram_set_pixelbuffer_callback(self.codec, None);
            ffmpeg_ram_free_decoder(self.codec);
            self.codec = std::ptr::null_mut();
        }
    }
}

/// Transaction-ordering tests for the GPU-frame path.
///
/// These drive both callbacks directly, so they need no decoder, no bitstream
/// and no GPU: they pin the state machine only ("does one decode call end up
/// with the last decoded frame, and exactly one delivery"). Each call's output
/// is a plain value, so "the previous call cannot be read" is a type-level fact
/// here and only the ordering still needs a test.
#[cfg(all(test, target_os = "macos"))]
mod output_tests {
    use super::*;
    use crate::ffmpeg_ram::pixelbuffer::test_support::{create_buffer, release_buffer};

    const W: i32 = 16;
    const H: i32 = 16;

    /// Push one software (NV12) frame through the real callback.
    fn software_frame(call: &mut DecodeCall<'_>) {
        let mut y = vec![0u8; (W * H) as usize];
        let mut uv = vec![0u8; (W * H / 2) as usize];
        let mut linesizes = [0 as c_int; AV_NUM_DATA_POINTERS as _];
        linesizes[0] = W;
        linesizes[1] = W;
        let mut datas = [std::ptr::null_mut::<u8>(); AV_NUM_DATA_POINTERS as _];
        datas[0] = y.as_mut_ptr();
        datas[1] = uv.as_mut_ptr();
        unsafe {
            Decoder::callback(
                call as *mut _ as *const c_void,
                W,
                H,
                AVPixelFormat::AV_PIX_FMT_NV12 as c_int,
                linesizes.as_mut_ptr(),
                datas.as_mut_ptr(),
                1,
            )
        };
    }

    /// Deliver one GPU frame through the real callback; returns its verdict.
    fn direct_frame(call: &mut DecodeCall<'_>, pixfmt: u32, raw: *mut c_void) -> c_int {
        let frame = FfiPixelBufferFrame {
            pixel_buffer: raw,
            width: W,
            height: H,
            pixfmt,
        };
        unsafe { Decoder::pixelbuffer_callback(call as *mut _ as *mut c_void, &frame) }
    }

    #[test]
    fn unconfigured_decoder_rejects_gpu_frames() {
        // Opt-in: a decoder the caller never configured must keep producing
        // software frames, so it must refuse the surface even when it could
        // deliver it. This is the regression that a Cargo.lock bump would
        // otherwise push into every consumer.
        let Some(raw) = create_buffer(crate::ffmpeg_ram::pixelbuffer::PIXEL_FORMAT_420F) else {
            eprintln!("skip: CVPixelBufferCreate failed in this environment");
            return;
        };
        let mut call = DecodeCall::new(None);
        assert!(
            call.wanted.is_none(),
            "a decoder without a caller flag must not want GPU frames"
        );
        assert_eq!(
            direct_frame(
                &mut call,
                crate::ffmpeg_ram::pixelbuffer::PIXEL_FORMAT_420F,
                raw
            ),
            PIXELBUFFER_REJECTED
        );
        assert!(
            call.pixelbuffer.is_none(),
            "a rejected frame must retain nothing"
        );

        // ... and it accepts once the caller says it can present them.
        let wanted = AtomicBool::new(true);
        let mut call = DecodeCall::new(Some(&wanted));
        assert_eq!(
            direct_frame(
                &mut call,
                crate::ffmpeg_ram::pixelbuffer::PIXEL_FORMAT_420F,
                raw
            ),
            PIXELBUFFER_ACCEPTED
        );
        assert!(call.pixelbuffer.is_some());
        release_buffer(raw);
    }

    #[test]
    fn software_then_direct_keeps_the_gpu_frame() {
        let Some(raw) = create_buffer(crate::ffmpeg_ram::pixelbuffer::PIXEL_FORMAT_420F) else {
            eprintln!("skip: CVPixelBufferCreate failed in this environment");
            return;
        };
        let wanted = AtomicBool::new(true);
        let mut call = DecodeCall::new(Some(&wanted));
        software_frame(&mut call);
        assert_eq!(call.frames.len(), 1);
        assert!(call.pixelbuffer.is_none());

        assert_eq!(
            direct_frame(
                &mut call,
                crate::ffmpeg_ram::pixelbuffer::PIXEL_FORMAT_420F,
                raw
            ),
            PIXELBUFFER_ACCEPTED
        );
        // The GPU frame arrived last, so it is the output of this call.
        assert!(call.pixelbuffer.is_some());
        assert_eq!(
            call.frames.len(),
            1,
            "software frames are not cleared by a GPU frame"
        );
        release_buffer(raw);
    }

    #[test]
    fn direct_then_software_clears_the_pending_gpu_frame() {
        let Some(raw) = create_buffer(crate::ffmpeg_ram::pixelbuffer::PIXEL_FORMAT_420V) else {
            eprintln!("skip: CVPixelBufferCreate failed in this environment");
            return;
        };
        let wanted = AtomicBool::new(true);
        let mut call = DecodeCall::new(Some(&wanted));
        assert_eq!(
            direct_frame(
                &mut call,
                crate::ffmpeg_ram::pixelbuffer::PIXEL_FORMAT_420V,
                raw
            ),
            PIXELBUFFER_ACCEPTED
        );
        assert!(call.pixelbuffer.is_some());

        software_frame(&mut call);
        // A software frame wins in the same call: no stale GPU frame may
        // survive, otherwise the renderer would show the previous one.
        assert!(call.pixelbuffer.is_none());
        assert_eq!(call.frames.len(), 1);
        release_buffer(raw);
    }

    #[test]
    fn unsupported_format_is_rejected() {
        // 32BGRA: a real buffer, but not directly deliverable.
        let Some(raw) = create_buffer(0x4247_5241) else {
            eprintln!("skip: CVPixelBufferCreate failed in this environment");
            return;
        };
        let wanted = AtomicBool::new(true);
        let mut call = DecodeCall::new(Some(&wanted));
        assert_eq!(
            direct_frame(&mut call, 0x4247_5241, raw),
            PIXELBUFFER_REJECTED
        );
        assert!(
            call.pixelbuffer.is_none(),
            "a rejected frame must retain nothing"
        );
        release_buffer(raw);
    }

    #[test]
    fn null_descriptor_is_rejected() {
        let wanted = AtomicBool::new(true);
        let mut call = DecodeCall::new(Some(&wanted));
        assert_eq!(
            direct_frame(
                &mut call,
                crate::ffmpeg_ram::pixelbuffer::PIXEL_FORMAT_420F,
                std::ptr::null_mut()
            ),
            PIXELBUFFER_REJECTED
        );
        assert!(call.pixelbuffer.is_none());

        // A null obj must be rejected as well, not dereferenced.
        let frame = FfiPixelBufferFrame {
            pixel_buffer: std::ptr::null_mut(),
            width: 0,
            height: 0,
            pixfmt: 0,
        };
        assert_eq!(
            unsafe { Decoder::pixelbuffer_callback(std::ptr::null_mut(), &frame) },
            PIXELBUFFER_REJECTED
        );
    }

    #[test]
    fn a_new_call_never_carries_the_previous_frame() {
        let Some(raw) = create_buffer(crate::ffmpeg_ram::pixelbuffer::PIXEL_FORMAT_420F) else {
            eprintln!("skip: CVPixelBufferCreate failed in this environment");
            return;
        };
        let wanted = AtomicBool::new(true);
        let mut first = DecodeCall::new(Some(&wanted));
        assert_eq!(
            direct_frame(
                &mut first,
                crate::ffmpeg_ram::pixelbuffer::PIXEL_FORMAT_420F,
                raw
            ),
            PIXELBUFFER_ACCEPTED
        );
        assert!(first.pixelbuffer.is_some());

        // The next call starts empty by construction: there is no slot left on
        // the decoder to answer from.
        let second = DecodeCall::new(Some(&wanted));
        assert!(second.pixelbuffer.is_none());
        assert!(second.frames.is_empty());
        release_buffer(raw);
    }
}
