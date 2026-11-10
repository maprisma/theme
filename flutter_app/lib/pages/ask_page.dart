import '../i18n.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart' show colorLabel, maxNameLength;

import '../app.dart';
import '../backend.dart' show ServiceError;
import '../theme.dart';
import '../widgets.dart';
import '../window.dart';
import 'editor_page.dart';

/// Ask AI (the plugin's ask_page.py): a plain request ("blue borders, red
/// text and a nice dog wallpaper", "a warm dark theme from the catalog")
/// answered with up to three candidates, each shown as it would look. Every
/// card is checked data from the core: the look-alike in its colors (with a
/// wallpaper from the wallhaven search for its phrase, ‹ › for the next
/// picture, no tokens), its terminal colors and font; Use, Not this, Refine…
class AskPage extends StatefulWidget {
  const AskPage({super.key});
  @override
  State<AskPage> createState() => _AskPageState();
}

List<String> get _examples => [
  tr("Blue borders, red text and a nice dog wallpaper"),
  tr("A calm light theme for daytime"),
  tr("Find a warm dark theme in the catalog"),
  tr("Another font for the current theme"),
];
const _maxPrompts = 12, _maxRequest = 600;
String get _description =>
    tr("Find or make a theme from a few words with a coding agent on this computer (Claude Code, Codex, pi or Hermes) or a local model, using your plan or tokens only when you click Ask; a local model uses none and nothing leaves the computer. Each Ask sends your words with the names and main colors of your installed themes, the omarchy.org theme names and your installed font names; nothing else.");
String get _noHelper => tr("No helper ready: install Claude Code, Codex, pi or Hermes and sign in, or connect pi or Hermes to a local model.");
String get _maprismaText =>
    tr("Maprisma sets up AI for you: online agents and their providers, and local models with llama.cpp or Ollama, connected on one map. Every agent it sets up can answer here too.");
const _paletteKeys = ['red', 'yellow', 'orange', 'green', 'cyan', 'blue', 'magenta', 'brown'];

/// One result card's own state (wallpaper search, refine field).
final class _Card {
  _Card(this.c);
  Map<String, dynamic> c;
  List<Map> walls = const [];
  int wall = 0;
  String? wallNote;
  bool searching = false, refining = false, loadingPicture = false, making = false;

  /// A catalog theme is not installed: its colors (and, while it has no
  /// search phrase, its wallpaper) come from its omarchy.org preview.
  Map? catalogColors;
  String? catalogPicture;
  TextEditingController? refine;
  TextEditingController? search;
  Object token = Object();
}

class _AskPageState extends State<AskPage> {
  final request = TextEditingController();
  final promptEdit = TextEditingController();
  final _field = FocusNode();
  List<Map<String, dynamic>> helpers = [];
  String? helper;
  bool loaded = false, asking = false, showNote = false;
  int? editing;
  String status = '';
  int seconds = 0;
  Timer? _ticker;
  final cards = <_Card>[];
  final rejected = <String>[];

  /// Maprisma Playground's picture generator (create.status), for cards whose
  /// wallpaper is to be made; pictures are made one after another.
  Map<String, dynamic>? generator;
  Timer? _setupPoll;
  Future<void> _makeChain = Future.value();
  List<Map>? catalog;
  StreamSubscription? _hidden;
  late MaprismaThemeAppState _app;

  MaprismaThemeAppState get app => _app;
  Map<String, dynamic> get settings => app.settings;
  bool get enabled => settings['ask_ai'] == true;
  bool get hints => settings['maprisma_hints'] != false;
  List<Map<String, dynamic>> get ready => [
    for (final h in helpers)
      if (h['signed_in'] == true) h,
  ];
  Map<String, dynamic>? get chosen => ready.where((h) => h['id'] == helper).firstOrNull;

  List<String>? get ownPrompts {
    final v = settings['ask_prompts'];
    return v is List ? v.whereType<String>().toList() : null;
  }

