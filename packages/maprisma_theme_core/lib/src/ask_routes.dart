import 'i18n.dart';
import 'dart:io';

import 'ask_ai.dart';
import 'context.dart';
import 'posix.dart';
import 'theme_ai.dart';

const maprismaUrl = 'https://plugins.omarchy.org/plugin.html?id=ubruckhaus.maprisma';

/// The installed themes as Ask AI sees them (no paths).
List<ThemeFacts> themeFacts(Ctx ctx) => [
  for (final t in ctx.themes())
    ThemeFacts(slug: t.slug, name: t.name, colors: completeColors(t.colors), custom: t.custom),
];

/// The omarchy.org names the GUI passes (from `import.omarchy_list`), checked.
List<CatalogName> catalogParam(Object? raw) {
  final out = <CatalogName>[];
  final seen = <String>{};
  for (final e in raw is List ? raw.take(1000) : const []) {
    if (e is! Map) continue;
    final slug = e['slug'] ?? e['name'];
    final name = e['title'] ?? e['name'] ?? slug;
    if (slug is! String || !RegExp(r'^[a-z0-9][a-z0-9._-]{0,99}$').hasMatch(slug) || !seen.add(slug)) continue;
    out.add((slug: slug, name: plainText(name, 60)));
  }
  return out;
}

Future<List<String>> fontFacts(Ctx ctx) async {
  try {
    return [
      for (final f in (await ctx.desktop.monospaceFonts()).toSet().take(200))
        if (fontRe.hasMatch(f)) f,
    ];
  } on Object {
    return const [];
  }
}

