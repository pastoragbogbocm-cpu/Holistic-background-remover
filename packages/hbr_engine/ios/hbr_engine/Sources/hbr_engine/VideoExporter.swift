import AVFoundation
import CoreMedia
import CoreVideo

#if canImport(HbrCore)
import HbrCore
#endif

struct ExportCancelled: Error {}

/// Full-quality export:
///  - every frame decoded at full resolution (AVAssetReader, hardware)
///  - Vision person mask -> core matte refinement at full resolution ->
///    compositing in Y'CbCr straight into the encoder's pixel buffer
///  - encoded with the source codec family (HEVC, H.264, or ProRes for
///    ProRes sources), same size, same timestamps, source colour tags and at
///    least the source bitrate
///  - audio passed through untouched, rotation kept as track metadata
final class VideoExporter {
  private let inputPath: String
  private var outputURL: URL
  private let background: [String: Any]
  private let settings: [String: Any]
  private let progress: (Double, Int, Double) -> Void
  private let isCancelled: () -> Bool

  init(inputPath: String, outputPath: String, background: [String: Any], settings: [String: Any],
       progress: @escaping (Double, Int, Double) -> Void, isCancelled: @escaping () -> Bool) {
    self.inputPath = inputPath
    self.outputURL = URL(fileURLWithPath: outputPath)
    self.background = background
    self.settings = settings
    self.progress = progress
    self.isCancelled = isCancelled
  }

  /// Returns (actual output path, optional warning).
  func run() async throws -> (String, String?) {
    let meta = try await VideoMeta.load(path: inputPath)
    var warnings: [String] = []
    let W = meta.width
    let H = meta.height

    // ---- reader
    let reader = try AVAssetReader(asset: meta.asset)
    let videoOut = AVAssetReaderTrackOutput(track: meta.videoTrack, outputSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ])
    videoOut.alwaysCopiesSampleData = false
    reader.add(videoOut)
    var audioOut: AVAssetReaderTrackOutput?