  List<String> get prompts => ownPrompts ?? _examples;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _app = AppScope.read(context);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    // Window hidden: the local models Ask AI loaded give their memory back.
    _hidden = AppWindow.instance.hidden.stream.listen((_) => _release());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _setupPoll?.cancel();
    _hidden?.cancel();
    _release(); // Ask AI left: the memory of the models it loaded back
    request.dispose();
    promptEdit.dispose();
    _field.dispose();
    for (final c in cards) {
      c.refine?.dispose();
      c.search?.dispose();
    }
    super.dispose();
  }

  void _release([String? keep]) => app.call('ask.release', {'keep': ?keep}).then((_) {}, onError: (_) {});

  Future<void> _load() async {
    try {
      final r = await app.call('ask.helpers');
      if (!mounted) return;
      setState(() {
        helpers = [for (final h in r['helpers'] as List) Map<String, dynamic>.from(h as Map)];
        final ids = ready.map((h) => h['id']).toSet();
        helper = ids.contains(helper) ? helper : r['chosen'] as String?;
        loaded = true;
      });
    } catch (e) {
      if (mounted) setState(() => loaded = true);
    }
  }

  Future<bool> _set(String key, Object? value) async {
    final r = await app.run('settings.set', {'key': key, 'value': value}, tr("Could not save the setting"));
    if (r == null) return false;
    await app.refreshLook();
    if (mounted) setState(() {});
    return true;
  }

  Future<void> _turnOn() async {
    if (await _set('ask_ai', true)) {
      app.changed();
      await _load();
    }
  }

  void _chooseHelper(String? id) {
    if (id == null || id == helper) return;
    setState(() => helper = id);
    _release(id); // another model or an online agent: the old model's memory back
    _set('ask_ai_helper', id);
  }

  // --- suggestions ----------------------------------------------------------------------

  static String _tidy(String s) {
    final t = s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
    return t.length > _maxRequest ? t.substring(0, _maxRequest) : t;
  }

  Future<void> _storePrompts(List<String>? list) async {
    if (await _set('ask_prompts', list)) setState(() => editing = null);
  }

  void _say(String text) => setState(() => status = text);

  Future<void> _savePrompt() async {
    final text = _tidy(request.text);
    if (text.isEmpty) {
      _say(tr("Write a request first, then save it as a suggestion."));
    } else if (prompts.contains(text)) {
      _say(tr("That is already a suggestion."));
    } else if (prompts.length >= _maxPrompts) {
      _say(trf("At most {0} suggestions: remove one first.", [_maxPrompts]));
    } else {
      await _storePrompts([...prompts, text]);
      _say(tr("Saved as suggestion."));
    }
  }

  Future<void> _finishEdit(bool save) async {
    final index = editing;
    if (index == null) return;
    final list = [...prompts];
    final text = _tidy(promptEdit.text);
    if (!save || index >= list.length || text == list[index]) {
      setState(() => editing = null);
      return;
    }
    if (text.isEmpty) {
      list.removeAt(index);
    } else if (list.contains(text)) {
      _say(tr("That is already a suggestion."));
      return;
    } else {
      list[index] = text;
    }
    await _storePrompts(list);
    _field.requestFocus();
  }

  Future<void> _movePrompt(int from, int to) async {
    final list = [...prompts];
    if (from < 0 || from >= list.length || to < 0 || to >= list.length || from == to) return;
    list.insert(to, list.removeAt(from));
    await _storePrompts(list);
  }

  Widget _promptRow(int index, String text, ColorScheme scheme) {
    const tight = VisualDensity(horizontal: -4, vertical: -4);
    if (editing == index) {
      return Row(
        children: [
          const SizedBox(width: 28),
          Expanded(
            child: CallbackShortcuts(
              bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => _finishEdit(false)},
              child: TextField(
                controller: promptEdit,
                autofocus: true,
                maxLength: _maxRequest,
                decoration: InputDecoration(isDense: true, counterText: '', hintText: tr("Edit suggestion")),
                onSubmitted: (_) => _finishEdit(true),
              ),
            ),
          ),
          IconButton(
            tooltip: tr("Save"),
            visualDensity: tight,
            iconSize: 18,
            onPressed: () => _finishEdit(true),
            icon: const Icon(Icons.check),
          ),
        ],
      );
    }
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      // Alt+↑/↓ on a focused suggestion moves it.
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent || !HardwareKeyboard.instance.isAltPressed) return KeyEventResult.ignored;
        final up = event.logicalKey == LogicalKeyboardKey.arrowUp;
        if (!up && event.logicalKey != LogicalKeyboardKey.arrowDown) return KeyEventResult.ignored;
        _movePrompt(index, index + (up ? -1 : 1));
        return KeyEventResult.handled;
      },
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Tooltip(
                message: tr("Drag to reorder (Alt+↑/↓)"),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(Icons.drag_indicator, size: 16, color: scheme.onSurfaceVariant),
                ),
              ),
            ),
          ),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(cornerSizes(context).control),
              onTap: enabled && chosen != null && !asking
                  ? () {
                      request.text = text;
                      _ask();
                    }
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
                child: Tooltip(
                  message: text,
                  child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: tr("Edit suggestion"),
            visualDensity: tight,
            iconSize: 16,
            onPressed: () => setState(() {
              editing = index;
              promptEdit.text = text;
              promptEdit.selection = TextSelection.collapsed(offset: text.length);
            }),
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: tr("Remove suggestion"),
            visualDensity: tight,
            iconSize: 16,
            onPressed: () => _storePrompts([...prompts]..removeAt(index)),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  Widget _suggestions(ColorScheme scheme, double width) {
    final list = prompts;
    final rows = width < 900 ? 2 : 4;
    const rowH = 38.0;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(corners(context)),
        border: Border.all(color: scheme.outlineVariant),
      ),
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: rowH * rows.clamp(1, list.isEmpty ? 1 : list.length),
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: list.length,
              itemExtent: rowH,
              onReorderItem: _movePrompt,
              itemBuilder: (context, i) => KeyedSubtree(key: ValueKey('row-${list[i]}'), child: _promptRow(i, list[i], scheme)),
            ),
          ),
          if (ownPrompts != null)
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: tr("Back to the built-in suggestions"),
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: () => _storePrompts(null),
                icon: const Icon(Icons.undo, size: 16),
              ),
            )
          else
            const SizedBox(height: 4),
        ],
      ),
    );
  }

  // --- asking ---------------------------------------------------------------------------

  /// The omarchy.org names the core may offer (from the Import page's list).
  Future<List<Map>> _catalog() async {
    if (catalog != null) return catalog!;
    try {
      final r = await app.call('import.omarchy_list');
      final list = r['themes'] ?? r['catalog'] ?? r['items'];
      catalog = [
        if (list is List)
          for (final e in list)
            if (e is Map) e,
      ];
    } catch (_) {
      catalog = []; // no network or no import module: installed themes still work
    }
    return catalog!;
  }

  Future<void> _ask({_Card? parent, String? words}) async {
    final h = chosen;
    final text = _tidy(words ?? request.text);
    if (asking || h == null || text.isEmpty) return;
    setState(() {
      asking = true;
      parent?.refining = true;
      if (parent == null) rejected.clear();
      seconds = 0;
      status = trf("Asking {0}… 0 s", [h['name']]);
    });
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && asking) setState(() => status = trf("Asking {0}… {1} s", [h['name'], ++seconds]));
    });
    try {
      final cat = await _catalog();
      final r = await app.call('ask.run', {
        'helper': h['id'],
        'request': text,
        'catalog': [
          for (final e in cat) {'slug': e['slug'] ?? e['name'], 'name': e['title'] ?? e['name']},
        ],
        'rejected': rejected,
        if (parent != null) 'refine': parent.c,
      });
      if (!mounted) return;
      final found = [for (final c in r['candidates'] as List) _Card(Map<String, dynamic>.from(c as Map))];
      setState(() {
        if (parent != null && found.isEmpty) {
          status = tr("Nothing visible changed. Try clearer words, e.g. “much darker”.");
        } else if (found.isEmpty) {
          status = tr("Nothing usable came back. Try other words.");
        } else {
          status = '${r['summary'] ?? ''}';
          if (parent != null) {
            var at = cards.indexOf(parent);
            if (at < 0) {
              at = 0;
            } else {
              cards.removeAt(at);
            }
            cards.insertAll(at, found);
            found.first.refine = TextEditingController(); // refine again right where you are
          } else {
            cards
              ..clear()
              ..addAll(found);
          }
        }
      });
      for (final card in found) {
        _searchWalls(card);
        if (card.c['picture_prompt'] is String) _makeFor(card);
        if (card.c['kind'] == 'catalog') _catalogLook(card);
      }
    } catch (e) {
      if (mounted) setState(() => status = trf("No answer: {0}", [_why(e)]));
    } finally {
      _ticker?.cancel();
      if (mounted) {
        setState(() {
          asking = false;
          parent?.refining = false;
        });
      }
    }
  }

  /// The core's reason (e.g. the local model server did not start), one line.
  static String _why(Object e) {
    var line = e is ServiceError
        ? (e.reason?.trim().isNotEmpty == true ? e.reason! : e.code.replaceAll('_', ' '))
        : '$e'.replaceFirst(RegExp(r'^(Bad state|Exception): '), '');
    line = line.split('\n').first.trim();
    if (line.length > 300) line = '${line.substring(0, 300)}…';
    return line;
  }

  // --- wallpapers (the wallhaven search, no tokens) ---------------------------------------

  /// A picture of a search result already on this computer (the core keeps
  /// the thumbnails); the GUI itself never downloads.
  static String? _thumb(Map item) {
    for (final k in ['thumb_path', 'thumb_file', 'thumb', 'preview_path', 'preview', 'path']) {
      final v = item[k];
      if (v is String && v.startsWith('/') && File(v).existsSync()) return v;
    }
    return null;
  }

  /// The suggestion's pictures from the web (a web Ask), as wallpaper results.
  static List<Map> _webWalls(_Card card) => [
    for (final (i, e) in ((card.c['wallpaper_images'] as List?) ?? const []).indexed)
      if (e is Map && e['url'] is String)
        {'kind': 'web', 'id': 'web$i', 'url': e['url'], if (e['page'] is String) 'page': e['page'], 'title': '${e['title'] ?? ''}'},
  ];

  Future<void> _searchWalls(_Card card) async {
    final query = card.c['wallpaper_query'] as String?;
    final web = card.c['query_by_user'] == true ? const <Map>[] : _webWalls(card);
    if (query == null || query.isEmpty) {
      if (web.isEmpty) return;
      setState(() {
        card.walls = [...card.walls.where((w) => w['kind'] == 'created'), ...web];
        card.wall = 0;
        card.wallNote = null;
      });
      _loadThumb(card);
      return;
    }
    final token = card.token = Object();
    setState(() {
      card.searching = true;
      card.wallNote = trf("Searching wallpapers for “{0}”…", [query]);
    });
    // Long phrases often find nothing on wallhaven: then fewer words.
    final words = query.split(' ');
    final tries = <String>[];
    for (final n in [words.length, 3, 2, 1]) {
      final phrase = words.take(n).join(' ');
      if (phrase.isNotEmpty && !tries.contains(phrase)) tries.add(phrase);
    }
    List<Map> results = const [];
    String? note;
    for (final phrase in tries) {
      try {
        final r = await app.call('wallhaven.search', {'query': phrase, 'page': 1});
        final list = r['results'] ?? r['items'] ?? r['wallpapers'];
        results = [
          if (list is List)
            for (final e in list)
              if (e is Map) e,
        ];
      } catch (e) {
        note = '$e'.contains('unknown_route')
            ? tr("The wallpaper search is not available in this version.")
            : tr("The wallpaper search did not answer.");
        break;
      }
      if (results.isNotEmpty) break;
    }
    if (!mounted || card.token != token) return;
    // The web's pictures first: chosen for this suggestion.
    results = [...card.walls.where((w) => w['kind'] == 'created'), ...web, ...results];
    setState(() {
      card.searching = false;
      card.walls = results;
      final chosenId = card.c['wallpaper_id'];
      final at = results.indexWhere((e) => chosenId != null && e['id'] == chosenId);
      card.wall = at < 0 ? 0 : at;
      card.wallNote = note ?? (results.isEmpty ? trf("No wallpapers found for “{0}”.", [query]) : null);
      if (results.isNotEmpty) card.c['wallpaper_id'] = '${results[card.wall]['id'] ?? ''}';
    });
    _loadThumb(card);
  }

  /// The core downloads and header-checks the shown result's thumbnail;
  /// the path is kept on the result as `thumb_path`.
  Future<void> _loadThumb(_Card card) async {
    if (card.walls.isEmpty) return;
    final item = card.walls[card.wall];
    if (_thumb(item) != null) return;
    setState(() => card.loadingPicture = true);
    try {
      final r = item['kind'] == 'web'
          ? await app.call('webimg.get', {'url': item['url']})
          : await app.call('wallhaven.thumb', {
              'item': {
                for (final e in item.entries)
                  if (e.key != 'added' && e.key != 'thumb_path') '${e.key}': e.value,
              },
            });
      final path = r['path'];
      if (path is String && mounted) setState(() => item['thumb_path'] = path);
    } catch (_) {
      // no picture: a web link that is none is left out; otherwise the card shows the colors only
      if (item['kind'] == 'web' && mounted) {
        setState(() {
          card.walls = [...card.walls]..remove(item);
          if (card.wall >= card.walls.length) card.wall = 0;
        });
        if (mounted) setState(() => card.loadingPicture = false);
        _loadThumb(card);
        return;
      }
    }
    if (mounted) setState(() => card.loadingPicture = false);
  }

  /// The colors of a catalog theme from its omarchy.org preview picture (the
  /// core fetches and checks it), and that picture as its wallpaper.
  Future<void> _catalogLook(_Card card) async {
    try {
      final r = await app.call('import.omarchy_preview', {'slug': card.c['theme']});
      final path = r['path'];
      if (path is! String || !mounted) return;
      final colors = await app.call('custom.from_wallpaper', {'path': path});
      if (!mounted) return;
      setState(() {
        card.catalogColors = colors['colors'] is Map ? colors['colors'] as Map : null;
        card.catalogPicture = path;
      });
    } catch (_) {
      // offline: the card shows the font line only
    }
  }

  // --- wallpapers made here (Maprisma Playground's generator) -------------------------

  Future<Map<String, dynamic>?> _generatorStatus() async {
    try {
      final st = await app.call('create.status');
      if (mounted) setState(() => generator = st);
      return st;
    } catch (_) {
      return null;
    }
  }

  /// Makes one wallpaper from the card's description and shows it first;
  /// waits its turn (one picture at a time). Not set up: the card offers it.
  Future<void> _makeFor(_Card card) async {
    final st = await _generatorStatus();
    if (st == null || st['ready'] != true || !mounted) return;
    final prompt = card.c['picture_prompt'] as String;
    setState(() => card.making = true);
    _makeChain = _makeChain.then((_) async {
      if (!mounted || !cards.contains(card)) return;
      try {
        final r = await app.call('create.make', {'prompt': prompt, 'seed': math.Random().nextInt(1 << 31)});
        if (!mounted) return;
        final path = r['path'] as String;
        setState(() {
          card.walls = [
            {'kind': 'created', 'id': 'made${card.walls.length}:$path', 'path': path, 'thumb_path': path},
            ...card.walls,
          ];
          card.wall = 0;
          card.wallNote = null;
        });
      } catch (e) {
        if (mounted) setState(() => card.wallNote = trf("Could not make the picture: {0}", [_why(e)]));
      } finally {
        if (mounted) setState(() => card.making = false);
      }
    });
  }

  /// Stops the download; what came down stays and a later Set up goes on from there.
  Future<void> _cancelSetup() async {
    try {
      await app.call('create.cancel_setup');
    } catch (_) {}
    await _generatorStatus();
  }

  Future<void> _setUpGenerator() async {
    try {
      final st = await app.call('create.setup');
      if (mounted) setState(() => generator = st);
    } catch (e) {
      if (mounted) setState(() => status = trf("Could not set up the picture generator: {0}", [_why(e)]));
      return;
    }
    _setupPoll?.cancel();
    _setupPoll = Timer.periodic(const Duration(seconds: 1), (t) async {
      final st = await _generatorStatus();
      if (!mounted) return t.cancel();
      if (st == null || st['setting_up'] == true) return;
      t.cancel();
      if (st['ready'] == true) {
        for (final card in [...cards]) {
          if (card.c['picture_prompt'] is String && !card.walls.any((w) => w['kind'] == 'created')) _makeFor(card);
        }
      }
    });
  }

  void _stepWall(_Card card, int by) {
    if (card.walls.isEmpty) return;
    setState(() {
      card.wall = (card.wall + by) % card.walls.length;
      card.c['wallpaper_id'] = '${card.walls[card.wall]['id'] ?? ''}';
    });
    _loadThumb(card);
  }

  void _ownSearch(_Card card) {
    final words = _tidy(card.search?.text ?? '');
    if (words.isEmpty) return;
    setState(() {
      card.c['wallpaper_query'] = words;
      card.c['query_by_user'] = true;
      card.c.remove('wallpaper_id');
    });
    _searchWalls(card);
  }

  // --- use, not this ----------------------------------------------------------------------

  Future<void> _use(_Card card, BuildContext buttonContext) async {
    final c = card.c;
    final slug = c['theme'] as String;
    switch (c['kind']) {
      case 'installed':
        final wall = _chosenWall(card);
        final r = await app.run('themes.apply', {'slug': slug});
        if (r != null) {
          if (wall != null) await _addWall(slug, wall);
          app.notify(trf("Applied {0}", [c['name']]));
          app.changed();
        }
      case 'catalog':
        final box = buttonContext.findRenderObject() as RenderBox?;
        final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
        if (box == null || overlay == null) return;
        final at = box.localToGlobal(Offset(0, box.size.height), ancestor: overlay);
        final action = await showMenu<VoidCallback>(
          context: context,
          position: RelativeRect.fromLTRB(at.dx, at.dy, overlay.size.width - at.dx, 0),
          items: [
            item(Icons.download_outlined, tr("Install"), () => _install(slug, false)),
            item(Icons.check_circle_outline, tr("Install and apply"), () => _install(slug, true)),
          ],
        );
        action?.call();
      default:
        final edit = c['mode'] == 'edit' && c['editable'] == true;
        final initial = <String, String>{
          if (c['mode'] == 'new' && c['name'] is String) 'name': c['name'] as String,
          if (c['font'] is String) 'font': c['font'] as String,
          for (final e in ((c['changes'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}',
        };
        final wall = _chosenWall(card);
        final picture = card.walls.isEmpty ? null : _thumb(card.walls[card.wall]);
        // Nothing is saved until you save; a system theme is never changed: a copy.
        // The editor gives back the saved theme's slug (null: not saved).
        final saved = await Navigator.of(context).push<Object?>(
          MaterialPageRoute(
            builder: (_) => EditorPage(
              base: edit ? null : slug,
              edit: edit ? slug : null,
              initial: initial,
              askWallpaper: wall == null ? null : picture,
              initialBlur: c['blur'] is Map ? Map<String, dynamic>.from(c['blur'] as Map) : null,
              fromAsk: !edit && c['mode'] == 'new',
            ),
          ),
        );
        if (saved is String && saved.isNotEmpty && wall != null) {
          await _addWall(saved, wall);
          app.changed();
        }
    }
  }

  /// The wallhaven result shown on the card (null: none), as the core takes it.
  Map<String, dynamic>? _chosenWall(_Card card) {
    if (card.walls.isEmpty || card.wall < 0 || card.wall >= card.walls.length) return null;
    final item = card.walls[card.wall];
    return {
      for (final e in item.entries)
        if (e.key != 'added' && e.key != 'thumb_path') '${e.key}': e.value,
    };
  }

  /// Adds the card's wallpaper to [slug]; shown right away when [slug] is the
  /// theme in use (the core only sets it then).
  Future<void> _addWall(String slug, Map<String, dynamic> wall) async {
    if (wall['kind'] == 'created') {
      await app.run('create.add', {'slug': slug, 'path': wall['path'], 'set': true}, tr("Could not add the wallpaper"));
    } else if (wall['kind'] == 'web') {
      await app.run('webimg.add', {'slug': slug, 'url': wall['url'], 'set': true}, tr("Could not add the wallpaper"));
    } else {
      await app.run('wallhaven.add', {'slug': slug, 'item': wall, 'set': true}, tr("Could not add the wallpaper"));
    }
  }

  Future<void> _install(String slug, bool apply) async {
    final r = await app.run('import.omarchy_install', {'name': slug, 'apply': apply}, trf("Could not install {0}", [slug]));
    if (r != null) {
      app.notify(apply ? trf("Installed and applied {0}", [slug]) : trf("Installed {0}", [slug]));
      app.changed();
    }
  }

  void _reject(_Card card) => setState(() {
    final c = card.c;
    rejected.add('${c['kind'] == 'catalog' ? c['theme'] : (c['agent_name'] ?? c['name'] ?? c['theme'])}');
    if (c['wallpaper_query'] is String && c['query_by_user'] != true) rejected.add(c['wallpaper_query'] as String);
    cards.remove(card);
    card.refine?.dispose();
    card.search?.dispose();
  });

  // --- cards ------------------------------------------------------------------------------

  Map _colorsOf(_Card card) {
    final c = card.c['colors'] ?? card.catalogColors;
    return c is Map && c.isNotEmpty ? c : app.colors;
  }

  /// Title, subtitle and reason (the plugin's ask_card_texts): after your own
  /// wallpaper search the title is that search (a new theme takes it as its
  /// name), and the reason says it is your search.
  (String, String, String) _texts(_Card card) {
    final c = card.c;
    final query = c['wallpaper_query'] is String ? c['wallpaper_query'] as String : '';
    final mine = c['query_by_user'] == true && query.isNotEmpty;
    var kind = switch (c['kind']) {
      'catalog' => tr("From omarchy.org"),
      'installed' => tr("Installed theme, as it is"),
      // A new theme is new for you: the theme the agent started from is internal.
      _ => c['mode'] == 'edit' ? trf("Edit {0}", [c['base_name']]) : tr("New theme"),
    };
    if (!mine) return ('${c['name']}', kind, '${c['summary'] ?? ''}');
    var title = query[0].toUpperCase() + query.substring(1);
    final agentName = c.putIfAbsent('agent_name', () => c['name']);
    if (c['kind'] == 'custom' && c['mode'] != 'edit') {
      // The editor's name, within its rules; else the agent's name stays.
      final name = (title.length > maxNameLength ? title.substring(0, maxNameLength) : title).trim();
      title = RegExp('[A-Za-z0-9]').hasMatch(name) ? name : '$agentName';
      c['name'] = title;
    } else if (c['kind'] == 'catalog') {
      kind = '$kind · ${c['name']}'; // the theme's name stays
    }
    return (title, kind, trf("Wallpaper: your search “{0}”", [query]));
  }

  String? _busyText(_Card card) {
    if (card.refining) return trf("Refining with {0}…", [chosen?['name'] ?? tr("the helper")]);
    if (card.loadingPicture) return tr("Loading the picture…");
    if (card.searching) return tr("Searching wallpapers…");
    if (card.making) return tr("Making the wallpaper on this computer…");
    return null;
  }

  Widget _card(_Card card, ColorScheme scheme, double previewW) {
    final c = card.c;
    final colors = _colorsOf(card);
    final hint = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    final (title, kind, reason) = _texts(card);
    String? picture = card.walls.isNotEmpty ? _thumb(card.walls[card.wall]) : null;
    if (picture == null && c['kind'] == 'catalog' && c['wallpaper_query'] == null) picture = card.catalogPicture;
    final busy = _busyText(card);
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(corners(context).clamp(0, 10)),
        border: Border.all(color: scheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(kind, maxLines: 1, overflow: TextOverflow.ellipsis, style: hint),
          const SizedBox(height: 6),
          SizedBox(
            height: previewW * 9 / 16,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _LookAlike(colors: colors, wallpaper: picture),
                if (_webWall(card) case final w?)
                  Positioned(left: 6, bottom: 6, child: TileBadge(tr("web"), tooltip: '${w['url']}')),
                if (_madeWall(card))
                  Positioned(left: 6, bottom: 6, child: TileBadge(tr("made here"), tooltip: '${c['picture_prompt'] ?? ''}')),
                if (busy != null)
                  Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(busy, style: const TextStyle(color: Colors.white, fontSize: 12)),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          _strip(c, colors, scheme, card),
          if (card.search != null) ...[const SizedBox(height: 4), _searchRow(card)],
          if (c['wallpaper_query'] is String || card.walls.isNotEmpty || c['picture_prompt'] is String) _wallRow(card, scheme),
          if (reason.isNotEmpty) ...[const SizedBox(height: 4), Text(reason, style: hint)],
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              Builder(
                builder: (b) => FilledButton.icon(
                  style: _small,
                  onPressed: () => _use(card, b),
                  icon: const Icon(Icons.check, size: 16),
                  label: Text(tr("Use")),
                ),
              ),
              OutlinedButton.icon(
                style: _small,
                onPressed: () => _reject(card),
                icon: const Icon(Icons.close, size: 16),
                label: Text(tr("Not this")),
              ),
              OutlinedButton.icon(
                style: _small,
                onPressed: () => setState(() => card.refine ??= TextEditingController()),
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: Text(tr("Refine…")),
              ),
              OutlinedButton.icon(
                style: _small,
                onPressed: () => _wallpaperButton(card),
                icon: const Icon(Icons.image_outlined, size: 16),
                label: Text(tr("Wallpaper…")),
              ),
            ],
          ),
          if (card.refine != null) ...[const SizedBox(height: 6), _refineRow(card)],
        ],
      ),
    );
  }

  static final _small = ButtonStyle(
    visualDensity: VisualDensity.compact,
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
  );

  /// Wallpaper…: opens your own search for this card (no tokens); a second
  /// click searches new words, or closes it again.
  void _wallpaperButton(_Card card) {
    final open = card.search;
    if (open == null) {
      setState(() => card.search = TextEditingController(text: '${card.c['wallpaper_query'] ?? ''}'));
      return;
    }
    final words = _tidy(open.text);
    if (words.isNotEmpty && words != card.c['wallpaper_query']) {
      _ownSearch(card);
    } else {
      setState(() {
        open.dispose();
        card.search = null;
      });
    }
  }

  Widget _searchRow(_Card card) => Row(
    children: [
      Expanded(
        child: TextField(
          controller: card.search,
          autofocus: true,
          maxLength: 100,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(isDense: true, counterText: '', hintText: tr("Search wallpapers, e.g. “husky snow”")),
          onSubmitted: (_) => _ownSearch(card),
        ),
      ),
      const SizedBox(width: 6),
      IconButton.filledTonal(
        tooltip: tr("Search wallpapers (no tokens)"),
        visualDensity: VisualDensity.compact,
        onPressed: () => _ownSearch(card),
        icon: const Icon(Icons.search, size: 18),
      ),
    ],
  );

  Widget _refineRow(_Card card) {
    final query = card.c['wallpaper_query'];
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: card.refine,
            autofocus: true,
            maxLength: _maxRequest,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              counterText: '',
              hintText: query is String
                  ? trf("How should it change? e.g. “warmer”, “another picture like {0}”", [query])
                  : tr("How should it change? e.g. “warmer”, “another wallpaper”"),
            ),
            onSubmitted: (t) {
              if (t.trim().isNotEmpty) _ask(parent: card, words: t);
            },
          ),
        ),
        const SizedBox(width: 6),
        IconButton.filledTonal(
          tooltip: tr("Refine…"),
          visualDensity: VisualDensity.compact,
          onPressed: asking || chosen == null
              ? null
              : () {
                  if (card.refine!.text.trim().isNotEmpty) _ask(parent: card, words: card.refine!.text);
                },
          icon: const Icon(Icons.send, size: 18),
        ),
      ],
    );
  }

  /// The card's shown wallpaper when it is a picture from the web, else null.
  static Map? _webWall(_Card card) {
    if (card.walls.isEmpty || card.wall < 0 || card.wall >= card.walls.length) return null;
    final w = card.walls[card.wall];
    return w['kind'] == 'web' ? w : null;
  }

  static bool _madeWall(_Card card) =>
      card.walls.isNotEmpty && card.wall >= 0 && card.wall < card.walls.length && card.walls[card.wall]['kind'] == 'created';

  static String _hostOf(Map w) => Uri.tryParse('${w['page'] ?? w['url']}')?.host ?? '';

  Future<void> _openWebPage(Map w) async {
    final r = await app.run('webimg.open', {'page': w['page'] ?? w['url']});
    if (r != null && r['opened'] != true) app.notify(tr("No web browser could be started (xdg-open)."));
  }

  /// ‹ "phrase" · n/24 ›: the pictures from the web, then the wallhaven
  /// search's (no tokens); a web picture's page opens with the button.
  Widget _wallRow(_Card card, ColorScheme scheme) {
    final c = card.c;
    const tight = VisualDensity(horizontal: -4, vertical: -4);
    final web = _webWall(card);
    final count = '${card.wall + 1}/${card.walls.length}';
    final label = card.wallNote ??
        (web != null
            ? '${'${web['title'] ?? ''}'.trim().isEmpty ? _hostOf(web) : web['title']} · ${tr("web")} · $count'
            : _madeWall(card)
                ? '${tr("made here")} · $count'
                : c['wallpaper_query'] is String
                    ? '“${c['wallpaper_query']}” · $count'
                    : card.walls.isEmpty
                        ? (c['picture_prompt'] is String ? _generatorNote() : '')
                        : count);
    return Row(
      children: [
        IconButton(
          tooltip: tr("Previous wallpaper"),
          visualDensity: tight,
          onPressed: card.walls.length > 1 ? () => _stepWall(card, -1) : null,
          icon: const Icon(Icons.chevron_left, size: 20),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
        if (c['picture_prompt'] is String) _makeButton(card),
        if (web != null)
          IconButton(
            tooltip: trf("Open on {0}", [_hostOf(web)]),
            visualDensity: tight,
            onPressed: () => _openWebPage(web),
            icon: const Icon(Icons.open_in_browser, size: 18),
          ),
        IconButton(
          tooltip: tr("Next wallpaper"),
          visualDensity: tight,
          onPressed: card.walls.length > 1 ? () => _stepWall(card, 1) : null,
          icon: const Icon(Icons.chevron_right, size: 20),
        ),
      ],
    );
  }

  /// The generator's state for a card whose wallpaper is to be made.
  String _generatorNote() {
    final g = generator;
    if (g == null || g['ready'] == true) return '';
    if (g['playground'] != true) return tr("Making it needs Maprisma Playground");
    if (g['setting_up'] == true) {
      return trf("Setting up the picture generator… {0} %", [(((g['fraction'] as num?) ?? 0) * 100).round()]);
    }
    return trf("Picture generator not set up ({0} GB once)", [(((g['download_bytes'] as num?) ?? 0) / 1e9).toStringAsFixed(1)]);
  }

  /// Make another wallpaper; or set the generator up first (shared with Playground).
  Widget _makeButton(_Card card) {
    const tight = VisualDensity(horizontal: -4, vertical: -4);
    final g = generator;
    if (g != null && g['ready'] != true) {
      if (g['playground'] != true) return const SizedBox();
      if (g['setting_up'] == true) {
        return TextButton.icon(
          onPressed: _cancelSetup,
          icon: const Icon(Icons.close, size: 16),
          label: Text(tr("Cancel")),
        );
      }
      return TextButton.icon(
        onPressed: _setUpGenerator,
        icon: const Icon(Icons.download, size: 16),
        label: Text(tr("Set up")),
      );
    }
    return IconButton(
      tooltip: tr("Make another wallpaper on this computer (no tokens)"),
      visualDensity: tight,
      onPressed: card.making ? null : () => _makeFor(card),
      icon: const Icon(Icons.auto_awesome_outlined, size: 18),
    );
  }

  /// Background and text (outlined, so black on black still shows), the
  /// eight terminal colors and the font: what the preview can't show clearly.
  Widget _strip(Map c, Map colors, ColorScheme scheme, _Card card) {
    final frame = hexColor(colors, 'foreground') ?? scheme.outline;
    final known = c['colors'] is Map || card.catalogColors != null;
    Widget swatch(String key, {bool outline = false}) => Tooltip(
      message: '${colorLabel(key)} ${colors[key]}',
      child: Container(
        width: 16,
        height: 16,
        margin: const EdgeInsets.only(right: 4),
        decoration: BoxDecoration(
          color: hexColor(colors, key),
          border: outline ? Border.all(color: frame.withValues(alpha: .5)) : null,
        ),
      ),
    );
    return Row(
      children: [
        if (known) ...[
          swatch('background', outline: true),
          swatch('foreground', outline: true),
          const SizedBox(width: 6),
          for (final k in _paletteKeys)
            if (hexColor(colors, k) != null) swatch(k),
          const SizedBox(width: 6),
        ],
        Expanded(
          child: Text(
            [
              c['font'] is String ? '${c['font']}' : (c['kind'] == 'catalog' ? tr("Its own font") : tr("Keep the current font")),
              if (c['blur'] is Map) (c['blur'] as Map)['on'] == true ? trf("Blur {0}", [(c['blur'] as Map)['strength']]) : tr("No blur"),
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  // --- page -------------------------------------------------------------------------------

  Widget _box(ColorScheme scheme, Widget child) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(corners(context).clamp(0, 10)),
      border: Border.all(color: scheme.outlineVariant),
    ),
    child: child,
  );

  Widget _note(ColorScheme scheme) => _box(
    scheme,
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr("Easy AI setup with Maprisma"), style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(_maprismaText, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => app.run('ask.open_maprisma', const {}, tr("Could not open the browser")),
          child: Text(tr("Get Maprisma in the Omarchy Plugin Marketplace")),
        ),
      ],
    ),
  );

  static String _helperName(Map h) => '${h['name']}${h['local'] == true ? tr(" · on this PC") : ''}';

  /// Helper: [name ▾] … [?]: the drop-down as wide as its name, the ? at the
  /// right edge (as the plugin's helper row).
  Widget _helperRow(ColorScheme scheme) {
    final list = ready;
    final current = chosen;
    final radius = BorderRadius.circular(cornerSizes(context).control);
    return Row(
      children: [
        Text(tr("Helper:")),
        const SizedBox(width: 8),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: PopupMenuButton<String>(
              tooltip: current == null ? tr("No helper ready") : _helperName(current),
              enabled: list.isNotEmpty && !asking,
              onSelected: _chooseHelper,
              position: PopupMenuPosition.under,
              itemBuilder: (_) => [
                for (final h in list)
                  CheckedPopupMenuItem(value: h['id'] as String, checked: h['id'] == helper, child: Text(_helperName(h))),
              ],
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
                decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: radius),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: Text(current == null ? '—' : _helperName(current), maxLines: 1, overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 4),
                    Icon(Icons.expand_more, size: 18, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        if (hints)
          IconButton.outlined(
            tooltip: tr("Easy AI setup with Maprisma"),
            visualDensity: VisualDensity.compact,
            isSelected: showNote,
            style: ButtonStyle(shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: radius))),
            onPressed: () => setState(() => showNote = !showNote),
            icon: const Icon(Icons.info_outline, size: 18),
          ),
      ],
    );
  }

  /// No helper ready: what to do, and the sign-in of installed agents that
  /// are not signed in yet (their own command, in a terminal).
  Widget _signIns(ColorScheme scheme) {
    final waiting = [
      for (final h in helpers)
        if (h['installed'] == true && h['signed_in'] != true && '${h['login']}'.isNotEmpty) h,
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          for (final h in waiting)
            OutlinedButton.icon(
              onPressed: () async {
                final r = await app.run('ask.signin', {'command': h['id']}, tr("No terminal found for the sign-in"));
                if (r != null) app.notify(tr("Sign in in the terminal, then come back here."));
              },
              icon: const Icon(Icons.login, size: 16),
              label: Text(trf("Sign in to {0}", [h['name']])),
            ),
          TextButton.icon(onPressed: _load, icon: const Icon(Icons.refresh, size: 16), label: Text(tr("Check again"))),
        ],
      ),
    );
  }

  Widget _requestRow(ColorScheme scheme) {
    final h = chosen;
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: request,
            focusNode: _field,
            autofocus: true,
            maxLength: _maxRequest,
            decoration: InputDecoration(
              counterText: '',
              hintText: tr("What do you want? e.g. “blue borders, red text and a dog wallpaper”"),
            ),
            onSubmitted: (_) => _ask(),
          ),
        ),
        const SizedBox(width: 6),
        Tooltip(
          message: tr("Asks once; uses your plan or tokens only now."),
          child: FilledButton.icon(
            onPressed: h != null && !asking ? () => _ask() : null,
            icon: const Icon(Icons.send, size: 16),
            label: Text(tr("Ask")),
          ),
        ),
        const SizedBox(width: 6),
        IconButton.outlined(
          tooltip: tr("Save as suggestion"),
          style: ButtonStyle(
            shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(cornerSizes(context).control))),
          ),
          onPressed: _savePrompt,
          icon: const Icon(Icons.bookmark_border, size: 18),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    AppScope.of(context); // rebuild when the settings change
    final scheme = Theme.of(context).colorScheme;
    final h = chosen;
    final hint = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    return SubPage(
      title: tr("Ask AI"),
      actions: [
        if (asking)
          TextButton.icon(
            onPressed: () => app.call('ask.cancel').then((_) {}, onError: (_) {}),
            icon: const Icon(Icons.stop_circle_outlined),
            label: Text(tr("Stop")),
          ),
      ],
      body: !loaded
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, box) {
                const pad = 0.0, gap = 12.0; // the window frame already has its margin
                final columns = box.maxWidth >= 900 ? 3 : 1;
                final cardW = (box.maxWidth - 2 * pad - gap * (columns - 1)) / columns;
                return ListView(
                  padding: const EdgeInsets.fromLTRB(pad, 0, pad, 12),
                  children: [
                    if (!enabled) ...[
                      _box(
                        scheme,
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_description),
                            const SizedBox(height: 10),
                            FilledButton(onPressed: _turnOn, child: Text(tr("Turn Ask AI on"))),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (enabled) ...[
                      if (hints && showNote) ...[_note(scheme), const SizedBox(height: 10)],
                      _helperRow(scheme),
                      const SizedBox(height: 6),
                      Text(
                        h == null
                            ? _noHelper
                            : h['local'] == true
                            ? tr("On this PC: no tokens, nothing leaves it. Enter asks.")
                            : trf("Uses your {0} plan or tokens, only when you click Ask. Enter asks.", [h['name']]),
                        style: hint,
                      ),
                      if (h == null) _signIns(scheme),
                      const SizedBox(height: 8),
                      _requestRow(scheme),
                      const SizedBox(height: 8),
                      _suggestions(scheme, box.maxWidth),
                      const SizedBox(height: 10),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (asking) ...[
                            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                            const SizedBox(width: 8),
                          ],
                          Expanded(child: SelectableText(status, style: hint)),
                          if (!asking && (cards.isNotEmpty || status.isNotEmpty))
                            IconButton(
                              tooltip: tr("Clear the results"),
                              visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                              onPressed: () => setState(() {
                                cards.clear();
                                rejected.clear();
                                status = '';
                                _field.requestFocus();
                              }),
                              icon: const Icon(Icons.cleaning_services_outlined, size: 16),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: gap,
                        runSpacing: gap,
                        children: [for (final card in cards) SizedBox(width: cardW, child: _card(card, scheme, cardW - 22))],
                      ),
                    ],
                  ],
                );
              },
            ),
    );
  }
}

