import 'i18n.dart';
import 'dart:async';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'backend.dart' show ServiceError;
import 'core_call.dart';
import 'esc_close.dart';
import 'pages/ask_page.dart';
import 'pages/import_page.dart';
import 'pages/info_page.dart';
import 'pages/presets_page.dart';
import 'pages/settings_page.dart';
import 'pages/themes_page.dart';
import 'screenshots.dart';
import 'theme.dart';
import 'material_translations.dart';
import 'window.dart';
import 'window_size.dart';

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

/// The header buttons in the plugin's default order (header_order.py).
const headerDefault = ['import', 'hidden', 'presets', 'ask', 'info'];

/// Known ids once, in the saved order, then any missing ones.
List<String> headerOrder(Object? saved) {
  final out = <String>[];
  if (saved is List) {
    for (final x in saved) {
      if (x is String && headerDefault.contains(x) && !out.contains(x)) out.add(x);
    }
  }
  return [...out, for (final x in headerDefault) if (!out.contains(x)) x];
}

/// The window's default size (my_application.cc).
const defaultWindowSize = Size(980, 700);

class MaprismaThemeApp extends StatefulWidget {
  const MaprismaThemeApp({super.key, required this.call});
  final CoreCall call;
  @override
  State<MaprismaThemeApp> createState() => MaprismaThemeAppState();
}

class MaprismaThemeAppState extends State<MaprismaThemeApp> with WidgetsBindingObserver {
  final navigator = GlobalKey<NavigatorState>();
  final messenger = GlobalKey<ScaffoldMessengerState>();
  final shotKey = GlobalKey();
  String desktopId = 'cosmic';
  String desktopName = 'COSMIC';
  String terminalName = 'COSMIC Terminal';
  Set<String> _caps = {
    'appearance', 'ron', 'wallpaper', 'terminal', 'fonts', 'icons',
    'workspaces', 'tiling', 'windows', 'shortcuts', 'panel',
  };
  bool can(String cap) => _caps.contains(cap);

  Future<void> _refreshDesktop() async {
    try {
      final info = await call('desktop.info');
      if (!mounted || info['caps'] is! List) return;
      setState(() {
        desktopId = info['id'] as String? ?? desktopId;
        desktopName = info['name'] as String? ?? desktopName;
        terminalName = info['terminal'] as String? ?? terminalName;
        _caps = Set<String>.from(info['caps'] as List);
      });
    } catch (_) {
      // Keep the last desktop information while the core is unavailable.
    }
  }

  Map colors = const {};
  int? windowRadius;
  Map<String, dynamic> settings = const {};

  /// Bumped whenever themes, wallpapers or settings changed somewhere, so
  /// pages that show them reload (listen with `revision.addListener`).
  final revision = ValueNotifier<int>(0);

  /// The theme list's type-to-filter text (the header title shows it).
  final listFilter = ValueNotifier<String>('');

  /// The name of the page on top ('settings', 'info', 'presets', 'ask',
  /// 'import'; null for the list and other pages): its header button hides.
  final topPage = ValueNotifier<String?>(null);
  late final _observer = _TopObserver(topPage);

  /// Esc that no page took: leave a field, Back on a page, hide on the list (rule 5a). Hidden,
  /// as the close button: the process (and its tray) stays.
  late final _esc = EscFallback(onClose: () => AppWindow.instance.hide());

  /// Whether an Ask AI helper is installed and signed in (null: unknown).
  bool? askReady;
  bool maximized = false;
  final _subs = <StreamSubscription>[];

  CoreCall get call => widget.call;

