import 'package:flutter/material.dart';

import '../widgets.dart';

/// Theme editor (TODO: port from the plugin).
class EditorPage extends StatelessWidget {
  const EditorPage({super.key, this.base, this.edit, this.wallpaper});
  final String? base, edit, wallpaper;
  @override
  Widget build(BuildContext context) => const SubPage(title: 'Theme editor', body: Center(child: Text('Coming soon')));
}
