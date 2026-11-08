import 'package:maprisma_theme_core/src/desktop_kde.dart';
import 'package:test/test.dart';

void main() {
  test('kdeRgbHex turns a KDE colour into #rrggbb', () {
    expect(KdeDesktop.kdeRgbHex('184,184,182'), '#b8b8b6');
    expect(KdeDesktop.kdeRgbHex('61, 174, 233, 255'), '#3daee9');
    expect(KdeDesktop.kdeRgbHex('300,0,0'), isNull);
    expect(KdeDesktop.kdeRgbHex(null), isNull);
  });
}
