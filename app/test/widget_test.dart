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
    expect(const MatteSettings().toMap()['temporalStrength'], 0.6);
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
}
