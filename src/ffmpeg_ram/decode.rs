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
    sync::atomic::{AtomicBool, Ordering},
    time::Instant,
    vec,
};

/// Whether decoded GPU frames should be taken over by the renderer.
///
/// The C++ decoder only skips its software transfer when the pixel buffer
/// callback accepts the frame *during* the decode call, so the decision has to
/// be reachable from here rather than after the fact: a frame that is accepted
/// and then dropped on the Rust side would leave the renderer with nothing to
/// paint and freeze the picture.  The app turns this off when it cannot present
/// GPU frames (texture render off, direct path disabled, or the loaded plugin
/// has no entry point), and then decode behaves exactly like the software path.
#[cfg(target_os = "macos")]
static PIXELBUFFER_WANTED: AtomicBool = AtomicBool::new(true);

/// Ask the decoder to hand out GPU frames (or stop doing so).
///
/// Takes effect on the next decoded frame; safe to call from any thread.
#[cfg(target_os = "macos")]
pub fn set_pixelbuffer_wanted(wanted: bool) {
    PIXELBUFFER_WANTED.store(wanted, Ordering::Relaxed);
}

/// Current value of [`set_pixelbuffer_wanted`].
#[cfg(target_os = "macos")]
pub fn pixelbuffer_wanted() -> bool {
    PIXELBUFFER_WANTED.load(Ordering::Relaxed)
}

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

/// Per-decode output state. Also the `obj` handed to both the software
/// callback and the pixel-buffer callback, so they share one transaction view:
/// a software frame clears the pending GPU frame of the same call, which makes
/// "last decoded frame wins" hold across mixed frames.
pub struct DecodeOutput {
    frames: Vec<DecodeFrame>,
    #[cfg(target_os = "macos")]
    pixelbuffer: Option<PixelBufferFrame>,
}

impl DecodeOutput {
    fn new() -> Self {
        Self {
            frames: vec![],
            #[cfg(target_os = "macos")]
            pixelbuffer: None,
        }
    }

    fn clear(&mut self) {
        self.frames.clear();
        // Transaction boundary: never answer with a frame from a previous call.
        #[cfg(target_os = "macos")]
        {
            self.pixelbuffer = None;
        }
    }
}