  bool get showHidden => settings['show_hidden'] == true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The saved size was given to the window before the first frame (main.dart).
    refreshLook().then((_) => _windowSize.saved ??= parseWindowSize(settings['size']));
    refreshAsk();
    _esc.attach();
    _subs.add(AppWindow.instance.shown.stream.listen((_) => refreshLook()));
    // A theme applied elsewhere (the tray popup, the CLI, an automation) or new window corners
    // show without a restart.
    _lookTimer = Timer.periodic(const Duration(seconds: 5), (_) => pollLook());
    HardwareKeyboard.instance.addHandler(_f12);
  }

  /// F12 (Settings › F12 saves a screenshot): wherever the keyboard is, also in a dialog or a
  /// field, but not with Ctrl, Shift, Alt or Super.
  bool _f12(KeyEvent event) {
    if (!isScreenshotKey(event) || settings['screenshot_key'] == false) return false;
    takeScreenshot(this);
    return true;
  }

  Timer? _maxTimer;

  /// The window's size is remembered (settings `size`, GTK's size with the title bar), half a
  /// second after the last resize, not while maximized, fullscreen or tiled (rule 5a).
  late final _windowSize = WindowSizeKeeper(
    geometry: AppWindow.instance.geometry,
    save: (w, h) => call('settings.set', {'key': 'size', 'value': [w, h]}),
  );

  @override
  void didChangeMetrics() {
    _windowSize.resized();
    _maxTimer?.cancel();
    _maxTimer = Timer(const Duration(milliseconds: 500), () async {
      final now = await AppWindow.instance.maximized();
      if (mounted && now != maximized) setState(() => maximized = now);
    });
    if (mounted) setState(() {}); // the header's double-click hint
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_f12);
    _esc.detach();
    _windowSize.dispose();
    _maxTimer?.cancel();
    _lookTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  /// Reloads the desktop's colors and the settings (after applying a theme
  /// the window restyles in the new colors, as the plugin's popup).
  Future<void> refreshLook() async {
    await _refreshDesktop();
    try {
      final look = await call('desktop.look');
      final s = await call('settings.get');
      if (!mounted) return;
      setState(() {
        colors = (look['colors'] as Map?) ?? const {};
        windowRadius = (look['corner_radius'] as num?)?.round();
        settings = Map<String, dynamic>.from(s['settings'] as Map);
        languageSetting = settings['language'] as String? ?? 'auto';
      });
      AppWindow.instance.titlebar(look['is_dark'] != false);
    } catch (_) {
      // the core is not ready: keep the defaults
    }
  }

  Timer? _lookTimer;
  bool _polling = false;

  /// Back in the window: the desktop's look may have changed meanwhile.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) pollLook();
  }

  /// Re-reads only the desktop's look (colours, window corners) and rebuilds only when it changed.
  Future<void> pollLook() async {
    if (_polling) return;
    _polling = true;
    try {
      final look = await call('desktop.look');
      if (!mounted) return;
      final fresh = (look['colors'] as Map?) ?? const {};
      final radius = (look['corner_radius'] as num?)?.round();
      if (mapEquals(fresh, colors) && radius == windowRadius) return;
      setState(() {
        colors = fresh;
        windowRadius = radius;
      });
      AppWindow.instance.titlebar(look['is_dark'] != false);
    } catch (_) {
      // the core is busy or gone: the old look stays
    } finally {
      _polling = false;
    }
  }

  /// The Ask AI sparkle: accent when a helper is ready, a dot while none is.
  Future<void> refreshAsk() async {
    try {
      final r = await call('ask.helpers');
      final helpers = r['helpers'];
      if (!mounted || helpers is! List) return;
      setState(() => askReady = helpers.any((h) => h is Map && h['installed'] != false && h['signed_in'] == true));
    } catch (_) {
      // not known
    }
  }

  /// Apply the saved language before desktop refreshes can delay the UI.
  void useLanguage(String setting) {
    setState(() {
      languageSetting = setting;
      settings = {...settings, 'language': setting};
    });
  }

  void changed() {
    revision.value++;
    refreshLook();
    refreshAsk();
  }

  /// Opens a page from the header, as the plugin's stack: from the list,
  /// never on top of another page.
  void openPage(String name) {
    final nav = navigator.currentState;
    if (nav == null) return;
    final Widget page = switch (name) {
      'settings' => const SettingsPage(),
      'info' => const InfoPage(),
      'presets' => const PresetsPage(),
      'ask' => const AskPage(),
      _ => const ImportPage(),
    };
    nav.popUntil((r) => r.isFirst);
    nav.push(MaterialPageRoute<void>(settings: RouteSettings(name: name), builder: (_) => page));
  }

  Future<void> setShowHidden(bool on) async {
    await run('settings.set', {'key': 'show_hidden', 'value': on});
    changed();
  }

  Future<void> saveHeaderOrder(List<String> order) async {
    setState(() => settings = {...settings, 'header_order': order});
    await run('settings.set', {'key': 'header_order', 'value': order});
  }

  /// "default", "max" or "between" (the double-click hint and action).
  String sizeState(Size size) {
    if (maximized) return 'max';
    if ((size.width - defaultWindowSize.width).abs() < 2 && (size.height - defaultWindowSize.height).abs() < 2) {
      return 'default';
    }
    return 'between';
  }

  /// At the default size either button maximizes, maximized either one goes
  /// back; in between left = default size, right = maximize.
  Future<void> headerDoubleClick(Size size, {required bool primary}) async {
    final state = sizeState(size);
    if (state == 'max' || (state == 'between' && primary)) {
      await AppWindow.instance.maximize(false);
      await AppWindow.instance.resize(defaultWindowSize.width.round(), defaultWindowSize.height.round());
      setState(() => maximized = false);
    } else {
      await AppWindow.instance.maximize(true);
      setState(() => maximized = true);
    }
  }

  /// A short message at the bottom; [undo] adds an Undo button (also Ctrl+Z).
  void notify(String text, {VoidCallback? undo, Duration? duration}) {
    final token = Object();
    _undo = undo;
    _undoToken = token;
    messenger.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text),
        duration: duration ?? (undo != null ? const Duration(seconds: 8) : const Duration(seconds: 4)),
        action: undo == null
            ? null
            : SnackBarAction(label: tr("Undo"), onPressed: () {
                _undo = null;
                undo();
              }),
      )).closed.then((_) {
        // Only this message's Undo: a newer message keeps its own.
        if (identical(_undoToken, token)) _undo = null;
      });
  }

  VoidCallback? _undo;
  Object? _undoToken;
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
        title: tr('Maprisma Theme'),
        locale: Locale(currentLanguage),
        supportedLocales: [for (final code in languageNames.keys) Locale(code)],
        localizationsDelegates: const [MaprismaMaterialDelegate()],
        debugShowCheckedModeBanner: false,
        navigatorKey: navigator,
        navigatorObservers: [_observer, _esc],
        scaffoldMessengerKey: messenger,
        theme: appTheme(platform, colors, radius),
        // Esc's last word sits outside the header too (its buttons can have the keyboard).
        builder: (context, child) => _esc.wrap(CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () => undoLast(),
          },
          child: RepaintBoundary(
            key: shotKey,
            // An overlay of its own: the header's tooltips live outside the navigator.
            child: Overlay(initialEntries: [
              OverlayEntry(builder: (context) => _Card(child: child!)),
            ]),
          ),
        )),
        home: const ThemesPage(),
      ),
    );
  }
}

