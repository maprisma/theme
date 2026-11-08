import 'dart:io';

import 'colors.dart';
import 'paths.dart';
import 'store.dart';

const imageExts = {'.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp'};
const heifExts = {'.heic', '.heif'};
const previewNames = ['preview.png', 'preview.jpg', 'preview.jpeg', 'preview.webp'];
const hiddenDir = '.hidden';
final slugRe = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9._+-]*$');

const lockSystem = 'Ships with a built-in theme: hide it instead';
const lockGit = 'Part of a theme installed from git; deleting would break its updates: hide it instead';

/// Omarchy's rule: capitalise the first letter and after every dash, dashes to spaces.
String displayName(String slug) =>
    slug.replaceAllMapped(RegExp(r'(^|-)([a-z])'), (m) => '${m[1]}${m[2]!.toUpperCase()}').replaceAll('-', ' ');

String extOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot).toLowerCase();
}

String baseName(String path) => path.substring(path.lastIndexOf('/') + 1);

final class ThemeInfo {
  ThemeInfo({
    required this.slug,
    required this.dir,
    required this.scope,
    required this.preview,
    this.systemDir,
  });

  final String slug;
  final String dir;

  /// "user" or "system"; a user copy wins over a system theme of the same slug.
  final String scope;
  final String? preview;

  /// The system theme of the same slug a user copy overlays, if any.
  final String? systemDir;

  String get name {
    final meta = this.meta;
    final n = meta['name'];
    return n is String && n.trim().isNotEmpty ? n.trim() : displayName(slug);
  }

  bool get system => scope == 'system';
  bool get fromGit => !system && !FileSystemEntity.isLinkSync(dir) && Directory('$dir/.git').existsSync();

  /// Made in Maprisma Theme (or the plugin): editable again.
  bool get custom => !system && !fromGit && File('$dir/theme-manager.json').existsSync();
  bool get cosmicNative => File('$dir/cosmic.ron').existsSync();

  /// A KDE Store theme: its Plasma color scheme as it came (`kde.colors`).
  bool get kdeNative => File('$dir/kde.colors').existsSync();

  Map<String, dynamic> get meta => readJsonMap('$dir/theme-manager.json');

  Map<String, String> get rawColors {
    final text = readSmall('$dir/colors.toml', limit: 256 * 1024);
    if (text != null) return parseColorsToml(text);
    if (systemDir != null) {
      final s = readSmall('$systemDir/colors.toml', limit: 256 * 1024);
      if (s != null) return parseColorsToml(s);
    }
    return {};
  }

  Map<String, String> get colors =>
      resolveColors(rawColors, lightModeFile: File('$dir/light.mode').existsSync());

  String? get iconTheme {
    final t = readSmall('$dir/icons.theme', limit: 1024)?.trim();
    return (t != null && RegExp(r'^[A-Za-z0-9 ._+-]{1,80}$').hasMatch(t)) ? t : null;
  }

  String? get font {
    final f = meta['font'];
    return f is String && f.isNotEmpty ? f : null;
  }
}

String? previewOf(String dir) {
  try {
    final entries = {
      for (final e in Directory(dir).listSync(followLinks: false)) baseName(e.path).toLowerCase(): e,
    };
    for (final n in previewNames) {
      final e = entries[n];
      if (e != null && FileSystemEntity.isFileSync(e.path)) return e.path;
    }
  } on FileSystemException {
    return null;
  }
  return null;
}

/// All themes, user and system, sorted by name.
List<ThemeInfo> discoverThemes(Paths paths) {
  final found = <String, ThemeInfo>{};
  for (final (scope, base) in [('user', paths.userThemes), ('system', paths.systemThemes)]) {
    List<FileSystemEntity> entries;
    try {
      entries = Directory(base).listSync()..sort((a, b) => a.path.compareTo(b.path));
    } on FileSystemException {
      continue;
    }
    for (final e in entries) {
      final slug = baseName(e.path);
      if (slug.startsWith('.') || found.containsKey(slug) || !slugRe.hasMatch(slug)) continue;
      if (!FileSystemEntity.isDirectorySync(e.path)) continue;
      final sys = '${paths.systemThemes}/$slug';
      found[slug] = ThemeInfo(
        slug: slug,
        dir: e.path,
        scope: scope,
        preview: previewOf(e.path) ?? (scope == 'user' ? previewOf(sys) : null),
        systemDir: scope == 'user' && Directory(sys).existsSync() ? sys : null,
      );
    }
  }
  final list = found.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return list;
}

ThemeInfo? findTheme(Paths paths, String slug) {
  if (!slugRe.hasMatch(slug)) return null;
  for (final t in discoverThemes(paths)) {
    if (t.slug == slug) return t;
  }
  return null;
}

final class WallpaperInfo {
  WallpaperInfo(this.path, this.source, {required this.deletable, this.hidden = false, this.lockedReason = ''});
  final String path;

  /// "user" (added, in `backgrounds/<theme>/`) or "theme" (shipped with it).
  final String source;
  final bool deletable, hidden;
  final String lockedReason;
  String get name => baseName(path);

  Map<String, dynamic> toJson() => {
    'path': path,
    'name': name,
    'source': source,
    'deletable': deletable,
    'hidden': hidden,
    'locked_reason': lockedReason,
  };
}

