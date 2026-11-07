import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

const _examples = [
  'Blue borders, red text and a nice dog wallpaper',
  'A calm light theme for daytime',
  'Find a warm dark theme in the catalog',
  'Another font for the current theme',
];
const _maxPrompts = 12, _maxRequest = 600;
const _description =
    'Find or make a theme from a few words with a coding agent on this computer (Claude Code, Codex, pi or '
    'Hermes) or a local model, using your plan or tokens only when you click Ask; a local model uses none and '
    'nothing leaves the computer. Each Ask sends your words with the names and main colors of your installed '
    'themes, the omarchy.org theme names and your installed font names; nothing else.';
const _noHelper =
    'No helper ready: install Claude Code, Codex, pi or Hermes and sign in, or connect pi or Hermes to a local model.';
const _maprismaText =
    'Maprisma sets up AI for you: online agents and their providers, and local models with llama.cpp or Ollama, '
    'connected on one map. Every agent it sets up can answer here too.';
const _paletteKeys = ['red', 'yellow', 'orange', 'green', 'cyan', 'blue', 'magenta', 'brown'];

/// One result card's own state (wallpaper search, refine field).
final class _Card {
  _Card(this.c);
  Map<String, dynamic> c;
  List<Map> walls = const [];
  int wall = 0;
  String? wallNote;
  bool searching = false, refining = false;
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
  List<Map>? catalog;
  StreamSubscription? _hidden;
  late MaprismaThemeAppState _app;

