/// Dart API for the on-device background removal engine.
///
/// All heavy lifting (decode, segmentation, matte refinement, compositing,
/// encode) happens natively on the phone. Nothing leaves the device.
library;

import 'dart:async';
import 'dart:convert';

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
  const OutputFrame({
    this.shape = FrameShape.original,
    this.fit = false,
    this.personScale = 1.0,
    this.personX = 0.0,
    this.personY = 0.0,
  });
  final FrameShape shape;
  final bool fit;

  /// Size of the speaker's video: 1 = fills (or fits) the frame, smaller
  /// shows more background around it, larger zooms in.
  final double personScale;

  /// Where the speaker's video sits, -1..1 (left/top .. right/bottom).
  final double personX;
  final double personY;

  bool get personMoved => personScale != 1.0 || personX != 0.0 || personY != 0.0;

  OutputFrame copyWith({FrameShape? shape, bool? fit, double? personScale, double? personX, double? personY}) =>
      OutputFrame(
        shape: shape ?? this.shape,
        fit: fit ?? this.fit,
        personScale: (personScale ?? this.personScale).clamp(0.3, 2.5),
        personX: (personX ?? this.personX).clamp(-1.0, 1.0),
        personY: (personY ?? this.personY).clamp(-1.0, 1.0),
      );

  OutputFrame withoutPersonMove() => OutputFrame(shape: shape, fit: fit);

  Map<String, Object?> toMap() => {
        'aspect': shape.id,
        'fit': fit,
        if (personMoved) ...{'personScale': personScale, 'personX': personX, 'personY': personY},
      };

  /// Size of the speaker's video on a [fw] x [fh] frame, for a source shown at [w] x [h].
  (double, double) personSizeOn(int fw, int fh, int w, int h) {
    final sx = fw / w, sy = fh / h;
    final s = (fit ? (sx < sy ? sx : sy) : (sx > sy ? sx : sy)) * personScale;
    return (w * s, h * s);
  }

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
    this.temporalStrength = 0.45,
    this.edgeSoftness = 0.2,
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

/// The exported soundtrack: the video's own sound, optionally with music.
class Soundtrack {
  const Soundtrack({
    this.musicPath,
    this.musicVolume = 0.3,
    this.voiceVolume = 1.0,
    this.duckMusic = true,
    this.musicStartMs = 0,
  });

  /// Where in the song the music starts (and loops back to), in ms.
  final int musicStartMs;

  /// An audio file on the device (MP3, M4A/AAC, WAV, OGG...). Loops if
  /// shorter than the video and fades out at the end.
  final String? musicPath;

  /// 0..1 music level.
  final double musicVolume;

  /// 0..1.5 level of the video's own sound (1 = unchanged).
  final double voiceVolume;

  /// Lowers the music automatically while the person speaks.
  final bool duckMusic;

  /// Nothing to mix: the original audio is copied untouched.
  bool get isOriginal => musicPath == null && voiceVolume == 1.0;

  Map<String, Object?> toMap() => {
        'audio': {
          'musicPath': musicPath,
          'musicVolume': musicVolume,
          'voiceVolume': voiceVolume,
          'duck': duckMusic,
          'musicStartMs': musicStartMs,
        },
      };

  Soundtrack copyWith({
    String? musicPath,
    bool clearMusic = false,
    double? musicVolume,
    double? voiceVolume,
    bool? duckMusic,
    int? musicStartMs,
  }) =>
      Soundtrack(
        musicPath: clearMusic ? null : (musicPath ?? this.musicPath),
        musicVolume: musicVolume ?? this.musicVolume,
        voiceVolume: voiceVolume ?? this.voiceVolume,
        duckMusic: duckMusic ?? this.duckMusic,
        // a new or removed song starts from its beginning
        musicStartMs: (clearMusic || musicPath != null) ? (musicStartMs ?? 0) : (musicStartMs ?? this.musicStartMs),
      );
}

/// A recognised word with its time in the video (milliseconds).
class CaptionWord {
  const CaptionWord(this.text, this.startMs, this.endMs);
  final String text;
  final int startMs;
  final int endMs;

  Map<String, Object?> toMap() => {'w': text, 't0': startMs, 't1': endMs};

  factory CaptionWord.fromMap(Map<String, Object?> m) =>
      CaptionWord(m['w'] as String, (m['t0'] as num).toInt(), (m['t1'] as num).toInt());
}

/// One caption on screen: a few words shown together.
class CaptionCue {
  const CaptionCue(this.words);
  final List<CaptionWord> words;

  int get startMs => words.first.startMs;
  int get endMs => words.last.endMs;
  String get text => words.map((w) => w.text).join(' ');

  /// Same time span with edited text; word times are spread by length.
  CaptionCue withText(String text) {
    final parts = text.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return CaptionCue(const []);
    final total = parts.fold<int>(0, (a, p) => a + p.length + 1);
    final span = (endMs - startMs).clamp(1, 1 << 30);
    var t = startMs.toDouble();
    final out = <CaptionWord>[];
    for (final p in parts) {
      final d = span * (p.length + 1) / total;
      out.add(CaptionWord(p, t.round(), (t + d).round()));
      t += d;
    }
    return CaptionCue(out);
  }