const _gap = .035;

/// The windows of a Master Left layout with three windows, as (x, y, w, h)
/// in 0…1 (the plugin's preset_rects("master-left", 3)).
const _rects = [
  (_gap, _gap, (1 - 3 * _gap) / 2, 1 - 2 * _gap),
  (2 * _gap + (1 - 3 * _gap) / 2, _gap, (1 - 3 * _gap) / 2, (1 - 3 * _gap) / 2),
  (2 * _gap + (1 - 3 * _gap) / 2, 2 * _gap + (1 - 3 * _gap) / 2, (1 - 3 * _gap) / 2, (1 - 3 * _gap) / 2),
];

/// The candidate as it would look (the plugin's LookAlike): its wallpaper,
/// a bar with the workspace dots and the clock, and three windows in its
/// colors, the first one with the accent border.
class _LookAlike extends StatelessWidget {
  const _LookAlike({required this.colors, this.wallpaper});
  final Map colors;
  final String? wallpaper;

  @override
  Widget build(BuildContext context) {
    final bg = hexColor(colors, 'background') ?? const Color(0xff1e1e2e);
    final accent = hexColor(colors, 'accent') ?? const Color(0xff89b4fa);
    final plain = ColoredBox(color: Color.alphaBlend(accent.withValues(alpha: .12), bg));
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (wallpaper != null)
            Image.file(File(wallpaper!), fit: BoxFit.cover, cacheWidth: 960, errorBuilder: (_, _, _) => plain)
          else
            plain,
          CustomPaint(painter: _LookPainter(colors)),
        ],
      ),
    );
  }
}

