import 'package:material_ui/material_ui.dart';

import 'src/export_sheet.dart';
import 'src/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  cleanOldExports().catchError((_) {});
  runApp(const HolisticApp());
}

class HolisticApp extends StatelessWidget {
  const HolisticApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF14B8A6),
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'Holistic Background Remover',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0B0F14),
      ),
      home: const HomeScreen(),
    );
  }
}
