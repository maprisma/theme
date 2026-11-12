import 'package:flutter/material.dart';

import 'app.dart';
import 'backend.dart';
import 'window.dart';
import 'window_size.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final backend = await Backend.start();
  // Rule 5a: the window opens at the size the user left it (the runner keeps it on the screen).
  try {
    final settings = (await backend.call('settings.get'))['settings'];
    final size = settings is Map ? parseWindowSize(settings['size']) : null;
    if (size != null) AppWindow.instance.resize(size.$1, size.$2).ignore();
  } on Object {
    // the default size
  }
  runApp(MaprismaThemeApp(call: backend.call));
}
