// test/v15_auto_sync_test.dart
//
// [Fix-AUTO-SYNC] V15 — tests des trois correctifs du retour utilisateur :
//   1. « la connexion et la synchronisation s'effectuent automatiquement
//      tant que le serveur est en ligne » → shouldAutoSync (transitions
//      d'état de connexion déclenchant la synchro auto) ;
//   2. « le classement devrait s'afficher aussi en mode hors-ligne » →
//      cache de classement (écriture/lecture/isolement par requête) et
//      service du cache par rankingProvider hors-ligne ;
//   3. « saisie de notes hors ligne » → isNetworkFailure (les pannes
//      réseau basculent vers l'outbox, les erreurs serveur remontent).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:getech_sms_mobile/core/network/api_exceptions.dart';
import 'package:getech_sms_mobile/core/sync/auto_sync.dart';
import 'package:getech_sms_mobile/features/connections/connection_state.dart';
import 'package:getech_sms_mobile/features/grades/grade_controller.dart';
import 'package:getech_sms_mobile/shared/models/grade_dto.dart';

/// État « appairé + en ligne » canonique.
ConnectionState _online() => const ConnectionState(
      status: ServerStatus.online,
      pairingToken: 'tok',
      serverIp: '192.168.1.10',
      serverPort: 8000,
    );

ConnectionState _offline() => const ConnectionState(
      status: ServerStatus.offline,
      pairingToken: 'tok',
      serverIp: '192.168.1.10',
      serverPort: 8000,
    );

ConnectionState _checking() => const ConnectionState(
      status: ServerStatus.checking,
      pairingToken: 'tok',
      serverIp: '192.168.1.10',
      serverPort: 8000,
    );

void main() {
  group('[V15-AUTO-SYNC] shouldAutoSync (transitions de connexion)', () {
    test('démarrage à froid (null) → en ligne : synchro de rattrapage', () {
      expect(shouldAutoSync(null, _online()), isTrue);
    });

    test('hors-ligne → en ligne : synchro automatique', () {
      expect(shouldAutoSync(_offline(), _online()), isTrue);
    });

    test('checking → en ligne (heartbeat au démarrage) : synchro', () {
      expect(shouldAutoSync(_checking(), _online()), isTrue);
    });

    test('en ligne → en ligne (recordSync, heartbeat) : PAS de re-synchro', () {
      // recordSync() émet un nouvel état (lastSyncAt) après chaque pull :
      // la transition ne doit PAS re-déclencher une synchro (sinon boucle).
      expect(shouldAutoSync(_online(), _online()), isFalse);
    });

    test('en ligne → hors-ligne : rien à faire', () {
      expect(shouldAutoSync(_online(), _offline()), isFalse);
    });

    test('hors-ligne → hors-ligne : rien à faire', () {
      expect(shouldAutoSync(_offline(), _offline()), isFalse);
    });

    test('mode hors-ligne forcé : JAMAIS de synchro auto', () {
      final forced = _online().copyWith(forceOffline: true);
      expect(shouldAutoSync(_offline(), forced), isFalse);
    });
  });

  group('[V15] isNetworkFailure (repli outbox vs erreur serveur)', () {
    test('NetworkException (timeout/refus) → repli outbox', () {
      expect(isNetworkFailure(const NetworkException('connexion refusée')),
          isTrue);
    });

    test('ApiException sans status (pas de réponse serveur) → repli outbox',
        () {
      expect(isNetworkFailure(const ApiException('DioException')), isTrue);
    });

    test('403 serveur → remonté à l’utilisateur (PAS de repli)', () {
      expect(
          isNetworkFailure(
              const ApiException('Permission insuffisante', statusCode: 403)),
          isFalse);
    });

    test('422 validation → remonté à l’utilisateur (PAS de repli)', () {
      expect(
          isNetworkFailure(
              const ApiException('Champ invalide', statusCode: 422)),
          isFalse);
    });

    test('401 → remonté (re-login), pas de repli silencieux', () {
      expect(isNetworkFailure(const UnauthorizedException()), isFalse);
    });
  });

  group('[V15-RANKING-OFFLINE] cache de classement', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    const q = RankingQuery(classroomId: 1, periodId: 2);
    const qSubject = RankingQuery(
      classroomId: 1,
      periodId: 2,
      rankingMode: RankingMode.subject,
      subjectId: 7,
    );

    final rows = const [
      RankingRowDto(
        rank: 1,
        studentId: 101,
        nom: 'KOUAME',
        prenoms: 'Yao',
        matricule: 'M101',
        average: 14.5,
        annualAverage: 13.75,
      ),
      RankingRowDto(
        rank: 2,
        rankLabel: '2 A',
        studentId: 102,
        nom: 'TRAORE',
        prenoms: 'Awa',
        average: 12.0,
      ),
    ];

    test('écriture puis lecture : roundtrip fidèle', () async {
      await writeRankingCache(q, rows);
      final cached = await readRankingCache(q);
      expect(cached, isNotNull);
      expect(cached!.length, 2);
      expect(cached[0].studentId, 101);
      expect(cached[0].nom, 'KOUAME');
      expect(cached[0].average, 14.5);
      expect(cached[0].annualAverage, 13.75);
      expect(cached[1].rankLabel, '2 A');
      expect(cached[1].average, 12.0);
    });

    test('cache isolé par requête (mode/matière différents)', () async {
      await writeRankingCache(q, rows);
      expect(await readRankingCache(qSubject), isNull);
      expect(rankingCacheKey(q) != rankingCacheKey(qSubject), isTrue);
    });

    test('liste vide → rien en cache (null, pas une liste vide)', () async {
      await writeRankingCache(q, const []);
      expect(await readRankingCache(q), isNull);
    });

    test('clé de cache : distincte par classe et période', () {
      const q2 = RankingQuery(classroomId: 3, periodId: 4);
      expect(rankingCacheKey(q) != rankingCacheKey(q2), isTrue);
    });

    test('rankingProvider hors-ligne (non appairé) sert le cache', () async {
      // ConnectionState par défaut = non appairé : le provider doit
      // renvoyer les lignes du cache local plutôt qu'une erreur.
      await writeRankingCache(q, rows);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final result = await container.read(rankingProvider(q).future);
      expect(result.length, 2);
      expect(result.first.studentId, 101);
      expect(result.first.nom, 'KOUAME');
    });

    test('rankingProvider hors-ligne sans cache → liste vide (pas de crash)',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final result =
          await container.read(rankingProvider(qSubject).future);
      expect(result, isEmpty);
    });
  });
}
