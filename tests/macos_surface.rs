//! One decode, one surface: the macOS VideoToolbox path exercised against a real
//! decoder, next to the software path it must not change.
//!
//! `cargo test --test macos_surface -- --nocapture` (macOS only).

#![cfg(target_os = "macos")]

use hwcodec::ffmpeg::AVHWDeviceType::{AV_HWDEVICE_TYPE_NONE, AV_HWDEVICE_TYPE_VIDEOTOOLBOX};
use hwcodec::ffmpeg_ram::decode::{DecodeContext, Decoder};
use std::ffi::c_void;

const H264_720P: &[u8] = include_bytes!("../src/res/720p.h264");

#[link(name = "CoreVideo", kind = "framework")]
extern "C" {
    fn CVPixelBufferGetWidth(pixelbuffer: *mut c_void) -> usize;
    fn CVPixelBufferGetHeight(pixelbuffer: *mut c_void) -> usize;
    fn CVPixelBufferGetIOSurface(pixelbuffer: *mut c_void) -> *mut c_void;
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFRetain(cf: *const c_void) -> *const c_void;
    fn CFRelease(cf: *const c_void);
}

fn context(device_type: hwcodec::ffmpeg::AVHWDeviceType) -> DecodeContext {
    DecodeContext {
        name: "h264".to_owned(),
        device_type,
        thread_count: 4,
    }
}

fn surface_decoder() -> Decoder {
    Decoder::new(context(AV_HWDEVICE_TYPE_VIDEOTOOLBOX)).expect("videotoolbox h264 decoder")
}

#[test]
fn surface_decode_hands_out_the_decoded_pixelbuffer() {
    let mut decoder = surface_decoder();
    let pixelbuffer = decoder
        .decode_surface(H264_720P)
        .expect("the surface path has to hand out a CVPixelBufferRef");
    assert!(!pixelbuffer.is_null());

    unsafe {
        assert_eq!(CVPixelBufferGetWidth(pixelbuffer), 1280);
        assert_eq!(CVPixelBufferGetHeight(pixelbuffer), 720);
        // Mapping into a texture is the downstream step; it needs an
        // IOSurface-backed buffer, which the dimensions alone do not prove.
        assert!(!CVPixelBufferGetIOSurface(pixelbuffer).is_null());
    }

    // Borrowed: the surface is valid until the next decode, and the next
    // decode keeps handing out a surface of its own.
    let second = decoder
        .decode_surface(H264_720P)
        .expect("decode 720p again");
    assert!(!second.is_null(), "surface after second decode");
    unsafe {
        assert_eq!(CVPixelBufferGetWidth(second), 1280);
        assert!(!CVPixelBufferGetIOSurface(second).is_null());
    }
}

#[test]
fn a_retained_surface_outlives_the_next_decode() {
    let mut decoder = surface_decoder();
    let pixelbuffer = decoder.decode_surface(H264_720P).expect("surface");
    // What a consumer that wants to keep the surface does.
    let kept = unsafe { CFRetain(pixelbuffer) };
    assert!(!kept.is_null());

    // Our own release happens on the next decode; the consumer's retain must
    // keep the surface readable past it.
    let second = decoder.decode_surface(H264_720P).expect("second surface");
    unsafe {
        // A pool that handed the same address back would make the check below
        // vacuous, so prove the two surfaces are actually distinct.
        assert_ne!(
            kept as usize, second as usize,
            "the pool reused the address; this test proves nothing"
        );
        assert_eq!(CVPixelBufferGetWidth(kept as *mut c_void), 1280);
        assert_eq!(CVPixelBufferGetHeight(kept as *mut c_void), 720);
    }

    // A call that decodes nothing still drops ours -- and still must not
    // invalidate the copy the consumer retained.
    assert!(
        decoder.decode_surface(&[]).is_err(),
        "an empty packet is rejected before it reaches the decoder"
    );
    unsafe {
        assert_eq!(CVPixelBufferGetWidth(kept as *mut c_void), 1280);
        CFRelease(kept);
    }
}

#[test]
fn surface_intent_does_not_carry_to_the_next_decode() {
    let mut decoder = surface_decoder();

    assert!(
        !decoder
            .decode_surface(H264_720P)
            .expect("surface")
            .is_null(),
        "the first call asks for a surface"
    );

    // The same decoder, one packet later, does not ask: it must go back to
    // copying into a software frame.
    let frames = decoder.decode(H264_720P).expect("software decode");
    assert_eq!(frames.len(), 1, "one packet, one frame");
    assert_eq!((frames[0].width, frames[0].height), (1280, 720));
    assert!(
        frames[0].data.iter().all(|plane| !plane.is_empty()),
        "planes are copied out when this call did not ask for a surface"
    );

    // And back again, to show the flag is read per call, not left on.
    assert!(
        !decoder
            .decode_surface(H264_720P)
            .expect("surface again")
            .is_null(),
        "asking again produces a surface again"
    );
}

#[test]
fn software_decode_is_unchanged() {
    let mut decoder = Decoder::new(context(AV_HWDEVICE_TYPE_NONE)).expect("software h264 decoder");
    let (count, size, planes) = {
        let frames = decoder.decode(H264_720P).expect("decode 720p");
        assert_eq!(frames.len(), 1, "one packet, one frame");
        (
            frames.len(),
            (frames[0].width, frames[0].height),
            frames[0].data.iter().map(|d| d.len()).collect::<Vec<_>>(),
        )
    };
    assert_eq!(count, 1);
    assert_eq!(size, (1280, 720));
    assert!(
        planes.iter().all(|len| *len > 0),
        "planes are copied out as before"
    );
}

#[test]
fn surface_is_refused_by_a_decoder_that_is_not_videotoolbox() {
    let mut decoder = Decoder::new(context(AV_HWDEVICE_TYPE_NONE)).expect("software h264 decoder");
    assert!(decoder.decode_surface(H264_720P).is_err());
}
