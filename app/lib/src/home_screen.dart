import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:hbr_engine/hbr_engine.dart';
import 'package:material_ui/material_ui.dart';

import 'editor_screen.dart';

/// Picks the original file, never a transcoded copy, so quality is preserved
/// from the very first step.
Future<String?> pickOriginal(FileType type) async {
  final file = await FilePicker.pickFile(
    type: type,
    compressionQuality: 0,
    darwinOptions: const DarwinOptions(
      assetRepresentationMode: DarwinAssetRepresentationMode.current,
    ),
  );
  return file?.path;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _openFromLaunch();
  }

  /// Opens a video (and background picture) passed in the launch intent.
  /// Used by the on-device tests to drive the real editor.
  Future<void> _openFromLaunch() async {
    try {
      final args = await const MethodChannel('holistic/launch').invokeMapMethod<String, String>('args');
      final video = args?['video'];
      if (video == null) return;
      final info = await HbrEngine.probe(video);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => EditorScreen(path: video, info: info, initialImage: args?['image']),
      ));
    } catch (_) {
      // normal start: no launch arguments
    }
  }

  Future<void> _pick() async {
    setState(() => _loading = true);
    try {
      final path = await pickOriginal(FileType.video);
      if (path == null || !mounted) return;
      final info = await HbrEngine.probe(path);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => EditorScreen(path: path, info: info),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not open video: $e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              Icon(Icons.auto_awesome, size: 48, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text('Holistic\nBackground Remover',
                  style: theme.textTheme.headlineLarge
                      ?.copyWith(fontWeight: FontWeight.w700, height: 1.1)),
              const SizedBox(height: 12),
              Text(
                'Remove or replace the background of any video. '
                'Everything runs on this phone, works offline, and keeps the '
                'original resolution, frame rate and sound.',
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 32),
              const _Feature(icon: Icons.wifi_off, text: '100% offline, nothing is uploaded'),
              const _Feature(icon: Icons.high_quality, text: 'Exports at source quality'),
              const _Feature(icon: Icons.palette_outlined, text: 'Color, image, blur or video backgrounds'),
              const Spacer(flex: 2),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: FilledButton.icon(
                  onPressed: _loading ? null : _pick,
                  icon: _loading
                      ? const SizedBox(
                          width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.video_library_outlined),
                  label: const Text('Choose a video'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Feature extends StatelessWidget {
  const _Feature({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ]),
      );
}