class _LookPainter extends CustomPainter {
  _LookPainter(this.colors);
  final Map colors;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = hexColor(colors, 'background') ?? const Color(0xff1e1e2e);
    final fg = hexColor(colors, 'foreground') ?? const Color(0xffcdd6f4);
    final accent = hexColor(colors, 'accent') ?? const Color(0xff89b4fa);
    final width = size.width, height = size.height;
    Paint fill(Color c, double a) => Paint()..color = c.withValues(alpha: a);
    final k = width / 272 < 1 ? 1.0 : width / 272; // details grow with the preview
    final bar = (height * .055).roundToDouble() < 7 ? 7.0 : (height * .055).roundToDouble();
    canvas.drawRect(Rect.fromLTWH(0, 0, width, bar), fill(bg, .92));
    for (var i = 0; i < 3; i++) {
      canvas.drawCircle(Offset((6 + i * 7) * k, bar / 2), 2 * k, fill(i == 0 ? accent : fg, i == 0 ? .9 : .5));
    }
    canvas.drawRect(Rect.fromLTWH(width / 2 - 8 * k, bar / 2 - 1.2 * k, 16 * k, 2.4 * k), fill(fg, .6));
    final top = bar + 2 * k, areaH = height - top;
    for (var i = 0; i < _rects.length; i++) {
      final (x, y, w, h) = _rects[i];
      final r = Rect.fromLTWH(x * width, top + y * areaH, w * width, h * areaH);
      final box = RRect.fromRectAndRadius(r, Radius.circular(4 * k));
      canvas.drawRRect(box, fill(bg, .8)); // the wallpaper shows through a little
      canvas.drawRRect(
        box,
        fill(i == 0 ? accent : fg, i == 0 ? .95 : .35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (i == 0 ? 2 : 1.2) * k,
      );
      // A title line and a few text lines, so it reads as a window.
      final pad = r.width * .08 < 3 ? 3.0 : r.width * .08;
      final line = 2.5 * k;
      canvas.drawRect(
        Rect.fromLTWH(r.left + pad, r.top + pad, r.width * .35 < 4 ? 4 : r.width * .35, line),
        fill(i == 0 ? accent : fg, .55),
      );
      var lineY = r.top + pad + line * 3;
      for (final part in const [.75, .6, .68, .4, .7, .55, .62, .3]) {
        if (lineY + line > r.bottom - pad) break;
        final w = (r.width - 2 * pad) * part;
        canvas.drawRect(Rect.fromLTWH(r.left + pad, lineY, w < 4 ? 4 : w, line * .8), fill(fg, .25));
        lineY += line * 2.6;
      }
    }
  }

  @override
  bool shouldRepaint(_LookPainter old) => old.colors != colors;
}
