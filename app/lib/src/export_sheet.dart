import 'dart:async';
import 'dart:io';

import 'package:gal/gal.dart';
import 'package:hbr_engine/hbr_engine.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'result_screen.dart';

/// Runs the export, shows progress, then saves to the gallery.
class ExportSheet extends StatefulWidget {
  const ExportSheet({
    super.key,
    required this.inputPath,
    required this.info,
    required this.background,
    required this.settings,
    this.frame = const OutputFrame(),
    this.soundtrack = const Soundtrack(),
  });

  final String inputPath;
  final VideoInfo info;
  final Background background;
  final MatteSettings settings;
  final OutputFrame frame;
  final Soundtrack soundtrack;

  @override
  State<ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<ExportSheet> {
  StreamSubscription<ExportProgress>? _sub;
  double _fraction = 0;
  double _fps = 0;
  int _frames = 0;
  String? _error;
  bool _cancelling = false;

  int get _totalFrames =>
      (widget.info.durationMs / 1000 * widget.info.frameRate).round().clamp(1, 1 << 30);

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final dir = await getTemporaryDirectory();
    final out = '${dir.path}/holistic_${DateTime.now().millisecondsSinceEpoch}.mp4';
    _sub = HbrEngine.export(
      inputPath: widget.inputPath,
      outputPath: out,
      background: widget.background,
      settings: widget.settings,
      frame: widget.frame,
      soundtrack: widget.soundtrack,
    ).listen((p) async {
      if (!mounted) return;
      if (p.error != null) {
        setState(() => _error = p.error);
      } else if (p.cancelled) {
        Navigator.of(context).pop();
      } else if (p.done) {
        await _finish(p.outputPath ?? out, p.warning);
      } else {
        setState(() {
          _fraction = p.fraction;
          _fps = p.fps;
          _frames = p.framesDone;
        });
      }
    });
  }

  Future<void> _finish(String path, String? warning) async {
    var saved = false;
    String? saveError;
    try {
      if (await Gal.hasPermission(toAlbum: true) || await Gal.requestPermission(toAlbum: true)) {
        await Gal.putVideo(path, album: 'Holistic');
        saved = true;
      }
    } catch (e) {
      saveError = '$e';
    }
    if (!mounted) return;
    final nav = Navigator.of(context);
    nav.pop();
    await nav.push(MaterialPageRoute<void>(
      builder: (_) => ResultScreen(
        path: path,
        savedToGallery: saved,
        note: [warning, if (saveError != null) 'Saving to gallery failed: $saveError']
            .whereType<String>()
            .join('\n'),
      ),
    ));
  }

  String get _eta {
    if (_fps <= 0) return 'Estimating time left...';
    final left = ((_totalFrames - _frames) / _fps).clamp(0, 1e6).round();
    final m = left ~/ 60, s = left % 60;
    return m > 0 ? 'About ${m}m ${s}s left' : 'About ${s}s left';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_error == null ? 'Exporting at original quality' : 'Export failed',
                style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(widget.info.summary,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 20),
            if (_error == null) ...[
              LinearProgressIndicator(value: _fraction > 0 ? _fraction : null),
              const SizedBox(height: 12),
              Text('${(_fraction * 100).toStringAsFixed(0)}% · frame $_frames of ~$_totalFrames'
                  '${_fps > 0 ? ' · ${_fps.toStringAsFixed(1)} fps' : ''}'),
              Text(_eta, style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              Text('Keep the app open. Nothing is uploaded.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ] else
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerRight,
              child: _error == null
                  ? TextButton(
                      onPressed: _cancelling
                          ? null
                          : () {
                              setState(() => _cancelling = true);
                              HbrEngine.cancel();
                            },
                      child: Text(_cancelling ? 'Cancelling...' : 'Cancel'),
                    )
                  : FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Close'),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Removes leftover exports from earlier sessions (they are already in the
/// gallery). Called on app start.
Future<void> cleanOldExports() async {
  final dir = await getTemporaryDirectory();
  final cutoff = DateTime.now().subtract(const Duration(days: 1));
  await for (final f in dir.list()) {
    if (f is File && f.path.contains('holistic_') && (await f.lastModified()).isBefore(cutoff)) {
      await f.delete();
    }
  }
}