List<String> imagesIn(String dir) {
  try {
    final list = Directory(dir)
        .listSync(followLinks: false)
        .where((e) => e is File && imageExts.contains(extOf(e.path)))
        .map((e) => e.path)
        .toList();
    list.sort((a, b) => baseName(a).toLowerCase().compareTo(baseName(b).toLowerCase()));
    return list;
  } on FileSystemException {
    return [];
  }
}

Map<String, Set<String>> loadHiddenWallpapers(Paths paths) {
  final data = readJsonMap(paths.file('hidden-wallpapers.json'));
  return {
    for (final e in data.entries)
      if (e.value is List) e.key: {for (final n in e.value as List) if (n is String) n},
  };
}

void saveHiddenWallpapers(Paths paths, Map<String, Set<String>> hidden) => writeJson(
  paths.file('hidden-wallpapers.json'),
  {for (final e in hidden.entries) if (e.value.isNotEmpty) e.key: (e.value.toList()..sort())},
);

/// The theme's wallpapers, the hidden ones marked; an added file shadows a
/// shipped one of the same name.
List<WallpaperInfo> listBackgrounds(Paths paths, ThemeInfo theme, {Map<String, Set<String>>? hidden}) {
  final hiddenNames = (hidden ?? loadHiddenWallpapers(paths))[theme.slug] ?? const <String>{};
  final merged = <String, WallpaperInfo>{};
  final added = '${paths.backgrounds}/${theme.slug}';
  for (final p in imagesIn(added)) {
    merged[baseName(p).toLowerCase()] = WallpaperInfo(p, 'user', deletable: true);
  }
  for (final p in imagesIn('$added/$hiddenDir')) {
    merged.putIfAbsent(baseName(p).toLowerCase(), () => WallpaperInfo(p, 'user', deletable: true, hidden: true));
  }
  final sources = <(String, String)>[
    if (!theme.system) ('${theme.dir}/backgrounds', theme.fromGit ? lockGit : ''),
    if (theme.system) ('${theme.dir}/backgrounds', lockSystem),
    if (theme.systemDir != null) ('${theme.systemDir}/backgrounds', lockSystem),
  ];
  for (final (dir, lock) in sources) {
    for (final p in imagesIn(dir)) {
      merged.putIfAbsent(
        baseName(p).toLowerCase(),
        () => WallpaperInfo(p, 'theme',
            deletable: lock.isEmpty, hidden: hiddenNames.contains(baseName(p)), lockedReason: lock),
      );
    }
  }
  return merged.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
}

List<WallpaperInfo> visibleBackgrounds(Paths paths, ThemeInfo theme) =>
    listBackgrounds(paths, theme).where((w) => !w.hidden).toList();

/// Theme lists kept by Maprisma Theme (same files and shapes as the plugin).
final class Lists {
  Lists(this.paths);
  final Paths paths;

  Set<String> _set(String name) {
    final v = readJson(paths.file(name));
    return v is List ? {for (final s in v) if (s is String) s} : <String>{};
  }

  void _saveSet(String name, Set<String> v) => writeJson(paths.file(name), v.toList()..sort());

  Set<String> get hidden => _set('hidden.json');
  set hidden(Set<String> v) => _saveSet('hidden.json', v);
  /// In the order they were added (theme_auto.load_favorites).
  List<String> get favorites {
    final v = readJson(paths.file('favorites.json'));
    final out = <String>[];
    if (v is List) {
      for (final s in v) {
        if (s is String && slugRe.hasMatch(s) && !out.contains(s)) out.add(s);
      }
    }
    return out;
  }

  set favorites(List<String> v) => writeJson(paths.file('favorites.json'), v);

  /// slug -> last use (seconds since the epoch).
  Map<String, double> get recent => {
    for (final e in readJsonMap(paths.file('recent.json')).entries)
      if (e.value is num) e.key: (e.value as num).toDouble(),
  };

  void markUsed(String slug, {DateTime? at}) {
    final r = recent;
    r[slug] = (at ?? DateTime.now()).millisecondsSinceEpoch / 1000;
    writeJson(paths.file('recent.json'), r);
  }

  void forget(String slug) {
    hidden = hidden..remove(slug);
    favorites = favorites..remove(slug);
    final r = recent..remove(slug);
    writeJson(paths.file('recent.json'), r);
  }
}

/// The theme in use and its wallpaper (~/.local/state/maprisma-theme/current.json).
final class Current {
  Current(this.paths);
  final Paths paths;
  Map<String, dynamic> get _data => readJsonMap(paths.currentFile);
  String get slug {
    final s = _data['theme'];
    return s is String && slugRe.hasMatch(s) ? s : '';
  }

  String? get wallpaper {
    final w = _data['wallpaper'];
    return w is String && w.startsWith('/') ? w : null;
  }

  void save({String? slug, String? wallpaper, bool clearWallpaper = false}) {
    final d = _data;
    if (slug != null) d['theme'] = slug;
    if (wallpaper != null) d['wallpaper'] = wallpaper;
    if (clearWallpaper) d.remove('wallpaper');
    writeJson(paths.currentFile, d);
  }
}
