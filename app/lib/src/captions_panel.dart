import 'package:hbr_engine/hbr_engine.dart';
import 'package:material_ui/material_ui.dart';

const _languages = <(String, String)>[
  ('en', 'English'),
  ('auto', 'Detect automatically'),
  ('fr', 'French'),
  ('es', 'Spanish'),
  ('pt', 'Portuguese'),
  ('de', 'German'),
  ('ar', 'Arabic'),
  ('hi', 'Hindi'),
  ('sw', 'Swahili'),
  ('yo', 'Yoruba'),
  ('ha', 'Hausa'),
  ('zh', 'Chinese'),
];

const _highlights = <int>[0xFFFFD60A, 0xFF2DD4BF, 0xFFFF4D8D, 0xFF7CFC00, 0xFFFF8A00, 0xFFFFFFFF];

/// Captions: generate on the phone, pick a look, edit the words.
class CaptionsSection extends StatefulWidget {
  const CaptionsSection({
    super.key,
    required this.videoPath,
    required this.hasAudio,
    required this.captions,
    required this.onChanged,
    required this.onSeek,
  });

  final String videoPath;
  final bool hasAudio;
  final Captions captions;
  final ValueChanged<Captions> onChanged;
  final ValueChanged<int> onSeek;

  @override
  State<CaptionsSection> createState() => _CaptionsSectionState();
}

class _CaptionsSectionState extends State<CaptionsSection> {
  String _language = 'en';
  double? _progress;
  String? _error;

  Captions get _c => widget.captions;

  Future<void> _generate() async {
    setState(() {
      _progress = 0;
      _error = null;
    });
    try {
      final words = await HbrEngine.transcribe(
        widget.videoPath,
        language: _language,
        onProgress: (f) {
          if (mounted) setState(() => _progress = f);
        },
      );
      if (!mounted) return;
      if (words.isEmpty) {
        setState(() => _error = 'No speech was found in this video.');
      } else {
        widget.onChanged(_c.copyWith(enabled: true, cues: CaptionCue.group(words)));
      }
    } catch (e) {
      if (mounted && !'$e'.contains('cancelled')) setState(() => _error = 'Captions failed: $e');
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  Future<void> _edit() async {
    final cues = await Navigator.of(context).push<List<CaptionCue>>(MaterialPageRoute(
      builder: (_) => CaptionEditor(cues: _c.cues, onSeek: widget.onSeek),
    ));
    if (cues != null) widget.onChanged(_c.copyWith(cues: cues));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final has = _c.cues.isNotEmpty;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text('Captions', style: theme.textTheme.titleMedium)),
        if (has)
          Switch(
            value: _c.enabled,
            onChanged: (v) => widget.onChanged(_c.copyWith(enabled: v)),
          ),
      ]),
      const SizedBox(height: 8),
      if (!widget.hasAudio)
        Text('This video has no sound, so there is nothing to caption.', style: small)
      else if (_progress != null) ...[
        Row(children: [
          Expanded(child: LinearProgressIndicator(value: _progress)),
          const SizedBox(width: 12),
          Text('${((_progress ?? 0) * 100).round()}%'),
          TextButton(onPressed: HbrEngine.cancelTranscribe, child: const Text('Cancel')),
        ]),
        const SizedBox(height: 4),
        Text('Listening on your phone. Nothing is uploaded.', style: small),
      ] else if (!has) ...[
        Text('Turns what is said into captions, word by word, right on your phone.', style: small),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: _language,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Spoken language', border: OutlineInputBorder(), isDense: true),
              items: [for (final (code, name) in _languages) DropdownMenuItem(value: code, child: Text(name))],
              onChanged: (v) => setState(() => _language = v ?? 'en'),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: _generate,
            icon: const Icon(Icons.closed_caption_outlined),
            label: const Text('Generate'),
          ),
        ]),
      ] else ...[
        Row(children: [
          Icon(Icons.subtitles_outlined, color: scheme.primary, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text('${_c.cues.length} captions · ${_c.cues.fold<int>(0, (a, c) => a + c.words.length)} words')),
          TextButton.icon(onPressed: _edit, icon: const Icon(Icons.edit_outlined, size: 18), label: const Text('Edit text')),
          IconButton(
            tooltip: 'Generate again',
            onPressed: () => widget.onChanged(_c.copyWith(cues: const [])),
            icon: const Icon(Icons.refresh),
          ),
        ]),
        const SizedBox(height: 8),
        SizedBox(
          height: 64,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final p in CaptionPreset.values)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _PresetChip(
                  preset: p,
                  highlight: Color(_c.style.highlightColor),
                  selected: _c.style.preset == p,
                  onTap: () => widget.onChanged(_c.copyWith(style: _c.style.copyWith(preset: p))),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 10),
        SegmentedButton<CaptionPosition>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: CaptionPosition.top, icon: Icon(Icons.vertical_align_top), label: Text('Top')),
            ButtonSegment(value: CaptionPosition.middle, icon: Icon(Icons.vertical_align_center), label: Text('Middle')),
            ButtonSegment(value: CaptionPosition.bottom, icon: Icon(Icons.vertical_align_bottom), label: Text('Bottom')),
          ],
          selected: {_c.style.position},
          onSelectionChanged: (s) => widget.onChanged(_c.copyWith(style: _c.style.copyWith(position: s.first))),
        ),
        Row(children: [
          const Icon(Icons.format_size, size: 20),
          const SizedBox(width: 8),
          const Text('Size'),
          Expanded(
            child: Slider(
              value: _c.style.size.clamp(0.6, 1.6),
              min: 0.6,
              max: 1.6,
              divisions: 20,
              onChanged: (v) => widget.onChanged(_c.copyWith(style: _c.style.copyWith(size: v))),
            ),
          ),
        ]),
        if (_c.style.preset != CaptionPreset.clean) ...[
          Text('Highlight colour', style: small),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: [
            for (final c in _highlights)
              GestureDetector(
                onTap: () => widget.onChanged(_c.copyWith(style: _c.style.copyWith(highlightColor: c))),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: c == _c.style.highlightColor ? scheme.primary : Colors.white24,
                      width: c == _c.style.highlightColor ? 3 : 1,
                    ),
                  ),
                ),
              ),
          ]),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('ALL CAPS'),
          value: _c.style.uppercase,
          onChanged: (v) => widget.onChanged(_c.copyWith(style: _c.style.copyWith(uppercase: v))),
        ),
      ],
      if (_error != null) Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(_error!, style: TextStyle(color: scheme.error)),
      ),
    ]);
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({required this.preset, required this.highlight, required this.selected, required this.onTap});
  final CaptionPreset preset;
  final Color highlight;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const base = TextStyle(fontSize: 15, fontWeight: FontWeight.w900, height: 1);
    final shadow = [const Shadow(color: Colors.black, blurRadius: 3)];
    final sample = switch (preset) {
      CaptionPreset.pop => Text.rich(TextSpan(children: [
          TextSpan(text: 'Aa ', style: base.copyWith(color: Colors.white, shadows: shadow)),
          TextSpan(text: 'Bb', style: base.copyWith(color: highlight, shadows: shadow)),
        ])),
      CaptionPreset.box => Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(5)),
          child: Text.rich(TextSpan(children: [
            TextSpan(text: 'Aa ', style: base.copyWith(color: Colors.white)),
            TextSpan(text: 'Bb', style: base.copyWith(color: highlight)),
          ])),
        ),
      CaptionPreset.clean => Text('Aa Bb',
          style: base.copyWith(color: Colors.white, fontWeight: FontWeight.w500, shadows: shadow)),
      CaptionPreset.karaoke => Text.rich(TextSpan(children: [
          TextSpan(text: 'Aa ', style: base.copyWith(color: highlight, shadows: shadow)),
          TextSpan(text: 'Bb', style: base.copyWith(color: Colors.white54, shadows: shadow)),
        ])),
    };
    return Material(
      color: const Color(0xFF2A3038),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          width: 84,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? scheme.primary : Colors.transparent, width: 2),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            sample,
            const SizedBox(height: 6),
            Text(preset.label, style: TextStyle(fontSize: 12, color: selected ? scheme.primary : Colors.white70)),
          ]),
        ),
      ),
    );
  }
}

