import 'package:flutter/material.dart';

import '../widgets.dart';

/// Theme editor (TODO: port from the plugin).
/// [base]: new theme from this theme; [edit]: edit this custom theme;
/// [wallpaper]: new theme from this picture (a file); [initial]: preset
/// values (Ask AI: `name`, `font`, and color keys as #rrggbb), on top of [base].
class EditorPage extends StatelessWidget {
  const EditorPage({super.key, this.base, this.edit, this.wallpaper, this.initial});
  final String? base, edit, wallpaper;
  final Map<String, String>? initial;
  @override
  Widget build(BuildContext context) => const SubPage(title: 'Theme editor', body: Center(child: Text('Coming soon')));
}
