/// Dart API for the on-device background removal engine.
///
/// All heavy lifting (decode, segmentation, matte refinement, compositing,
/// encode) happens natively on the phone. Nothing leaves the device.
library;

import 'dart:async';

import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('hbr_engine');
const EventChannel _events = EventChannel('hbr_engine/progress');

/// Properties of a source video, as stored in the file.
class VideoInfo {
  const VideoInfo({
    required this.width,
    required this.height,
    required this.rotation,
    required this.durationMs,
    required this.frameRate,
    required this.bitrate,
    required this.codec,
    required this.hasAudio,
    required this.isHdr,
  });

  /// Stored (encoded) frame size, before rotation.
  final int width;
  final int height;

  /// Clockwise display rotation in degrees (0, 90, 180, 270).
  final int rotation;
  final int durationMs;
  final double frameRate;

  /// Bits per second of the video track.
  final int bitrate;

  /// "hevc", "h264", ...
  final String codec;
  final bool hasAudio;
  final bool isHdr;

  int get displayWidth => rotation % 180 == 0 ? width : height;
  int get displayHeight => rotation % 180 == 0 ? height : width;
  double get aspectRatio => displayWidth / displayHeight;

  factory VideoInfo.fromMap(Map<Object?, Object?> m) => VideoInfo(
        width: (m['width'] as num).toInt(),
        height: (m['height'] as num).toInt(),
        rotation: (m['rotation'] as num? ?? 0).toInt(),
        durationMs: (m['durationMs'] as num? ?? 0).toInt(),
        frameRate: (m['frameRate'] as num? ?? 30).toDouble(),
        bitrate: (m['bitrate'] as num? ?? 0).toInt(),
        codec: m['codec'] as String? ?? 'unknown',
        hasAudio: m['hasAudio'] as bool? ?? false,
        isHdr: m['isHdr'] as bool? ?? false,
      );

  String get summary {
    final mbps = (bitrate / 1e6).toStringAsFixed(1);
    final fps = frameRate.toStringAsFixed(frameRate % 1 == 0 ? 0 : 2);
    return '${displayWidth}x$displayHeight · $fps fps · ${codec.toUpperCase()}'
        ' · $mbps Mbps${hasAudio ? ' · audio' : ''}${isHdr ? ' · HDR' : ''}';
  }
}

/// What goes behind the person.
sealed class Background {
  const Background();

  Map<String, Object?> toMap();
}

class ColorBackground extends Background {
  const ColorBackground(this.argb);
  final int argb;
  @override
  Map<String, Object?> toMap() => {'type': 'color', 'argb': argb};
}

/// How a background picture or video sits behind the person.
class BackgroundPlacement {
  const BackgroundPlacement({
    this.scale = 1.0,
    this.panX = 0.0,
    this.panY = 0.0,
    this.fillArgb = 0xFF000000,
  });

  /// 1 = exactly covers the frame. Below 1 the picture gets smaller and
  /// [fillArgb] shows around it; above 1 it zooms in.
  final double scale;

  /// -1..1: which part shows (or where a smaller picture sits).
  /// -1 = left/top edge, 0 = centred, 1 = right/bottom edge.
  final double panX;
  final double panY;
  final int fillArgb;

  bool get isDefault => scale == 1.0 && panX == 0.0 && panY == 0.0;

  Map<String, Object?> toMap() =>
      {'scale': scale, 'panX': panX, 'panY': panY, 'fill': fillArgb};

  BackgroundPlacement copyWith({double? scale, double? panX, double? panY, int? fillArgb}) =>
      BackgroundPlacement(
        scale: scale ?? this.scale,
        panX: (panX ?? this.panX).clamp(-1.0, 1.0),
        panY: (panY ?? this.panY).clamp(-1.0, 1.0),
        fillArgb: fillArgb ?? this.fillArgb,
      );
}

