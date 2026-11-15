import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_theme/theme.dart';

void main() {
  test('the desktop\'s interface font is the theme\'s; its monospace font is monoFont\'s', () {
    final t = appTheme(Brightness.dark, const {}, 12, fonts: const {'ui': 'Noto Sans', 'mono': 'Hack'});
    expect(t.textTheme.bodyMedium!.fontFamily, 'Noto Sans');
    expect(t.extension<AppFonts>()!.mono, 'Hack');
    final none = appTheme(Brightness.dark, const {}, 12);
    expect(none.extension<AppFonts>()!.mono, isNull);
    expect(fontFamily(const {'ui': '  '}, 'ui'), isNull);
  });

  testWidgets('monoFont: the desktop\'s, else monospace', (tester) async {
    late String a, b;
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.dark, const {}, 12, fonts: const {'mono': 'Hack'}),
      home: Builder(builder: (c) => Text(a = monoFont(c))),
    ));
    await tester.pumpWidget(MaterialApp(key: UniqueKey(), home: Builder(builder: (c) => Text(b = monoFont(c)))));
    expect((a, b), ('Hack', 'monospace'));
  });

  testWidgets('tooltips look like Maprisma\'s: a dark card tone on dark, the dark inverted surface on light', (tester) async {
    for (final b in Brightness.values) {
      final t = appTheme(b, const {}, 12);
      await tester.pumpWidget(MaterialApp(key: UniqueKey(), theme: t, home: const Scaffold(body: Tooltip(message: 'tip', child: Text('x')))));
      tester.state<TooltipState>(find.byType(Tooltip)).ensureTooltipVisible();
      await tester.pumpAndSettle();
      final box = tester.widget<Container>(find.ancestor(of: find.text('tip'), matching: find.byType(Container)).first).decoration as BoxDecoration;
      final s = t.colorScheme;
      expect(box.color, b == Brightness.dark ? s.surfaceContainerHighest : s.inverseSurface.withValues(alpha: .92));
      await tester.pumpWidget(const SizedBox());
    }
  });
}
