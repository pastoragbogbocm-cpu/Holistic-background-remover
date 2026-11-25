import CoreGraphics
import CoreVideo
import Vision

/// Apple Vision person segmentation (on-device, offline, Neural Engine).
///
/// For video it reuses one request with a sequence handler, which lets
/// Vision keep its own frame-to-frame state; the core then adds its own
/// motion-adaptive smoothing and full-resolution edge refinement on top.
final class PersonSegmenter {
  private let request: VNGeneratePersonSegmentationRequest
  private let sequence = VNSequenceRequestHandler()

  init(highQuality: Bool) {
    request = VNGeneratePersonSegmentationRequest()
    request.qualityLevel = highQuality ? .accurate : .balanced
    request.outputPixelFormat = kCVPixelFormatType_OneComponent8
  }

  /// Mask for a video frame in stored orientation.
  func mask(for pixelBuffer: CVPixelBuffer, rotation: Int) throws -> CVPixelBuffer {
    try sequence.perform([request], on: pixelBuffer, orientation: orientation(forRotation: rotation))
    guard let mask = request.results?.first?.pixelBuffer else {
      throw HbrError.message("Person segmentation returned no mask")
    }
    return mask
  }

  /// Mask for an upright still image.
  func mask(for image: CGImage) throws -> CVPixelBuffer {
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try handler.perform([request])
    guard let mask = request.results?.first?.pixelBuffer else {
      throw HbrError.message("Person segmentation returned no mask")
    }
    return mask
  }

  /// Vision returns the mask in the orientation it analysed. For sideways
  /// video the aspect ratio tells us whether that was upright or stored
  /// orientation, so the core can map it back to stored pixels either way.
  static func maskRotation(maskWidth: Int, maskHeight: Int,
                           frameWidth: Int, frameHeight: Int, rotation: Int) -> Int {
    guard rotation == 90 || rotation == 270 else { return rotation }
    if maskWidth == maskHeight { return rotation }
    let maskLandscape = maskWidth > maskHeight
    let frameLandscape = frameWidth > frameHeight
    return maskLandscape == frameLandscape ? 0 : rotation
  }
}