/// Routes of the ask module: `ask.helpers`, `ask.run`, `ask.cancel`,
/// `ask.release`, `ask.signin`, `ask.open_maprisma`.
Map<String, Handler> askRoutes(Ctx ctx) {
  final runner = AskRunner(home: ctx.paths.home, environment: ctx.environment);
  List<Map<String, dynamic>> states() => helperStates(ctx.paths.home, ctx.environment);

  return {
    'ask.helpers': (p) async {
      final list = states();
      final ready = [for (final h in list) if (h['signed_in'] == true) h['id'] as String];
      final saved = ctx.settings.get('ask_ai_helper');
      return {
        'helpers': list,
        'chosen': ready.contains(saved) ? saved : ready.firstOrNull,
        'enabled': ctx.settings.get('ask_ai') == true,
        'busy': runner.busy,
      };
    },
    // One click: context, prompt, one answer, checked candidates. A refine
    // sends only that candidate back; it gets one changed candidate, more
    // only when the words ask for options.
    'ask.run': (p) async {
      if (ctx.settings.get('ask_ai') != true) throw RouteError('off', tr("Ask AI is off"));
      final helper = str(p, 'helper');
      final request = (p['request'] is String ? p['request'] as String : '').split(RegExp(r'\s+')).join(' ').trim();
      if (request.isEmpty || request.length > maxRequest) throw RouteError('bad_params', 'request');
      if (!states().any((h) => h['id'] == helper && h['signed_in'] == true)) {
        throw RouteError('not_ready', tr("that helper is not installed or not signed in"));
      }
      if (runner.busy) throw RouteError('busy', tr("another Ask is running"));
      final themes = themeFacts(ctx);
      final catalog = catalogParam(p['catalog']);
      final fonts = await fontFacts(ctx);
      Map<String, dynamic>? parent;
      if (p['refine'] != null) {
        parent = checkParent(p['refine'], themes, catalog, fonts);
        if (parent == null) throw RouteError('bad_params', 'refine');
      }
      final rejected = [
        for (final r in p['rejected'] is List ? (p['rejected'] as List).take(20) : const [])
          if (r is String && r.isNotEmpty) plainText(r, 80),
      ];
      final prompt = buildPrompt(request, themes, catalog, fonts,
          previous: parent == null ? null : forRefine(parent), rejected: rejected);
      String text;
      try {
        text = await runner.run(helper, prompt);
      } on AskError catch (e) {
        throw RouteError(e.message == 'cancelled' ? 'cancelled' : 'helper_failed', e.message == 'cancelled' ? tr('Cancelled') : e.message);
      }
      final json = firstJson(text);
      if (json == null) throw RouteError('bad_answer', tr("no JSON object in the answer"));
      final limit = parent == null || wantsOptions(request) ? maxCandidates : 1;
      final (summary, candidates) = verify(json, themes, catalog, fonts,
          parent: parent, limit: limit, current: ctx.current.slug);
      return {
        'summary': summary,
        'candidates': candidates,
        if (parent != null && candidates.isEmpty) 'unchanged': true,
      };
    },
    // Words for the wallpaper search of one theme: the helper turns the
    // request and the theme's colors into wallhaven.cc search phrases.
    'ask.wallpapers': (p) async {
      if (ctx.settings.get('ask_ai') != true) throw RouteError('off', tr("Ask AI is off"));
      final helper = str(p, 'helper');
      final request = (p['request'] is String ? p['request'] as String : '').split(RegExp(r'\s+')).join(' ').trim();
      if (request.isEmpty || request.length > maxRequest) throw RouteError('bad_params', 'request');
      final slug = str(p, 'slug');
      final theme = themeFacts(ctx).where((t) => t.slug == slug).firstOrNull;
      if (theme == null) throw RouteError('bad_params', 'slug');
      if (!states().any((h) => h['id'] == helper && h['signed_in'] == true)) {
        throw RouteError('not_ready', tr("that helper is not installed or not signed in"));
      }
      if (runner.busy) throw RouteError('busy', tr("another Ask is running"));
      final rejected = [
        for (final r in p['rejected'] is List ? (p['rejected'] as List).take(20) : const [])
          if (r is String && r.isNotEmpty) plainText(r, 80),
      ];
      String text;
      try {
        text = await runner.run(helper, buildWallpaperPrompt(request, theme, rejected: rejected));
      } on AskError catch (e) {
        throw RouteError(e.message == 'cancelled' ? 'cancelled' : 'helper_failed', e.message == 'cancelled' ? tr('Cancelled') : e.message);
      }
      final json = firstJson(text);
      if (json == null) throw RouteError('bad_answer', tr("no JSON object in the answer"));
      final (summary, queries) = verifyWallpaperAnswer(json);
      if (queries.isEmpty) throw RouteError('bad_answer', tr("no usable search words in the answer"));
      return {'summary': summary, 'queries': queries};
    },
    'ask.cancel': (p) async {
      runner.cancel();
      return {'cancelled': true};
    },
    // GPU memory back: unload the local models Ask AI loaded, except the one
    // [keep] (a helper id) runs on (window hidden, helper changed, page left).
    'ask.release': (p) async {
      final keepModel = localModelOf(optStr(p, 'keep'), ctx.paths.home);
      final done = await runner.release(keep: keepModel == null ? null : localKey(keepModel));
      return {'unloaded': done.length};
    },
    // The helper's own sign-in from the table, in a terminal (no user text).
    'ask.signin': (p) async {
      final id = str(p, 'command');
      final h = helpers.where((h) => h.id == id).firstOrNull;
      if (h == null) throw RouteError('bad_params', 'command');
      final term = _terminal(ctx.environment);
      if (term == null) throw RouteError('no_terminal', tr("no terminal found"));
      final argv = [...term, ...h.login.split(' ')];
      try {
        await Process.start(argv.first, argv.sublist(1), mode: ProcessStartMode.detached, workingDirectory: ctx.paths.home);
      } on ProcessException {
        throw RouteError('no_terminal', tr("the terminal did not start"));
      }
      return {'started': true};
    },
    // The Maprisma note's button: a fixed address, the desktop's opener.
    'ask.open_maprisma': (p) async {
      final open = which('xdg-open', ctx.environment);
      if (open == null) throw RouteError('no_browser', tr("xdg-open is missing"));
      try {
        await Process.start(open, [maprismaUrl], mode: ProcessStartMode.detached);
      } on ProcessException {
        throw RouteError('no_browser', tr("the browser did not start"));
      }
      return {'opened': true};
    },
  };
}

List<String>? _terminal(Map<String, String> env) {
  for (final (program, flag) in const [
    ('cosmic-term', '-e'),
    ('alacritty', '-e'),
    ('kitty', '--'),
    ('ghostty', '-e'),
    ('foot', '--'),
    ('xterm', '-e'),
  ]) {
    final path = which(program, env);
    if (path != null) return [path, flag];
  }
  return null;
}
