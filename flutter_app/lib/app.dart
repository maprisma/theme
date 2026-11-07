import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'backend.dart' show ServiceError;
import 'core_call.dart';
import 'pages/themes_page.dart';
import 'screenshots.dart';
import 'theme.dart';
import 'window.dart';

/// What every page reaches through `AppScope.of(context)`.
final class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.state, required super.child});
  final MaprismaThemeAppState state;

  static MaprismaThemeAppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.state;

  /// Without registering a dependency (in callbacks).
  static MaprismaThemeAppState read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.state;

  @override
  bool updateShouldNotify(AppScope oldWidget) => true;
}

class MaprismaThemeApp extends StatefulWidget {
  const MaprismaThemeApp({super.key, required this.call});
  final CoreCall call;
  @override
  State<MaprismaThemeApp> createState() => MaprismaThemeAppState();
}

class MaprismaThemeAppState extends State<MaprismaThemeApp> {
  final navigator = GlobalKey<NavigatorState>();
  final messenger = GlobalKey<ScaffoldMessengerState>();
  final shotKey = GlobalKey();
  Map colors = const {};
  int? windowRadius;
  Map<String, dynamic> settings = const {};

  /// Bumped whenever themes, wallpapers or settings changed somewhere, so
  /// pages that show them reload (listen with `revision.addListener`).
  final revision = ValueNotifier<int>(0);
  final _subs = <StreamSubscription>[];

  CoreCall get call => widget.call;

  @override
  void initState() {
    super.initState();
    refreshLook();
    _subs.add(AppWindow.instance.shown.stream.listen((_) => refreshLook()));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  /// Reloads the desktop's colors and the settings (after applying a theme
  /// the window restyles in the new colors, as the plugin's popup).
  Future<void> refreshLook() async {
    try {
      final look = await call('desktop.look');
      final s = await call('settings.get');
      if (!mounted) return;
      setState(() {
        colors = (look['colors'] as Map?) ?? const {};
        windowRadius = (look['corner_radius'] as num?)?.round();
        settings = Map<String, dynamic>.from(s['settings'] as Map);
      });
      AppWindow.instance.titlebar(look['is_dark'] != false);
    } catch (_) {
      // the core is not ready: keep the defaults
    }
  }

  void changed() {
    revision.value++;
    refreshLook();
  }

  /// A short message at the bottom; [undo] adds an Undo button (also Ctrl+Z).
  void notify(String text, {VoidCallback? undo, Duration? duration}) {
    _undo = undo;
    messenger.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text),
        duration: duration ?? (undo != null ? const Duration(seconds: 8) : const Duration(seconds: 4)),
        action: undo == null
            ? null
            : SnackBarAction(label: 'Undo', onPressed: () {
                _undo = null;
                undo();
              }),
      )).closed.then((_) => _undo = null);
  }

  VoidCallback? _undo;
  bool undoLast() {
    final u = _undo;
    if (u == null) return false;
    _undo = null;
    messenger.currentState?.hideCurrentSnackBar();
    u();
    return true;
  }

  /// Runs a route and reports a failure as a message; null on failure.
  Future<Map<String, dynamic>?> run(String method, [Map<String, dynamic> params = const {}, String? failure]) async {
    try {
      return await call(method, params);
    } catch (e) {
      notify(failure ?? errorText(e));
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final radius = cornerRadius(settings['corners'] as String? ?? 'windows', windowRadius);
    final platform = MediaQuery.platformBrightnessOf(context);
    return AppScope(
      state: this,
      child: MaterialApp(
        title: 'Maprisma Theme',
        debugShowCheckedModeBanner: false,
        navigatorKey: navigator,
        scaffoldMessengerKey: messenger,
        theme: appTheme(platform, colors, radius),
        builder: (context, child) => CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.f12): () {
              if (settings['screenshot_key'] != false) takeScreenshot(this);
            },
            const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () => undoLast(),
          },
          child: RepaintBoundary(key: shotKey, child: child!),
        ),
        home: const ThemesPage(),
      ),
    );
  }
}

/// A readable message for a failed core call.
String errorText(Object e) {
  if (e is ServiceError && (e.reason ?? '').isNotEmpty) return e.reason!;
  final s = e.toString();
  final m = RegExp(r'Service operation failed: (\w+)').firstMatch(s);
  if (m != null) {
    return switch (m[1]) {
      'apply_failed' => 'COSMIC did not take the theme. Is maprisma-theme-helper installed?',
      'not_found' => 'Not found any more.',
      'timeout' => 'That took too long.',
      final code => 'Failed: ${code!.replaceAll('_', ' ')}',
    };
  }
  return 'Failed: $s';
}
