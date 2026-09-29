import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'map/map_screen.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Accessibility tree always on in the browser (screen readers, automated UI tests).
  if (kIsWeb) SemanticsBinding.instance.ensureSemantics();
  final app = await AppState.load();
  runApp(PepApp(app: app));
}

class PepApp extends StatelessWidget {
  const PepApp({super.key, required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Parcours et Pistes',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorSchemeSeed: const Color(0xFF1565C0), useMaterial3: true),
    darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF1565C0), brightness: Brightness.dark, useMaterial3: true),
    home: MapScreen(app: app),
  );
}
