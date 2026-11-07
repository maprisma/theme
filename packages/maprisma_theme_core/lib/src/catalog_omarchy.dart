import 'dart:io';
import 'dart:math';

import 'bounded.dart';
import 'context.dart';
import 'images.dart';
import 'import_net.dart';
import 'plugin_catalog.dart' show privateDir;
import 'posix.dart';
import 'store.dart';

/// The omarchy.org theme gallery (theme_catalog.py): lists the themes on
/// https://omarchy.org/themes/, fetches their previews and installs one
/// with git, without replacing an existing theme.
///
/// Trust rules: one fixed host (`omarchy.org`), HTTPS only, no redirects,
/// bounded. The page is untrusted: a theme is kept only with a repository
/// of the exact form `https://github.com/<owner>/<repo>` and a preview under
/// `/assets/themes/`; names are plain text. Installing runs
/// `git clone --depth 1` (argv, no prompts, no hooks or templates) into the
/// user themes folder.

const omarchySite = 'https://omarchy.org';
const omarchyCatalogUrl = '$omarchySite/themes/';
const _hosts = {'omarchy.org'};
const maxPageBytes = 4 * 1024 * 1024;
const maxPreviewBytes = 3 * 1024 * 1024;
const catalogTtl = Duration(days: 1);
const previewTtl = Duration(days: 1);
const cloneTimeout = Duration(seconds: 180);

final repoRe = RegExp(r'^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?$');
final previewRe = RegExp(r'^/assets/themes/([a-z0-9][a-z0-9._-]*\.(?:webp|png|jpe?g))$');
final _cardRe = RegExp(r'<li><a href="([^"]+)"[^>]*><img src="([^"]+)"[^>]*/?><span[^>]*>([^<]{1,120})</span></a></li>');

/// Omarchy's rule for a theme directory name (omarchy-theme-install).
final installSlugRe = RegExp(r'^[a-z0-9_][a-z0-9._+-]*$');

final class OmarchyTheme {
  OmarchyTheme(this.name, this.repo, this.slug, this.preview);
  final String name, repo, slug;

  /// The file name under /assets/themes/.
  final String preview;

  Map<String, dynamic> toJson() => {'name': name, 'repo': repo, 'slug': slug, 'preview': preview};
}

/// The directory name `omarchy theme install` gives a repository, or null
/// when [repo] is not exactly `https://github.com/<owner>/<repo>`.
String? slugForRepo(String? repo) {
  final m = repo == null ? null : repoRe.firstMatch(repo);
  if (m == null) return null;
  final owner = m[1]!;
  if (RegExp(r'^\.+$').hasMatch(owner) || RegExp(r'^\.+$').hasMatch(m[2]!)) return null;
  var name = m[2]!.toLowerCase().replaceFirst(RegExp(r'^omarchy-'), '').replaceFirst(RegExp(r'-theme$'), '');
  name = name.trim();
  return installSlugRe.hasMatch(name) ? name : null;
}

/// The gallery's themes, by name (one per slug, the first wins).
List<OmarchyTheme> parseOmarchyCatalog(String page) {
  final themes = <String, OmarchyTheme>{};
  for (final m in _cardRe.allMatches(page)) {
    final repo = htmlUnescape(m[1]!).trim();
    final preview = previewRe.firstMatch(htmlUnescape(m[2]!).trim());
    final slug = slugForRepo(repo);
    final title = plainText(htmlUnescape(m[3]!), limit: 60).trim();
    if (preview == null || slug == null || title.isEmpty) continue;
    themes.putIfAbsent(slug, () => OmarchyTheme(title, repo.replaceFirst(RegExp(r'/$'), ''), slug, preview[1]!));
  }
  return themes.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
}

String _cacheFile(Ctx ctx) => '${ctx.paths.cache}/catalog.json';
String _previewDir(Ctx ctx) => '${ctx.paths.cache}/previews';

/// (themes, fetched at): from a one-day cache unless [force]; a failed
/// refresh falls back to the cache. Throws a RouteError when neither works.
Future<(List<OmarchyTheme>, DateTime)> loadOmarchyCatalog(Ctx ctx, {bool force = false}) async {
  final cached = <OmarchyTheme>[];
  var fetchedAt = DateTime.fromMillisecondsSinceEpoch(0);
  final data = readJson(_cacheFile(ctx));
  if (data is Map && data['fetched_at'] is num && data['themes'] is List) {
    fetchedAt = DateTime.fromMillisecondsSinceEpoch(((data['fetched_at'] as num) * 1000).round());
    for (final item in data['themes'] as List) {
      if (item is! Map) continue;
      final values = [for (final k in ['name', 'repo', 'slug', 'preview']) item[k]];
      if (values.any((v) => v is! String)) continue;
      final e = OmarchyTheme(
        plainText(values[0] as String, limit: 60),
        values[1] as String,
        values[2] as String,
        values[3] as String,
      );
      // The cache is checked again like the page itself.
      if (e.name.trim().isNotEmpty && slugForRepo(e.repo) == e.slug && previewRe.hasMatch('/assets/themes/${e.preview}')) {
        cached.add(e);
      }
    }
  }
  final now = ctx.clock();
  final age = now.difference(fetchedAt);
  if (cached.isNotEmpty && !force && !age.isNegative && age < catalogTtl) return (cached, fetchedAt);
  final reply = await netFetch(NetRequest(Uri.parse(omarchyCatalogUrl), hosts: _hosts, maxBytes: maxPageBytes));
  final themes = reply != null && reply.status == 200 ? parseOmarchyCatalog(reply.text) : <OmarchyTheme>[];
  if (themes.isNotEmpty) {
    try {
      writeJson(_cacheFile(ctx), {
        'fetched_at': now.millisecondsSinceEpoch / 1000,
        'themes': [for (final t in themes) t.toJson()],
      });
    } on FileSystemException {
      // shown anyway, fetched again next time
    }
    return (themes, now);
  }
  if (cached.isNotEmpty) return (cached, fetchedAt);
  throw RouteError('offline', 'could not load the theme list from omarchy.org');
}

