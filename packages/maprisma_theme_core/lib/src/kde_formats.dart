import 'i18n.dart';
import 'colors.dart';

/// Render first so the scheme name is never interpreted as a template token.
String? renderKdeScheme(
  String template,
  Map<String, String> resolved,
  String name,
) => renderTemplate(template, resolved)?.replaceAll(
  '@SCHEME_NAME@',
  name.replaceAll(RegExp(r'[\r\n\u0085\u2028\u2029\[\]=]'), '').trim(),
);

// Retain the terminator on each line, including mixed LF/CRLF input.
List<String> _lines(String text) =>
    RegExp(r'[^\n]*\n|[^\n]+$').allMatches(text).map((m) => m[0]!).toList();
String _body(String line) => line.replaceFirst(RegExp(r'\r?\n$'), '');
String? _group(String line) {
  final body = _body(line).trim();
  return RegExp(r'^\[[^\]\r\n]+\](?:\[[^\]\r\n]+\])*$').hasMatch(body)
      ? body.substring(1, body.length - 1)
      : null;
}

bool _key(String line, String key) {
  final body = _body(line).trimLeft();
  if (body.startsWith('#') || body.startsWith(';')) return false;
  final eq = body.indexOf('=');
  return eq >= 0 && body.substring(0, eq).trim() == key;
}

/// Nested groups use their literal interior, e.g. `Colors:Header][Inactive`.
String? iniValue(String text, String group, String key) {
  String? current;
  String? result;
  for (final line in _lines(text)) {
    final header = _group(line);
    if (header != null) {
      current = header;
    } else if (current == group && _key(line, key)) {
      result = _body(line).substring(line.indexOf('=') + 1).trim();
    }
  }
  return result;
}

/// Edit only matching values; all other bytes retain their order and spelling.
String setIniValue(String? text, String group, String key, String value) {
  final source = text ?? '';
  final lines = _lines(source);
  final newline = source.contains('\r\n') ? '\r\n' : '\n';
  String? current;
  int? insert;
  var found = false;
  for (var i = 0; i < lines.length; i++) {
    final header = _group(lines[i]);
    if (header != null) {
      if (current == group) insert = i;
      current = header;
      if (current == group) insert = i + 1;
    } else if (current == group) {
      insert = i + 1;
      if (_key(lines[i], key)) {
        final line = lines[i];
        final body = _body(line);
        final eq = body.indexOf('=');
        final rest = body.substring(eq + 1);
        final leading = RegExp(r'^\s*').stringMatch(rest)!;
        final trailing = rest.trim().isEmpty
            ? ''
            : RegExp(r'\s*$').stringMatch(rest)!;
        lines[i] =
            '${body.substring(0, eq + 1)}$leading$value$trailing'
            '${line.substring(body.length)}';
        found = true;
      }
    }
  }
  if (found) return lines.join();
  if (insert != null) {
    if (insert > 0 && !lines[insert - 1].endsWith('\n')) {
      lines[insert - 1] += newline;
    }
    lines.insert(insert, '$key=$value$newline');
    return lines.join();
  }
  return '$source${source.isNotEmpty && !source.endsWith('\n') ? newline : ''}'
      '[$group]$newline$key=$value$newline';
}

/// A KDE color value ("r,g,b" or "r,g,b,a") as #rrggbb, or null.
String? kdeRgb(String? value) {
  if (value == null) return null;
  final parts = value.split(',').map((p) => int.tryParse(p.trim())).toList();
  if ((parts.length != 3 && parts.length != 4) ||
      parts.any((p) => p == null || p < 0 || p > 255)) {
    return null;
  }
  return hexOf(parts[0]!, parts[1]!, parts[2]!);
}

/// A partial palette is unusable: callers need all three colors to draw a look.
Map<String, dynamic>? kdeCurrentLook(String kdeglobals) {
  final background = kdeRgb(
    iniValue(kdeglobals, 'Colors:Window', 'BackgroundNormal'),
  );
  final foreground = kdeRgb(
    iniValue(kdeglobals, 'Colors:Window', 'ForegroundNormal'),
  );
  // The scheme's accent: Plasma's own setting, else the focus decoration
  // (the accent itself in Maprisma's and Breeze's schemes); the selection
  // background last (often a muted mix, too dark to draw text in).
  final accent =
      kdeRgb(iniValue(kdeglobals, 'General', 'AccentColor')) ??
      kdeRgb(iniValue(kdeglobals, 'Colors:View', 'DecorationFocus')) ??
      kdeRgb(iniValue(kdeglobals, 'Colors:Selection', 'BackgroundNormal'));
  if (background == null || foreground == null || accent == null) return null;
  return {
    'colors': {
      'background': background,
      'foreground': foreground,
      'accent': accent,
    },
    'is_dark': luminance(background) < 0.5,
    'corner_radius': null,
  };
}

List<String>? _qfont(String? value) {
  if (value == null || value.contains(RegExp(r'[\r\n]'))) return null;
  final parts = value.split(',');
  // Qt5 writes ten numeric fields; Qt6 appends more, among them the style
  // name as text ("Regular", or empty) and font features: only the first
  // ten must be numbers, the rest is kept as it is.
  if (parts.length < 10 ||
      parts.first.trim().isEmpty ||
      parts.skip(1).take(9).any((p) => double.tryParse(p.trim()) == null)) {
    return null;
  }
  return parts;
}

String? qfontFamily(String? value) => _qfont(value)?.first.trim();

String qfontWithFamily(String? old, String family) {
  if (family.contains(',') ||
      family.contains(RegExp(r'[\r\n]')) ||
      family.trim().isEmpty) {
    throw ArgumentError.value(
      family,
      'family',
      tr("Expected a single font family"),
    );
  }
  final parts =
      _qfont(old) ?? 'sans,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1'.split(',');
  parts[0] = family;
  return parts.join(',');
}

String konsoleProfile(String? existing, String profileName, String scheme) {
  var text = setIniValue(existing, 'Appearance', 'ColorScheme', scheme);
  text = setIniValue(text, 'General', 'Name', profileName);
  if (existing == null) {
    text = setIniValue(text, 'General', 'Parent', 'FALLBACK/');
  }
  return text;
}
