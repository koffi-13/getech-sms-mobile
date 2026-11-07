// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:getech_sms_mobile/app.dart';
import 'package:getech_sms_mobile/core/config/theme.dart';
import 'package:getech_sms_mobile/shared/widgets/kpi_card.dart';
import 'package:getech_sms_mobile/shared/widgets/content_sized_grid.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(
      const ProviderScope(
        child: GeTechApp(),
      ),
    );

    // Initial load should show something (splash or redirect).
    expect(find.byType(GeTechApp), findsOneWidget);
  });

  testWidgets('KPI cards fit when text is scaled up', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: ListView(
              children: const [
                ContentSizedGrid(
                  children: [
                    KpiCard(label: 'Mes classes', value: '12'),
                    KpiCard(label: 'Cours aujourd\'hui', value: '4'),
                    KpiCard(label: 'Mes matières', value: '8'),
                    KpiCard(label: 'Mes élèves', value: '36'),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('three-column cards fit when text is scaled up', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: ContentSizedGrid(
              crossAxisCount: 3,
              padding: const EdgeInsets.all(16),
              children: [
                for (final label in [
                  'Import élèv.',
                  'Établiss.',
                  'Paramètres',
                  'Long libellé de test',
                ])
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.settings, size: 24),
                          const SizedBox(height: 8),
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 2,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
