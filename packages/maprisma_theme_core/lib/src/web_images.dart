import 'i18n.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'bounded.dart';
import 'context.dart';
import 'images.dart';
import 'posix.dart';
import 'store.dart';
import 'theme_ai.dart' show publicHttpsUrl, publicImageUrl;
import 'wallpapers.dart';

/// Pictures an Ask AI helper found on the web (any site): fetched only from
/// a public host name whose every address is public (no loopback, private,
/// link-local, shared or multicast range), with curl pinned to the checked
/// address (no second DNS answer), HTTPS only, no redirects, a byte cap and a
/// deadline; kept only when the bytes are a JPEG, PNG or WebP of sane size.

const maxWebImagesCached = 40;

/// One GET of [url] from [address] (already checked), as fetchHttps.
typedef PinnedFetch = Future<Uint8List?> Function(String url, InternetAddress address, int maxBytes, Duration timeout);

/// The host's addresses (system resolver).
typedef Resolve = Future<List<InternetAddress>> Function(String host);

Future<Uint8List?> fetchPinned(String url, InternetAddress address, int maxBytes, Duration timeout) async {
  final host = Uri.parse(url).host;
  final ip = address.type == InternetAddressType.IPv6 ? '[${address.address}]' : address.address;
  final data = await readBoundedBytes([
    'curl', '--silent', '--fail', '--proto', '=https', '--max-redirs', '0',
    '--resolve', '$host:443:$ip',
    '--max-time', '${timeout.inSeconds}', '--max-filesize', '$maxBytes', '--', url,
  ], maxBytes: maxBytes, timeout: timeout + const Duration(seconds: 2));
  return data == null || data.isEmpty ? null : data;
}

Future<List<InternetAddress>> resolveHost(String host) =>
    InternetAddress.lookup(host).timeout(const Duration(seconds: 5));

/// Whether [a] is a public unicast address.
bool isPublicAddress(InternetAddress a) {
  final b = a.rawAddress;
  if (a.type == InternetAddressType.IPv4 && b.length == 4) return _publicV4(b);
  if (a.type != InternetAddressType.IPv6 || b.length != 16) return false;
  // IPv4-mapped (::ffff:a.b.c.d) and IPv4-compatible (::a.b.c.d): the IPv4 rules.
  final zeros10 = b.sublist(0, 10).every((x) => x == 0);
  if (zeros10 && b[10] == 0xff && b[11] == 0xff) return _publicV4(b.sublist(12));
  if (zeros10 && b[10] == 0 && b[11] == 0) return false; // ::, ::1, ::a.b.c.d
  if (b[0] == 0x64 && b[1] == 0xff && b[2] == 0x9b) return false; // NAT64 64:ff9b::/96 and /48
  if ((b[0] & 0xe0) != 0x20) return false; // only global unicast 2000::/3
  if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8) return false; // documentation
  if (b[0] == 0x20 && b[1] == 0x02) return false; // 6to4 (embeds any IPv4)
  if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0 && b[3] == 0) return false; // Teredo
  return true;
}

bool _publicV4(List<int> b) {
  final (x, y) = (b[0], b[1]);
  return !(x == 0 ||
      x == 10 ||
      x == 127 ||
      (x == 100 && y >= 64 && y <= 127) || // shared (CGNAT)
      (x == 169 && y == 254) ||
      (x == 172 && y >= 16 && y <= 31) ||
      (x == 192 && y == 168) ||
      (x == 192 && y == 0 && (b[2] == 0 || b[2] == 2)) ||
      (x == 198 && (y == 18 || y == 19)) ||
      (x == 198 && y == 51 && b[2] == 100) ||
      (x == 203 && y == 0 && b[2] == 113) ||
      x >= 224); // multicast, reserved, broadcast
}

final class WebImages {
  WebImages(this.ctx, {PinnedFetch? fetch, Resolve? resolve})
      : fetch = fetch ?? fetchPinned,
        resolve = resolve ?? resolveHost;
  final Ctx ctx;
  final PinnedFetch fetch;
  final Resolve resolve;

  String get cacheDir => '${ctx.paths.cache}/web-images';

  static String checkUrl(Object? url) =>
      publicImageUrl(url) ?? (throw RouteError('bad_params', tr("not a public https image address")));

  String _key(String url) => sha256.convert(utf8.encode(url)).toString().substring(0, 32);

  String? _cached(String url) {
    for (final ext in const ['.jpg', '.png', '.webp']) {
      final path = '$cacheDir/${_key(url)}$ext';
      if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.file) {
        return imageSizeProblem(path) == null ? path : null;
      }
    }
    return null;
  }

  /// The picture's local copy (downloaded when missing); thrown when the host
  /// is not public, the download failed or the bytes are no usable picture.
  Future<String> get(Object? rawUrl) async {
    final url = checkUrl(rawUrl);
    final cached = _cached(url);
    if (cached != null) return cached;
    final host = Uri.parse(url).host;
    List<InternetAddress> addresses;
    try {
      addresses = await resolve(host);
    } on Object {
      throw RouteError('network', trf("{0} could not be found", [host]));
    }
    if (addresses.isEmpty || !addresses.every(isPublicAddress)) {
      throw RouteError('not_public', trf("{0} is not a public web address", [host]));
    }
    final data = await fetch(url, addresses.first, maxBackgroundBytes, const Duration(seconds: 60));
    if (data == null) throw RouteError('network', tr("the image could not be downloaded"));
    final ext = imageExtension(data);
    if (!isImageData(data) || ext == null) throw RouteError('bad_image', tr("the link is not a JPEG, PNG or WebP picture"));
    final problem = imageBytesProblem(data);
    if (problem != null) throw RouteError('bad_image', problem);
    final path = '$cacheDir/${_key(url)}$ext';
    writeAtomic(path, data);
    _prune();
    return path;
  }

  /// A file name from the link: its last path segment, made safe.
  static String fileNameOf(String url, String path) {
    final last = Uri.parse(url).pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? 'web-wallpaper';
    final stem = last.contains('.') ? last.substring(0, last.lastIndexOf('.')) : last;
    final clean = stem.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-').replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');
    final name = clean.isEmpty ? 'web-wallpaper' : (clean.length > 60 ? clean.substring(0, 60) : clean);
    return 'web-$name${path.substring(path.lastIndexOf('.'))}';
  }

  /// The picture added to the theme's wallpapers; its path there.
  Future<String> add(String slug, Object? rawUrl) async {
    final path = await get(rawUrl);
    final url = checkUrl(rawUrl);
    return addBackgroundBytes(ctx, slug, File(path).readAsBytesSync(), fileNameOf(url, path));
  }

  void _prune() {
    try {
      final files = Directory(cacheDir)
          .listSync(followLinks: false)
          .whereType<File>()
          .map((f) => (f, f.statSync().modified))
          .toList()
        ..sort((a, b) => a.$2.compareTo(b.$2));
      for (var i = 0; i < files.length - maxWebImagesCached; i++) {
        files[i].$1.deleteSync();
      }
    } on FileSystemException {
      // best effort
    }
  }
}

/// Opens the page a web picture is shown on in the default browser.
Future<bool> openWebPage(Ctx ctx, Object? page) async {
  final url = publicHttpsUrl(page) ?? (throw RouteError('bad_params', tr("not a public https address")));
  final opener = which('xdg-open', ctx.environment);
  if (opener == null) return false;
  try {
    await Process.start(opener, [url], mode: ProcessStartMode.detached);
    return true;
  } on ProcessException {
    return false;
  }
}
