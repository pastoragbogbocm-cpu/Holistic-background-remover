import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:hbr_engine/hbr_engine.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import 'captions_panel.dart';
import 'export_sheet.dart';
import 'home_screen.dart';

const _swatches = <int>[
  0xFF00B140, // chroma green
  0xFF0047BB, // chroma blue
  0xFFFFFFFF,
  0xFF000000,
  0xFF808080,
  0xFF14B8A6,
  0xFFF59E0B,
  0xFFEC4899,
];

enum _BgKind { color, image, blur, video }

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.path, required this.info, this.initialImage});
  final String path;

  /// Background picture to start with (on-device tests).
  final String? initialImage;
  final VideoInfo info;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  /// Created only when the original is shown, so opening a video does not
  /// start a second decoder next to the preview (that froze slow phones).
  VideoPlayerController? _player;
  bool get _playerReady => _player?.value.isInitialized ?? false;
  _BgKind _kind = _BgKind.color;
  int _color = _swatches.first;
  String? _imagePath;
  String? _videoPath;
  double _blur = 0.03;
  MatteSettings _settings = const MatteSettings();
  OutputFrame _frame = const OutputFrame();
  BackgroundPlacement _placement = const BackgroundPlacement();
  Soundtrack _sound = const Soundtrack();
  Captions _captions = const Captions();
  Outline _outline = const Outline();
  Sequence _seq = const Sequence();
  bool _showOriginal = false;
  VideoPlayerController? _musicPlayer;
  bool _musicListening = false;

  /// What dragging the preview moves (when the background can move too).
  bool _dragSpeaker = true;
  int _timeMs = 0;

  Uint8List? _preview;
  bool _rendering = false;
  bool _renderAgain = false;
  String? _previewError;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _timeMs = (widget.info.durationMs * 0.2).round();
    if (widget.initialImage != null) {
      _imagePath = widget.initialImage;
      _kind = _BgKind.image;
    }
    _schedulePreview(immediate: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _player?.dispose();
    _musicPlayer?.dispose();
    super.dispose();
  }

  Background get _background => switch (_kind) {
    _BgKind.color => ColorBackground(_color),
    _BgKind.image => _imagePath != null ? ImageBackground(_imagePath!, placement: _placement) : ColorBackground(_color),
    _BgKind.blur => BlurBackground(_blur),
    _BgKind.video => _videoPath != null ? VideoBackground(_videoPath!, placement: _placement) : ColorBackground(_color),
  };

  void _schedulePreview({bool immediate = false}) {
    _debounce?.cancel();
    _debounce = Timer(immediate ? Duration.zero : const Duration(milliseconds: 250), _render);
  }

  Future<void> _render() async {
    if (_rendering) {
      _renderAgain = true;
      return;
    }
    setState(() => _rendering = true);
    do {
      _renderAgain = false;
      try {
        final bytes = await HbrEngine.previewFrame(
          widget.path,
          timeMs: _timeMs,
          background: _background,
          settings: _settings,
          frame: _frame,
          captions: _captions,
          outline: _outline,
        );
        if (!mounted) return;
        if (bytes == null) continue; // a newer request is on its way
        setState(() {
          _preview = bytes;
          _previewError = null;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() => _previewError = '$e');
      }
    } while (_renderAgain && mounted);
    if (mounted) setState(() => _rendering = false);
  }

  void _setShowOriginal(bool show) {
    setState(() => _showOriginal = show);
    if (show && _player == null) {
      final p = VideoPlayerController.file(File(widget.path));
      _player = p;
      p.initialize().then((_) {
        if (!mounted || _player != p) return;
        p.seekTo(Duration(milliseconds: _timeMs));
        setState(() {});
      });
    } else if (!show) {
      // free the decoder while editing the result
      final p = _player;
      _player = null;
      p?.dispose();
    }
  }

  Future<void> _pickImage() async {
    final path = await pickOriginal(FileType.image);
    if (path == null) return;
    setState(() {
      _imagePath = path;
      _kind = _BgKind.image;
    });
    _schedulePreview(immediate: true);
  }

  Future<void> _pickVideo() async {
    final path = await pickOriginal(FileType.video);
    if (path == null) return;
    setState(() {
      _videoPath = path;
      _kind = _BgKind.video;
    });
    _schedulePreview(immediate: true);
  }

  Future<void> _export() async {
    if (_kind == _BgKind.image && _imagePath == null) return _pickImage();
    if (_kind == _BgKind.video && _videoPath == null) return _pickVideo();
    _player?.pause();
    _musicPlayer?.pause();
    await showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      isScrollControlled: true,
      builder: (_) => ExportSheet(
        inputPath: widget.path,
        info: widget.info,
        background: _background,
        settings: _settings,
        frame: _frame,
        soundtrack: _sound,
        captions: _captions,
        outline: _outline,
        sequence: _seq,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = widget.info;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit background'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              onPressed: _export,
              icon: const Icon(Icons.ios_share),
              label: const Text('Export'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            _previewArea(theme, info),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: _timeMs.toDouble().clamp(0, info.durationMs.toDouble()),
                    max: info.durationMs.toDouble().clamp(1, double.infinity),
                    onChanged: (v) {
                      setState(() => _timeMs = v.round());
                      if (_playerReady) {
                        _player!.seekTo(Duration(milliseconds: _timeMs));
                      }
                      _schedulePreview();
                    },
                  ),
                ),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: false, label: Text('Result')),
                    ButtonSegment(value: true, label: Text('Original')),
                  ],
                  selected: {_showOriginal},
                  onSelectionChanged: (s) => _setShowOriginal(s.first),
                ),
              ],
            ),
            Text(
              _exportSummary(info),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            _frameSection(theme),
            const SizedBox(height: 20),
            Text('Background', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<_BgKind>(
              segments: const [
                ButtonSegment(value: _BgKind.color, icon: Icon(Icons.palette_outlined), label: Text('Color')),
                ButtonSegment(value: _BgKind.image, icon: Icon(Icons.image_outlined), label: Text('Image')),
                ButtonSegment(value: _BgKind.blur, icon: Icon(Icons.blur_on), label: Text('Blur')),
                ButtonSegment(value: _BgKind.video, icon: Icon(Icons.movie_outlined), label: Text('Video')),
              ],
              selected: {_kind},
              onSelectionChanged: (s) {
                final k = s.first;
                if (k == _BgKind.image && _imagePath == null) {
                  _pickImage();
                  return;
                }
                if (k == _BgKind.video && _videoPath == null) {
                  _pickVideo();
                  return;
                }
                setState(() => _kind = k);
                _schedulePreview(immediate: true);
              },
            ),
            const SizedBox(height: 12),
            _backgroundOptions(theme),
            const SizedBox(height: 24),
            CaptionsSection(
              videoPath: widget.path,
              hasAudio: widget.info.hasAudio,
              captions: _captions,
              onChanged: (c) {
                setState(() => _captions = c);
                _schedulePreview();
              },
              onSeek: (ms) {
                setState(() => _timeMs = ms);
                if (_playerReady) _player!.seekTo(Duration(milliseconds: ms));
                _schedulePreview(immediate: true);
              },
            ),
            const SizedBox(height: 24),
            _outlineSection(theme),
            const SizedBox(height: 24),
            _introSection(theme),
            const SizedBox(height: 24),
            _soundSection(theme),
            const SizedBox(height: 20),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text('Matte quality', style: theme.textTheme.titleMedium),
              children: [
                _labeledSlider(
                  'Edge softness',
                  _settings.edgeSoftness,
                  (v) => _settings = _settings.copyWith(edgeSoftness: v),
                  left: 'Crisp',
                  right: 'Soft',
                ),
                _labeledSlider(
                  'Edge smoothing',
                  _settings.edgeSmoothing,
                  (v) => _settings = _settings.copyWith(edgeSmoothing: v),
                  left: 'Raw',
                  right: 'Smoothest',
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Clean edge colours'),
                  subtitle: const Text('Removes the old background tint from hair and edges'),
                  value: _settings.cleanEdgeColors,
                  onChanged: (v) {
                    setState(() => _settings = _settings.copyWith(cleanEdgeColors: v));
                    _schedulePreview(immediate: true);
                  },
                ),
                _labeledSlider(
                  'Stability (reduces flicker)',
                  _settings.temporalStrength,
                  (v) => _settings = _settings.copyWith(temporalStrength: v),
                  left: 'Off',
                  right: 'Max',
                  affectsPreview: false,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Highest quality segmentation'),
                  subtitle: const Text('Slower export, finer hair and edges'),
                  value: _settings.highQualitySegmentation,
                  onChanged: (v) {
                    setState(() => _settings = _settings.copyWith(highQualitySegmentation: v));
                    _schedulePreview();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  bool get _movable => (_kind == _BgKind.image && _imagePath != null) || (_kind == _BgKind.video && _videoPath != null);

  String _exportSummary(VideoInfo info) {
    if (_frame.shape == FrameShape.original && _sound.isOriginal) return 'Export keeps ${info.summary}';
    if (_frame.shape == FrameShape.original) {
      return 'Export keeps ${info.displayWidth}x${info.displayHeight} video quality · sound: '
          '${_sound.musicPath != null ? 'voice + music' : 'voice level changed'}';
    }
    final (w, h) = _frame.sizeFor(info.displayWidth, info.displayHeight);
    final fps = info.frameRate.toStringAsFixed(info.frameRate % 1 == 0 ? 0 : 2);
    return 'Export: ${w}x$h (${_frame.shape.label}, ${_frame.fit ? 'whole video' : 'filled'})'
        ' · $fps fps · ${info.codec.toUpperCase()}${info.hasAudio ? ' · audio' : ''}';
  }

  Widget _frameSection(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Frame size', style: theme.textTheme.titleMedium),
        const SizedBox(height: 10),
        SizedBox(
          height: 78,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final shape in FrameShape.values)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: _ShapeChip(
                    shape: shape,
                    sourceRatio: widget.info.aspectRatio,
                    selected: _frame.shape == shape,
                    onTap: () {
                      setState(() => _frame = _frame.copyWith(shape: shape));
                      _schedulePreview(immediate: true);
                    },
                  ),
                ),
            ],
          ),
        ),
        if (_frame.shape != FrameShape.original) ...[
          const SizedBox(height: 10),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, icon: Icon(Icons.crop), label: Text('Fill frame')),
              ButtonSegment(value: true, icon: Icon(Icons.fit_screen_outlined), label: Text('Whole video')),
            ],
            selected: {_frame.fit},
            onSelectionChanged: (s) {
              setState(() => _frame = _frame.copyWith(fit: s.first));
              _schedulePreview(immediate: true);
            },
          ),
          const SizedBox(height: 4),
          Text(
            _frame.fit
                ? 'The whole video is shown; your background fills the rest of the frame.'
                : 'The video fills the frame; the edges outside it are trimmed.',
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: Text('Speaker', style: theme.textTheme.titleSmall)),
            if (_frame.personMoved)
              TextButton.icon(
                onPressed: () {
                  setState(() => _frame = _frame.withoutPersonMove());
                  _schedulePreview(immediate: true);
                },
                icon: const Icon(Icons.restart_alt, size: 18),
                label: const Text('Reset'),
              ),
          ],
        ),
        Row(
          children: [
            const Icon(Icons.person_outline, size: 20),
            Expanded(
              child: Slider(
                value: _frame.personScale,
                min: 0.3,
                max: 2.5,
                label: '${(_frame.personScale * 100).round()}%',
                divisions: 44,
                onChanged: (v) => setState(() => _frame = _frame.copyWith(personScale: v)),
                onChangeEnd: (_) => _schedulePreview(immediate: true),
              ),
            ),
            SizedBox(width: 48, child: Text('${(_frame.personScale * 100).round()}%', textAlign: TextAlign.end)),
          ],
        ),
        if (_movable)
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: true, icon: Icon(Icons.person_pin_outlined), label: Text('Move speaker')),
              ButtonSegment(value: false, icon: Icon(Icons.wallpaper_outlined), label: Text('Move background')),
            ],
            selected: {_dragSpeaker},
            onSelectionChanged: (s) => setState(() => _dragSpeaker = s.first),
          ),
        const SizedBox(height: 4),
        Text(
          _dragSpeaker || !_movable
              ? 'Drag the preview to move the speaker. Make them smaller to show more background.'
              : 'Drag the preview to move the background picture.',
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  /// Moves the speaker's video so it follows the finger exactly.
  void _moveSpeaker(DragUpdateDetails d, Size box) {
    final (fw, fh) = _frame.sizeFor(widget.info.displayWidth, widget.info.displayHeight);
    final (pw, ph) = _frame.personSizeOn(fw, fh, widget.info.displayWidth, widget.info.displayHeight);
    // the preview box shows the whole frame: box px -> frame px
    final k = fw / box.width;
    final freeX = fw - pw, freeY = fh - ph; // pan -1..1 spans this range
    setState(
      () => _frame = _frame.copyWith(
        personX: freeX.abs() < 1 ? _frame.personX : _frame.personX + 2 * d.delta.dx * k / freeX,
        personY: freeY.abs() < 1 ? _frame.personY : _frame.personY + 2 * d.delta.dy * k / freeY,
      ),
    );
    _schedulePreview();
  }

  Widget _placementControls(ThemeData theme) {
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Row(
          children: [
            const Icon(Icons.zoom_out_map, size: 20),
            const SizedBox(width: 8),
            const Text('Size'),
            Expanded(
              child: Slider(
                value: _placement.scale.clamp(0.4, 3.0),
                min: 0.4,
                max: 3.0,
                divisions: 52,
                label: '${(_placement.scale * 100).round()}%',
                onChanged: (v) => setState(() => _placement = _placement.copyWith(scale: v)),
                onChangeEnd: (_) => _schedulePreview(immediate: true),
              ),
            ),
            SizedBox(width: 48, child: Text('${(_placement.scale * 100).round()}%', textAlign: TextAlign.end)),
          ],
        ),
        Row(
          children: [
            Expanded(child: Text('Drag the preview to move the background.', style: small)),
            TextButton.icon(
              onPressed: _placement.isDefault
                  ? null
                  : () {
                      setState(() => _placement = BackgroundPlacement(fillArgb: _placement.fillArgb));
                      _schedulePreview(immediate: true);
                    },
              icon: const Icon(Icons.center_focus_strong_outlined, size: 18),
              label: const Text('Reset'),
            ),
          ],
        ),
        if (_placement.scale < 1.0) ...[
          const SizedBox(height: 6),
          Text('Colour around the background', style: small),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              for (final c in _swatches)
                _Swatch(
                  color: c,
                  size: 28,
                  selected: c == _placement.fillArgb,
                  onTap: () {
                    setState(() => _placement = _placement.copyWith(fillArgb: c));
                    _schedulePreview(immediate: true);
                  },
                ),
            ],
          ),
        ],
      ],
    );
  }

  static const _outlineColors = [
    0xFFFFFFFF,
    0xFF000000,
    0xFFF59E0B,
    0xFFEC4899,
    0xFF2DD4BF,
    0xFF0047BB,
    0xFFEF4444,
    0xFF22C55E,
  ];

  void _setOutline(Outline o) {
    setState(() => _outline = o);
    _schedulePreview(immediate: true);
  }

  Widget _outlineSection(ThemeData theme) {
    final o = _outline;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('Outline', style: theme.textTheme.titleMedium),
          subtitle: const Text('A line or glow around the speaker'),
          value: o.enabled,
          onChanged: (v) => _setOutline(o.copyWith(enabled: v)),
        ),
        if (o.enabled) ...[
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final c in _outlineColors)
                _Swatch(
                  color: c,
                  size: 34,
                  selected: c == o.argb,
                  onTap: () => _setOutline(o.copyWith(argb: c)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<double>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: Outline.thin, label: Text('Thin')),
                ButtonSegment(value: Outline.medium, label: Text('Medium')),
                ButtonSegment(value: Outline.thick, label: Text('Thick')),
              ],
              selected: {o.width},
              onSelectionChanged: (s) => _setOutline(o.copyWith(width: s.first)),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('Solid line')),
                ButtonSegment(value: true, label: Text('Soft glow')),
              ],
              selected: {o.glow},
              onSelectionChanged: (s) => _setOutline(o.copyWith(glow: s.first)),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _addClip(bool before, bool video) async {
    final path = await pickOriginal(video ? FileType.video : FileType.image);
    if (path == null || !mounted) return;
    double? len;
    if (video) {
      try {
        len = (await HbrEngine.probe(path)).durationMs / 1000;
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open that video: $e')));
        }
        return;
      }
    }
    if (!mounted) return;
    final clip = IntroClip(path: path, isVideo: video, videoLengthS: len);
    setState(
      () => _seq = before ? _seq.copyWith(before: [..._seq.before, clip]) : _seq.copyWith(after: [..._seq.after, clip]),
    );
  }

  void _updateClip(bool before, int i, IntroClip? c) {
    final list = [...(before ? _seq.before : _seq.after)];
    if (c == null) {
      list.removeAt(i);
    } else {
      list[i] = c;
    }
    setState(() => _seq = before ? _seq.copyWith(before: list) : _seq.copyWith(after: list));
  }

  static String _secs(double s) => '${s >= 10 ? s.round() : (s * 10).round() / 10} s';

  Widget _clipTile(ThemeData theme, bool before, int i, IntroClip c) {
    final scheme = theme.colorScheme;
    DropdownMenuItem<String> item(String v, String l) => DropdownMenuItem(value: v, child: Text(l));
    Widget drop<T>(T value, List<DropdownMenuItem<T>> items, void Function(T) on) => DropdownButton<T>(
      value: value,
      isDense: true,
      items: items,
      onChanged: (v) {
        if (v != null) on(v);
      },
    );
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(12)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 52,
              height: 52,
              child: c.isVideo
                  ? ColoredBox(
                      color: Colors.black,
                      child: Icon(Icons.movie_outlined, color: scheme.primary),
                    )
                  : Image.file(
                      File(c.path),
                      fit: BoxFit.cover,
                      cacheWidth: 120,
                      errorBuilder: (_, _, _) => const Icon(Icons.image_outlined),
                    ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${c.path.split('/').last} · ${_secs(c.lengthS)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    drop<String>(c.transition, [
                      for (final t in transitions) item(t.$1, t.$2),
                    ], (v) => _updateClip(before, i, c.copyWith(transition: v))),
                    drop<bool>(c.fit, const [
                      DropdownMenuItem(value: false, child: Text('Fill frame')),
                      DropdownMenuItem(value: true, child: Text('Whole picture')),
                    ], (v) => _updateClip(before, i, c.copyWith(fit: v))),
                    if (!c.isVideo) ...[
                      drop<double>(c.durationS, [
                        for (final d in const [2.0, 3.0, 4.0, 5.0, 7.0, 10.0])
                          DropdownMenuItem(value: d, child: Text('${d.round()} seconds')),
                      ], (v) => _updateClip(before, i, c.copyWith(durationS: v))),
                      drop<String>(c.motion, [
                        item('none', 'Still'),
                        item('in', 'Slow zoom in'),
                        item('out', 'Slow zoom out'),
                      ], (v) => _updateClip(before, i, c.copyWith(motion: v))),
                    ],
                  ],
                ),
              ],
            ),
          ),
          IconButton(tooltip: 'Remove', onPressed: () => _updateClip(before, i, null), icon: const Icon(Icons.close)),
        ],
      ),
    );
  }

  Widget _clipList(ThemeData theme, bool before) {
    final list = before ? _seq.before : _seq.after;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              before ? 'Before your video' : 'After your video',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton.icon(
                  onPressed: () => _addClip(before, false),
                  icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                  label: const Text('Picture'),
                ),
                TextButton.icon(
                  onPressed: () => _addClip(before, true),
                  icon: const Icon(Icons.video_call_outlined, size: 18),
                  label: const Text('Video'),
                ),
              ],
            ),
          ],
        ),
        for (var i = 0; i < list.length; i++) _clipTile(theme, before, i, list[i]),
      ],
    );
  }

  Widget _introSection(ThemeData theme) {
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final extra = [..._seq.before, ..._seq.after].fold<double>(0, (a, c) => a + c.lengthS);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Intro & outro', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Add pictures or videos before and after your video, with an animation between each part.'
          '${extra > 0 ? ' Adds ${_secs(extra)}.' : ''}',
          style: small,
        ),
        _clipList(theme, true),
        _clipList(theme, false),
        const SizedBox(height: 12),
        const Text('Animation into your video', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in transitions)
              ChoiceChip(
                label: Text(t.$2),
                selected: _seq.into == t.$1,
                onSelected: (_) => setState(() => _seq = _seq.copyWith(into: t.$1)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text('Animation length ${_seq.transitionS.toStringAsFixed(1)} s'),
        Row(
          children: [
            Expanded(
              child: Slider(
                value: _seq.transitionS,
                min: 0.3,
                max: 2,
                divisions: 17,
                label: '${_seq.transitionS.toStringAsFixed(1)} s',
                onChanged: (v) => setState(() => _seq = _seq.copyWith(transitionS: v)),
              ),
            ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Fade in from black'),
          value: _seq.fadeIn,
          onChanged: (v) => setState(() => _seq = _seq.copyWith(fadeIn: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Fade to black at the end'),
          value: _seq.fadeOut,
          onChanged: (v) => setState(() => _seq = _seq.copyWith(fadeOut: v)),
        ),
      ],
    );
  }

  Future<void> _pickMusic() async {
    final path = await pickOriginal(FileType.audio);
    if (path == null) return;
    setState(() => _sound = _sound.copyWith(musicPath: path));
    _openMusicPlayer(path);
  }

  /// Player for the chosen song: gives its length and lets the person
  /// listen from the chosen start point.
  void _openMusicPlayer(String? path) {
    final old = _musicPlayer;
    _musicPlayer = null;
    old?.dispose();
    if (path == null) return;
    final p = VideoPlayerController.file(File(path));
    _musicPlayer = p;
    p
        .initialize()
        .then((_) {
          if (mounted && _musicPlayer == p) setState(() {});
        })
        .catchError((_) {});
    p.addListener(() {
      if (mounted && _musicPlayer == p && _musicListening != p.value.isPlaying) {
        setState(() => _musicListening = p.value.isPlaying);
      }
    });
  }

  Future<void> _listenFromStart() async {
    final p = _musicPlayer;
    if (p == null || !p.value.isInitialized) return;
    if (p.value.isPlaying) {
      await p.pause();
      return;
    }
    await p.seekTo(Duration(milliseconds: _sound.musicStartMs));
    await p.play();
  }

  /// Latest start point: one second before the end of the song.
  double get _musicStartMax => ((_musicPlayer?.value.duration.inMilliseconds ?? 0) - 1000).clamp(1, 1 << 30).toDouble();

  static String _mmss(int ms) {
    final s = ms ~/ 1000;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  Widget _soundSection(ThemeData theme) {
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final music = _sound.musicPath;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Sound', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(14)),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.music_note_rounded, color: scheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      music == null ? 'No music' : music.split('/').last,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      music == null ? 'Add a song or beat from your phone' : 'Loops to the end, fades out',
                      style: small,
                    ),
                  ],
                ),
              ),
              if (music != null)
                IconButton(
                  tooltip: 'Remove music',
                  onPressed: () {
                    setState(() => _sound = _sound.copyWith(clearMusic: true));
                    _openMusicPlayer(null);
                  },
                  icon: const Icon(Icons.close),
                ),
              FilledButton.tonal(onPressed: _pickMusic, child: Text(music == null ? 'Add music' : 'Change')),
            ],
          ),
        ),
        if (music != null && (_musicPlayer?.value.isInitialized ?? false)) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              IconButton.filledTonal(
                tooltip: _musicListening ? 'Stop' : 'Listen from here',
                onPressed: _listenFromStart,
                icon: Icon(_musicListening ? Icons.stop_rounded : Icons.play_arrow_rounded),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Music starts at ${_mmss(_sound.musicStartMs)}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Slider(
                      value: _sound.musicStartMs.toDouble().clamp(0, _musicStartMax),
                      max: _musicStartMax,
                      onChanged: (v) => setState(() => _sound = _sound.copyWith(musicStartMs: v.round())),
                      onChangeEnd: (v) {
                        if (_musicListening) _musicPlayer?.seekTo(Duration(milliseconds: v.round()));
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
          Text(
            'Slide to choose the part of the song you want. Song length ${_mmss(_musicPlayer!.value.duration.inMilliseconds)}.',
            style: small,
          ),
        ],
        if (music != null) ...[
          _volumeRow(
            Icons.music_note_outlined,
            'Music',
            _sound.musicVolume,
            1.0,
            (v) => _sound = _sound.copyWith(musicVolume: v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Lower music while talking'),
            subtitle: const Text('Keeps the voice clear over the music'),
            value: _sound.duckMusic,
            onChanged: (v) => setState(() => _sound = _sound.copyWith(duckMusic: v)),
          ),
        ],
        if (widget.info.hasAudio)
          _volumeRow(
            Icons.record_voice_over_outlined,
            'Voice',
            _sound.voiceVolume,
            1.5,
            (v) => _sound = _sound.copyWith(voiceVolume: v),
          ),
      ],
    );
  }

  Widget _volumeRow(IconData icon, String label, double value, double max, void Function(double) apply) => Row(
    children: [
      Icon(icon, size: 20),
      const SizedBox(width: 8),
      SizedBox(width: 48, child: Text(label)),
      Expanded(
        child: Slider(
          value: value.clamp(0.0, max),
          max: max,
          divisions: (max * 20).round(),
          label: '${(value * 100).round()}%',
          onChanged: (v) => setState(() => apply(v)),
        ),
      ),
      SizedBox(width: 44, child: Text('${(value * 100).round()}%', textAlign: TextAlign.end)),
    ],
  );

  void _dragBackground(DragUpdateDetails d, Size box) {
    // Follow the finger: a zoomed-in picture moves its visible part, a
    // smaller picture moves around the frame.
    final sign = _placement.scale >= 1.0 ? -1.0 : 1.0;
    setState(
      () => _placement = _placement.copyWith(
        panX: _placement.panX + sign * 2 * d.delta.dx / box.width,
        panY: _placement.panY + sign * 2 * d.delta.dy / box.height,
      ),
    );
    _schedulePreview();
  }

  Widget _previewArea(ThemeData theme, VideoInfo info) {
    final (fw, fh) = _frame.sizeFor(info.displayWidth, info.displayHeight);
    final aspect = _showOriginal ? info.aspectRatio : fw / fh;
    Widget child;
    if (_showOriginal) {
      child = _playerReady
          ? GestureDetector(
              onTap: () => setState(() => _player!.value.isPlaying ? _player!.pause() : _player!.play()),
              child: VideoPlayer(_player!),
            )
          : const Center(child: CircularProgressIndicator());
    } else if (_preview != null) {
      child = Image.memory(_preview!, fit: BoxFit.contain, gaplessPlayback: true);
      // Keep the picture in its own final variable: the builder runs later,
      // and reading `child` there would find this LayoutBuilder itself and
      // nest it inside itself without end (that froze the app).
      final picture = child;
      child = LayoutBuilder(
        builder: (context, c) => GestureDetector(
          onPanUpdate: (d) => _movable && !_dragSpeaker ? _dragBackground(d, c.biggest) : _moveSpeaker(d, c.biggest),
          child: picture,
        ),
      );
    } else if (_previewError != null) {
      child = Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Preview failed: $_previewError', textAlign: TextAlign.center),
        ),
      );
    } else {
      child = const Center(child: CircularProgressIndicator());
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
        child: AspectRatio(
          aspectRatio: aspect,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Colors.black),
              child,
              if (_rendering && !_showOriginal)
                const Positioned(
                  right: 12,
                  top: 12,
                  child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _backgroundOptions(ThemeData theme) {
    switch (_kind) {
      case _BgKind.color:
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final c in _swatches)
              _Swatch(
                color: c,
                selected: c == _color,
                onTap: () {
                  setState(() => _color = c);
                  _schedulePreview(immediate: true);
                },
              ),
          ],
        );
      case _BgKind.image:
        return Column(
          children: [
            _fileRow(Icons.image_outlined, _imagePath, 'Choose image', _pickImage),
            if (_imagePath != null) _placementControls(theme),
          ],
        );
      case _BgKind.video:
        return Column(
          children: [
            _fileRow(Icons.movie_outlined, _videoPath, 'Choose video', _pickVideo),
            if (_videoPath != null) _placementControls(theme),
          ],
        );
      case _BgKind.blur:
        return _labeledSlider(
          'Blur strength',
          (_blur - 0.005) / 0.075,
          (v) => _blur = 0.005 + v * 0.075,
          left: 'Light',
          right: 'Heavy',
        );
    }
  }

  Widget _fileRow(IconData icon, String? path, String label, VoidCallback onTap) => Row(
    children: [
      Icon(icon),
      const SizedBox(width: 12),
      Expanded(child: Text(path == null ? 'Nothing selected' : path.split('/').last, overflow: TextOverflow.ellipsis)),
      OutlinedButton(onPressed: onTap, child: Text(path == null ? label : 'Change')),
    ],
  );

  Widget _labeledSlider(
    String label,
    double value,
    void Function(double) apply, {
    required String left,
    required String right,
    bool affectsPreview = true,
  }) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label),
        Row(
          children: [
            Text(left, style: small),
            Expanded(
              child: Slider(
                value: value.clamp(0.0, 1.0),
                onChanged: (v) => setState(() => apply(v)),
                onChangeEnd: (_) {
                  if (affectsPreview) _schedulePreview(immediate: true);
                },
              ),
            ),
            Text(right, style: small),
          ],
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.selected, required this.onTap, this.size = 40});
  final int color;
  final bool selected;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Color(color),
          shape: BoxShape.circle,
          border: Border.all(color: selected ? primary : Colors.white24, width: selected ? 3 : 1),
        ),
      ),
    );
  }
}

/// A frame-shape choice drawn as a small proportional rectangle.
class _ShapeChip extends StatelessWidget {
  const _ShapeChip({required this.shape, required this.sourceRatio, required this.selected, required this.onTap});
  final FrameShape shape;
  final double sourceRatio;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = shape.ratio ?? sourceRatio;
    const box = 34.0;
    final w = r >= 1 ? box : box * r;
    final h = r >= 1 ? box / r : box;
    final fg = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Material(
      color: selected ? scheme.primary.withValues(alpha: 0.14) : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          width: 66,
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? scheme.primary : Colors.transparent, width: 1.5),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: box,
                height: box,
                child: Center(
                  child: Container(
                    width: w,
                    height: h,
                    decoration: BoxDecoration(
                      border: Border.all(color: fg, width: 2),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              // scales down instead of overflowing with large system text
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    shape.label,
                    maxLines: 1,
                    style: TextStyle(fontSize: 12, color: fg, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
