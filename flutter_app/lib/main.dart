import 'package:flutter/material.dart';

import 'app.dart';
import 'backend.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final backend = await Backend.start();
  runApp(MaprismaThemeApp(call: backend.call));
}