class _TopObserver extends NavigatorObserver {
  _TopObserver(this.top);
  final ValueNotifier<String?> top;
  void _set(Route? r) => WidgetsBinding.instance.addPostFrameCallback((_) => top.value = r?.settings.name);
  @override
  void didPush(Route route, Route? previousRoute) => _set(route is PopupRoute ? previousRoute : route);
  @override
  void didPop(Route route, Route? previousRoute) {
    if (route is! PopupRoute) _set(previousRoute);
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) => _set(newRoute);
  @override
  void didRemove(Route route, Route? previousRoute) {
    if (route is! PopupRoute) _set(previousRoute);
  }
}

/// The plugin's card: 17 px around everything, the header on top of every
/// page.
class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    return Material(
      color: look.bg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const MainHeader(),
          const SizedBox(height: 8),
          Expanded(child: child),
        ]),
      ),
    );
  }
}

/// The header: the title (with “(Showing hidden)” and the list's filter),
/// a small hint what a double-click does, the button group in the saved
/// order (drag or Alt+←/→ to rearrange) and the bordered gear, rightmost.
/// Settings, Information, Presets and Ask AI hide while their page is open.
class MainHeader extends StatefulWidget {
  const MainHeader({super.key});
  @override
  State<MainHeader> createState() => _MainHeaderState();
}

class _MainHeaderState extends State<MainHeader> {
  DateTime? _lastRight;
  String? _dropBefore;

