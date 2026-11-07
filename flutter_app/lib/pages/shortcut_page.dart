import 'package:flutter/material.dart';

import '../widgets.dart';

/// Shortcut (TODO: port from the plugin).
class ShortcutPage extends StatelessWidget {
  const ShortcutPage({super.key, required this.target, this.title});
  final String target;
  final String? title;
  @override
  Widget build(BuildContext context) => const SubPage(title: 'Shortcut', body: Center(child: Text('Coming soon')));
}