class ImageBackground extends Background {
  const ImageBackground(this.path, {this.placement = const BackgroundPlacement()});
  final String path;
  final BackgroundPlacement placement;
  @override
  Map<String, Object?> toMap() => {'type': 'image', 'path': path, ...placement.toMap()};
}

class BlurBackground extends Background {
  /// [amount] is the blur radius as a fraction of the short side, 0.005-0.1.
  const BlurBackground([this.amount = 0.03]);
  final double amount;
  @override
  Map<String, Object?> toMap() => {'type': 'blur', 'amount': amount};
}

class VideoBackground extends Background {
  /// Loops if shorter than the main video; scaled with aspect-fill.
  const VideoBackground(this.path, {this.placement = const BackgroundPlacement()});
  final String path;
  final BackgroundPlacement placement;
  @override
  Map<String, Object?> toMap() => {'type': 'video', 'path': path, ...placement.toMap()};
}

/// Shape of the exported frame.
enum FrameShape {
  original('original', 'Original', null),
  portrait('9:16', '9:16', 9 / 16),
  square('1:1', '1:1', 1.0),
  portrait45('4:5', '4:5', 4 / 5),
  landscape('16:9', '16:9', 16 / 9);

  const FrameShape(this.id, this.label, this.ratio);
  final String id;
  final String label;

  /// width / height, or null to keep the source's shape.
  final double? ratio;
}

/// Output frame: its shape, and whether the whole video is shown ([fit],
/// with the new background filling the rest) or it fills the frame (cropped).
class OutputFrame {
  const OutputFrame({this.shape = FrameShape.original, this.fit = false});
  final FrameShape shape;
  final bool fit;

  Map<String, Object?> toMap() => {'aspect': shape.id, 'fit': fit};

  /// Display size of the exported video for a source shown at [w] x [h].
  (int, int) sizeFor(int w, int h) {
    final r = shape.ratio;
    if (r == null) return (w, h);
    final short = w < h ? w : h;
    int even(double v) => ((v / 2).round() * 2).clamp(2, 1 << 30);
    return r >= 1 ? (even(short * r), short) : (short, even(short / r));
  }
}

/// Matte tuning. Defaults are tuned for people at 0.5-4 m from the camera.
class MatteSettings {
  const MatteSettings({
    this.temporalStrength = 0.6,
    this.edgeSoftness = 0.5,
    this.edgeSmoothing = 0.8,
    this.cleanEdgeColors = true,
    this.highQualitySegmentation = true,
  });

  /// 0 = no temporal smoothing, 1 = maximum flicker suppression.
  final double temporalStrength;

  /// 0 = crisp cut-out, 1 = soft feathered edges.
  final double edgeSoftness;

  /// 0 = raw outline, 1 = smoothest: rounds off stair-steps and steadies
  /// the outline over time where the picture is still.
  final double edgeSmoothing;

  /// Removes the old background's colour from hair and other
  /// semi-transparent edge pixels (no dark/green fringe).
  final bool cleanEdgeColors;

  /// Uses the slower, more accurate segmentation mode where the platform
  /// offers one (Vision `.accurate` on iOS).
  final bool highQualitySegmentation;

  Map<String, Object?> toMap() => {
        'temporalStrength': temporalStrength,
        'edgeSoftness': edgeSoftness,
        'edgeSmoothing': edgeSmoothing,
        'cleanEdges': cleanEdgeColors,
        'highQuality': highQualitySegmentation,
      };

  MatteSettings copyWith({
    double? temporalStrength,
    double? edgeSoftness,
    double? edgeSmoothing,
    bool? cleanEdgeColors,
    bool? highQualitySegmentation,
  }) =>
      MatteSettings(
        temporalStrength: temporalStrength ?? this.temporalStrength,
        edgeSoftness: edgeSoftness ?? this.edgeSoftness,
        edgeSmoothing: edgeSmoothing ?? this.edgeSmoothing,
        cleanEdgeColors: cleanEdgeColors ?? this.cleanEdgeColors,
        highQualitySegmentation:
            highQualitySegmentation ?? this.highQualitySegmentation,
      );
}

