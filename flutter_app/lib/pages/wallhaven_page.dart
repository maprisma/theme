import '../i18n.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../theme.dart';
import '../widgets.dart';
import 'wallpapers_page.dart' show failText, previewSeconds;

const _source = 'wallhaven.cc';
const _thumbWorkers = 4;

/// Search wallpapers on wallhaven.cc for one theme (the plugin's web search
/// page): safe for work, landscape, at least 1920×1080, more as you scroll.
class WallhavenPage extends StatefulWidget {
  const WallhavenPage({super.key, required this.slug, required this.themeName, this.current = false, this.askAi = false});
  final String slug, themeName;

  /// Opened from the wallpapers page's Ask AI: the AI prompt has the focus.
  final bool askAi;

  /// The theme is in use (Add and set as background is offered).
  final bool current;
  @override
  State<WallhavenPage> createState() => _WallhavenPageState();
}

class _WallhavenPageState extends State<WallhavenPage> {
  late final MaprismaThemeAppState app;
  final field = TextEditingController();
  final fieldFocus = FocusNode();
  final gridFocus = FocusNode();
  final scroll = ScrollController();
  final _tileKeys = <String, GlobalKey>{};
  final _menuKeys = <String, GlobalKey<PopupMenuButtonState<VoidCallback>>>{};

  List<Map<String, dynamic>> results = [];

  /// Pictures Ask AI found on the web (kind `web`), shown before the wallhaven results.
  List<Map<String, dynamic>> webPictures = [];

  /// Pictures made here from Ask AI's description (kind `created`), shown first.
  List<Map<String, dynamic>> created = [];

  /// Wallhaven results shown so far: a batch at a time (Next shows more).
  int shownCount = 0;
  List<Map<String, dynamic>> get shown => [...created, ...webPictures, ...results.take(shownCount)];

  /// Pictures per batch (Settings key wallpaper_count: 5, 10 or 20).
  late int count;

  // Making pictures (Maprisma Theme's own picture generator).
  String? picturePrompt;
  Map<String, dynamic>? generator;
  bool making = false, stopMaking = false;
  int madeInBatch = 0, batchSize = 0;
  Timer? setupPoll;
  String lastRequest = '';
  bool moreWeb = false;
  final thumbs = <String, String?>{};
  String query = '', status = '';
  int page = 0, lastPage = 1, generation = 0, selected = 0, columns = 3;
  bool loading = false;
  final _thumbQueue = <Map<String, dynamic>>[];
  int _thumbsRunning = 0;

  // Ask AI (only while it is on and a helper is ready): words → search phrases.
  final aiField = TextEditingController();
  final aiFocus = FocusNode();
  Map? aiHelper;
  bool asking = false;

  /// Each Ask (and Next's web ask) belongs to this number; a new search, another
  /// helper or leaving the page moves it on, so an answer still on its way is
  /// stale and never shown or acted on.
  int askGen = 0;

  /// The running Ask no longer fits: it is stopped, its answer is stale.
  void dropAsk() {
    askGen++;
    if (asking) {
      app.call('ask.cancel').ignore();
      asking = false;
    }
  }

  /// The ready helpers (signed in) for the choice at the title's right, and
  /// whether Settings › Ask AI lets a helper search the web.
  List<Map> aiReady = [];
  bool aiWebAllowed = true;

  /// The helper also searches the web (it can, and Settings › Ask AI allows it).
  bool aiWeb = false;
  String aiSummary = '';
  List<String> aiQueries = [];
  final aiSearched = <String>[];

  /// The result whose preview is loading or shown (`web:<id>`), null when none.
  String? previewing;
  bool previewShown = false;
  Timer? previewTimer;

  @override
  void initState() {
    super.initState();
    app = AppScope.read(context);
    final saved = app.settings['wallpaper_count'];
    count = saved is int && const {5, 10, 20}.contains(saved) ? saved : 10;
    WidgetsBinding.instance.addPostFrameCallback((_) => fieldFocus.requestFocus());
    loadHelper();
  }

  Future<void> loadHelper() async {
    Map<String, dynamic>? r;
    try {
      r = await app.call('ask.helpers');
    } catch (_) {
      return;
    }
    if (!mounted || r['enabled'] != true) return;
    final chosen = r['chosen'];
    final ready = [for (final h in (r['helpers'] as List?) ?? const []) if (h is Map && h['signed_in'] == true) h];
    // The chosen helper, else the first ready one (as the plugin).
    final h = ready.where((h) => h['id'] == chosen).firstOrNull ?? ready.firstOrNull;
    if (h == null) return;
    setState(() {
      aiReady = ready;
      aiWebAllowed = r!['web'] != false;
      aiHelper = h;
      aiWeb = h['web'] == true && aiWebAllowed;
    });
    if (widget.askAi) WidgetsBinding.instance.addPostFrameCallback((_) => aiFocus.requestFocus());
  }

