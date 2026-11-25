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
}