  Map<String, Object?> toMap() =>
      {'t0': startMs, 't1': endMs, 'words': [for (final w in words) w.toMap()]};

  /// Groups words into short captions: up to [maxWords] words / [maxChars]
  /// characters, breaking at sentence ends and pauses.
  static List<CaptionCue> group(List<CaptionWord> words, {int maxWords = 5, int maxChars = 28}) {
    final cues = <CaptionCue>[];
    var cur = <CaptionWord>[];
    var chars = 0;
    for (final w in words) {
      final pause = cur.isNotEmpty && w.startMs - cur.last.endMs > 600;
      if (cur.isNotEmpty && (pause || cur.length >= maxWords || chars + w.text.length + 1 > maxChars)) {
        cues.add(CaptionCue(cur));
        cur = [];
        chars = 0;
      }
      cur.add(w);
      chars += w.text.length + 1;
      if (RegExp(r'[.!?]$').hasMatch(w.text)) {
        cues.add(CaptionCue(cur));
        cur = [];
        chars = 0;
      }
    }
    if (cur.isNotEmpty) cues.add(CaptionCue(cur));
    // keep each caption up until the next one starts (no flicker in short gaps)
    for (var i = 0; i + 1 < cues.length; i++) {
      final gap = cues[i + 1].startMs - cues[i].endMs;
      if (gap > 0 && gap < 400) {
        final last = cues[i].words.last;
        cues[i] = CaptionCue([
          ...cues[i].words.sublist(0, cues[i].words.length - 1),
          CaptionWord(last.text, last.startMs, cues[i + 1].startMs),
        ]);
      }
    }
    return cues;
  }
}

enum CaptionPreset {
  pop('pop', 'Pop'),
  box('box', 'Box'),
  clean('clean', 'Clean'),
  karaoke('karaoke', 'Karaoke');

  const CaptionPreset(this.id, this.label);
  final String id;
  final String label;
}

enum CaptionPosition { top, middle, bottom }

class CaptionStyle {
  const CaptionStyle({
    this.preset = CaptionPreset.pop,
    this.position = CaptionPosition.bottom,
    this.size = 1.0,
    this.textColor = 0xFFFFFFFF,
    this.highlightColor = 0xFFFFD60A,
    this.uppercase = false,
  });
  final CaptionPreset preset;
  final CaptionPosition position;

  /// 0.6..1.6 relative text size.
  final double size;
  final int textColor;

  /// Colour of the word being spoken (Pop, Box, Karaoke).
  final int highlightColor;
  final bool uppercase;

  Map<String, Object?> toMap() => {
        'preset': preset.id,
        'position': position.name,
        'size': size,
        'textColor': textColor,
        'highlightColor': highlightColor,
        'uppercase': uppercase,
      };

  CaptionStyle copyWith({
    CaptionPreset? preset,
    CaptionPosition? position,
    double? size,
    int? textColor,
    int? highlightColor,
    bool? uppercase,
  }) =>
      CaptionStyle(
        preset: preset ?? this.preset,
        position: position ?? this.position,
        size: size ?? this.size,
        textColor: textColor ?? this.textColor,
        highlightColor: highlightColor ?? this.highlightColor,
        uppercase: uppercase ?? this.uppercase,
      );
}

/// Burned-in captions.
class Captions {
  const Captions({this.enabled = true, this.cues = const [], this.style = const CaptionStyle()});
  final bool enabled;
  final List<CaptionCue> cues;
  final CaptionStyle style;

  bool get active => enabled && cues.isNotEmpty;

  Map<String, Object?> toMap() => active
      ? {
          'captions': {
            'enabled': true,
            'cues': [for (final c in cues) if (c.words.isNotEmpty) c.toMap()],
            'style': style.toMap(),
          },
        }
      : const {};

  Captions copyWith({bool? enabled, List<CaptionCue>? cues, CaptionStyle? style}) =>
      Captions(enabled: enabled ?? this.enabled, cues: cues ?? this.cues, style: style ?? this.style);
}

/// A line or soft glow around the speaker.
class Outline {
  const Outline({this.enabled = false, this.argb = 0xFFFFFFFF, this.width = 0.012, this.glow = false});
  final bool enabled;
  final int argb;

  /// Thickness as a fraction of the frame's short side.
  final double width;
  final bool glow;

  static const thin = 0.006, medium = 0.012, thick = 0.02;

  Map<String, Object?> toMap() =>
      enabled ? {'outline': {'argb': argb, 'width': width, 'glow': glow}} : const {};

  Outline copyWith({bool? enabled, int? argb, double? width, bool? glow}) => Outline(
      enabled: enabled ?? this.enabled, argb: argb ?? this.argb, width: width ?? this.width, glow: glow ?? this.glow);
}

/// The animations between parts: id and label.
const transitions = <(String, String)>[
  ('cut', 'Cut'), ('fade', 'Fade'), ('black', 'Dip to black'), ('flash', 'Flash'),
  ('slide', 'Slide'), ('push', 'Push'), ('up', 'Slide up'), ('zoomin', 'Zoom in'),
  ('zoomout', 'Zoom out'), ('circle', 'Circle'), ('wipe', 'Wipe'), ('spin', 'Spin'),
];

