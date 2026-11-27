import 'package:flutter_test/flutter_test.dart';
import 'package:hbr_engine/hbr_engine.dart';
import 'package:holistic_bg/main.dart';

void main() {
  testWidgets('home screen offers to choose a video', (tester) async {
    await tester.pumpWidget(const HolisticApp());
    expect(find.text('Choose a video'), findsOneWidget);
    expect(find.textContaining('offline'), findsWidgets);
  });

  test('video info reports display size for rotated phone video', () {
    final info = VideoInfo.fromMap({
      'width': 1920, 'height': 1080, 'rotation': 90, 'durationMs': 5000,
      'frameRate': 30.0, 'bitrate': 12000000, 'codec': 'hevc',
      'hasAudio': true, 'isHdr': false,
    });
    expect(info.displayWidth, 1080);
    expect(info.displayHeight, 1920);
    expect(info.summary, '1080x1920 · 30 fps · HEVC · 12.0 Mbps · audio');
  });

  test('backgrounds serialise for the native engine', () {
    expect(const ColorBackground(0xFF00B140).toMap(), {'type': 'color', 'argb': 0xFF00B140});
    expect(const BlurBackground(0.05).toMap(), {'type': 'blur', 'amount': 0.05});
    // crisper defaults: less trailing blur around a moving person
    expect(const MatteSettings().toMap()['temporalStrength'], 0.45);
    expect(const MatteSettings().toMap()['edgeSoftness'], 0.2);
    // speaker position is sent only when moved; music start point is sent
    expect(const OutputFrame().toMap().containsKey('personScale'), false);
    final moved = const OutputFrame().copyWith(personScale: 0.5, personX: 2);
    expect(moved.toMap()['personScale'], 0.5);
    expect(moved.toMap()['personX'], 1.0);
    final s = const Soundtrack(musicPath: '/a.mp3').copyWith(musicStartMs: 42000);
    expect((s.toMap()['audio'] as Map)['musicStartMs'], 42000);
    expect(s.copyWith(musicPath: '/b.mp3').musicStartMs, 0);
  });

  test('frame sizes keep the short side', () {
    expect(const OutputFrame(shape: FrameShape.square).sizeFor(1920, 1080), (1080, 1080));
    expect(const OutputFrame(shape: FrameShape.portrait).sizeFor(1920, 1080), (1080, 1920));
    expect(const OutputFrame(shape: FrameShape.portrait45).sizeFor(1080, 1920), (1080, 1350));
    expect(const OutputFrame().sizeFor(1080, 1920), (1080, 1920));
    expect(const OutputFrame(shape: FrameShape.landscape, fit: true).toMap(), {'aspect': '16:9', 'fit': true});
  });

  test('background placement serialises and clamps', () {
    final p = const BackgroundPlacement().copyWith(scale: 1.5, panX: 3);
    expect(p.panX, 1.0);
    expect(ImageBackground('/a.jpg', placement: p).toMap(),
        {'type': 'image', 'path': '/a.jpg', 'scale': 1.5, 'panX': 1.0, 'panY': 0.0, 'fill': 0xFF000000});
  });

  test('captions group into short lines and keep timing when edited', () {
    final words = [
      for (var i = 0; i < 12; i++) CaptionWord(i == 5 ? 'end.' : 'word$i', i * 300, i * 300 + 250),
    ];
    final cues = CaptionCue.group(words);
    expect(cues.first.text, 'word0 word1 word2 word3');
    expect(cues.any((c) => c.text.endsWith('end.')), isTrue);
    final edited = cues.first.withText('Hello there friends');
    expect(edited.words.length, 3);
    expect(edited.startMs, cues.first.startMs);
    expect(edited.endMs, cues.first.endMs);
    final m = Captions(cues: cues).toMap()['captions'] as Map;
    expect((m['style'] as Map)['preset'], 'pop');
    expect(const Captions().toMap(), isEmpty);
  });

  test('outline and intro/outro serialise for the engine', () {
    expect(const Outline().toMap(), isEmpty);
    expect(const Outline(enabled: true, argb: 0xFFF59E0B, width: Outline.thick, glow: true).toMap(),
        {'outline': {'argb': 0xFFF59E0B, 'width': 0.02, 'glow': true}});
    expect(const Sequence().toMap(), isEmpty);
    final s = const Sequence(
      before: [IntroClip(path: '/logo.png', durationS: 2, motion: 'out')],
      after: [IntroClip(path: '/end.mp4', isVideo: true, transition: 'circle', videoLengthS: 4)],
      into: 'push',
      fadeOut: true,
    ).toMap()['sequence'] as Map;
    expect(s['into'], 'push');
    expect(s['fadeOut'], true);
    expect((s['before'] as List).single,
        {'kind': 'image', 'path': '/logo.png', 'durationS': 2.0, 'motion': 'out', 'fit': false, 'transition': 'fade', 'maxS': 60});
    expect(((s['after'] as List).single as Map)['kind'], 'video');
    expect(const Sequence(fadeIn: true).active, isTrue);
    expect(transitions.length, 12);
  });
}