  static Map<String, String> get _tips => {
    'import': tr("Import themes from omarchy.org and cosmic-themes.org (Ctrl+I)"),
    'presets': tr("Presets: saved theme, wallpaper and font"),
    'info': tr("Information"),
    'ask': tr("Ask AI: find or make a theme"),
  };
  static String get _moveHint => tr("Drag to rearrange · Alt+←/→");

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final look = Look.of(context);
    final r = corners(context);
    final size = MediaQuery.sizeOf(context);
    final state = app.sizeState(size);
    final hint = switch (state) {
      'default' => tr("Double-click: maximize"),
      'max' => tr("Double-click: default size"),
      _ => tr("Double-click: default size · right double-click: maximize"),
    };
    return ListenableBuilder(
      listenable: Listenable.merge([app.listFilter, app.topPage]),
      builder: (context, _) {
        final page = app.topPage.value;
        final onPage = const {'settings', 'info', 'presets', 'ask'}.contains(page);
        final order = headerOrder(app.settings['header_order']);
        final visible = [
          for (final id in order)
            if (!onPage || !const {'info', 'presets', 'ask'}.contains(id)) id,
        ];
        var title = tr('Maprisma Theme');
        if (app.showHidden) title += tr(" (Showing hidden)");
        if (app.listFilter.value.isNotEmpty) title += ' — ${app.listFilter.value}';
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: () => app.headerDoubleClick(size, primary: true),
          onSecondaryTapUp: (_) {
            final now = DateTime.now();
            final last = _lastRight;
            _lastRight = now;
            if (last != null && now.difference(last) < const Duration(milliseconds: 400)) {
              _lastRight = null;
              app.headerDoubleClick(size, primary: false);
            }
          },
          child: SizedBox(
            height: 32,
            child: Row(children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: size.width * .45),
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge!.copyWith(fontWeight: FontWeight.w600, color: look.fg)),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Tooltip(
                    message: hint,
                    child: Text(hint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall!.copyWith(color: look.dim)),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                decoration: BoxDecoration(color: look.fg.withValues(alpha: .05), borderRadius: BorderRadius.circular(r)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  for (var i = 0; i < visible.length; i++) ...[
                    if (i > 0)
                      Container(width: 1, height: 18, color: look.fg.withValues(alpha: .18)),
                    _draggable(app, visible[i], order),
                  ],
                ]),
              ),
              if (page != 'settings') ...[
                const SizedBox(width: 8),
                Tooltip(
                  message: tr("Settings"),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(r),
                    onTap: () => app.openPage('settings'),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        border: Border.all(color: look.fg.withValues(alpha: .35)),
                        borderRadius: BorderRadius.circular(r),
                      ),
                      child: Icon(Icons.settings_outlined, size: 16, color: look.fg),
                    ),
                  ),
                ),
              ],
            ]),
          ),
        );
      },
    );
  }

  Widget _button(MaprismaThemeAppState app, String id) {
    final look = Look.of(context);
    final tip = id == 'hidden'
        ? (app.showHidden ? tr("Hide hidden themes and wallpapers") : tr("Show hidden themes and wallpapers"))
        : _tips[id]!;
    Widget icon;
    VoidCallback onTap;
    switch (id) {
      case 'hidden':
        icon = Icon(app.showHidden ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 16, color: look.fg);
        onTap = () => app.setShowHidden(!app.showHidden);
      case 'import':
        icon = Icon(Icons.download_outlined, size: 16, color: look.fg);
        onTap = () => app.openPage('import');
      case 'presets':
        icon = Icon(Icons.bookmarks_outlined, size: 16, color: look.fg);
        onTap = () => app.openPage('presets');
      case 'info':
        icon = Icon(Icons.info_outline, size: 16, color: look.fg);
        onTap = () => app.openPage('info');
      default:
        // The sparkle: accent when a helper is ready, dim while Ask AI is off,
        // a dot while it is on but no helper is signed in.
        final on = app.settings['ask_ai'] == true;
        final ready = app.askReady == true;
        icon = Stack(clipBehavior: Clip.none, children: [
          Icon(Icons.auto_awesome, size: 16, color: !on ? look.dim : ready ? look.accent : look.fg),
          if (on && app.askReady == false)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: look.accent, shape: BoxShape.circle),
              ),
            ),
        ]);
        onTap = () => app.openPage('ask');
    }
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, e) {
        if (e is! KeyDownEvent || !HardwareKeyboard.instance.isAltPressed) return KeyEventResult.ignored;
        final dir = e.logicalKey == LogicalKeyboardKey.arrowLeft
            ? -1
            : e.logicalKey == LogicalKeyboardKey.arrowRight
            ? 1
            : 0;
        if (dir == 0) return KeyEventResult.ignored;
        final order = headerOrder(app.settings['header_order']);
        final i = order.indexOf(id);
        final j = (i + dir).clamp(0, order.length - 1);
        if (i != j) {
          order
            ..removeAt(i)
            ..insert(j, id);
          app.saveHeaderOrder(order);
        }
        return KeyEventResult.handled;
      },
      child: Tooltip(
        message: '$tip\n$_moveHint',
        child: InkWell(
          key: ValueKey('header-$id'),
          borderRadius: BorderRadius.circular(cornerSizes(context).control),
          onTap: onTap,
          child: Padding(padding: const EdgeInsets.all(4), child: icon),
        ),
      ),
    );
  }

  /// A header button that can be dragged onto another one (it goes before it).
  Widget _draggable(MaprismaThemeAppState app, String id, List<String> order) {
    final look = Look.of(context);
    final button = _button(app, id);
    return DragTarget<String>(
      onWillAcceptWithDetails: (d) {
        final ok = d.data != id;
        if (ok) setState(() => _dropBefore = id);
        return ok;
      },
      onLeave: (_) => setState(() => _dropBefore = null),
      onAcceptWithDetails: (d) {
        setState(() => _dropBefore = null);
        final next = [...order]..remove(d.data);
        next.insert(next.indexOf(id), d.data);
        app.saveHeaderOrder(next);
      },
      builder: (context, _, _) => Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: _dropBefore == id ? look.selection : Colors.transparent, width: 3)),
        ),
        child: Draggable<String>(
          data: id,
          feedback: Material(color: Colors.transparent, child: Opacity(opacity: .8, child: button)),
          childWhenDragging: Opacity(opacity: .3, child: button),
          child: button,
        ),
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
      'apply_failed' => tr("The desktop did not take the theme."),
      'not_found' => tr("Not found any more."),
      'timeout' => tr("That took too long."),
      final code => trf("Failed: {0}", [code!.replaceAll('_', ' ')]),
    };
  }
  return trf("Failed: {0}", [s]);
}
