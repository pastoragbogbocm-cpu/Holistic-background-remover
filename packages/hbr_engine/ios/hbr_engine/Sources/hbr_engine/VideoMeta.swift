import AVFoundation
import CoreMedia

#if canImport(HbrCore)
import HbrCore
#endif

/// Source properties we reproduce on export.
struct VideoMeta {
  let asset: AVURLAsset
  let videoTrack: AVAssetTrack
  let audioTrack: AVAssetTrack?
  let width: Int
  let height: Int
  /// Clockwise display rotation in degrees.
  let rotation: Int
  let duration: CMTime
  let frameRate: Float
  let bitrate: Int
  let codecType: CMVideoCodecType
  let colorPrimaries: String?
  let transferFunction: String?
  let yCbCrMatrix: String?

  var isHdr: Bool {
    let hlg = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
    let pq = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
    return transferFunction == hlg || transferFunction == pq
  }

  var isProRes: Bool {
    [kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ,
     kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy,
     kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ].contains(codecType)
  }

  var codecName: String {
    switch codecType {
    case kCMVideoCodecType_HEVC: return "hevc"
    case kCMVideoCodecType_H264: return "h264"
    default: return isProRes ? "prores" : fourCC(codecType)
    }
  }

  var displayWidth: Int { rotation % 180 == 0 ? width : height }
  var displayHeight: Int { rotation % 180 == 0 ? height : width }

  var matrix: hbr_matrix {
    switch yCbCrMatrix {
    case .some(let m) where m == (kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4 as String):
      return HBR_MATRIX_BT601
    case .some(let m) where m == (kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String):
      return HBR_MATRIX_BT2020
    case .some:
      return HBR_MATRIX_BT709
    case .none:
      return height >= 720 || width >= 1280 ? HBR_MATRIX_BT709 : HBR_MATRIX_BT601
    }
  }

  func toMap() -> [String: Any] {
    [
      "width": width, "height": height, "rotation": rotation,
      "durationMs": Int(CMTimeGetSeconds(duration) * 1000),
      "frameRate": Double(frameRate), "bitrate": bitrate, "codec": codecName,
      "hasAudio": audioTrack != nil, "isHdr": isHdr,
    ]
  }

  static func load(path: String) async throws -> VideoMeta {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path),
                           options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    guard let video = try await asset.loadTracks(withMediaType: .video).first else {
      throw HbrError.message("No video track in this file")
    }
    let audio = try await asset.loadTracks(withMediaType: .audio).first
    let (size, transform, fps, rate, formats) = try await video.load(
      .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate, .formatDescriptions)
    let duration = try await asset.load(.duration)
    let fd = formats.first
    let ext = fd.flatMap { CMFormatDescriptionGetExtensions($0) as? [String: Any] } ?? [:]
    let angle = atan2(Double(transform.b), Double(transform.a)) * 180 / .pi
    let rotation = ((Int(angle.rounded()) % 360) + 360) % 360
    let w = Int(size.width.rounded())
    let h = Int(size.height.rounded())
    let fpsValue = fps > 0 ? fps : 30
    return VideoMeta(
      asset: asset, videoTrack: video, audioTrack: audio,
      width: w, height: h, rotation: rotation, duration: duration,
      frameRate: fpsValue,
      bitrate: rate > 0 ? Int(rate) : Int(Float(w * h) * fpsValue * 0.15),
      codecType: fd.map { CMFormatDescriptionGetMediaSubType($0) } ?? kCMVideoCodecType_H264,
      colorPrimaries: ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String,
      transferFunction: ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String,
      yCbCrMatrix: ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String)
  }
}

func fourCC(_ code: FourCharCode) -> String {
  let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
  return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
}

/// EXIF-style orientation for a clockwise display rotation.
func orientation(forRotation r: Int) -> CGImagePropertyOrientation {
  switch r {
  case 90: return .right
  case 180: return .down
  case 270: return .left
  default: return .up
  }
}