/// Progress of a running export.
class ExportProgress {
  const ExportProgress({
    required this.jobId,
    required this.fraction,
    required this.framesDone,
    required this.fps,
    this.outputPath,
    this.error,
    this.warning,
    this.done = false,
    this.cancelled = false,
  });

  final String jobId;
  final double fraction;
  final int framesDone;

  /// Processing speed in frames per second.
  final double fps;
  final String? outputPath;
  final String? error;

  /// Non-fatal note, e.g. that audio could not be copied.
  final String? warning;
  final bool done;
  final bool cancelled;

  factory ExportProgress.fromMap(Map<Object?, Object?> m) => ExportProgress(
        jobId: m['jobId'] as String,
        fraction: (m['fraction'] as num? ?? 0).toDouble(),
        framesDone: (m['frames'] as num? ?? 0).toInt(),
        fps: (m['fps'] as num? ?? 0).toDouble(),
        outputPath: m['outputPath'] as String?,
        error: m['error'] as String?,
        warning: m['warning'] as String?,
        done: m['done'] as bool? ?? false,
        cancelled: m['cancelled'] as bool? ?? false,
      );
}

class HbrEngine {
  HbrEngine._();

  static Stream<ExportProgress>? _progress;

  static Stream<ExportProgress> get _allProgress => _progress ??= _events
      .receiveBroadcastStream()
      .map((e) => ExportProgress.fromMap(e as Map<Object?, Object?>))
      .asBroadcastStream();

  /// Reads resolution, frame rate, bitrate, rotation and codec of [path].
  static Future<VideoInfo> probe(String path) async {
    final m = await _channel.invokeMapMethod<Object?, Object?>(
        'probe', {'path': path});
    return VideoInfo.fromMap(m!);
  }

  /// Renders one processed frame at [timeMs] as JPEG bytes, upright, with
  /// the longest side limited to [maxSize] pixels.
  static Future<Uint8List> previewFrame(
    String path, {
    required int timeMs,
    required Background background,
    MatteSettings settings = const MatteSettings(),
    OutputFrame frame = const OutputFrame(),
    int maxSize = 960,
  }) async {
    final bytes = await _channel.invokeMethod<Uint8List>('preview', {
      'path': path,
      'timeMs': timeMs,
      'background': background.toMap(),
      'settings': {...settings.toMap(), ...frame.toMap()},
      'maxSize': maxSize,
    });
    return bytes!;
  }

  /// Exports the full video with the background replaced. Resolution, frame
  /// rate, rotation, colour tags and codec family match the source, the
  /// bitrate is at least the source bitrate, and audio is copied untouched.
  ///
  /// The stream ends after an event with `done`, `error` or `cancelled`.
  static Stream<ExportProgress> export({
    required String inputPath,
    required String outputPath,
    required Background background,
    MatteSettings settings = const MatteSettings(),
    OutputFrame frame = const OutputFrame(),
  }) async* {
    final jobId = DateTime.now().microsecondsSinceEpoch.toString();
    final events = _allProgress.where((e) => e.jobId == jobId);
    final controller = StreamController<ExportProgress>();
    final sub = events.listen(controller.add);
    try {
      await _channel.invokeMethod<void>('export', {
        'jobId': jobId,
        'input': inputPath,
        'output': outputPath,
        'background': background.toMap(),
        'settings': {...settings.toMap(), ...frame.toMap()},
      });
      await for (final e in controller.stream) {
        yield e;
        if (e.done || e.error != null || e.cancelled) break;
      }
    } finally {
      await sub.cancel();
      await controller.close();
    }
  }

  /// Cancels the running export, if any. The partial file is deleted.
  static Future<void> cancel() => _channel.invokeMethod<void>('cancel');
}
