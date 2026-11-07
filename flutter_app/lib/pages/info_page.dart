import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../widgets.dart';
import '../window.dart';

/// Information: a card for each of the author's other plugins in the Omarchy
/// Plugin Marketplace (more_plugins.py). The list comes from the
/// marketplace's catalog (read at most hourly by the core), else the
/// built-in one; a click opens the plugin's fixed marketplace page.
class InfoPage extends StatefulWidget {
  const InfoPage({super.key});
  @override
  State<InfoPage> createState() => _InfoPageState();
}

/// Glyphs of the known plugins; a new one gets a package.
const _icons = <String, IconData>{
  'ubruckhaus.wlan-monitor': Icons.wifi,
  'ubruckhaus.theme-manager': Icons.palette_outlined,
  'ubruckhaus.bluetooth-monitor': Icons.bluetooth,
  'ubruckhaus.llm-usage': Icons.memory,
  'ubruckhaus.ai-agents-map': Icons.hub_outlined,
  'ubruckhaus.simple-launcher-for-fools': Icons.apps,
  'ubruckhaus.maprisma-launcher': Icons.rocket_launch_outlined,
  'ubruckhaus.simple-tile': Icons.view_quilt_outlined,
  'ubruckhaus.hue-lights': Icons.lightbulb_outline,
  'ubruckhaus.video-trans': Icons.closed_caption_outlined,
  'ubruckhaus.simple-reader': Icons.record_voice_over_outlined,
  'ubruckhaus.simple-recipes': Icons.restaurant_menu,
  'ubruckhaus.my-plugins': Icons.extension_outlined,
};

class _InfoPageState extends State<InfoPage> {
  late final MaprismaThemeAppState app;
  List<Map> plugins = const [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    app = AppScope.read(context);
    load();
  }

  /// The cached list at once, then the marketplace's (at most hourly).
  Future<void> load() async {
    for (final cached in [true, false]) {
      try {
        final r = await app.call('info.plugins', {'cached': cached});
        if (!mounted) return;
        setState(() {
          plugins = [for (final p in r['plugins'] as List) p as Map];
          loading = false;
        });
      } catch (_) {
        if (mounted) setState(() => loading = false);
      }
    }
  }

  Future<void> openCard(Map p) async {
    final r = await app.run('info.open', {'id': p['id']});
    if (r?['opened'] == true) {
      AppWindow.instance.hide();
    } else if (r != null) {
      app.notify('Could not open the browser.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context),
        const SingleActivator(LogicalKeyboardKey.backspace): () => Navigator.maybePop(context),
      },
      child: Focus(
        autofocus: true,
        child: SubPage(
          title: 'Information',
          body: loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(14),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text('MORE PLUGINS BY THE SAME AUTHOR',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1, color: scheme.onSurfaceVariant)),
                    ),
                    LayoutBuilder(
                      builder: (context, box) {
                        final width = (box.maxWidth - 8) / 2;
                        return Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [for (final p in plugins) SizedBox(width: width, child: _card(context, p))],
                        );
                      },
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context, Map p) {
    final scheme = Theme.of(context).colorScheme;
    final name = '${p['name']}';
    return Tooltip(
      message: 'Open $name in the Omarchy Plugin Marketplace',
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => openCard(p),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(color: scheme.primary.withValues(alpha: .16), borderRadius: BorderRadius.circular(5)),
                  child: Icon(_icons[p['id']] ?? Icons.inventory_2_outlined, size: 19, color: scheme.primary),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                      Text('${p['summary']}', maxLines: 3, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                Icon(Icons.open_in_new, size: 14, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
