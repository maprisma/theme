import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_theme/app.dart';

void main() {
  testWidgets('KDE Store lists, pages, searches, and installs on a generic desktop', (tester) async {
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final lists = <Map<String, dynamic>>[];
    final installs = <Map<String, dynamic>>[];
    final previews = <int>[];
    final applies = <Map<String, dynamic>>[];
    Map<String, dynamic> theme(int id) => {
      'id': id,
      'name': 'Scheme $id',
      'author': 'Artist $id',
      'downloads': 100,
      'score': 92,
      'page': 'https://store.kde.org/p/$id',
      'preview': null,
      'installed': false,
      'slug': null,
    };
    Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> params = const {}]) async {
      switch (method) {
        case 'desktop.info':
          return {'id': 'generic', 'name': 'Generic', 'caps': <String>[]};
        case 'settings.get':
          return {'settings': <String, dynamic>{}};
        case 'themes.list':
        case 'import.omarchy_list':
          return {'themes': <Map<String, dynamic>>[]};
        case 'import.kde_list':
          lists.add(Map.of(params));
          return {
            'themes': [theme(params['page'] == 2 ? 2 : 1)],
            'next_page': params['page'] == 2 || params.containsKey('search') ? null : 2,
            'sorts': [
              {'value': 'high', 'label': 'Rating'},
              {'value': 'new', 'label': 'Newest'},
              {'value': 'down', 'label': 'Downloads'},
              {'value': 'alpha', 'label': 'Name'},
            ],
          };
        case 'import.kde_preview':
          previews.add(params['id'] as int);
          return {'path': null};
        case 'import.kde_install':
          installs.add(Map.of(params));
          return {'slug': 'kde-scheme-1', 'applied': false};
        case 'themes.apply':
          applies.add(Map.of(params));
          return {'applied': true};
        default:
          return {};
      }
    }

    // The import page's other tabs keep a spinner turning while they wait, so
    // pumpAndSettle would never return: a fixed number of frames instead.
    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.pumpWidget(MaprismaThemeApp(call: call));
    await settle();
    final app = tester.state<MaprismaThemeAppState>(find.byType(MaprismaThemeApp));
    app.openPage('import');
    await settle();
    expect(lists, isEmpty);
    await tester.tap(find.text('KDE'));
    await settle();
    expect(lists.single, {'sort': 'high'});
    expect(find.text('Scheme 1'), findsOneWidget);
    expect(find.text('by Artist 1'), findsOneWidget);
    expect(find.text('Score: 92/100'), findsOneWidget);
    expect(previews, [1]);

    await tester.ensureVisible(find.text('Load more'));
    await tester.tap(find.text('Load more'));
    await settle();
    expect(lists.last, {'sort': 'high', 'page': 2});
    expect(find.text('Scheme 2'), findsOneWidget);
    expect(find.text('Load more'), findsNothing);

    // The shared gallery keyboard opens the first tile's menu.
    await tester.tap(find.byType(TextField).last);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await settle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle();
    await tester.tap(find.text('Install'));
    await settle();
    expect(installs.single, {'id': 1, 'apply': false});
    expect(find.text('installed'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle();
    await tester.tap(find.text('Apply theme'));
    await settle();
    expect(applies.single, {'slug': 'kde-scheme-1'});

    await tester.enterText(find.byType(TextField).last, 'Breeze');
    await tester.pump(const Duration(milliseconds: 401));
    await settle();
    expect(lists.last, {'sort': 'high', 'search': 'Breeze'});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await settle();
  });
}
