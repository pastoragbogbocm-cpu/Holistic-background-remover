# Architecture

## Goals

1. Runs on the phone, offline. No network permission in release builds, models bundled.
2. Output quality equals input quality: nothing the user didn't ask to change is changed.
3. One engine for phone today and web/desktop later.

## Stack

```
Flutter UI (Dart)                      app/
   |  MethodChannel "hbr_engine" + EventChannel "hbr_engine/progress"
Native pipelines                       packages/hbr_engine/{android,ios}
   Android: MediaExtractor -> MediaCodec (HW decode) -> MediaPipe selfie segmenter
            -> core -> MediaCodec (HW encode) -> MediaMuxer (+ audio sample copy)
   iOS:     AVAssetReader -> Vision VNGeneratePersonSegmentationRequest
            -> core -> AVAssetWriter (+ audio passthrough)
Portable matte engine (C++17, C ABI)   core/
```

Flutter gives one UI codebase for iOS, Android, and later web and desktop.
The heavy video work stays native because only the platform APIs reach the
hardware decoders, encoders and neural accelerators. The image math lives
in `core/` so every platform produces identical mattes; it has no
dependencies and will compile to WASM for web and natively for desktop.

## Per-frame pipeline

1. **Decode** at full resolution to 8-bit 4:2:0 (NV12/I420), stored orientation.
2. **Segment** a small upright copy (~256 px) of the frame. Android: MediaPipe
   selfie segmenter (square or landscape model by aspect, GPU delegate with CPU
   fallback). iOS: Vision person segmentation (`.accurate` by default).
3. **Refine** (core, `hbr_refine_*`):
   - map the low-res mask back into stored orientation (handles 90/180/270 video),
   - motion-adaptive temporal smoothing: small frame-to-frame mask changes are
     model jitter and get averaged; large changes are real motion and pass
     through immediately, so there is no ghosting; history resets on hard cuts,
   - fast guided filter with the full-resolution luma as the guide, so the
     matte edge snaps to the real hair/clothing edge at full resolution.
     The window adapts to the mask's resolution.
   - optional tightening (edge softness setting).
4. **Composite** (core, `hbr_composite_*`) directly in Y'CbCr into the encoder's
   input buffer. Where alpha is 255 the person's pixels are copied bit-exactly
   (unit-tested), so no colour conversion touches them.
   - colour: converted once with the video's own matrix and range,
   - image: decoded upright, aspect-filled and rotated into stored orientation once,
   - video: decoded in step, looped, rotated and aspect-filled per frame,
   - blur: computed at reduced resolution with background-only weighting
     (normalised convolution), so the person doesn't bleed a halo into the blur.
5. **Encode** with the same codec family (HEVC stays HEVC, H.264 stays H.264,
   ProRes stays ProRes on iOS), same size, the original timestamps (VFR-safe),
   colour primaries/transfer/matrix copied, bitrate = max(source, quality floor),
   rotation kept as metadata exactly like the camera wrote it.
6. **Audio** samples are copied without decoding.

## Why these choices

- **Segment small, refine big.** Running a model at 4K is impossible on a phone,
  and upscaling a 256 px mask gives blurry, wobbly edges. The guided filter
  rebuilds a full-resolution matte from the low-res one using the real image,
  which is where the quality comes from.
- **Y'CbCr compositing.** Converting to RGB and back costs time and quality.
  Blending in Y'CbCr is mathematically the same blend and leaves the person untouched.
- **Platform segmenters.** Vision on iOS uses the Neural Engine and needs no
  model file; MediaPipe on Android ships a 250 KB model that runs on the GPU.
  Both are free, offline and production-grade. The model is swappable behind
  `Segmenter`/`PersonSegmenter` if a matting model (e.g. RVM/MODNet) is added later.

## Road to web and desktop

- Desktop (Flutter desktop): reuse `core/` natively; decode/encode via the OS
  (Media Foundation / AVFoundation) or FFmpeg; segmentation via ONNX Runtime or
  LiteRT with the same `.tflite` (the desktop harness already does this).
- Web (Flutter web): compile `core/` to WASM, decode/encode with WebCodecs,
  segment with MediaPipe Tasks for Web.

## Next steps

1. Device testing on a range of phones; tune defaults.
2. 10-bit path (P010 / 420 10-bit buffers) for HDR sources end to end.
3. GPU compositing (Metal / GLES) to raise 4K export speed.
4. Optional higher-quality matting model for hair (RVM) on capable devices.
5. Live camera mode using the same engine.