  MaprismaThemeAppState get app => _app;
  Map<String, dynamic> get settings => app.settings;
  bool get enabled => settings['ask_ai'] == true;
  bool get hints => settings['maprisma_hints'] != false;
  List<Map<String, dynamic>> get ready => [for (final h in helpers) if (h['signed_in'] == true) h];
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
    final r = await app.run('settings.set', {'key': key, 'value': value}, 'Could not save the setting');
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
      _say('Write a request first, then save it as a suggestion.');
    } else if (prompts.contains(text)) {
      _say('That is already a suggestion.');
    } else if (prompts.length >= _maxPrompts) {
      _say('At most $_maxPrompts suggestions: remove one first.');
    } else {
      await _storePrompts([...prompts, text]);
      _say('Saved as suggestion.');
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
      _say('That is already a suggestion.');
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
                decoration: const InputDecoration(isDense: true, counterText: '', hintText: 'Edit suggestion'),
                onSubmitted: (_) => _finishEdit(true),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Save',
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
                message: 'Drag to reorder (Alt+↑/↓)',
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text('⠿', style: TextStyle(fontSize: 16, color: scheme.onSurfaceVariant)),
                ),
              ),
            ),
          ),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: enabled && chosen != null && !asking
                  ? () {
                      request.text = text;
                      _ask();
                    }
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
                child: Tooltip(message: text, child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis)),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Edit suggestion',
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
            tooltip: 'Remove suggestion',
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
              itemBuilder: (context, i) =>
                  KeyedSubtree(key: ValueKey('row-${list[i]}'), child: _promptRow(i, list[i], scheme)),
            ),
          ),
          if (ownPrompts != null)
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: 'Back to the built-in suggestions',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: () => _storePrompts(null),
                icon: const Text('↺', style: TextStyle(fontSize: 18)),
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
      catalog = [if (list is List) for (final e in list) if (e is Map) e];
    } catch (_) {
      catalog = []; // no network or no import module: installed themes still work
    }
    return catalog!;
  }

  Map? _catalogEntry(String? slug) => catalog?.where((e) => (e['slug'] ?? e['name']) == slug).firstOrNull;

  Future<void> _ask({_Card? parent, String? words}) async {
    final h = chosen;
    final text = _tidy(words ?? request.text);
    if (asking || h == null || text.isEmpty) return;
    setState(() {
      asking = true;
      parent?.refining = true;
      if (parent == null) rejected.clear();
      seconds = 0;
      status = 'Asking ${h['name']}… 0 s';
    });
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && asking) setState(() => status = 'Asking ${h['name']}… ${++seconds} s');
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
          status = 'Nothing visible changed. Try clearer words, e.g. “much darker”.';
        } else if (found.isEmpty) {
          status = 'Nothing usable came back. Try other words.';
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
      }
    } catch (e) {
      if (mounted) setState(() => status = 'No answer: ${_why(e)}');
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

  Future<void> _searchWalls(_Card card) async {
    final query = card.c['wallpaper_query'] as String?;
    if (query == null || query.isEmpty) return;
    final token = card.token = Object();
    setState(() {
      card.searching = true;
      card.wallNote = 'Searching wallpapers for “$query”…';
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
        results = [if (list is List) for (final e in list) if (e is Map) e];
      } catch (e) {
        note = '$e'.contains('unknown_route')
            ? 'The wallpaper search is not available in this version.'
            : 'The wallpaper search did not answer.';
        break;
      }
      if (results.isNotEmpty) break;
    }
    if (!mounted || card.token != token) return;
    setState(() {
      card.searching = false;
      card.walls = results;
      final chosenId = card.c['wallpaper_id'];
      final at = results.indexWhere((e) => chosenId != null && e['id'] == chosenId);
      card.wall = at < 0 ? 0 : at;
      card.wallNote = note ?? (results.isEmpty ? 'No wallpapers found for “$query”.' : null);
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
    try {
      final r = await app.call('wallhaven.thumb', {
        'item': {for (final e in item.entries) if (e.key != 'added' && e.key != 'thumb_path') '${e.key}': e.value},
      });
      final path = r['path'];
      if (path is String && mounted) setState(() => item['thumb_path'] = path);
    } catch (_) {
      // no picture: the card shows the colors only
    }
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
        final r = await app.run('themes.apply', {'slug': slug});
        if (r != null) {
          app.notify('Applied ${c['name']}');
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
            item(Icons.download_outlined, 'Install', () => _install(slug, false)),
            item(Icons.check_circle_outline, 'Install and apply', () => _install(slug, true)),
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
        // Nothing is saved until you save; a system theme is never changed: a copy.
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => EditorPage(base: edit ? null : slug, edit: edit ? slug : null, initial: initial),
          ),
        );
    }
  }

  Future<void> _install(String slug, bool apply) async {
    final r = await app.run('import.omarchy_install', {'name': slug, 'apply': apply}, 'Could not install $slug');
    if (r != null) {
      app.notify(apply ? 'Installed and applied $slug' : 'Installed $slug');
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
    final c = card.c['colors'];
    return c is Map && c.isNotEmpty ? c : app.colors;
  }

  Widget _card(_Card card, ColorScheme scheme) {
    final c = card.c;
    final colors = _colorsOf(card);
    final mine = c['query_by_user'] == true && c['wallpaper_query'] is String;
    final kind = switch (c['kind']) {
      'catalog' => 'From omarchy.org',
      'installed' => 'Installed theme, as it is',
      _ => c['mode'] == 'edit' ? 'Edit ${c['base_name']}' : 'New theme from ${c['base_name']}',
    };
    final reason = mine ? 'Wallpaper: your search “${c['wallpaper_query']}”' : '${c['summary'] ?? ''}';
    String? picture = card.walls.isNotEmpty ? _thumb(card.walls[card.wall]) : null;
    if (picture == null && c['kind'] == 'catalog' && c['wallpaper_query'] == null) {
      final entry = _catalogEntry(c['theme'] as String?);
      if (entry != null) picture = _thumb(entry);
    }
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(corners(context)),
        border: Border.all(color: scheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${c['name']}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
          Text(
            kind,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(corners(context) * .6),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _LookAlike(colors: colors, wallpaper: picture),
                  if (card.searching || card.refining)
                    Container(
                      color: Colors.black38,
                      alignment: Alignment.center,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                          const SizedBox(width: 8),
                          Text(
                            card.refining ? 'Refining…' : 'Searching wallpapers…',
                            style: const TextStyle(color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (c['wallpaper_query'] is String)
            Row(
              children: [
                IconButton(
                  tooltip: 'Previous wallpaper',
                  onPressed: card.walls.length > 1 ? () => _stepWall(card, -1) : null,
                  icon: const Text('‹', style: TextStyle(fontSize: 20)),
                ),
                Expanded(
                  child: Text(
                    card.wallNote ?? '“${c['wallpaper_query']}” · ${card.wall + 1}/${card.walls.length}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ),
                IconButton(
                  tooltip: 'Next wallpaper',
                  onPressed: card.walls.length > 1 ? () => _stepWall(card, 1) : null,
                  icon: const Text('›', style: TextStyle(fontSize: 20)),
                ),
              ],
            ),
          const SizedBox(height: 6),
          _strip(c, colors, scheme),
          if (reason.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(reason, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ],
          if (card.search != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: card.search,
                    autofocus: true,
                    maxLength: 100,
                    decoration: const InputDecoration(
                      isDense: true,
                      counterText: '',
                      hintText: 'Search wallpapers, e.g. “husky snow”',
                    ),
                    onSubmitted: (_) => _ownSearch(card),
                  ),
                ),
                IconButton(
                  tooltip: 'Search wallpapers (no tokens)',
                  onPressed: () => _ownSearch(card),
                  icon: const Icon(Icons.search),
                ),
              ],
            ),
          ],
          if (card.refine != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: card.refine,
                    autofocus: true,
                    maxLength: _maxRequest,
                    decoration: InputDecoration(
                      isDense: true,
                      counterText: '',
                      hintText: c['wallpaper_query'] is String
                          ? 'How should it change? e.g. “warmer”, “another picture like ${c['wallpaper_query']}”'
                          : 'How should it change? e.g. “warmer”, “another wallpaper”',
                    ),
                    onSubmitted: (t) {
                      if (t.trim().isNotEmpty) _ask(parent: card, words: t);
                    },
                  ),
                ),
                IconButton(
                  tooltip: 'Refine…',
                  onPressed: asking ? null : () => _ask(parent: card, words: card.refine!.text),
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              Builder(
                builder: (b) => FilledButton.icon(
                  onPressed: () => _use(card, b),
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('Use'),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () => _reject(card),
                icon: const Icon(Icons.close, size: 18),
                label: const Text('Not this'),
              ),
              OutlinedButton.icon(
                onPressed: asking ? null : () => setState(() => card.refine ??= TextEditingController()),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Refine…'),
              ),
              OutlinedButton.icon(
                onPressed: () => setState(() {
                  if (card.search == null) {
                    card.search = TextEditingController(text: '${c['wallpaper_query'] ?? ''}');
                  } else {
                    card.search!.dispose();
                    card.search = null;
                  }
                }),
                icon: const Icon(Icons.image_outlined, size: 18),
                label: const Text('Wallpaper…'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Background and text, the eight terminal colors and the font.
  Widget _strip(Map c, Map colors, ColorScheme scheme) {
    final frame = hexColor(colors, 'foreground') ?? scheme.outline;
    Widget swatch(String key, {bool outline = false}) => Tooltip(
      message: '$key ${colors[key]}',
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
        if (c['kind'] != 'catalog' || c['colors'] is Map) ...[
          swatch('background', outline: true),
          swatch('foreground', outline: true),
          const SizedBox(width: 6),
          for (final k in _paletteKeys)
            if (hexColor(colors, k) != null) swatch(k),
          const SizedBox(width: 6),
        ],
        Expanded(
          child: Text(
            c['font'] is String
                ? '${c['font']}'
                : (c['kind'] == 'catalog' ? 'Its own colors and font' : 'Keep the current font'),
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
      borderRadius: BorderRadius.circular(corners(context)),
      border: Border.all(color: scheme.outlineVariant),
    ),
    child: child,
  );

  Widget _note(ColorScheme scheme) => _box(
    scheme,
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Easy AI setup with Maprisma', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(_maprismaText, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => app.run('ask.open_maprisma', const {}, 'Could not open the browser'),
          child: const Text('Get Maprisma in the Omarchy Plugin Marketplace'),
        ),
      ],
    ),
  );

  Widget _helperRow(ColorScheme scheme) {
    final list = ready;
    final anyReady = list.isNotEmpty;
    return Row(
      children: [
        // Accent when a helper is ready, a dot while none is signed in.
        anyReady
            ? Icon(Icons.auto_awesome, size: 18, color: scheme.primary)
            : Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: scheme.onSurfaceVariant, shape: BoxShape.circle),
              ),
        const SizedBox(width: 8),
        const Text('Helper:'),
        const SizedBox(width: 8),
        if (anyReady)
          Flexible(
            child: DropdownButton<String>(
              value: chosen?['id'] as String?,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              items: [
                for (final h in list)
                  DropdownMenuItem(
                    value: h['id'] as String,
                    child: Text(
                      '${h['name']}${h['local'] == true ? ' · on this PC' : ''}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: asking ? null : _chooseHelper,
            ),
          )
        else
          const Spacer(),
        if (hints)
          IconButton(
            tooltip: 'Easy AI setup with Maprisma',
            visualDensity: VisualDensity.compact,
            isSelected: showNote,
            onPressed: () => setState(() => showNote = !showNote),
            icon: const Icon(Icons.help_outline, size: 18),
          ),
      ],
    );
  }

  /// Installed agents that are not signed in yet: their own sign-in in a terminal.
  Widget _signIns(ColorScheme scheme) {
    final waiting = [
      for (final h in helpers)
        if (h['installed'] == true && h['signed_in'] != true && '${h['login']}'.isNotEmpty) h,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_noHelper, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final h in waiting)
              OutlinedButton.icon(
                onPressed: () async {
                  final r = await app.run('ask.signin', {'command': h['id']}, 'No terminal found for the sign-in');
                  if (r != null) app.notify('Sign in in the terminal, then come back here.');
                },
                icon: const Icon(Icons.login, size: 16),
                label: Text('Sign in to ${h['name']}'),
              ),
            TextButton.icon(onPressed: _load, icon: const Icon(Icons.refresh, size: 16), label: const Text('Check again')),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    AppScope.of(context); // rebuild when the settings change
    final scheme = Theme.of(context).colorScheme;
    final h = chosen;
    return SubPage(
      title: 'Ask AI',
      actions: [
        if (asking)
          TextButton.icon(
            onPressed: () => app.call('ask.cancel').then((_) {}, onError: (_) {}),
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text('Stop'),
          ),
      ],
      body: !loaded
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, box) {
                final columns = box.maxWidth >= 900 ? 3 : 1;
                final cardW = (box.maxWidth - 32 - 12 * (columns - 1)) / columns;
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (!enabled)
                      _box(
                        scheme,
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(_description),
                            const SizedBox(height: 10),
                            FilledButton(onPressed: _turnOn, child: const Text('Turn Ask AI on')),
                          ],
                        ),
                      ),
                    if (enabled) ...[
                      _helperRow(scheme),
                      if (hints && showNote) ...[const SizedBox(height: 6), _note(scheme), const SizedBox(height: 6)],
                      if (h == null)
                        _signIns(scheme)
                      else
                        Text(
                          h['local'] == true
                              ? 'On this PC: no tokens, nothing leaves it. Enter asks.'
                              : 'Uses your ${h['name']} plan or tokens, only when you click Ask. Enter asks.',
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: request,
                              focusNode: _field,
                              autofocus: true,
                              maxLength: _maxRequest,
                              decoration: const InputDecoration(
                                counterText: '',
                                hintText: 'What do you want? e.g. “blue borders, red text and a dog wallpaper”',
                              ),
                              onSubmitted: (_) => _ask(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Tooltip(
                            message: 'Asks once; uses your plan or tokens only now.',
                            child: FilledButton.icon(
                              onPressed: h != null && !asking ? () => _ask() : null,
                              icon: const Icon(Icons.send, size: 18),
                              label: const Text('Ask'),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Save as suggestion',
                            onPressed: _savePrompt,
                            icon: const Icon(Icons.bookmark_add_outlined),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _suggestions(scheme, box.maxWidth),
                      const SizedBox(height: 10),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (asking) ...[
                            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                            const SizedBox(width: 8),
                          ],
                          Expanded(
                            child: SelectableText(
                              status,
                              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                            ),
                          ),
                          if (!asking && (cards.isNotEmpty || status.isNotEmpty))
                            IconButton(
                              tooltip: 'Clear the results',
                              visualDensity: VisualDensity.compact,
                              onPressed: () => setState(() {
                                cards.clear();
                                rejected.clear();
                                status = '';
                                _field.requestFocus();
                              }),
                              icon: const Icon(Icons.clear_all, size: 18),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [for (final card in cards) SizedBox(width: cardW, child: _card(card, scheme))],
                      ),
                    ],
                  ],
                );
              },
            ),
    );
  }
}

/// The candidate as it would look: its wallpaper (or background), two windows
/// in its colors with the accent border, text lines and the terminal colors.
class _LookAlike extends StatelessWidget {
  const _LookAlike({required this.colors, this.wallpaper});
  final Map colors;
  final String? wallpaper;

  @override
  Widget build(BuildContext context) {
    final bg = hexColor(colors, 'background') ?? Colors.black;
    final fg = hexColor(colors, 'foreground') ?? Colors.white;
    final accent = hexColor(colors, 'accent') ?? fg;
    final muted = hexColor(colors, 'muted') ?? fg.withValues(alpha: .6);
    final sel = hexColor(colors, 'selection') ?? accent.withValues(alpha: .3);
    final dark = hexColor(colors, 'darker_background') ?? bg;
    final palette = [for (final k in _paletteKeys) hexColor(colors, k) ?? fg];
    Widget line(Color c, double w) => FractionallySizedBox(
      widthFactor: w,
      alignment: Alignment.centerLeft,
      child: Container(height: 5, margin: const EdgeInsets.only(bottom: 5), color: c),
    );
    Widget window({required bool active, required List<Widget> body}) => Container(
      decoration: BoxDecoration(
        color: bg.withValues(alpha: .94),
        border: Border.all(color: active ? accent : muted.withValues(alpha: .5), width: 2),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.all(8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: body),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        if (wallpaper != null)
          Image.file(
            File(wallpaper!),
            fit: BoxFit.cover,
            cacheWidth: 640,
            errorBuilder: (_, _, _) => ColoredBox(color: dark),
          )
        else
          ColoredBox(color: dark),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 3,
                child: window(
                  active: true,
                  body: [
                    Text('~ \$ ls', style: TextStyle(color: fg, fontFamily: 'monospace', fontSize: 11), maxLines: 1),
                    const SizedBox(height: 6),
                    line(fg, .8),
                    Container(color: sel, child: line(fg, .5)),
                    line(muted, .6),
                    const Spacer(),
                    Row(children: [for (final c in palette) Expanded(child: Container(height: 8, color: c))]),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: Column(
                  children: [
                    Expanded(
                      child: window(
                        active: false,
                        body: [line(palette[5], .7), line(palette[3], .5), line(palette[6], .8), line(muted, .4)],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: window(active: false, body: [line(palette[0], .6), line(palette[1], .8), line(fg, .5)]),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
