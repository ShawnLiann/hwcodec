//! macOS encode entry that accepts a CVPixelBuffer directly.
//!
//! `vt_pixbuf_encode.mm` holds the VideoToolbox session; this file is the Rust side that
//! hwcodec's encoder calls when the frame arrived as a pixel buffer instead of a RAM slice.
//!
//! NOT COMPILED YET: this machine has no vcpkg/ffmpeg, so `hwcodec` cannot build here at all.
//! The C++ half was compiled and smoke-tested standalone (60 frames, 4K, keyframe emitted,
//! 0.31 ms/frame of submit CPU); the Rust half needs the first CI build to be validated.
//!
//! Wiring (see ENCODE-ZEROCOPY-DESIGN-20261030.md):
//!   1. build.rs: on macOS add `vt_pixbuf_encode.mm` to the cc::Build that already compiles the
//!      ffmpeg_ram sources, and `cargo:rustc-link-lib=framework=VideoToolbox` / `CoreVideo`.
//!   2. encode.rs: add `EncodeInput::PixelBuffer(*mut c_void, i32, i32)` next to YUV/RGB, and in
//!      `Encoder::encode_to_vec` short-circuit to `VTEncoder::encode` when the variant is present.
//!   3. scrap/video_service: hand over the captured IOSurface as a CVPixelBuffer and skip
//!      `frame.to(encoder.yuvfmt(), ...)`.

use crate::common::DataFormat;
use std::{
    ffi::c_void,
    fmt::{Display, Formatter},
    os::raw::c_int,
    sync::{Arc, Mutex},
};

#[repr(C)]
pub struct VTPixbufEncoder {
    _private: [u8; 0],
}

type RawCallback = unsafe extern "C" fn(*const u8, c_int, i64, c_int, *const c_void);

extern "C" {
    fn vt_pixbuf_new(
        width: c_int,
        height: c_int,
        codec: c_int,
        fps: c_int,
        kbps: c_int,
        gop: c_int,
        cb: Option<RawCallback>,
        obj: *const c_void,
    ) -> *mut VTPixbufEncoder;
    fn vt_pixbuf_encode(enc: *mut VTPixbufEncoder, cvpixelbuffer: *mut c_void, pts: i64) -> c_int;
    fn vt_pixbuf_flush(enc: *mut VTPixbufEncoder);
    fn vt_pixbuf_free(enc: *mut VTPixbufEncoder);
}

pub struct Frame {
    pub data: Vec<u8>,
    pub pts: i64,
    pub key: bool,
}

struct Sink {
    frames: Mutex<Vec<Frame>>,
}

unsafe extern "C" fn on_frame(data: *const u8, size: c_int, pts: i64, key: c_int, obj: *const c_void) {
    if obj.is_null() || data.is_null() || size <= 0 {
        return;
    }
    let sink = &*(obj as *const Sink);
    let slice = std::slice::from_raw_parts(data, size as usize);
    if let Ok(mut frames) = sink.frames.lock() {
        frames.push(Frame {
            data: slice.to_vec(),
            pts,
            key: key != 0,
        });
    }
}

/// One VideoToolbox session fed with BGRA pixel buffers. Dropping it flushes and releases.
pub struct VTEncoder {
    enc: *mut VTPixbufEncoder,
    sink: Arc<Sink>,
    width: i32,
    height: i32,
    format: DataFormat,
}

// The VT session is documented as safe to submit to from one thread at a time; hwcodec already
// serialises encoding per encoder instance.
unsafe impl Send for VTEncoder {}

impl VTEncoder {
    pub fn new(
        width: i32,
        height: i32,
        format: DataFormat,
        fps: i32,
        kbps: i32,
        gop: i32,
    ) -> Option<Self> {
        let sink = Arc::new(Sink {
            frames: Mutex::new(Vec::new()),
        });
        let codec = match format {
            DataFormat::H264 => 0,
            DataFormat::H265 => 1,
            _ => return None,
        };
        let enc = unsafe {
            vt_pixbuf_new(
                width,
                height,
                codec,
                fps,
                kbps,
                gop,
                Some(on_frame),
                Arc::as_ptr(&sink) as *const c_void,
            )
        };
        if enc.is_null() {
            return None;
        }
        Some(Self {
            enc,
            sink,
            width,
            height,
            format,
        })
    }

    /// `cvpixelbuffer` must be a BGRA `CVPixelBufferRef` (IOSurface-backed is fine, that is the
    /// point). The wrapper tags it BT.601 if it carries no matrix attachment.
    pub fn encode(
        &self,
        cvpixelbuffer: *mut c_void,
        pts_ms: i64,
    ) -> Result<Vec<Frame>, Box<dyn std::error::Error>> {
        let rc = unsafe { vt_pixbuf_encode(self.enc, cvpixelbuffer, pts_ms) };
        if rc != 0 {
            let e = format!("vt_pixbuf_encode rc={rc}");
            return Err(e.into());
        }
        self.drain()
    }

    pub fn flush(&self) -> Vec<Frame> {
        unsafe { vt_pixbuf_flush(self.enc) };
        self.drain().unwrap_or_default()
    }

    fn drain(&self) -> Result<Vec<Frame>, Box<dyn std::error::Error>> {
        let mut frames = self
            .sink
            .frames
            .lock()
            .map_err(|e| format!("frame sink poisoned: {e}"))?;
        let out: Vec<Frame> = frames.drain(..).collect();
        Ok(out)
    }
}

impl Display for VTEncoder {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "vt_pixbuf {}x{} {:?}",
            self.width, self.height, self.format
        )
    }
}

impl Drop for VTEncoder {
    fn drop(&mut self) {
        if !self.enc.is_null() {
            unsafe { vt_pixbuf_free(self.enc) };
            self.enc = std::ptr::null_mut();
        }
    }
}
