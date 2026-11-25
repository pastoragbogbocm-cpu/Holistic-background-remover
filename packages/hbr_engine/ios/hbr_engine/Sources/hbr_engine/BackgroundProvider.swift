import AVFoundation
import CoreGraphics
import UIKit

#if canImport(HbrCore)
import HbrCore
#endif

/// Background for one frame, ready for the compositor.
enum BackgroundFrame {
  case color(UInt8, UInt8, UInt8)
  case image(I420Buffer)
  case blur(Float)
}

/// Produces backgrounds already in the output's stored orientation, size
/// and colour matrix.
final class BackgroundProvider {
  private enum Kind {
    case fixed(BackgroundFrame)
    case video(LoopingVideoReader)
  }

  private let kind: Kind

  /// - Parameter previewTime: for previews a video background shows the
  ///   frame at this time instead of being read sequentially.
  init(spec: [String: Any], width: Int, height: Int, rotation: Int,
       matrix: hbr_matrix, fullRange: Bool, previewTime: CMTime? = nil) throws {
    switch spec["type"] as? String {
    case "color":
      let argb = (spec["argb"] as? NSNumber)?.intValue ?? 0xFF00B140
      let c = CoreColor.yuv(argb: argb, matrix: matrix, fullRange: fullRange)
      kind = .fixed(.color(c.0, c.1, c.2))
    case "blur":
      let amount = (spec["amount"] as? NSNumber)?.floatValue ?? 0.03
      kind = .fixed(.blur(min(max(amount, 0.002), 0.2)))
    case "image":
      guard let path = spec["path"] as? String, let img = UIImage(contentsOfFile: path),
            let cg = uprightCGImage(img) else {
        throw HbrError.message("Cannot read the background image")
      }
      kind = .fixed(.image(Self.still(cg, width: width, height: height, rotation: rotation,
                                      matrix: matrix, fullRange: fullRange)))
    case "video":
      guard let path = spec["path"] as? String else { throw HbrError.message("Missing background video") }
      if let t = previewTime {
        let cg = try Self.frame(ofVideo: path, at: t)
        kind = .fixed(.image(Self.still(cg, width: width, height: height, rotation: rotation,
                                        matrix: matrix, fullRange: fullRange)))
      } else {
        kind = .video(try LoopingVideoReader(path: path, width: width, height: height, rotation: rotation))
      }
    default:
      throw HbrError.message("Unknown background type")
    }
  }

  func next() throws -> BackgroundFrame {
    switch kind {
    case .fixed(let f): return f
    case .video(let r): return .image(try r.next())
    }
  }

  /// Upright image -> aspect-filled I420 in stored orientation.
  static func still(_ image: CGImage, width: Int, height: Int, rotation: Int,
                    matrix: hbr_matrix, fullRange: Bool) -> I420Buffer {
    let dispW = rotation % 180 == 0 ? width : height
    let dispH = rotation % 180 == 0 ? height : width
    let upright = I420Buffer(width: dispW, height: dispH)
    let rgba = RGBAImage(image)
    var dst = upright.yuv
    hbr_rgba_to_yuv_fill(rgba.data, Int32(rgba.width), Int32(rgba.height), Int32(rgba.width * 4),
                         &dst, Int32(dispW), Int32(dispH), matrix, fullRange ? 1 : 0)
    return CoreColor.rotate(upright, by: (360 - rotation) % 360)
  }

  static func frame(ofVideo path: String, at time: CMTime) throws -> CGImage {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: 1920, height: 1920)
    let dur = asset.duration
    var t = time
    if dur.seconds > 0 {
      t = CMTime(seconds: time.seconds.truncatingRemainder(dividingBy: dur.seconds), preferredTimescale: 600)
    }
    return try gen.copyCGImage(at: t, actualTime: nil)
  }
}

/// Reads a background video frame by frame, looping, converted to the main
/// video's stored orientation and size.
final class LoopingVideoReader {
  private let asset: AVURLAsset
  private let track: AVAssetTrack
  private var reader: AVAssetReader?
  private var output: AVAssetReaderTrackOutput?
  private let width: Int
  private let height: Int
  private let turn: Int
  private let out: I420Buffer

  init(path: String, width: Int, height: Int, rotation: Int) throws {
    asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let t = asset.tracks(withMediaType: .video).first else {
      throw HbrError.message("Background video has no video track")
    }
    track = t
    let tr = t.preferredTransform
    let angle = Int((atan2(Double(tr.b), Double(tr.a)) * 180 / .pi).rounded())
    let bgRotation = ((angle % 360) + 360) % 360
    turn = ((bgRotation - rotation) % 360 + 360) % 360
    self.width = width
    self.height = height
    out = I420Buffer(width: width, height: height)
    try restart()
  }

  private func restart() throws {
    reader?.cancelReading()
    let r = try AVAssetReader(asset: asset)
    let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    ])
    o.alwaysCopiesSampleData = false
    r.add(o)
    guard r.startReading() else { throw r.error ?? HbrError.message("Cannot read background video") }
    reader = r
    output = o
  }

  func next() throws -> I420Buffer {
    var sample = output?.copyNextSampleBuffer()
    if sample == nil {
      try restart()
      sample = output?.copyNextSampleBuffer()
    }
    guard let sb = sample, let pb = CMSampleBufferGetImageBuffer(sb) else { return out }
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let sw = CVPixelBufferGetWidth(pb)
    let sh = CVPixelBufferGetHeight(pb)
    var src = nv12View(pb)
    var srcW = sw
    var srcH = sh
    var rotated: I420Buffer?
    if turn != 0 {
      let swap = turn == 90 || turn == 270
      let r = I420Buffer(width: swap ? sh : sw, height: swap ? sw : sh)
      var d = r.yuv
      hbr_rotate_yuv(&src, Int32(sw), Int32(sh), &d, Int32(turn))
      rotated = r
      src = r.yuv
      srcW = r.width
      srcH = r.height
    }
    var dst = out.yuv
    hbr_scale_yuv_fill(&src, Int32(srcW), Int32(srcH), &dst, Int32(width), Int32(height))
    _ = rotated  // keep alive until scaled
    return out
  }

  deinit { reader?.cancelReading() }
}

/// Upright RGBA8 copy of a CGImage.
final class RGBAImage {
  let width: Int
  let height: Int
  let data: UnsafeMutablePointer<UInt8>

  init(_ image: CGImage) {
    width = image.width
    height = image.height
    data = .allocate(capacity: width * height * 4)
    data.initialize(repeating: 0, count: width * height * 4)
    let ctx = CGContext(data: data, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  }

  deinit { data.deallocate() }
}

/// Applies UIImage orientation so pixels are upright.
func uprightCGImage(_ image: UIImage) -> CGImage? {
  if image.imageOrientation == .up { return image.cgImage }
  let format = UIGraphicsImageRendererFormat.default()
  format.scale = 1
  let r = UIGraphicsImageRenderer(size: image.size, format: format)
  return r.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }.cgImage
}