  /// Another helper chosen: it asks from now on (an answer on its way stays),
  /// and the Ask AI page uses it too (the same remembered choice).
  Future<void> chooseHelper(String id) async {
    final h = aiReady.where((h) => h['id'] == id).firstOrNull;
    if (h == null || h['id'] == aiHelper?['id']) return;
    setState(() {
      dropAsk(); // the old helper's answer is not this helper's
      aiHelper = h;
      aiWeb = h['web'] == true && aiWebAllowed;
    });
    await app.run('settings.set', {'key': 'ask_ai_helper', 'value': id}, tr("Could not save the setting"));
    app.changed();
  }

  static String helperName(Map h) => '${h['name']}${h['local'] == true ? tr(" · on this PC") : ''}';

  /// [name ▾] at the title's right, as the Ask AI page's helper choice.
  Widget helperChoice() {
    final scheme = Theme.of(context).colorScheme;
    final current = aiHelper!;
    return PopupMenuButton<String>(
      key: const ValueKey('wallpaper-helper'),
      tooltip: '${tr("Helper:")} ${helperName(current)}',
      enabled: aiReady.isNotEmpty,
      onSelected: chooseHelper,
      position: PopupMenuPosition.under,
      itemBuilder: (_) => [
        for (final h in aiReady)
          CheckedPopupMenuItem(value: h['id'] as String, checked: h['id'] == current['id'], child: Text(helperName(h))),
      ],
      child: Container(
        constraints: const BoxConstraints(maxWidth: 200),
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
        decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(cornerSizes(context).control)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: Text(helperName(current), maxLines: 1, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 4),
          Icon(Icons.expand_more, size: 18, color: scheme.onSurfaceVariant),
        ]),
      ),
    );
  }

  Future<void> askAi() async {
    final words = aiField.text.trim();
    final helper = aiHelper;
    if (words.isEmpty || helper == null || asking) return;
    final mine = ++askGen;
    setState(() {
      asking = true;
      aiSummary = '';
      status = aiWeb
          ? trf("Asking {0} for wallpaper ideas and searching the web… (this can take a few minutes)", [helper['name']])
          : trf("Asking {0} for wallpaper ideas…", [helper['name']]);
    });
    Map<String, dynamic>? r;
    String? error;
    try {
      r = await app.call('ask.wallpapers', {
        'helper': helper['id'],
        'request': words,
        'slug': widget.slug,
        'rejected': aiSearched.take(20).toList(),
        'count': count,
      });
    } catch (e) {
      error = failText(e);
    }
    if (!mounted || mine != askGen) return; // a new search, another helper: stale
    final queries = [for (final q in (r?['queries'] as List?) ?? const []) if (q is String) q];
    final pictures = [
      for (final (i, e) in ((r?['images'] as List?) ?? const []).indexed)
        if (e is Map && e['url'] is String) webItem(e, i),
    ];
    final prompt = r?['picture_prompt'];
    setState(() {
      asking = false;
      lastRequest = words;
      moreWeb = pictures.isNotEmpty;
      webPictures = pictures;
      created = [];
      picturePrompt = prompt is String && prompt.isNotEmpty ? prompt : null;
      for (final w in pictures) {
        if (!_thumbQueue.contains(w)) _thumbQueue.add(w);
      }
      if (r == null || (queries.isEmpty && pictures.isEmpty && picturePrompt == null)) {
        status = trf("Ask AI failed: {0}", [error ?? tr("no usable search words in the answer")]);
        return;
      }
      aiQueries = queries;
      aiSummary = '${r['summary'] ?? ''}';
    });
    if (picturePrompt != null) makePictures();
    if (queries.isNotEmpty) {
      searchFor(queries.first);
    } else if (picturePrompt == null) {
      setState(() => status = trf("{0} pictures from the web.", [pictures.length]));
    }
    _pumpThumbs(generation);
  }

  // --- made here ------------------------------------------------------------------

  /// Makes a batch of pictures from Ask AI's description (new seeds each time);
  /// when the generator is not set up yet, the banner offers it.
  Future<void> makePictures() async {
    final prompt = picturePrompt;
    if (prompt == null || making) return;
    Map<String, dynamic> st;
    try {
      st = await app.call('create.status');
    } catch (e) {
      if (mounted) setState(() => status = trf("No picture generator: {0}", [failText(e)]));
      return;
    }
    if (!mounted) return;
    setState(() => generator = st);
    if (st['ready'] != true) {
      if (st['setting_up'] == true) _pollSetup();
      return;
    }
    setState(() {
      making = true;
      stopMaking = false;
      madeInBatch = 0;
      batchSize = count;
    });
    final random = math.Random();
    var failed = false;
    for (var i = 0; i < batchSize && !stopMaking && mounted; i++) {
      setState(() => status = trf("Making picture {0} of {1} on this computer…", [i + 1, batchSize]));
      try {
        final r = await app.call('create.make', {'prompt': prompt, 'seed': random.nextInt(1 << 31)});
        if (!mounted || picturePrompt != prompt) break;
        final path = r['path'] as String;
        final item = {'kind': 'created', 'id': 'made${created.length}:$path', 'path': path, 'file_name': trf("Created picture {0}", [created.length + 1])};
        setState(() {
          thumbs[item['id'] as String] = path;
          created.add(item);
          madeInBatch++;
        });
      } catch (e) {
        failed = true;
        if (mounted && !stopMaking) setState(() => status = trf("Could not make the picture: {0}", [failText(e)]));
        break;
      }
    }
    if (!mounted) return;
    setState(() {
      making = false;
      if (!failed) {
        status = trf("{0} pictures made on this computer. Next makes {1} more.", [created.length, count]);
      }
    });
  }

  Future<void> stopMakingPictures() async {
    setState(() => stopMaking = true);
    try {
      await app.call('create.cancel');
    } catch (_) {}
  }

  Future<void> setUpGenerator() async {
    try {
      final st = await app.call('create.setup');
      if (mounted) setState(() => generator = st);
    } catch (e) {
      if (mounted) setState(() => status = trf("Could not set up the picture generator: {0}", [failText(e)]));
      return;
    }
    _pollSetup();
  }

  /// Stops the download; what came down stays and a later Set up goes on from there.
  Future<void> cancelSetup() async {
    try {
      final st = await app.call('create.cancel_setup');
      if (mounted) setState(() => generator = st);
    } catch (_) {}
  }

  void _pollSetup() {
    setupPoll?.cancel();
    setupPoll = Timer.periodic(const Duration(seconds: 1), (t) async {
      Map<String, dynamic> st;
      try {
        st = await app.call('create.status');
      } catch (_) {
        return;
      }
      if (!mounted) return t.cancel();
      setState(() => generator = st);
      if (st['setting_up'] != true) {
        t.cancel();
        if (st['ready'] == true) makePictures();
      }
    });
  }

  // --- next batch -----------------------------------------------------------------

  bool get moreResults => query.isNotEmpty && (results.length > shownCount || page < lastPage);
  bool get canNext => !asking && !making && (picturePrompt != null || (moreWeb && aiHelper != null) || moreResults);

  /// The next batch of each kind on the page: pictures made here (no tokens),
  /// pictures from the web (asks the helper again, without the ones shown),
  /// wallhaven results (no tokens).
  Future<void> next() async {
    if (picturePrompt != null && generator?['ready'] == true) makePictures();
    if (moreWeb && aiHelper != null && lastRequest.isNotEmpty) moreFromWeb();
    if (moreResults) revealMore();
  }

  Future<void> moreFromWeb() async {
    final helper = aiHelper!;
    final mine = ++askGen;
    setState(() {
      asking = true;
      status = trf("Asking {0} for more pictures from the web…", [helper['name']]);
    });
    Map<String, dynamic>? r;
    String? error;
    try {
      r = await app.call('ask.wallpapers', {
        'helper': helper['id'],
        'request': lastRequest,
        'slug': widget.slug,
        'rejected': aiSearched.take(20).toList(),
        'count': count,
        'seen': [for (final w in webPictures) w['url']].take(60).toList(),
      });
    } catch (e) {
      error = failText(e);
    }
    if (!mounted || mine != askGen) return; // a new search, another helper: stale
    final fresh = [
      for (final (i, e) in ((r?['images'] as List?) ?? const []).indexed)
        if (e is Map && e['url'] is String && !webPictures.any((w) => w['url'] == e['url'])) webItem(e, webPictures.length + i),
    ];
    setState(() {
      asking = false;
      webPictures.addAll(fresh);
      _thumbQueue.addAll(fresh);
      moreWeb = fresh.isNotEmpty;
      status = r == null
          ? trf("Ask AI failed: {0}", [error])
          : fresh.isEmpty
              ? tr("No more pictures from the web.")
              : trf("{0} more pictures from the web.", [fresh.length]);
    });
    _pumpThumbs(generation);
  }

  /// Shows the next batch of wallhaven results, loading pages as needed.
  Future<void> revealMore() async {
    final gen = generation;
    final want = shownCount + count;
    while (mounted && gen == generation && results.length < want && page < lastPage) {
      final before = results.length;
      await loadMore();
      if (results.length == before) break;
    }
    if (!mounted || gen != generation) return; // another search meanwhile: its own count
    setState(() {
      shownCount = math.min(want, results.length);
      status = trf("{0} of {1}+ wallpapers for “{2}”.{3}", [shownCount, results.length, query, moreResults ? tr(" Next shows more.") : '']);
    });
  }

  /// A picture from the web as a tile: its link, the page it is on, a caption.
  static Map<String, dynamic> webItem(Map e, int i) {
    final url = e['url'] as String;
    final title = '${e['title'] ?? ''}'.trim();
    final host = Uri.tryParse(url)?.host ?? '';
    return {
      'kind': 'web',
      'id': 'web$i:${url.hashCode}',
      'url': url,
      if (e['page'] is String) 'page': e['page'],
      'title': title,
      'host': host,
      'file_name': title.isNotEmpty ? title : host,
    };
  }

  static bool isWeb(Map item) => item['kind'] == 'web';
  static bool isMade(Map item) => item['kind'] == 'created';

  Future<void> stopAsking() async {
    try {
      await app.call('ask.cancel');
    } catch (_) {}
  }

  void searchFor(String phrase) {
    if (!aiSearched.contains(phrase)) aiSearched.add(phrase);
    field.text = phrase;
    search();
  }

  @override
  void dispose() {
    generation++;
    askGen++;
    if (previewShown) app.call('wallpapers.preview_end').ignore();
    previewTimer?.cancel();
    field.dispose();
    fieldFocus.dispose();
    aiField.dispose();
    aiFocus.dispose();
    if (asking) app.call('ask.cancel').ignore();
    if (making) app.call('create.cancel').ignore();
    setupPoll?.cancel();
    gridFocus.dispose();
    scroll.dispose();
    super.dispose();
  }

  String get hint {
    if (status.isNotEmpty) return status;
    return trf("Type what you are looking for and press Enter. Results come from {0}: safe for work, landscape, at least 1920×1080.", [_source]);
  }

  Future<void> search() async {
    final q = field.text.trim();
    if (q.isEmpty) return;
    generation++;
    dropAsk(); // a new search: an Ask still on its way never starts its own
    _thumbQueue.removeWhere((x) => !isWeb(x));
    setState(() {
      query = q;
      page = 0;
      lastPage = 1;
      results = [];
      shownCount = 0;
      selected = 0;
      loading = false;
    });
    await revealMore();
  }

  Future<void> loadMore() async {
    if (loading || query.isEmpty || page >= lastPage) return;
    final gen = generation, next = page + 1;
    setState(() {
      loading = true;
      status = trf("Searching {0} for “{1}”…", [_source, query]);
    });
    Map<String, dynamic>? r;
    String? error;
    try {
      r = await app.call('wallhaven.search', {'query': query, 'page': next, 'slug': widget.slug});
    } catch (e) {
      error = failText(e);
    }
    if (!mounted || gen != generation) return;
    setState(() {
      loading = false;
      if (r == null) {
        status = trf("Search failed: {0}", [error]);
        return;
      }
      page = next;
      lastPage = (r['last_page'] as num?)?.toInt() ?? 1;
      final fresh = [for (final x in (r['results'] as List?) ?? const []) Map<String, dynamic>.from(x as Map)];
      final known = {for (final x in results) x['id']};
      results.addAll(fresh.where((x) => !known.contains(x['id'])));
      _thumbQueue.addAll(fresh.where((x) => !thumbs.containsKey(x['id'])));
      if (results.isEmpty) {
        status = trf("Nothing found for “{0}”. Try other words.", [query]);
      } else {
        status = trf("{0} wallpapers for “{1}”.{2} Enter on a tile opens its menu.", [results.length, query, page < lastPage ? tr(" Scroll down for more.") : '']);
      }
    });
    _pumpThumbs(gen);
  }

  void _pumpThumbs(int gen) {
    while (_thumbsRunning < _thumbWorkers && _thumbQueue.isNotEmpty) {
      final item = _thumbQueue.removeAt(0);
      _thumbsRunning++;
      () async {
        String? path;
        try {
          path = isWeb(item)
              ? (await app.call('webimg.get', {'url': item['url']}))['path'] as String?
              : (await app.call('wallhaven.thumb', {'item': item}))['path'] as String?;
        } catch (_) {
          path = null;
        }
        _thumbsRunning--;
        if (!mounted) return;
        // A wallhaven thumb of an older search, or a web picture no longer shown
        // (a newer Ask replaced the list): nothing changes.
        if (isWeb(item) ? !webPictures.contains(item) : gen != generation) {
          _pumpThumbs(generation); // the worker is free: the current search's thumbs go on
          return;
        }
        setState(() {
          thumbs[item['id'] as String] = path;
          // A web link that is no usable picture (or not public) is left out.
          if (path == null && isWeb(item)) webPictures.remove(item);
        });
        _pumpThumbs(generation);
      }();
    }
  }

  // --- actions -------------------------------------------------------------------

  Future<void> add(Map<String, dynamic> item, {bool set = false}) async {
    setState(() => status = trf("Downloading {0}…", [item['file_name']]));
    try {
      final r = isMade(item)
          ? await app.call('create.add', {'slug': widget.slug, 'path': item['path'], 'set': set})
          : isWeb(item)
          ? await app.call('webimg.add', {'slug': widget.slug, 'url': item['url'], 'set': set})
          : await app.call('wallhaven.add', {'slug': widget.slug, 'item': _plain(item), 'set': set});
      if (!mounted) return;
      setState(() {
        item['added'] = true;
        if (r['path'] is String) item['added_path'] = r['path']; // Apply uses this copy, never a second one
        status = trf("Added {0} to {1}.", [r['name'], widget.themeName]);
      });
      app.notify(trf("Wallpaper added: {0} → {1}", [r['name'], widget.themeName]));
      app.changed();
    } catch (e) {
      final why = failText(e);
      if (mounted) setState(() => status = trf("Could not add {0}: {1}", [item['file_name'], why]));
      app.notify(trf("Could not add wallpaper: {0}: {1}", [item['file_name'], why]));
    }
  }

  /// Apply in one step: the picture into the theme (or its copy there), as
  /// the theme's wallpaper, and the theme applied when it is not in use.
  Future<void> applyNow(Map<String, dynamic> item) async {
    setState(() => status = trf("Applying {0}…", [item['file_name']]));
    String? path = item['added_path'] as String?;
    try {
      if (path == null && item['added'] == true) {
        final list = await app.call('wallpapers.list', {'slug': widget.slug});
        path = [
          for (final w in (list['wallpapers'] as List? ?? const []))
            if (w is Map && w['name'] == item['file_name']) w['path'] as String,
        ].firstOrNull;
      }
      if (path == null) {
        final r = isMade(item)
            ? await app.call('create.add', {'slug': widget.slug, 'path': item['path']})
            : isWeb(item)
            ? await app.call('webimg.add', {'slug': widget.slug, 'url': item['url']})
            : await app.call('wallhaven.add', {'slug': widget.slug, 'item': _plain(item)});
        path = r['path'] as String;
        if (mounted) {
          setState(() {
            item['added'] = true;
            item['added_path'] = path;
          });
        }
      }
      await app.call('wallpapers.set', {'slug': widget.slug, 'path': path});
      if (!widget.current) await app.call('themes.apply', {'slug': widget.slug});
      if (!mounted) return;
      setState(() => status = trf("Applied {0} with {1}.", [widget.themeName, item['file_name']]));
      app.notify(trf("Applied {0} with {1}.", [widget.themeName, item['file_name']]));
      app.changed();
    } catch (e) {
      final why = failText(e);
      if (mounted) setState(() => status = trf("Could not apply {0}: {1}", [item['file_name'], why]));
      app.notify(trf("Could not apply {0}: {1}", [item['file_name'], why]));
    }
  }

  /// The fields the core checks again (its exact URL shapes).
  Map<String, dynamic> _plain(Map item) => {
    for (final k in ['id', 'page', 'thumb', 'full', 'resolution', 'file_size']) k: item[k],
  };

  Future<void> preview(Map<String, dynamic> item, {int seconds = 0}) async {
    final tag = 'web:${item['id']}';
    previewTimer?.cancel();
    previewTimer = null;
    previewing = tag;
    setState(() => status = trf("Loading a preview of {0}…", [item['file_name']]));
    String? path;
    try {
      path = isMade(item)
          ? item['path'] as String
          : isWeb(item)
          ? (await app.call('webimg.get', {'url': item['url']}))['path'] as String?
          : (await app.call('wallhaven.preview', {'item': _plain(item)}))['path'] as String?;
    } catch (_) {
      path = null;
    }
    if (!mounted) return;
    setState(() => status = '');
    if (path == null) {
      if (previewing == tag) previewing = null;
      app.notify(trf("No preview: {0} could not be loaded", [item['file_name']]));
      return;
    }
    if (previewing != tag) return; // Space was let go meanwhile
    final r = await app.run('wallpapers.preview', {'path': path});
    if (r == null) return;
    previewShown = true;
    if (previewing != tag) {
      endPreview();
      return;
    }
    if (seconds > 0) previewTimer = Timer(Duration(seconds: seconds), endPreview);
  }

  Future<void> endPreview() async {
    previewTimer?.cancel();
    previewTimer = null;
    previewing = null;
    if (!previewShown) return;
    previewShown = false;
    await app.run('wallpapers.preview_end');
  }

  Future<void> openPage(Map item) async {
    final r = isWeb(item)
        ? await app.run('webimg.open', {'page': item['page'] ?? item['url']})
        : await app.run('wallhaven.open', {'page': item['page']});
    if (r != null && r['opened'] != true) app.notify(tr("No web browser could be started (xdg-open)."));
  }

  List<PopupMenuEntry<VoidCallback>> menuFor(Map<String, dynamic> w) => [
    if (app.can('wallpaper'))
      item(Icons.check_circle_outline, tr("Apply"), () => applyNow(w),
          tooltip: widget.current
              ? trf("Adds it to {0} and sets it as the background", [widget.themeName])
              : trf("Adds it to {0}, applies {0} and sets it as the background", [widget.themeName])),
    if (w['added'] == true)
      item_(Icons.check, tr("Already added"), null)
    else ...[
      item(Icons.add, trf("Add to {0}", [widget.themeName]), () => add(w), tooltip: trf("Saved in ~/.config/maprisma-theme/backgrounds/{0}/", [widget.slug])),
    ],
    if (app.can('wallpaper'))
      item(Icons.visibility_outlined, tr("Preview on desktop"), () => preview(w, seconds: previewSeconds),
          tooltip: trf("Loads the full image and shows it for {0} seconds; or hold Space on the tile", [previewSeconds])),
    if (!isMade(w)) ...[
      menuLine(),
      item(Icons.open_in_browser, trf("Open on {0}", [isWeb(w) ? w['host'] : _source]), () => openPage(w),
          tooltip: '${w['page'] ?? w['url']}'),
    ],
  ];

  PopupMenuItem<VoidCallback> item_(IconData icon, String label, VoidCallback? action) =>
      item(icon, label, action ?? () {}, enabled: action != null);

  // --- keyboard ------------------------------------------------------------------

  void select(int i) {
    if (shown.isEmpty) return;
    setState(() => selected = i.clamp(0, shown.length - 1));
    final ctx = _tileKeys['${shown[selected]['id']}']?.currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx, alignment: .5, duration: const Duration(milliseconds: 120));
  }

  KeyEventResult onGridKey(FocusNode node, KeyEvent e) {
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.space && app.can('wallpaper')) {
      if (e is KeyDownEvent && selected < shown.length) {
        preview(shown[selected]);
      } else if (e is KeyUpEvent && previewTimer == null) {
        endPreview();
      }
      return KeyEventResult.handled;
    }
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    switch (key) {
      case LogicalKeyboardKey.arrowRight:
        select(selected + 1);
      case LogicalKeyboardKey.arrowLeft:
        if (selected % columns == 0) {
          Navigator.of(context).maybePop();
        } else {
          select(selected - 1);
        }
      case LogicalKeyboardKey.arrowDown:
        select(selected + columns);
      case LogicalKeyboardKey.arrowUp:
        if (selected < columns) {
          fieldFocus.requestFocus();
        } else {
          select(selected - columns);
        }
      case LogicalKeyboardKey.home:
        select(0);
      case LogicalKeyboardKey.end:
        select(shown.length - 1);
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter || LogicalKeyboardKey.contextMenu:
        if (selected < shown.length) _menuKeys['${shown[selected]['id']}']?.currentState?.showButtonMenu();
      case LogicalKeyboardKey.escape || LogicalKeyboardKey.backspace:
        Navigator.of(context).maybePop();
      default:
        final ch = e.character;
        if (ch != null && ch.isNotEmpty && ch.codeUnitAt(0) >= 32 && ch.codeUnitAt(0) != 127) {
          // typing goes back to the search field
          field.text += ch;
          field.selection = TextSelection.collapsed(offset: field.text.length);
          fieldFocus.requestFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  KeyEventResult onFieldKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.arrowDown && shown.isNotEmpty) {
      gridFocus.requestFocus();
      select(selected);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // --- view ----------------------------------------------------------------------

  Widget tile(Map<String, dynamic> item, int index) {
    final look = Look.of(context);
    final id = item['id'] as String;
    final menuKey = _menuKeys.putIfAbsent(id, () => GlobalKey());
    final thumb = thumbs[id];
    return PluginTile(
      selected: index == selected && gridFocus.hasFocus,
      onTap: () {
        gridFocus.requestFocus();
        select(index);
      },
      onSecondaryTap: () => menuKey.currentState?.showButtonMenu(),
      // Thumbnails are header-checked by the core before they are handed over.
      picture: thumb != null
          ? Image.file(File(thumb), fit: BoxFit.cover, cacheWidth: 640,
              errorBuilder: (_, _, _) => ColoredBox(color: look.fg.withValues(alpha: .06)))
          : ColoredBox(
              color: look.fg.withValues(alpha: .06),
              child: thumbs.containsKey(id) ? Icon(Icons.image_not_supported_outlined, color: look.muted) : null,
            ),
      menu: TileMenuButton(menuKey: menuKey, tooltip: tr("Wallpaper actions (Enter)"), menu: () => menuFor(item)),
      bottomLeft: [
        if (isWeb(item)) TileBadge(tr("web"), tooltip: '${item['url']}'),
        if (isMade(item)) TileBadge(tr("made here"), tooltip: picturePrompt),
        if (item['added'] == true) TileBadge(tr("added")),
      ],
      captionText: isWeb(item) || isMade(item) ? '${item['file_name']}' : '${item['resolution']}'.replaceAll('x', ' × '),
    );
  }

  /// Pictures per batch: 5, 10 or 20 (remembered).
  Widget countChoice() {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tr("Pictures per batch: from the web, made here and from wallhaven.cc; Next shows the next batch"),
      child: Container(
        padding: const EdgeInsets.only(left: 10, right: 4),
        decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(cornerSizes(context).control)),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            value: count,
            isDense: true,
            borderRadius: BorderRadius.circular(cornerSizes(context).control),
            items: [for (final n in const [5, 10, 20]) DropdownMenuItem(value: n, child: Text(trf("{0} pictures", [n])))],
            onChanged: (v) async {
              if (v == null) return;
              setState(() => count = v);
              await app.run('settings.set', {'key': 'wallpaper_count', 'value': v}, tr("Could not save the setting"));
              app.changed();
            },
          ),
        ),
      ),
    );
  }

  /// Ask AI wants a picture made: Maprisma Theme's own picture generator,
  /// set up here once (a download), with progress and Cancel.
  Widget generatorBanner() {
    final look = Look.of(context);
    final g = generator!;
    final gb = ((g['download_bytes'] as num?) ?? 0) / 1e9;
    final Widget body;
    if (g['setting_up'] == true) {
      body = Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(trf("Setting up the picture generator… {0}", ['${g['text'] ?? ''}'])),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: ((g['fraction'] as num?) ?? 0).toDouble()),
          ]),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: cancelSetup,
          icon: const Icon(Icons.close, size: 16),
          label: Text(tr("Cancel")),
        ),
      ]);
    } else {
      body = Row(children: [
        Expanded(
          child: Text([
            trf("Ask AI wants to make this picture on this computer. The picture generator is not set up yet: {0} GB to download once.", [gb.toStringAsFixed(1)]),
            if ('${g['error'] ?? ''}'.isNotEmpty) trf("Last try: {0}", [g['error']]),
          ].join(' ')),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(onPressed: setUpGenerator, icon: const Icon(Icons.download, size: 16), label: Text(tr("Set up"))),
      ]);
    }
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: look.fg.withValues(alpha: .06),
        border: Border.all(color: look.accent.withValues(alpha: .5)),
        borderRadius: BorderRadius.circular(corners(context)),
      ),
      child: DefaultTextStyle.merge(style: const TextStyle(fontSize: 13), child: body),
    );
  }

  /// Ask AI: the words, Ask (Stop while asking), the phrases it came back with.
  Widget aiRow() {
    final helper = aiHelper!;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: Focus(
            onKeyEvent: (node, e) {
              if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
                Navigator.of(context).maybePop();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: TextField(
              controller: aiField,
              focusNode: aiFocus,
              maxLength: 600,
              enabled: !asking,
              decoration: InputDecoration(
                prefixIcon: Icon(Icons.auto_awesome_outlined, size: 18),
                hintText: tr("Ask AI, e.g. “calm and wintry, fits this theme”"),
                counterText: '',
              ),
              onSubmitted: (_) => askAi(),
            ),
          ),
        ),
        const SizedBox(width: 6),
        countChoice(),
        const SizedBox(width: 6),
        // As the Ask AI page: a filled Ask (Stop while asking); corners from the theme.
        making
            ? FilledButton.icon(onPressed: stopMakingPictures, icon: const Icon(Icons.stop, size: 16), label: Text(tr("Stop")))
            : asking
            ? FilledButton.icon(onPressed: stopAsking, icon: const Icon(Icons.stop, size: 16), label: Text(tr("Stop")))
            : Tooltip(
                message: trf("Ask {0} for search words: it gets your words and this theme's name and colors; the search itself uses no tokens", [helper['name']]),
                child: FilledButton.icon(onPressed: askAi, icon: const Icon(Icons.send, size: 16), label: Text(tr("Ask"))),
              ),
      ]),
      if (picturePrompt != null && generator != null && generator!['ready'] != true) ...[
        const SizedBox(height: 6),
        generatorBanner(),
      ],
      if (aiQueries.isNotEmpty) ...[
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (aiSummary.isNotEmpty) Text(aiSummary, style: hintStyle(context)),
          for (final q in aiQueries)
            ActionChip(
              label: Text(q),
              tooltip: trf("Search for “{0}”", [q]),
              visualDensity: VisualDensity.compact,
              onPressed: () => searchFor(q),
            ),
        ]),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return SubPage(
      title: trf("{0} — search wallpapers", [widget.themeName]),
      section: false,
      backTooltip: tr("Back to the wallpapers (Backspace or Esc)"),
      actions: [if (aiHelper != null) ...[const SizedBox(width: 8), helperChoice()]],
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Focus(
              onKeyEvent: onFieldKey,
              child: TextField(
                controller: field,
                focusNode: fieldFocus,
                maxLength: 100,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  prefixIcon: Icon(Icons.search, size: 18),
                  hintText: tr("Search, e.g. misty forest, neon city"),
                  counterText: '',
                ),
                onSubmitted: (_) => search(),
              ),
            ),
          ),
          // Without Ask AI the batch size sits here; with it, next to Ask (one on screen).
          if (aiHelper == null) ...[const SizedBox(width: 6), countChoice()],
        ]),
        if (aiHelper != null) ...[
          const SizedBox(height: 8),
          aiRow(),
        ],
        const SizedBox(height: 6),
        // Busy: Ask AI is thinking or a search is loading (fixed height, no jump).
        SizedBox(height: 2, child: asking || loading || making ? const LinearProgressIndicator() : null),
        const SizedBox(height: 6),
        Text(hint, style: hintStyle(context)),
        const SizedBox(height: 8),
        Expanded(
          child: Focus(
            focusNode: gridFocus,
            onKeyEvent: onGridKey,
            onFocusChange: (_) => setState(() {}),
            child: LayoutBuilder(builder: (context, box) {
              columns = gridColumns(box.maxWidth);
              return TileGrid(
                controller: scroll,
                count: shown.length,
                columns: columns,
                footer: loading
                    ? const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator()))
                    : canNext
                        ? Padding(
                            padding: const EdgeInsets.all(12),
                            child: Center(
                              child: OutlineAction(
                                icon: Icons.navigate_next,
                                label: trf("Next {0}", [count]),
                                tooltip: [
                                  if (picturePrompt != null) trf("{0} more pictures made on this computer (no tokens)", [count]),
                                  if (moreWeb && aiHelper != null) trf("{0} more from the web (asks {1} again)", [count, aiHelper!['name']]),
                                  if (moreResults) trf("{0} more from {1}", [count, _source]),
                                ].join(' · '),
                                onPressed: next,
                              ),
                            ),
                          )
                        : null,
                builder: (context, i) {
                  final item = shown[i];
                  return KeyedSubtree(
                    key: _tileKeys.putIfAbsent('${item['id']}', () => GlobalKey()),
                    child: tile(item, i),
                  );
                },
              );
            }),
          ),
        ),
      ]),
    );
  }
}