/// Full-screen list to correct the recognised words.
class CaptionEditor extends StatefulWidget {
  const CaptionEditor({super.key, required this.cues, required this.onSeek});
  final List<CaptionCue> cues;
  final ValueChanged<int> onSeek;

  @override
  State<CaptionEditor> createState() => _CaptionEditorState();
}

class _CaptionEditorState extends State<CaptionEditor> {
  late final List<TextEditingController> _ctrl = [
    for (final c in widget.cues) TextEditingController(text: c.text),
  ];

  @override
  void dispose() {
    for (final c in _ctrl) {
      c.dispose();
    }
    super.dispose();
  }

  String _time(int ms) {
    final s = ms ~/ 1000;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}.${((ms % 1000) ~/ 100)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit captions'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop([
                for (var i = 0; i < widget.cues.length; i++)
                  if (_ctrl[i].text.trim().isNotEmpty) widget.cues[i].withText(_ctrl[i].text),
              ]),
              child: const Text('Done'),
            ),
          ),
        ],
      ),
      body: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        itemCount: widget.cues.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          final c = widget.cues[i];
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            InkWell(
              onTap: () => widget.onSeek(c.startMs),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 14, 8, 8),
                child: Text(_time(c.startMs),
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary, fontFeatures: const [FontFeature.tabularFigures()])),
              ),
            ),
            Expanded(
              child: TextField(
                controller: _ctrl[i],
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, hintText: 'Empty removes this caption'),
              ),
            ),
          ]);
        },
      ),
    );
  }
}