/// A picture or video shown before or after the main video.
class IntroClip {
  const IntroClip({
    required this.path,
    this.isVideo = false,
    this.durationS = 3,
    this.motion = 'in',
    this.fit = false,
    this.transition = 'fade',
    this.videoLengthS,
  });
  final String path;
  final bool isVideo;

  /// How long a picture shows.
  final double durationS;

  /// 'none', 'in' (slow zoom in) or 'out' (slow zoom out); pictures only.
  final String motion;

  /// true: whole picture over a blurred copy; false: fills the frame.
  final bool fit;

  /// Animation into this clip.
  final String transition;

  /// Length of a video clip (for display only).
  final double? videoLengthS;

  double get lengthS => isVideo ? (videoLengthS ?? 0).clamp(0, 60).toDouble() : durationS;

  Map<String, Object?> toMap() => {
        'kind': isVideo ? 'video' : 'image',
        'path': path,
        'durationS': durationS,
        'motion': motion,
        'fit': fit,
        'transition': transition,
        'maxS': 60,
      };

  IntroClip copyWith({double? durationS, String? motion, bool? fit, String? transition}) => IntroClip(
        path: path,
        isVideo: isVideo,
        durationS: durationS ?? this.durationS,
        motion: motion ?? this.motion,
        fit: fit ?? this.fit,
        transition: transition ?? this.transition,
        videoLengthS: videoLengthS,
      );
}

/// Pictures and videos before and after the main video, and the animations.
class Sequence {
  const Sequence({
    this.before = const [],
    this.after = const [],
    this.into = 'fade',
    this.fadeIn = false,
    this.fadeOut = false,
    this.transitionS = 0.8,
  });
  final List<IntroClip> before;
  final List<IntroClip> after;

  /// Animation from the intro into the main video.
  final String into;
  final bool fadeIn;
  final bool fadeOut;
  final double transitionS;

  bool get active => before.isNotEmpty || after.isNotEmpty || fadeIn || fadeOut;

  Map<String, Object?> toMap() => active
      ? {
          'sequence': {
            'before': [for (final c in before) c.toMap()],
            'after': [for (final c in after) c.toMap()],
            'into': into,
            'fadeIn': fadeIn,
            'fadeOut': fadeOut,
            'transitionS': transitionS,
          },
        }
      : const {};

  Sequence copyWith({
    List<IntroClip>? before,
    List<IntroClip>? after,
    String? into,
    bool? fadeIn,
    bool? fadeOut,
    double? transitionS,
  }) =>
      Sequence(
        before: before ?? this.before,
        after: after ?? this.after,
        into: into ?? this.into,
        fadeIn: fadeIn ?? this.fadeIn,
        fadeOut: fadeOut ?? this.fadeOut,
        transitionS: transitionS ?? this.transitionS,
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
  /// Returns null when a newer preview request replaced this one.
  static Future<Uint8List?> previewFrame(
    String path, {
    required int timeMs,
    required Background background,
    MatteSettings settings = const MatteSettings(),
    OutputFrame frame = const OutputFrame(),
    Captions captions = const Captions(),
    Outline outline = const Outline(),
    int maxSize = 960,
  }) async {
    final bytes = await _channel.invokeMethod<Uint8List>('preview', {
      'path': path,
      'timeMs': timeMs,
      'background': background.toMap(),
      'settings': {...settings.toMap(), ...frame.toMap(), ...captions.toMap(), ...outline.toMap()},
      'maxSize': maxSize,
    });
    return bytes;
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
    Soundtrack soundtrack = const Soundtrack(),
    Captions captions = const Captions(),
    Outline outline = const Outline(),
    Sequence sequence = const Sequence(),
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
        'settings': {
          ...settings.toMap(),
          ...frame.toMap(),
          ...soundtrack.toMap(),
          ...captions.toMap(),
          ...outline.toMap(),
          ...sequence.toMap(),
        },
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

  /// Recognises the speech in [path] on the device. [language] is a
  /// Whisper code ("en", "fr", ...) or "auto". [onProgress] gets 0..1.
  static Future<List<CaptionWord>> transcribe(
    String path, {
    String language = 'en',
    void Function(double fraction)? onProgress,
  }) async {
    final jobId = 'speech-${DateTime.now().microsecondsSinceEpoch}';
    final sub = _allProgress.where((e) => e.jobId == jobId).listen((e) => onProgress?.call(e.fraction));
    try {
      final json = await _channel.invokeMethod<String>(
          'transcribe', {'jobId': jobId, 'path': path, 'language': language});
      final list = jsonDecode(json ?? '[]') as List<Object?>;
      return [for (final w in list) CaptionWord.fromMap((w as Map).cast<String, Object?>())];
    } finally {
      await sub.cancel();
    }
  }

  static Future<void> cancelTranscribe() => _channel.invokeMethod<void>('cancelTranscribe');

  /// Cancels the running export, if any. The partial file is deleted.
  static Future<void> cancel() => _channel.invokeMethod<void>('cancel');
}
