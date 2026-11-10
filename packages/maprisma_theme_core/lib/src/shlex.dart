/// Python's shlex.split / shlex.quote / shlex.join (POSIX mode, no comments).
library;

import 'i18n.dart';

final class ShlexError extends FormatException {
  const ShlexError(super.message);
}

const _whitespace = ' \t\r\n';

List<String> shlexSplit(String text) {
  final words = <String>[];
  final word = StringBuffer();
  var inWord = false;
  String? quote; // ' or "
  var i = 0;
  while (i < text.length) {
    final c = text[i];
    if (quote == "'") {
      if (c == "'") {
        quote = null;
      } else {
        word.write(c);
      }
    } else if (quote == '"') {
      if (c == '"') {
        quote = null;
      } else if (c == r'\') {
        if (i + 1 >= text.length) throw ShlexError(tr('No closing quotation'));
        final next = text[i + 1];
        // In double quotes a backslash escapes only itself and the quote.
        if (next == r'\' || next == '"') {
          word.write(next);
          i++;
        } else {
          word.write(c);
        }
      } else {
        word.write(c);
      }
    } else if (_whitespace.contains(c)) {
      if (inWord) {
        words.add(word.toString());
        word.clear();
        inWord = false;
      }
    } else if (c == "'" || c == '"') {
      quote = c;
      inWord = true;
    } else if (c == r'\') {
      if (i + 1 >= text.length) throw ShlexError(tr('No escaped character'));
      word.write(text[i + 1]);
      i++;
      inWord = true;
    } else {
      word.write(c);
      inWord = true;
    }
    i++;
  }
  if (quote != null) throw ShlexError(tr('No closing quotation'));
  if (inWord) words.add(word.toString());
  return words;
}

final _safe = RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$');

String shlexQuote(String word) {
  if (word.isEmpty) return "''";
  if (_safe.hasMatch(word)) return word;
  return "'${word.replaceAll("'", "'\"'\"'")}'";
}

String shlexJoin(Iterable<String> words) => words.map(shlexQuote).join(' ');
