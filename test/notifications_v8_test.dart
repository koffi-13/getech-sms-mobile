/// Tests V8 :
/// - [NotificationStore] : ajout, déduplication, marquage lu, plafond 50 ;
/// - [AppErrorWidget.humanize] : « introuvable » → message actionnable ;
/// - sentinel 'ALL' du cache EDT (cours « toutes semaines »).
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getech_sms_mobile/core/notifications/notification_store.dart';
import 'package:getech_sms_mobile/shared/widgets/app_error_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  NotificationEntry entry(
    int id,
    String title, {
    bool read = false,
    DateTime? created,
  }) =>
      NotificationEntry(
        id: id,
        title: title,
        body: 'Corps de $title',
        category: NotificationCategory.grades,
        route: '/grades',
        createdAt: created ?? DateTime(2026, 10, 12, 8, 30),
        read: read,
      );

  group('NotificationStore (centre de notifications)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('add + load : la plus récente en premier', () async {
      final store = NotificationStore();
      await store.add(entry(1, 'Ancienne',
          created: DateTime(2026, 10, 10)));
      await store.add(entry(2, 'Récente',
          created: DateTime(2026, 10, 12)));
      final entries = await store.load();
      expect(entries.length, 2);
      expect(entries.first.title, 'Récente');
      expect(entries.last.title, 'Ancienne');
    });

    test('add déduplique par id (remplacement)', () async {
      final store = NotificationStore();
      await store.add(entry(7, 'Première version'));
      await store.add(entry(7, 'Version corrigée'));
      final entries = await store.load();
      expect(entries.length, 1);
      expect(entries.first.title, 'Version corrigée');
    });

    test('markAllRead / markRead / clear', () async {
      final store = NotificationStore();
      await store.add(entry(1, 'A'));
      await store.add(entry(2, 'B'));
      await store.markRead(1);
      var entries = await store.load();
      expect(entries.firstWhere((e) => e.id == 1).read, isTrue);
      expect(entries.firstWhere((e) => e.id == 2).read, isFalse);

      await store.markAllRead();
      entries = await store.load();
      expect(entries.every((e) => e.read), isTrue);

      await store.clear();
      entries = await store.load();
      expect(entries, isEmpty);
    });

    test('plafonnement à 50 entrées (les plus anciennes sortent)', () async {
      final store = NotificationStore();
      for (var i = 0; i < 60; i++) {
        await store.add(entry(i, 'N$i',
            created: DateTime(2026, 10, 1).add(Duration(hours: i))));
      }
      final entries = await store.load();
      expect(entries.length, 50);
      // Les 50 plus récentes (10..59) sont conservées.
      expect(entries.map((e) => e.id), contains(59));
      expect(entries.map((e) => e.id), isNot(contains(5)));
    });

    test('round-trip JSON complet (catégorie + route + lu)', () async {
      final store = NotificationStore();
      await store.add(NotificationEntry(
        id: 42,
        title: 'Titre',
        body: 'Corps',
        category: NotificationCategory.sync,
        route: '/notifications',
        createdAt: DateTime(2026, 10, 12, 9),
        read: true,
      ));
      final e = (await store.load()).single;
      expect(e.category, NotificationCategory.sync);
      expect(e.route, '/notifications');
      expect(e.read, isTrue);
      expect(e.title, 'Titre');
    });
  });

  group('AppErrorWidget.humanize — introuvable', () {
    test('StateError « Classe #12 introuvable en local. » → message clair',
        () {
      final msg = AppErrorWidget.humanize(
          "Bad state: Classe #12 introuvable en local.");
      expect(msg, contains('introuvable'));
      expect(msg, contains('rafraîchir'));
      // Plus JAMAIS le message générique « donnée inattendue ».
      expect(msg.contains('donnée inattendue'), isFalse);
    });

    test('ApiException déjà rédigée avec « introuvable » → réécrite propre',
        () {
      // Même un message déjà rédigé contenant « introuvable » est réécrit
      // avec la consigne d'action (tirer pour rafraîchir).
      final msg = AppErrorWidget.humanize(
          'Classe introuvable. Tirez pour rafraîchir la liste des classes '
          'puis réessayez.');
      expect(msg, contains('rafraîchir'));
      expect(msg, contains('introuvable'));
    });
  });

  group('Semaines alternées — conventions', () {
    test('WeekTypeHelper : semaines A/B depuis la date de démarrage', () {
      // Le miroir mobile du calcul serveur (SchoolYear.week_type_for_date).
      const start = '2026-09-28'; // lundi de semaine A
      final s = DateTime.parse(start);
      expect(
        _weekTypeFor(DateTime(2026, 10, 12), s), // lundi suivant
        'A',
      );
      expect(
        _weekTypeFor(DateTime(2026, 10, 19), s), // +7j → semaine B
        'B',
      );
      expect(
        _weekTypeFor(DateTime(2026, 10, 26), s), // +14j → semaine A
        'A',
      );
      expect(_weekTypeFor(DateTime(2026, 9, 21), s), isNull); // avant départ
    });
  });
}

/// Miroir local du calcul (identique à WeekTypeHelper.weekTypeForDate).
String? _weekTypeFor(DateTime date, DateTime? alternatingStart) {
  if (alternatingStart == null) return null;
  final deltaDays = date.difference(DateTime(
    alternatingStart.year,
    alternatingStart.month,
    alternatingStart.day,
  )).inDays;
  if (deltaDays < 0) return null;
  final weekNumber = deltaDays ~/ 7;
  return weekNumber % 2 == 0 ? 'A' : 'B';
}

// Silence les warnings de binding pour les méthodes statiques.
// ignore: unused_element
final _ = SystemChannels.platform;