    // ---- writer
    let codec: AVVideoCodecType
    var fileType: AVFileType = .mp4
    if meta.isProRes {
      codec = .proRes422HQ
      fileType = .mov
      outputURL = outputURL.deletingPathExtension().appendingPathExtension("mov")
    } else if meta.codecType == kCMVideoCodecType_HEVC {
      codec = .hevc
    } else {
      codec = .h264
    }
    try? FileManager.default.removeItem(at: outputURL)
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)

    let fps = max(1, min(meta.frameRate, 240))
    let floorRate = Float(W * H) * fps * (codec == .hevc ? 0.07 : 0.1)
    let bitrate = max(meta.bitrate, Int(floorRate))
    var videoSettings: [String: Any] = [
      AVVideoCodecKey: codec,
      AVVideoWidthKey: W,
      AVVideoHeightKey: H,
    ]
    if !meta.isProRes {
      var compression: [String: Any] = [
        AVVideoAverageBitRateKey: bitrate,
        AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
        AVVideoMaxKeyFrameIntervalKey: Int(fps.rounded()),
      ]
      if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
      videoSettings[AVVideoCompressionPropertiesKey] = compression
    }
    videoSettings[AVVideoColorPropertiesKey] = [
      AVVideoColorPrimariesKey: meta.colorPrimaries ?? AVVideoColorPrimaries_ITU_R_709_2,
      AVVideoTransferFunctionKey: meta.transferFunction ?? AVVideoTransferFunction_ITU_R_709_2,
      AVVideoYCbCrMatrixKey: meta.yCbCrMatrix ?? AVVideoYCbCrMatrix_ITU_R_709_2,
    ]
    let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoIn.expectsMediaDataInRealTime = false
    videoIn.transform = try await meta.videoTrack.load(.preferredTransform)
    guard writer.canAdd(videoIn) else { throw HbrError.message("Cannot encode \(W)x\(H) \(codec.rawValue)") }
    writer.add(videoIn)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelBufferWidthKey as String: W,
      kCVPixelBufferHeightKey as String: H,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ])

    // Audio: compressed samples are copied as-is (no decode, no re-encode).
    var audioIn: AVAssetWriterInput?
    if let a = meta.audioTrack {
      let hint = try await a.load(.formatDescriptions).first
      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
      input.expectsMediaDataInRealTime = false
      let o = AVAssetReaderTrackOutput(track: a, outputSettings: nil)
      if writer.canAdd(input) && reader.canAdd(o) {
        writer.add(input)
        reader.add(o)
        audioIn = input
        audioOut = o
      } else {
        warnings.append("The audio format can't be copied into this container, so it was left out.")
      }
    }

    // ---- processing state
    let temporal = (settings["temporalStrength"] as? NSNumber)?.floatValue ?? 0.6
    let softness = (settings["edgeSoftness"] as? NSNumber)?.floatValue ?? 0.5
    let highQuality = (settings["highQuality"] as? Bool) ?? true
    let engine = try MatteEngine(width: W, height: H, temporal: temporal, edgeSoftness: softness)
    let bg = try BackgroundProvider(spec: background, width: W, height: H, rotation: meta.rotation,
                                    matrix: meta.matrix, fullRange: false)
    let segmenter = PersonSegmenter(highQuality: highQuality)

    guard reader.startReading() else { throw reader.error ?? HbrError.message("Cannot read the video") }
    guard writer.startWriting() else { throw writer.error ?? HbrError.message("Cannot write the video") }
    writer.startSession(atSourceTime: .zero)

    let total = max(CMTimeGetSeconds(meta.duration), 0.001)
    let started = Date()
    var frames = 0
    var videoDone = false
    var audioDone = audioIn == nil

    do {
      while !videoDone || !audioDone {
        if isCancelled() { throw ExportCancelled() }
        if writer.status == .failed { throw writer.error ?? HbrError.message("Encoder failed") }
        var progressed = false

        if !videoDone && videoIn.isReadyForMoreMediaData {
          progressed = true
          if let sample = videoOut.copyNextSampleBuffer(), let src = CMSampleBufferGetImageBuffer(sample) {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            try autoreleasepool {
              try processFrame(src, pts: pts, meta: meta, engine: engine, background: bg,
                               segmenter: segmenter, adaptor: adaptor)
            }
            frames += 1
            if frames % 5 == 0 {
              let secs = Date().timeIntervalSince(started)
              progress(min(0.99, CMTimeGetSeconds(pts) / total), frames, Double(frames) / max(secs, 0.001))
            }
          } else {
            if reader.status == .failed { throw reader.error ?? HbrError.message("Decoding failed") }
            videoIn.markAsFinished()
            videoDone = true
          }
        }

        if !audioDone, let ain = audioIn, ain.isReadyForMoreMediaData {
          progressed = true
          if let s = audioOut?.copyNextSampleBuffer() {
            if !ain.append(s) { throw writer.error ?? HbrError.message("Audio copy failed") }
          } else {
            ain.markAsFinished()
            audioDone = true
          }
        }

        if !progressed { usleep(1000) }
      }
    } catch {
      reader.cancelReading()
      writer.cancelWriting()
      try? FileManager.default.removeItem(at: outputURL)
      throw error
    }

    await writer.finishWriting()
    if writer.status != .completed {
      throw writer.error ?? HbrError.message("Could not finish the video file")
    }
    guard frames > 0 else { throw HbrError.message("No frames were exported") }
    progress(1, frames, Double(frames) / max(Date().timeIntervalSince(started), 0.001))
    if meta.isHdr {
      warnings.append("HDR video was processed in 8-bit; colours keep their HDR tags.")
    }
    return (outputURL.path, warnings.isEmpty ? nil : warnings.joined(separator: " "))
  }

  private func processFrame(_ src: CVPixelBuffer, pts: CMTime, meta: VideoMeta, engine: MatteEngine,
                            background: BackgroundProvider, segmenter: PersonSegmenter,
                            adaptor: AVAssetWriterInputPixelBufferAdaptor) throws {
    let mask = try segmenter.mask(for: src, rotation: meta.rotation)
    guard let pool = adaptor.pixelBufferPool else { throw HbrError.message("Encoder is not ready") }
    var outPB: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outPB)
    guard let dst = outPB else { throw HbrError.message("Out of memory") }
    let bgFrame = try background.next()

    CVPixelBufferLockBaseAddress(src, .readOnly)
    CVPixelBufferLockBaseAddress(mask, .readOnly)
    CVPixelBufferLockBaseAddress(dst, [])
    defer {
      CVPixelBufferUnlockBaseAddress(dst, [])
      CVPixelBufferUnlockBaseAddress(mask, .readOnly)
      CVPixelBufferUnlockBaseAddress(src, .readOnly)
    }
    guard CVPixelBufferGetWidth(src) == engine.width, CVPixelBufferGetHeight(src) == engine.height else {
      throw HbrError.message("Unexpected frame size \(CVPixelBufferGetWidth(src))x\(CVPixelBufferGetHeight(src))")
    }
    let srcView = nv12View(src)
    let mw = CVPixelBufferGetWidth(mask)
    let mh = CVPixelBufferGetHeight(mask)
    let maskRot = PersonSegmenter.maskRotation(maskWidth: mw, maskHeight: mh, frameWidth: engine.width,
                                               frameHeight: engine.height, rotation: meta.rotation)
    try engine.refine(
      luma: srcView.y, lumaStride: Int(srcView.y_stride),
      mask: CVPixelBufferGetBaseAddress(mask)!.assumingMemoryBound(to: UInt8.self),
      maskWidth: mw, maskHeight: mh, maskStride: CVPixelBufferGetBytesPerRow(mask),
      maskRotation: maskRot)
    try engine.composite(src: srcView, dst: nv12View(dst), background: bgFrame)
    if !adaptor.append(dst, withPresentationTime: pts) {
      throw HbrError.message("Could not encode frame")
    }
  }
}
