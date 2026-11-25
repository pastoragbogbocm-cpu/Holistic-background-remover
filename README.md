# Holistic Background Remover

Phone app (Flutter, iOS + Android) that removes and replaces the background of
a video **fully offline, on the device**, and exports at the **source quality**:
same resolution, frame rate, timestamps, rotation, colour tags and codec family,
at least the source bitrate, and the original audio copied bit-for-bit.

Backgrounds: solid colour, image, blur (only the real background is blurred,
so the person never smears into it), or a looping video.

## Repository layout

| Path | What it is |
| --- | --- |
| `core/` | Portable C++17 matte engine shared by every platform (C ABI). Temporal smoothing, full-resolution edge refinement, Y'CbCr compositing, colour/scale/rotate helpers. Unit tests in `core/tests`. |
| `packages/hbr_engine/` | Flutter plugin: Dart API + native pipelines. Android: MediaPipe selfie segmenter + MediaCodec + MediaMuxer (Kotlin, JNI into `core`). iOS: Vision person segmentation + AVAssetReader/Writer (Swift, links `core` via symlinks). |
| `app/` | The Flutter app: import, live processed preview, background picker, matte settings, export with progress, save to gallery. |
| `web/` | Web version: same C++ engine compiled to WebAssembly, WebCodecs decode/encode, MediaPipe segmentation, offline-capable. Build with `web/build.sh` (needs emsdk + node), serve `web/dist`. |
| `tools/harness/` | Desktop harness that runs the exact same per-frame pipeline with ffmpeg + the same `.tflite` model, used to validate quality preservation without a phone. |
| `ARCHITECTURE.md` | How it works and why. |

## Build and run

Requirements: Flutter 3.50+, Xcode 16+ (iOS 15+ devices), Android Studio with NDK 28 (Android 7.0+ devices).

```bash
cd app
flutter pub get
flutter run            # pick your connected phone
flutter build apk --release   # or: flutter build ipa
```

Run on a real phone: the simulator/emulator has no Neural Engine / hardware
encoder and will be very slow.

Core tests:

```bash
cmake -S core -B build/core -DHBR_BUILD_TESTS=ON && cmake --build build/core && ./build/core/hbr_core_tests
```

Desktop validation (needs ffmpeg, `pip install ai-edge-litert numpy pillow`):

```bash
cmake -S core -B build/core -DHBR_BUILD_SHARED=ON && cmake --build build/core
python3 tools/harness/hbr_harness.py in.mp4 out.mp4 --lib build/core/libhbr_core.so \
  --model packages/hbr_engine/android/src/main/assets/selfie_segmenter.tflite \
  --landscape-model packages/hbr_engine/android/src/main/assets/selfie_segmenter_landscape.tflite \
  --bg image:background.jpg --matte matte.mp4
```

## Verification status

| Part | Status |
| --- | --- |
| C++ core | Built and unit-tested (11 tests: edge fringe removal, lossless person pixels, exact background, edge snapping, flicker reduction without motion lag, rotation, colour, scaling, rotation helper, blur). |
| End-to-end pipeline | Validated on desktop with the same model and core: 1080p30 H.264, rotated portrait HEVC, 768x576 clip. Resolution, fps, rotation and audio preserved. |
| Dart (plugin + app) | `flutter analyze` clean, widget/unit tests pass. |
| Android Kotlin | Compiles against the Android 17 framework and Flutter embedding (MediaPipe API stubbed). Not yet run on a device. |
| JNI bridge | Compiles. |
| iOS Swift | Written against AVFoundation/Vision but **not compiled** (no macOS here). First build on a Mac may need small fixes. |

## Known limits (MVP)

- Processing is 8-bit. 10-bit HDR (e.g. iPhone Dolby Vision/HLG) is exported
  with its HDR tags but at 8-bit depth. A 10-bit path is the next step.
- The segmentation models are tuned for people roughly 0.5-4 m from the camera
  (selfie/vlog/talking-head). Small distant people are often missed.
- Export speed depends on the phone; expect several frames per second at 1080p
  on recent devices, slower at 4K.
