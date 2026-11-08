import 'dart:io';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';

Future<void> main(List<String> args) async {
  final code = args.length == 1 && args.first == 'daemon' ? await runDaemon(Platform.environment) : await runCli(args);
  await stdout.flush();
  exit(code);
}
