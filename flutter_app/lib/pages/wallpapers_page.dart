import 'package:flutter/material.dart';

import '../widgets.dart';

/// Wallpapers (TODO: port from the plugin).
class WallpapersPage extends StatelessWidget {
  const WallpapersPage({super.key, required this.slug});
  final String slug;
  @override
  Widget build(BuildContext context) => const SubPage(title: 'Wallpapers', body: Center(child: Text('Coming soon')));
}