pub struct Decoder {
    codec: *mut c_void,
    output: *mut DecodeOutput,
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
                output: Box::into_raw(Box::new(DecodeOutput::new())),
                ctx,
            })
        }
    }

    pub fn decode(&mut self, packet: &[u8]) -> Result<&mut Vec<DecodeFrame>, i32> {
        unsafe {
            let output = &mut *self.output;
            output.clear();
            let ret = ffmpeg_ram_decode(
                self.codec,
                packet.as_ptr(),
                packet.len() as c_int,
                self.output as *const _ as *const c_void,
            );

            if ret < 0 {
                Err(ret)
            } else {
                Ok(&mut output.frames)
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
        let output = &mut *(obj as *mut DecodeOutput);
        let datas = from_raw_parts(datas, AV_NUM_DATA_POINTERS as _);
        let linesizes = from_raw_parts(linesizes, AV_NUM_DATA_POINTERS as _);

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

            // A software frame wins over a GPU frame of the same transaction.
            #[cfg(target_os = "macos")]
            {
                output.pixelbuffer = None;
            }
            output.frames.push(frame);
        } else if pixfmt == AVPixelFormat::AV_PIX_FMT_NV12 as c_int {
            let y = from_raw_parts(datas[0], (linesizes[0] * height) as usize).to_vec();
            let uv = from_raw_parts(datas[1], (linesizes[1] * height / 2) as usize).to_vec();

            frame.data.push(y);
            frame.data.push(uv);

            frame.linesize.push(linesizes[0]);
            frame.linesize.push(linesizes[1]);

            // A software frame wins over a GPU frame of the same transaction.
            #[cfg(target_os = "macos")]
            {
                output.pixelbuffer = None;
            }
            output.frames.push(frame);
        } else {
            error!("unsupported pixfmt {}", pixfmt as i32);
        }
    }

    /// The software frames produced by the last `decode()` call.
    ///
    /// Use this instead of the `decode()` return value when the caller must
    /// also read [`Self::take_pixelbuffer`]: `decode()` returns a mutable borrow
    /// of the decoder, so the two cannot overlap.
    pub fn last_frames(&self) -> &[DecodeFrame] {
        unsafe { &(*self.output).frames }
    }

    /// Take the GPU frame delivered to this decode call, if any.
    ///
    /// `None` means this call produced no direct frame: either the decoder
    /// rejected it, the format is not directly deliverable, or a software frame
    /// won in the same transaction. The caller must not fall back to a frame
    /// from a previous call.
    #[cfg(target_os = "macos")]
    pub fn take_pixelbuffer(&mut self) -> Option<PixelBufferFrame> {
        unsafe { (&mut *self.output).pixelbuffer.take() }
    }

    #[cfg(target_os = "macos")]
    pub fn has_pixelbuffer(&self) -> bool {
        unsafe { (&*self.output).pixelbuffer.is_some() }
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
        // Rejecting here is what makes the C++ side fall back to its software
        // transfer on this very frame, so the renderer never has a frame taken
        // away from it.
        if !pixelbuffer_wanted() {
            return PIXELBUFFER_REJECTED;
        }
        let frame = &*frame;
        if !is_direct_deliverable(frame.pixfmt) || frame.pixel_buffer.is_null() {
            return PIXELBUFFER_REJECTED;
        }
        let output = &mut *(obj as *mut DecodeOutput);
        match PixelBufferFrame::retain_from_borrowed(frame) {
            Some(pixelbuffer) => {
                output.pixelbuffer = Some(pixelbuffer);
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
            // output state, so freeing it below cannot race a decode.
            #[cfg(target_os = "macos")]
            ffmpeg_ram_set_pixelbuffer_callback(self.codec, None);
            ffmpeg_ram_free_decoder(self.codec);
            self.codec = std::ptr::null_mut();
            let _ = Box::from_raw(self.output);
        }
    }
}

/// Transaction-ordering tests for the GPU-frame path.
///
/// These drive both callbacks directly, so they need no decoder, no bitstream
/// and no GPU: they pin the state machine only ("does this decode call end up
/// with the last decoded frame, and exactly one delivery"). The per-iteration
/// reset inside `do_decode()` still requires a real VideoToolbox decode and is
/// verified on hardware, not here.
#[cfg(all(test, target_os = "macos"))]
mod output_tests {
    use super::*;
    use crate::ffmpeg_ram::pixelbuffer::test_support::{create_buffer, release_buffer};

    const W: i32 = 16;
    const H: i32 = 16;

    /// Push one software (NV12) frame through the real callback.
    fn software_frame(output: &mut DecodeOutput) {
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
                output as *mut _ as *const c_void,
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
    fn direct_frame(output: &mut DecodeOutput, pixfmt: u32, raw: *mut c_void) -> c_int {
        let frame = FfiPixelBufferFrame {
            pixel_buffer: raw,
            width: W,
            height: H,
            pixfmt,
        };
        unsafe { Decoder::pixelbuffer_callback(output as *mut _ as *mut c_void, &frame) }
    }

    #[test]
    fn software_then_direct_keeps_the_gpu_frame() {
        let Some(raw) = create_buffer(crate::ffmpeg_ram::pixelbuffer::PIXEL_FORMAT_420F) else {
            eprintln!("skip: CVPixelBufferCreate failed in this environment");
            return;
        };
        let mut output = DecodeOutput::new();
        software_frame(&mut output);
        assert_eq!(output.frames.len(), 1);
        assert!(output.pixelbuffer.is_none());

        assert_eq!(
            direct_frame(
                &mut output,
                crate::ffmpeg_ram::pixelbuffer::PIXEL_FORMAT_420F,
                raw
            ),
            PIXELBUFFER_ACCEPTED
        );
        // The GPU frame arrived last, so it is the output of this call.
        assert!(output.pixelbuffer.is_some());
        assert_eq!(output.frames.len(), 1, "software frames are not cleared by a GPU frame");

        output.clear();
        assert!(output.pixelbuffer.is_none());
        assert!(output.frames.is_empty());
        release_buffer(raw);
    }

    #[test]
    fn direct_then_software_clears_the_pending_gpu_frame() {
        let Some(raw) = create_buffer(crate::ffmpeg_ram::pixelbuffer::PIXEL_FORMAT_420V) else {
            eprintln!("skip: CVPixelBufferCreate failed in this environment");
            return;
        };
        let mut output = DecodeOutput::new();
        assert_eq!(
            direct_frame(
                &mut output,
                crate::ffmpeg_ram::pixelbuffer::PIXEL_FORMAT_420V,
                raw
            ),
            PIXELBUFFER_ACCEPTED
        );
        assert!(output.pixelbuffer.is_some());

        software_frame(&mut output);
        // A software frame wins in the same transaction: no stale GPU frame may
        // survive, otherwise the renderer would show the previous one.
        assert!(output.pixelbuffer.is_none());
        assert_eq!(output.frames.len(), 1);
        release_buffer(raw);
    }

    #[test]
    fn unsupported_format_is_rejected() {
        // 32BGRA: a real buffer, but not directly deliverable.
        let Some(raw) = create_buffer(0x4247_5241) else {
            eprintln!("skip: CVPixelBufferCreate failed in this environment");
            return;
        };
        let mut output = DecodeOutput::new();
        assert_eq!(direct_frame(&mut output, 0x4247_5241, raw), PIXELBUFFER_REJECTED);
        assert!(output.pixelbuffer.is_none(), "a rejected frame must retain nothing");
        release_buffer(raw);
    }

    #[test]
    fn null_descriptor_is_rejected() {
        let mut output = DecodeOutput::new();
        assert_eq!(
            direct_frame(
                &mut output,
                crate::ffmpeg_ram::pixelbuffer::PIXEL_FORMAT_420F,
                std::ptr::null_mut()
            ),
            PIXELBUFFER_REJECTED
        );
        assert!(output.pixelbuffer.is_none());

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
    fn clear_drops_the_pending_frame_of_the_previous_call() {
        let Some(raw) = create_buffer(crate::ffmpeg_ram::pixelbuffer::PIXEL_FORMAT_420F) else {
            eprintln!("skip: CVPixelBufferCreate failed in this environment");
            return;
        };
        let mut output = DecodeOutput::new();
        assert_eq!(
            direct_frame(
                &mut output,
                crate::ffmpeg_ram::pixelbuffer::PIXEL_FORMAT_420F,
                raw
            ),
            PIXELBUFFER_ACCEPTED
        );
        assert!(output.pixelbuffer.is_some());
        output.clear();
        // The next call must not answer with this frame.
        assert!(output.pixelbuffer.is_none());
        release_buffer(raw);
    }
}
