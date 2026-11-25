import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:hbr_engine/hbr_engine.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

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
  const EditorScreen({super.key, required this.path, required this.info});
  final String path;
  final VideoInfo info;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final VideoPlayerController _player;
  _BgKind _kind = _BgKind.color;
  int _color = _swatches.first;
  String? _imagePath;
  String? _videoPath;
  double _blur = 0.03;
  MatteSettings _settings = const MatteSettings();
  bool _showOriginal = false;
  int _timeMs = 0;

  Uint8List? _preview;
  bool _rendering = false;
  bool _renderAgain = false;
  String? _previewError;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _player = VideoPlayerController.file(File(widget.path))
      ..initialize().then((_) {
        if (mounted) setState(() {});
      });
    _timeMs = (widget.info.durationMs * 0.2).round();
    _schedulePreview(immediate: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _player.dispose();
    super.dispose();
  }

  Background get _background => switch (_kind) {
        _BgKind.color => ColorBackground(_color),
        _BgKind.image => _imagePath != null
            ? ImageBackground(_imagePath!)
            : ColorBackground(_color),
        _BgKind.blur => BlurBackground(_blur),
        _BgKind.video => _videoPath != null
            ? VideoBackground(_videoPath!)
            : ColorBackground(_color),
      };

  void _schedulePreview({bool immediate = false}) {
    _debounce?.cancel();
    _debounce = Timer(
        immediate ? Duration.zero : const Duration(milliseconds: 250), _render);
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
        );
        if (!mounted) return;
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
    _player.pause();
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
            Row(children: [
              Expanded(
                child: Slider(
                  value: _timeMs.toDouble().clamp(0, info.durationMs.toDouble()),
                  max: info.durationMs.toDouble().clamp(1, double.infinity),
                  onChanged: (v) {
                    setState(() => _timeMs = v.round());
                    if (_player.value.isInitialized) {
                      _player.seekTo(Duration(milliseconds: _timeMs));
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
                onSelectionChanged: (s) => setState(() => _showOriginal = s.first),
              ),
            ]),
            Text(
              'Export keeps ${info.summary}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
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

  Widget _previewArea(ThemeData theme, VideoInfo info) {
    final aspect = info.aspectRatio;
    Widget child;
    if (_showOriginal) {
      child = _player.value.isInitialized
          ? GestureDetector(
              onTap: () => setState(() =>
                  _player.value.isPlaying ? _player.pause() : _player.play()),
              child: VideoPlayer(_player),
            )
          : const Center(child: CircularProgressIndicator());
    } else if (_preview != null) {
      child = Image.memory(_preview!, fit: BoxFit.contain, gaplessPlayback: true);
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
          child: Stack(fit: StackFit.expand, children: [
            const ColoredBox(color: Colors.black),
            child,
            if (_rendering && !_showOriginal)
              const Positioned(
                right: 12,
                top: 12,
                child: SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
          ]),
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
              GestureDetector(
                onTap: () {
                  setState(() => _color = c);
                  _schedulePreview(immediate: true);
                },
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: c == _color ? theme.colorScheme.primary : Colors.white24,
                      width: c == _color ? 3 : 1,
                    ),
                  ),
                ),
              ),
          ],
        );
      case _BgKind.image:
        return _fileRow(Icons.image_outlined, _imagePath, 'Choose image', _pickImage);
      case _BgKind.video:
        return _fileRow(Icons.movie_outlined, _videoPath, 'Choose video', _pickVideo);
      case _BgKind.blur:
        return _labeledSlider('Blur strength', (_blur - 0.005) / 0.075,
            (v) => _blur = 0.005 + v * 0.075,
            left: 'Light', right: 'Heavy');
    }
  }

  Widget _fileRow(IconData icon, String? path, String label, VoidCallback onTap) => Row(children: [
        Icon(icon),
        const SizedBox(width: 12),
        Expanded(
          child: Text(path == null ? 'Nothing selected' : path.split('/').last,
              overflow: TextOverflow.ellipsis),
        ),
        OutlinedButton(onPressed: onTap, child: Text(path == null ? label : 'Change')),
      ]);

  Widget _labeledSlider(String label, double value, void Function(double) apply,
      {required String left, required String right, bool affectsPreview = true}) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label),
      Row(children: [
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
      ]),
    ]);
  }
}