/// The preview already in the cache (fresh or not), without the network.
String? cachedOmarchyPreview(Ctx ctx, OmarchyTheme theme) {
  if (!previewRe.hasMatch('/assets/themes/${theme.preview}')) return null;
  final path = '${_previewDir(ctx)}/${theme.preview}';
  return FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.file ? path : null;
}

/// The cached preview of [theme], downloaded first when missing or older
/// than a day (a stale one is kept when the download fails). Only image
/// data within the size limits is kept.
Future<String?> omarchyPreview(Ctx ctx, OmarchyTheme theme) async {
  if (!previewRe.hasMatch('/assets/themes/${theme.preview}')) return null;
  final path = '${_previewDir(ctx)}/${theme.preview}';
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  final have = type == FileSystemEntityType.file;
  if (have) {
    final age = ctx.clock().difference(File(path).lastModifiedSync());
    if (!age.isNegative && age < previewTtl) return path;
  }
  final reply = await netFetch(NetRequest(Uri.parse('$omarchySite/assets/themes/${theme.preview}'),
      hosts: _hosts, maxBytes: maxPreviewBytes));
  final data = reply?.status == 200 ? reply!.body : null;
  if (data == null || !isImageData(data) || imageBytesProblem(data) != null) return have ? path : null;
  try {
    privateDir(ctx.paths.cache, create: true); // made 0700 first, not by the nested create
    writeAtomic(path, data);
  } on FileSystemException {
    return have ? path : null;
  }
  return path;
}

/// Clones [theme] into the user themes folder; the new folder's path.
/// Never replaces a theme.
Future<String> installOmarchyTheme(Ctx ctx, OmarchyTheme theme) async {
  final slug = slugForRepo(theme.repo);
  if (slug == null || slug != theme.slug) throw RouteError('bad_url', 'not a GitHub theme repository: ${theme.repo}');
  final base = ctx.paths.userThemes;
  final dest = '$base/$slug';
  if (FileSystemEntity.typeSync(dest, followLinks: false) != FileSystemEntityType.notFound) {
    throw RouteError('exists', 'a theme named “$slug” is already installed');
  }
  final git = which('git', ctx.environment);
  if (git == null) throw RouteError('no_git', 'git is not installed');
  // Omarchy's own check, where it exists (an Omarchy install sharing this PATH).
  final check = which('omarchy-git-url-check', ctx.environment);
  if (check != null) {
    final (code, _) = await runBounded([check, theme.repo], timeout: const Duration(seconds: 10));
    if (code != 0) throw RouteError('bad_url', 'Omarchy refuses this repository URL: ${theme.repo}');
  }
  Directory(base).createSync(recursive: true);
  // Cloned beside the target first, then renamed into place, so a failed or
  // concurrent clone never leaves a half theme under the real name.
  final tmp = '$base/.import-$slug-$pid-${Random().nextInt(1 << 32)}';
  final env = {
    ...ctx.environment,
    'GIT_TERMINAL_PROMPT': '0',
    'GIT_ASKPASS': '/bin/false',
    'SSH_ASKPASS': '/bin/false',
    'GIT_CONFIG_NOSYSTEM': '1',
    'GIT_PROTOCOL_FROM_USER': '0',
  };
  final (code, _) = await runBounded([
    git,
    '-c', 'core.hooksPath=/dev/null',
    '-c', 'protocol.allow=never',
    '-c', 'protocol.https.allow=always',
    '-c', 'credential.helper=',
    '-c', 'submodule.recurse=false',
    'clone', '--depth', '1', '--quiet', '--no-recurse-submodules', '--template=',
    '--', theme.repo, tmp,
  ], timeout: cloneTimeout, environment: env);
  void cleanup() {
    final d = Directory(tmp);
    if (FileSystemEntity.typeSync(tmp, followLinks: false) == FileSystemEntityType.directory) {
      try {
        d.deleteSync(recursive: true);
      } on FileSystemException {
        // left for the user; hidden (dot name)
      }
    }
  }

  if (code != 0) {
    cleanup();
    throw RouteError('clone_failed', 'git clone failed for ${theme.repo}');
  }
  if (FileSystemEntity.typeSync(dest, followLinks: false) != FileSystemEntityType.notFound) {
    cleanup();
    throw RouteError('exists', 'a theme named “$slug” is already installed');
  }
  try {
    Directory(tmp).renameSync(dest);
  } on FileSystemException {
    cleanup();
    throw RouteError('install_failed', 'could not move the theme into place');
  }
  return dest;
}

/// Whether [url] is one the omarchy.org tab may open (a theme's GitHub page
/// or the gallery).
bool omarchyOpenable(String url) => slugForRepo(url) != null || url == omarchyCatalogUrl;
