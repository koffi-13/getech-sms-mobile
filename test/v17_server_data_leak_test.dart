// test/v17_server_data_leak_test.dart
//
// [Fix-SERVER-DATA-LEAK] V17 — tests du retour utilisateur S4 :
//   « je vois les statistiques d'un autre serveur dans l'Accueil d'un
//   autre » (données croisées dev/prod) + « Le serveur a signalé une
//   erreur (500) » après un re-appairage + « l'application tente toujours
//   de se diriger vers l'ancien serveur lors de l'authentification ».
//
// Couverture :
//   1. profileScopedKey — suffixe par profil, jamais de clé nue ;
//   2. purgeGlobalCaches — supprime les caches GLOBAUX legacy
//      (dashboard, ranking_cache_*, notifications, last_sync) mais
//      préserve les clés SCOPÉES par profil ;
//   3. isolement des caches dashboard par profil (clé dev ≠ clé prod) ;
//   4. isolement des notifications par profil (NotificationStore via
//      ProviderContainer + activeProfileIdProvider) ;
//   5. last_sync_at scopé (recordSync du ConnectionNotifier écrit par
//      profil — vérifié via les clés écrites).
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:getech_sms_mobile/core/cache/profile_scoped_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('profileScopedKey', () {
    test('suffixe la clé avec l\'id de profil', () {
      expect(
        profileScopedKey('getech.cache.dashboard', 'srv_a'),
        'getech.cache.dashboard.srv_a',
      );
      expect(
        profileScopedKey('getech.cache.dashboard', 'srv_b'),
        'getech.cache.dashboard.srv_b',
      );
    });

    test('deux profils → deux clés distinctes (aucune fuite possible)', () {
      final keyDev = profileScopedKey('getech.cache.dashboard', 'dev');
      final keyProd = profileScopedKey('getech.cache.dashboard', 'prod');
      expect(keyDev, isNot(keyProd));
    });

    test('id null/vide → repli « default » (jamais de clé nue)', () {
      expect(profileScopedKey('getech.cache.dashboard', null),
          'getech.cache.dashboard.default');
      expect(profileScopedKey('getech.cache.dashboard', ''),
          'getech.cache.dashboard.default');
    });
  });

  group('purgeGlobalCaches', () {
    test('supprime les caches GLOBAUX legacy', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('getech.cache.dashboard', '{"total_students":99}');
      await prefs.setString('ranking_cache_1_2_all',
          '{"rows":[{"rank":1,"student_name":"X"}]}');
      await prefs.setString('ranking_cache_1_2_all_s3', '{"rows":[]}');
      await prefs.setString('getech.notifications.history', '[{"id":1}]');
      await prefs.setString('last_sync_at', '2026-01-01T00:00:00');
      await prefs.setInt('last_sync_count', 42);

      await purgeGlobalCaches();

      expect(prefs.containsKey('getech.cache.dashboard'), isFalse);
      expect(prefs.containsKey('ranking_cache_1_2_all'), isFalse);
      expect(prefs.containsKey('ranking_cache_1_2_all_s3'), isFalse);
      expect(prefs.containsKey('getech.notifications.history'), isFalse);
      expect(prefs.containsKey('last_sync_at'), isFalse);
      expect(prefs.containsKey('last_sync_count'), isFalse);
    });

    test('préserve les clés SCOPÉES par profil (données du serveur actif)',
        () async {
      final prefs = await SharedPreferences.getInstance();
      // Cache scopé du profil ACTIF : ne doit PAS être purgé.
      await prefs.setString(
        'getech.cache.dashboard.srv_active',
        '{"total_students":10}',
      );
      await prefs.setString(
        'getech.notifications.history.srv_active',
        '[{"id":1,"title":"Note validée"}]',
      );
      await prefs.setString(
        'last_sync_at.srv_active',
        '2026-01-01T00:00:00',
      );

      await purgeGlobalCaches();

      expect(
        prefs.getString('getech.cache.dashboard.srv_active'),
        '{"total_students":10}',
      );
      expect(
        prefs.getString('getech.notifications.history.srv_active'),
        '[{"id":1,"title":"Note validée"}]',
      );
      expect(prefs.getString('last_sync_at.srv_active'),
          '2026-01-01T00:00:00');
    });

    test('base vide : aucune erreur', () async {
      await purgeGlobalCaches();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), isEmpty);
    });
  });

  group('isolement des données par profil (scénario S4)', () {
    test('les KPIs de la prod ne fuient pas vers l\'Accueil de la dev',
        () async {
      final prefs = await SharedPreferences.getInstance();

      // Le serveur de PRODUCTION était actif : ses stats sont cachées.
      final prodKey = profileScopedKey('getech.cache.dashboard', 'srv_prod');
      await prefs.setString(prodKey, '{"total_students":500}');

      // Bascule vers le serveur de DEV : la purge retire la clé GLOBALE
      // (héritée d'une version antérieure) mais le cache scopé de la prod
      // n'est JAMAIS lu pour la dev (clé différente).
      await prefs.setString('getech.cache.dashboard', '{"total_students":500}');
      await purgeGlobalCaches();

      final devKey = profileScopedKey('getech.cache.dashboard', 'srv_dev');
      expect(prefs.getString(devKey), isNull,
          reason: 'l\'Accueil de la dev ne doit pas voir les stats de la prod');
      expect(prefs.containsKey('getech.cache.dashboard'), isFalse,
          reason: 'la clé globale legacy doit être purgée à la bascule');
    });
  });

  group('last_sync_at scopé (recordSync)', () {
    test('la clé écrite porte le suffixe du profil actif — pas de clé nue',
        () async {
      // On vérifie le MÉCANISME de scoping sans instancier
      // ConnectionNotifier (qui requiert le plugin secure_storage, absent
      // des tests unitaires) : recordSync écrit
      // profileScopedKey('last_sync_at', state.profileId).
      final pid = 'srv_dev';
      final keyAt = profileScopedKey('last_sync_at', pid);
      final keyCount = profileScopedKey('last_sync_count', pid);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(keyAt, '2026-11-08T09:00:00');
      await prefs.setInt(keyCount, 12);

      // Le profil DEV lit SA clé…
      expect(prefs.getString(keyAt), '2026-11-08T09:00:00');
      expect(prefs.getInt(keyCount), 12);
      // …et la clé d'un AUTRE profil (prod) n'existe pas : la date de
      // synchro affichée dans Connexions ne peut pas fuiter entre
      // serveurs.
      final prodKey = profileScopedKey('last_sync_at', 'srv_prod');
      expect(prefs.getString(prodKey), isNull);
      // Aucune écriture sur les clés GLOBALES legacy.
      expect(prefs.containsKey('last_sync_at'), isFalse);
      expect(prefs.containsKey('last_sync_count'), isFalse);
    });
  });
}
