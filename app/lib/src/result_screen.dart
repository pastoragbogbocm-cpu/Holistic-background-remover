import 'dart:io';

import 'package:hbr_engine/hbr_engine.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

class ResultScreen extends StatefulWidget {
  const ResultScreen({super.key, required this.path, required this.savedToGallery, this.note = ''});
  final String path;
  final bool savedToGallery;
  final String note;

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  late final VideoPlayerController _player;
  VideoInfo? _info;

  @override
  void initState() {
    super.initState();
    _player = VideoPlayerController.file(File(widget.path))
      ..setLooping(true)
      ..initialize().then((_) {
        if (mounted) {
          setState(() {});
          _player.play();
        }
      });
    HbrEngine.probe(widget.path).then((i) {
      if (mounted) setState(() => _info = i);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Done')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Center(
                  child: _player.value.isInitialized
                      ? AspectRatio(
                          aspectRatio: _player.value.aspectRatio,
                          child: ClipRRect(
                              borderRadius: BorderRadius.circular(16), child: VideoPlayer(_player)),
                        )
                      : const CircularProgressIndicator(),
                ),
              ),
              const SizedBox(height: 16),
              Row(children: [
                Icon(widget.savedToGallery ? Icons.check_circle : Icons.info_outline,
                    color: widget.savedToGallery ? theme.colorScheme.primary : null),
                const SizedBox(width: 8),
                Text(widget.savedToGallery
                    ? 'Saved to your gallery (album "Holistic")'
                    : 'Not saved to the gallery'),
              ]),
              if (_info != null) ...[
                const SizedBox(height: 6),
                Text(_info!.summary, style: theme.textTheme.bodySmall),
              ],
              if (widget.note.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(widget.note, style: theme.textTheme.bodySmall),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
                  child: const Text('Edit another video'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
