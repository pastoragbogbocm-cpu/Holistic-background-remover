
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hbr_engine/hbr_engine.dart';
import 'package:holistic_bg/src/editor_screen.dart';
import 'package:material_ui/material_ui.dart';

// 1x1 PNG
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
  0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

void main() {
  const info = VideoInfo(
    width: 720, height: 1280, rotation: 0, durationMs: 10000, frameRate: 30,
    bitrate: 4000000, codec: 'avc', hasAudio: true, isHdr: false,
  );

  Future<void> openEditor(WidgetTester tester, {String? image, double textScale = 1}) async {
    tester.view.physicalSize = const Size(1080, 2340); // a typical phone
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('hbr_engine'),
      (call) async => call.method == 'preview' ? _png : null,
    );
    final sw = Stopwatch()..start();
    await tester.pumpWidget(MediaQuery(
      data: MediaQueryData(size: const Size(393, 851), textScaler: TextScaler.linear(textScale)),
      child: MaterialApp(home: EditorScreen(path: '/x.mp4', info: info, initialImage: image)),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    // scroll through every section so all of it is built and laid out
    for (var i = 0; i < 20; i++) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
      await tester.pump(const Duration(milliseconds: 50));
    }
    // ignore: avoid_print
    print('editor (image=$image, text x$textScale) laid out in ${sw.elapsedMilliseconds} ms');
    expect(sw.elapsedMilliseconds, lessThan(10000));
  }

  /// The editor must lay out quickly (an endless layout froze phones).
  testWidgets('editor lays out quickly', (tester) => openEditor(tester),
      timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('editor with a picture background lays out quickly',
      (tester) => openEditor(tester, image: '/bg.jpg'),
      timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('editor fits with large system text', (tester) => openEditor(tester, image: '/bg.jpg', textScale: 1.4),
      timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('turning the outline on sends it to the preview', (tester) async {
    final calls = <MethodCall>[];
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('hbr_engine'), (call) async {
      calls.add(call);
      return call.method == 'preview' ? _png : null;
    });
    await tester.pumpWidget(const MaterialApp(home: EditorScreen(path: '/x.mp4', info: info)));
    await tester.pump(const Duration(milliseconds: 100));
    final toggle = find.widgetWithText(SwitchListTile, 'Outline');
    await tester.scrollUntilVisible(toggle, 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(toggle);
    await tester.pump(const Duration(milliseconds: 400));
    final last = calls.lastWhere((c) => c.method == 'preview');
    final settings = (last.arguments as Map)['settings'] as Map;
    expect(settings['outline'], {'argb': 0xFFFFFFFF, 'width': 0.012, 'glow': false});
    expect(find.text('Thick'), findsOneWidget);
    expect(find.text('Intro & outro'), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
