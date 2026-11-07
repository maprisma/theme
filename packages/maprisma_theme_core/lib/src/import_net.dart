import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The import module's network access (omarchy.org, cosmic-themes.org, the
/// marketplace catalog): HTTPS only, one exact host per caller, no
/// redirects, a byte cap and one deadline on every request. Nothing from a
/// page decides which host is contacted.

final class NetRequest {
  NetRequest(
    this.uri, {
    required this.hosts,
    this.method = 'GET',
    this.headers = const {},
    this.body,
    this.maxBytes = 4 * 1024 * 1024,
    this.timeout = const Duration(seconds: 15),
  });

  final Uri uri;

  /// The only hosts this request may go to (exact match).
  final Set<String> hosts;
  final String method;
  final Map<String, String> headers;
  final List<int>? body;
  final int maxBytes;
  final Duration timeout;
}

final class NetReply {
  NetReply(this.status, this.headers, this.body, {this.cookies = const {}});
  final int status;

  /// Lower-case header names, the first value of each.
  final Map<String, String> headers;
  final Uint8List body;

  /// Cookie name → value from Set-Cookie.
  final Map<String, String> cookies;

  String get text => utf8.decode(body, allowMalformed: true);
}

typedef Fetcher = Future<NetReply?> Function(NetRequest request);

/// The fetcher the import module uses; tests replace it so they never
/// touch the network.
Fetcher netFetch = httpsFetch;

/// Why [uri] may not be fetched for [hosts], or null when it may.
String? urlProblem(Uri uri, Set<String> hosts) {
  if (uri.scheme != 'https') return 'not https';
  if (!hosts.contains(uri.host)) return 'host not allowed';
  if (uri.userInfo.isNotEmpty) return 'user info in the URL';
  if (uri.hasPort && uri.port != 443) return 'unexpected port';
  if (uri.fragment.isNotEmpty) return 'fragment in the URL';
  return null;
}

const userAgent = 'maprisma-theme';

/// One bounded HTTPS request with dart:io's HttpClient; null on any
/// failure (refused URL, network, too large, too slow). Any status is
/// returned (callers check it); redirects are never followed.
Future<NetReply?> httpsFetch(NetRequest r) async {
  if (urlProblem(r.uri, r.hosts) != null) return null;
  final client = HttpClient()
    ..connectionTimeout = r.timeout
    ..idleTimeout = const Duration(seconds: 2)
    ..autoUncompress = true
    ..userAgent = userAgent
    ..findProxy = ((_) => 'DIRECT');
  try {
    return await _fetch(client, r).timeout(r.timeout);
  } on TimeoutException {
    return null;
  } on IOException {
    return null;
  } on FormatException {
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<NetReply?> _fetch(HttpClient client, NetRequest r) async {
  final request = await client.openUrl(r.method, r.uri);
  request
    ..followRedirects = false
    ..maxRedirects = 0
    ..persistentConnection = false;
  r.headers.forEach(request.headers.set);
  final body = r.body;
  if (body != null) {
    request.contentLength = body.length;
    request.add(body);
  }
  final response = await request.close();
  // Too large by its own word: the client is closed by force afterwards.
  if (response.contentLength > r.maxBytes) return null;
  final out = BytesBuilder(copy: false);
  await for (final chunk in response) {
    if (out.length + chunk.length > r.maxBytes) return null;
    out.add(chunk);
  }
  final headers = <String, String>{};
  response.headers.forEach((name, values) {
    if (values.isNotEmpty) headers[name.toLowerCase()] = values.first;
  });
  final cookies = <String, String>{};
  try {
    for (final c in response.cookies) {
      cookies[c.name] = c.value;
    }
  } on FormatException {
    // a malformed Set-Cookie: none
  } on HttpException {
    // the same
  }
  return NetReply(response.statusCode, headers, out.takeBytes(), cookies: cookies);
}

/// Opens [url] in the default browser (xdg-open, detached). Callers check
/// the URL's shape first.
Future<bool> openInBrowser(String url, Map<String, String> environment) async {
  if (!url.startsWith('https://') || url.contains(RegExp(r'[\s\x00-\x1f]'))) return false;
  try {
    await Process.start('xdg-open', [url], mode: ProcessStartMode.detached, environment: environment);
    return true;
  } on ProcessException {
    return false;
  }
}

/// theme_core.plain_text: no control characters and no markup characters,
/// at most [limit] characters.
String plainText(String text, {int limit = 300}) {
  final flat = text.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').replaceAll(RegExp('[<>&]'), '');
  return flat.length > limit ? flat.substring(0, limit) : flat;
}

/// Python's html.unescape for the entities pages use.
String htmlUnescape(String text) => text.replaceAllMapped(RegExp(r'&(#[0-9]{1,7}|#[xX][0-9A-Fa-f]{1,6}|[A-Za-z]{2,8});'), (m) {
  final e = m[1]!;
  if (e.startsWith('#')) {
    final code = e[1] == 'x' || e[1] == 'X' ? int.tryParse(e.substring(2), radix: 16) : int.tryParse(e.substring(1));
    if (code == null || code == 0 || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) return '�';
    return String.fromCharCode(code);
  }
  return switch (e) {
    'amp' => '&',
    'lt' => '<',
    'gt' => '>',
    'quot' => '"',
    'apos' => "'",
    'nbsp' => ' ',
    'middot' => '·',
    _ => m[0]!,
  };
});
