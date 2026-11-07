import 'package:flutter/material.dart';

import '../app.dart';
import '../theme.dart';
import '../widgets.dart';

class PresetsPage extends StatefulWidget {
  const PresetsPage({super.key});
  @override
  State<PresetsPage> createState() => _PresetsPageState();
}

class _PresetsPageState extends State<PresetsPage> {
  Map state = {}, layouts = {};
  List presets = [];
  bool busy = false, loaded = false;
  int workspace = 1;
  String conflict = 'ask';
  final name = TextEditingController();
  bool include = false;
  MaprismaThemeAppState? app;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = AppScope.of(context);
    if (app != next) {
      app?.revision.removeListener(reload);
      app = next;
      next.revision.addListener(reload);
    }
    if (!loaded) {
      loaded = true;
      reload();
    }
  }

  @override
  void dispose() {
    app?.revision.removeListener(reload);
    name.dispose();
    super.dispose();
  }

  Future<void> reload() async {
    final a = app!;
    final w = await a.run('workspaces.get');
    final p = await a.run('presets.list');
    if (!mounted) return;
    setState(() {
      state = w?['state'] as Map? ?? {};
      layouts = state['workspaceLayouts'] as Map? ?? {};
      presets = p?['presets'] as List? ?? [];
    });
  }

  Future<Map<String, dynamic>?> perform(
    String route, [
    Map<String, dynamic> params = const {},
  ]) async {
    if (busy) return null;
    setState(() => busy = true);
    try {
      final result = await app!.run(route, params);
      if (result == null) return null;
      if (result['status'] != 'conflict') {
        final receipt = result['receipt'];
        final failures = result['failed'] as List? ?? [];
        app!.notify(
          failures.isEmpty
              ? 'Preset updated'
              : 'Could not restore: ${failures.join(', ')}',
          undo: receipt == null
              ? null
              : () async {
                  await app!.run('presets.undo', {
                    'receipt': receipt,
                    'appearance': result['appearance'] == true,
                  });
                  app!.changed();
                  await reload();
                },
        );
        app!.changed();
        await reload();
      }
      return result;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> restore() async {
    final result = await perform('apppresets.restore', {
      'workspace': workspace,
      'action': conflict,
    });
    if (result?['status'] != 'conflict' || !mounted) return;
    final action = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Other windows on this workspace'),
        content: Text(
          '${result!['conflict_count']} other windows. Choose what to do with them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          for (final a in ['move', 'close', 'keep'])
            TextButton(
              onPressed: () => Navigator.pop(c, a),
              child: Text(
                a == 'move'
                    ? 'Move to empty workspace'
                    : a == 'close'
                    ? 'Close'
                    : 'Keep',
              ),
            ),
        ],
      ),
    );
    if (action != null) {
      await perform('apppresets.restore', {
        'workspace': workspace,
        'action': action,
      });
    }
  }

  Widget limitPicker(
    int? value,
    void Function(int?) change, {
    bool inherited = false,
  }) => DropdownButton<int>(
    value: value ?? 0,
    items: [
      if (inherited)
        const DropdownMenuItem(value: 0, child: Text('Default limit')),
      for (var n = 1; n <= 4; n++)
        DropdownMenuItem(
          value: n,
          child: Text('$n ${n == 1 ? 'window' : 'windows'}'),
        ),
    ],
    onChanged: busy ? null : (v) => change(v == 0 ? null : v),
  );
  Widget workspacesTab() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text('All Workspaces', style: Theme.of(context).textTheme.titleLarge),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Tiling active'),
        subtitle: const Text(
          'New windows overflow to the next workspace with room.',
        ),
        value: state['active'] == true,
        onChanged: (v) => perform('workspaces.set', {'active': v}),
      ),
      Row(
        children: [
          const Expanded(child: Text('Default window limit')),
          limitPicker(
            state['maxWindows'] as int? ?? 2,
            (v) => perform('workspaces.set', {'maxWindows': v}),
          ),
        ],
      ),
      Wrap(
        spacing: 8,
        children: [
          FilledButton.tonal(
            onPressed: () => perform('workspaces.apply'),
            child: const Text('Apply now'),
          ),
          TextButton(
            onPressed: () async {
              if (await confirm(
                context,
                'Clear everything?',
                'Clear workspace limits, modes, saved apps and autostart settings.',
              )) {
                await perform('workspaces.reset');
              }
            },
            child: const Text('Clear everything'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      LayoutBuilder(
        builder: (context, box) => Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (var ws = 1; ws <= 10; ws++)
              SizedBox(
                width: box.maxWidth > 620
                    ? (box.maxWidth - 24) / 3
                    : box.maxWidth > 380
                    ? (box.maxWidth - 12) / 2
                    : box.maxWidth,
                child: workspaceCard(ws),
              ),
          ],
        ),
      ),
    ],
  );
  Widget workspaceCard(int ws) {
    final caps = state['workspaceCaps'] as Map? ?? {};
    final modes = state['workspaceModes'] as Map? ?? {};
    final mode = modes['$ws'] as String? ?? 'default';
    final cap = caps['$ws'] as int? ?? state['maxWindows'] as int? ?? 2;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Workspace $ws',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 90,
              width: double.infinity,
              child: CustomPaint(
                painter: _LayoutPainter(cap, mode, app!.colors),
              ),
            ),
            limitPicker(
              caps['$ws'] as int?,
              (v) => perform('workspaces.set', {'workspace': ws, 'limit': v}),
              inherited: true,
            ),
            DropdownButton<String>(
              isExpanded: true,
              value: mode,
              items: [
                for (final m in ['default', 'tiled', 'floating'])
                  DropdownMenuItem(
                    value: m,
                    child: Text(
                      m == 'default'
                          ? 'Default (unchanged)'
                          : m == 'tiled'
                          ? 'Tiled'
                          : 'Floating',
                    ),
                  ),
              ],
              onChanged: (v) =>
                  perform('workspaces.set', {'workspace': ws, 'mode': v}),
            ),
          ],
        ),
      ),
    );
  }

  Widget appsTab() {
    final layout = layouts['$workspace'] as Map?;
    final apps = layout?['apps'] as List? ?? [];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        DropdownButton<int>(
          value: workspace,
          items: [
            for (var ws = 1; ws <= 10; ws++)
              DropdownMenuItem(value: ws, child: Text('Workspace $ws')),
          ],
          onChanged: (v) => setState(() => workspace = v!),
        ),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              onPressed: () =>
                  perform('apppresets.save', {'workspace': workspace}),
              child: const Text('Save open apps'),
            ),
            OutlinedButton(
              onPressed: layout == null ? null : restore,
              child: const Text('Restore'),
            ),
            TextButton(
              onPressed: layout == null
                  ? null
                  : () =>
                        perform('apppresets.remove', {'workspace': workspace}),
              child: const Text('Remove preset'),
            ),
          ],
        ),
        const Text(
          'Apps reopen from their installed launchers; documents and window sizes are not saved.',
        ),
        SwitchListTile(
          title: const Text('Auto-move on restore'),
          value: state['autoMoveOnRestore'] == true,
          onChanged: (v) => perform('workspaces.set', {'autoMoveOnRestore': v}),
        ),
        DropdownButton<String>(
          value: conflict,
          isExpanded: true,
          items: [
            for (final a in ['ask', 'move', 'close', 'keep'])
              DropdownMenuItem(value: a, child: Text('Other windows: $a')),
          ],
          onChanged: (v) => setState(() => conflict = v!),
        ),
        SwitchListTile(
          title: const Text('Autostart on session startup'),
          value: layout?['autostart'] == true,
          onChanged: layout == null
              ? null
              : (v) => perform('apppresets.autostart', {
                  'workspace': workspace,
                  'enabled': v,
                }),
        ),
        if (apps.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No saved apps on this workspace.'),
          ),
        for (var i = 0; i < apps.length; i++)
          ListTile(
            title: Text('${apps[i]}'),
            trailing: IconButton(
              tooltip: 'Remove app',
              icon: const Icon(Icons.close),
              onPressed: () => perform('apppresets.remove', {
                'workspace': workspace,
                'index': i,
              }),
            ),
          ),
      ],
    );
  }

  Future<void> assign(Map p) async {
    final part = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Assign to workspaces'),
        children: [
          for (final v in ['theme', 'wallpaper', 'both'])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, v),
              child: Text(
                v == 'both'
                    ? 'Theme and wallpaper'
                    : v == 'theme'
                    ? 'Theme'
                    : 'Wallpaper',
              ),
            ),
        ],
      ),
    );
    if (part == null || !mounted) return;
    final selected = await pickWorkspaces(context, 'Assign ${p['name']}', {});
    if (selected != null && selected.isNotEmpty) {
      await perform('presets.assign', {
        'name': p['name'],
        'part': part,
        'workspaces': selected.toList(),
      });
    }
  }

  Widget savedTab() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      TextField(
        controller: name,
        maxLength: 60,
        decoration: const InputDecoration(labelText: 'Preset name'),
      ),
      CheckboxListTile(
        title: const Text('Include workspace presets and app presets'),
        value: include,
        onChanged: (v) => setState(() => include = v!),
      ),
      FilledButton(
        onPressed: () => perform('presets.save', {
          'name': name.text,
          'includeWorkspaces': include,
        }),
        child: const Text('Save current theme, wallpaper and font'),
      ),
      const SizedBox(height: 16),
      if (presets.isEmpty) const Text('No saved presets yet.'),
      for (final p in presets)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${p['name']}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  '${p['theme']} · ${p['wallpaper'] ?? 'No wallpaper'} · ${p['font'] ?? 'Default font'}',
                ),
                if (p['workspaces'] != null)
                  const Text('Includes workspace and app presets'),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () async {
                        final moves = p['workspaces'] != null;
                        if (moves &&
                            !await confirm(
                              context,
                              'Restore this preset?',
                              'This restores saved apps and moves other windows to an empty workspace.',
                              action: 'Restore',
                            )) {
                          return;
                        }
                        await perform('presets.apply', {
                          'name': p['name'],
                          'confirmed': moves,
                        });
                      },
                      child: const Text('Apply'),
                    ),
                    TextButton(
                      onPressed: () => assign(p as Map),
                      child: const Text('Assign to workspaces'),
                    ),
                    IconButton(
                      tooltip: 'Delete preset',
                      onPressed: () =>
                          perform('presets.delete', {'name': p['name']}),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
    ],
  );
  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: SubPage(
      title: 'Presets',
      body: Column(
        children: [
          const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Workspaces'),
              Tab(text: 'App Presets'),
              Tab(text: 'Save/Load Presets'),
            ],
          ),
          if (busy) const LinearProgressIndicator(),
          Expanded(
            child: AbsorbPointer(
              absorbing: busy,
              child: TabBarView(
                children: [workspacesTab(), appsTab(), savedTab()],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _LayoutPainter extends CustomPainter {
  _LayoutPainter(this.count, this.mode, this.colors);
  final int count;
  final String mode;
  final Map colors;
  @override
  void paint(Canvas canvas, Size size) {
    final bg = hexColor(colors, 'background') ?? const Color(0xff202020);
    final fg = hexColor(colors, 'foreground') ?? Colors.white;
    final accent = hexColor(colors, 'accent') ?? Colors.blue;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6)),
      Paint()..color = bg,
    );
    final n = mode == 'floating' ? 3 : count;
    for (var i = 0; i < n; i++) {
      final rect = mode == 'floating'
          ? Rect.fromLTWH(
              8 + i * size.width * .15,
              8 + i * 13,
              size.width * .55,
              size.height * .5,
            )
          : Rect.fromLTWH(
              6 + i * (size.width - 12) / n,
              6,
              (size.width - 12) / n - 4,
              size.height - 12,
            );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        Paint()..color = Color.lerp(bg, fg, .15)!,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        Paint()
          ..color = i == 0 ? accent : fg.withValues(alpha: .4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      canvas.drawLine(
        rect.topLeft + const Offset(5, 8),
        rect.topRight + const Offset(-5, 8),
        Paint()..color = fg.withValues(alpha: .5),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LayoutPainter oldDelegate) => true;
}
