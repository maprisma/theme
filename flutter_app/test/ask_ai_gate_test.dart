import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_theme/app.dart';
import 'package:maprisma_theme/ask_ai_gate.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart';

void main() {
  testWidgets(
    'blocked Ask button is disabled and settings link uses core route',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('theme-rules-widget-');
      addTearDown(() => root.deleteSync(recursive: true));
      final env = {'HOME': root.path, 'PATH': '/usr/bin'};
      final core = CoreService(
        environment: env,
        paths: Paths.fromEnvironment(env, share: root.path),
        desktop: FakeDesktop(),
      );
      var opened = false;
      Future<Map<String, dynamic>> call(
        String method, [
        Map<String, dynamic> p = const {},
      ]) async {
        if (method == 'ask.rules') {
          return {
            'level': 'review',
            'actions': {'theme.apply': false},
          };
        }
        if (method == 'ask.open_settings') {
          opened = true;
          return {'opened': true};
        }
        return core.call(method, p);
      }

      await tester.runAsync(() async {
        await tester.pumpWidget(MaprismaThemeApp(call: call));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      final state = tester.state<MaprismaThemeAppState>(
        find.byType(MaprismaThemeApp),
      );
      state.navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: AskAiGate(
              proposal: 'test-proposal',
              actions: const ['theme.apply'],
              builder: (allowed) => FilledButton(
                onPressed: allowed ? () {} : null,
                child: const Text('Use'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.widgetWithText(
        FilledButton,
        'Switched off in Maprisma Settings › AI',
      );
      expect(button, findsOneWidget);
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      await tester.tap(
        find.widgetWithText(TextButton, 'Maprisma Settings › AI'),
      );
      await tester.pump();
      expect(opened, isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
