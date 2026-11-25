import AVFoundation
import UIKit

#if canImport(HbrCore)
import HbrCore
#endif

/// Renders one processed, upright frame as JPEG for the editor preview.
final class FramePreviewer {
  private var segmenters: [Bool: PersonSegmenter] = [:]

  func render(path: String, timeMs: Int, background: [String: Any], settings: [String: Any],
              maxSize: Int) throws -> Data {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: maxSize, height: maxSize)
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    let time = CMTime(value: CMTimeValue(timeMs), timescale: 1000)
    let frame = try gen.copyCGImage(at: time, actualTime: nil)

    // even size for 4:2:0
    let w = frame.width & ~1
    let h = frame.height & ~1
    let matrix = HBR_MATRIX_BT709
    let rgba = RGBAImage(frame)
    let src = I420Buffer(width: w, height: h)
    var sv = src.yuv
    hbr_rgba_to_yuv_fill(rgba.data, Int32(rgba.width), Int32(rgba.height), Int32(rgba.width * 4),
                         &sv, Int32(w), Int32(h), matrix, 1)

    let highQuality = (settings["highQuality"] as? Bool) ?? true
    let seg = segmenters[highQuality] ?? PersonSegmenter(highQuality: highQuality)
    segmenters[highQuality] = seg
    let mask = try seg.mask(for: frame)
    let softness = (settings["edgeSoftness"] as? NSNumber)?.floatValue ?? 0.5
    let engine = try MatteEngine(width: w, height: h, temporal: 0, edgeSoftness: softness)
    CVPixelBufferLockBaseAddress(mask, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
    try engine.refine(
      luma: src.data, lumaStride: w,
      mask: CVPixelBufferGetBaseAddress(mask)!.assumingMemoryBound(to: UInt8.self),
      maskWidth: CVPixelBufferGetWidth(mask), maskHeight: CVPixelBufferGetHeight(mask),
      maskStride: CVPixelBufferGetBytesPerRow(mask), maskRotation: 0)

    let bg = try BackgroundProvider(spec: background, width: w, height: h, rotation: 0, matrix: matrix,
                                    fullRange: true, previewTime: time)
    let out = I420Buffer(width: w, height: h)
    try engine.composite(src: src.yuv, dst: out.yuv, background: try bg.next())

    let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4)
    defer { pixels.deallocate() }
    var ov = out.yuv
    hbr_yuv_to_rgba(&ov, Int32(w), Int32(h), pixels, Int32(w * 4), matrix, 1)
    guard let ctx = CGContext(data: pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let cg = ctx.makeImage(),
          let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.92) else {
      throw HbrError.message("Could not render preview")
    }
    return jpeg
  }
}
