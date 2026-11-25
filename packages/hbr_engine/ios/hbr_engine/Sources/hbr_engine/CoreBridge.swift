import CoreVideo
import Foundation

#if canImport(HbrCore)
import HbrCore  // Swift Package Manager build; with CocoaPods the C API is in this module.
#endif

enum HbrError: LocalizedError {
  case message(String)
  var errorDescription: String? {
    switch self {
    case .message(let m): return m
    }
  }
}

/// A tight 8-bit I420 image owned by Swift.
final class I420Buffer {
  let width: Int
  let height: Int
  let data: UnsafeMutablePointer<UInt8>
  let count: Int

  init(width: Int, height: Int) {
    self.width = width
    self.height = height
    count = width * height + 2 * ((width + 1) / 2) * ((height + 1) / 2)
    data = .allocate(capacity: count)
    data.initialize(repeating: 0, count: count)
  }

  deinit { data.deallocate() }

  var yuv: hbr_yuv {
    let cw = (width + 1) / 2
    let ch = (height + 1) / 2
    let u = data + width * height
    return hbr_yuv(y: data, y_stride: Int32(width), u: u, v: u + cw * ch,
                   uv_stride: Int32(cw), uv_pixel_stride: 1)
  }
}

/// NV12 view over a locked CVPixelBuffer (420v / 420f).
func nv12View(_ pb: CVPixelBuffer) -> hbr_yuv {
  let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
  let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
  return hbr_yuv(y: y, y_stride: Int32(CVPixelBufferGetBytesPerRowOfPlane(pb, 0)),
                 u: uv, v: uv + 1,
                 uv_stride: Int32(CVPixelBufferGetBytesPerRowOfPlane(pb, 1)),
                 uv_pixel_stride: 2)
}

/// Swift owner of an `hbr_engine`.
final class MatteEngine {
  let width: Int
  let height: Int
  private let handle: OpaquePointer

  init(width: Int, height: Int, temporal: Float, edgeSoftness: Float,
       edgeSmoothing: Float = 0.8, cleanEdges: Bool = true) throws {
    self.width = width
    self.height = height
    var cfg = hbr_config()
    hbr_default_config(&cfg, Int32(width), Int32(height))
    cfg.temporal_strength = temporal
    cfg.edge_smoothing = edgeSmoothing
    cfg.decontaminate = cleanEdges ? 1 : 0
    // softness 0 -> crisp (0.3..0.7 remapped), 1 -> soft (0..1)
    let low = 0.3 * (1 - min(max(edgeSoftness, 0), 1))
    cfg.matte_low = low
    cfg.matte_high = 1 - low
    guard let h = hbr_create(&cfg) else {
      throw HbrError.message("Could not create matte engine for \(width)x\(height)")
    }
    handle = h
  }

  deinit { hbr_destroy(handle) }

  func reset() { hbr_reset(handle) }

  /// - Parameters:
  ///   - luma: full-resolution Y plane of the frame (stored orientation).
  ///   - mask: 8-bit person mask; `maskRotation` is the clockwise rotation
  ///     that takes the stored frame into the mask's orientation.
  func refine(luma: UnsafePointer<UInt8>, lumaStride: Int,
              mask: UnsafePointer<UInt8>, maskWidth: Int, maskHeight: Int, maskStride: Int,
              maskRotation: Int) throws {
    let rc = hbr_refine_u8(handle, luma, Int32(lumaStride), mask, Int32(maskWidth),
                           Int32(maskHeight), Int32(maskStride), Int32(maskRotation))
    if rc != 0 { throw HbrError.message("Matte refinement failed (\(rc))") }
  }

  func composite(src: hbr_yuv, dst: hbr_yuv, background: BackgroundFrame) throws {
    var s = src
    var d = dst
    let rc: Int32
    switch background {
    case .color(let y, let u, let v):
      rc = hbr_composite_color(handle, &s, &d, y, u, v)
    case .image(let buffer):
      var b = buffer.yuv
      rc = hbr_composite_image(handle, &s, &b, &d)
    case .blur(let amount):
      rc = hbr_composite_blur(handle, &s, &d, amount)
    }
    if rc != 0 { throw HbrError.message("Compositing failed (\(rc))") }
  }
}

enum CoreColor {
  static func yuv(argb: Int, matrix: hbr_matrix, fullRange: Bool) -> (UInt8, UInt8, UInt8) {
    var y: UInt8 = 0, u: UInt8 = 0, v: UInt8 = 0
    hbr_rgb_to_yuv(UInt8((argb >> 16) & 0xff), UInt8((argb >> 8) & 0xff), UInt8(argb & 0xff),
                   matrix, fullRange ? 1 : 0, &y, &u, &v)
    return (y, u, v)
  }

  /// Rotates an I420 buffer clockwise.
  static func rotate(_ src: I420Buffer, by rot: Int) -> I420Buffer {
    if rot % 360 == 0 { return src }
    let swap = rot == 90 || rot == 270
    let out = I420Buffer(width: swap ? src.height : src.width, height: swap ? src.width : src.height)
    var s = src.yuv
    var d = out.yuv
    hbr_rotate_yuv(&s, Int32(src.width), Int32(src.height), &d, Int32(rot))
    return out
  }
}
