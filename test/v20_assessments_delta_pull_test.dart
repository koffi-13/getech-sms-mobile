// test/v20_assessments_delta_pull_test.dart
//
// [Fix-SYNC-CACHE-VERSION-DELTA] V20 — régression du retour utilisateur :
// « les périodes se chargent hors-ligne mais PAS les évaluations » après
// installation de la nouvelle APK PAR-DESSUS l'ancienne (même signature,
// données Drift conservées).
//
// Scénario exact de l'appareil (AVANT ce correctif) :
//   - l'ancienne APK (e1e07ef, qui contenait DÉJÀ _mobileCacheVersion = 3
//     introduit à dea0674) avait synchronisé : syncMetadata portait le
//     marqueur '__mobile_cache_version__' avec lastCount = 3 et un
//     lastSyncedAt RÉCENT ;
//   - la nouvelle APK lit « lastCount == 3 == _mobileCacheVersion » → pull
//     DELTA (since = dernier lastSyncedAt) ;
//   - le serveur filtre `updated_at > since` → les évaluations créées il y
//     a longtemps (jamais modifiées) ne sont JAMAIS renvoyées ;
//   - les périodes/cycles s'affichaient car l'ancienne app les répliquait
//     déjà localement (cache conservé) → symptôme asymétrique.
//
// Le correctif : bump _mobileCacheVersion 3 → 4 → tout appareil venant
// d'une APK antérieure force un pull COMPLET (since = 2000-01-01).
//
// Ce test verrouille :
//   1. un appareil « ancienne APK » (marqueur v3 + curseur récent + cache
//      périodes présent mais ZÉRO évaluation) ;
//   2. un pull avec un serveur qui renvoie le payload complet (le pull
//      forcé le demande : since=2000) ;
//   3. hors-ligne : les évaluations apparaissent (et la note préexistante).
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value, InsertMode;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:getech_sms_mobile/core/auth/auth_state.dart';
import 'package:getech_sms_mobile/core/database/database.dart';
import 'package:getech_sms_mobile/core/network/dio_client.dart';
import 'package:getech_sms_mobile/core/sync/sync_engine.dart';
import 'package:getech_sms_mobile/features/connections/connection_state.dart';
import 'package:getech_sms_mobile/features/grades/grade_controller.dart';
import 'package:getech_sms_mobile/shared/models/auth_dto.dart';

/// Payload réel capturé (même fixture que v19).
final String _payloadPath = File('test/fixtures/e2e_pull_real.json').existsSync()
    ? 'test/fixtures/e2e_pull_real.json'
    : '/home/z/my-project/scripts/e2e_pull_real.json';

/// Intercepteur qui journalise le paramètre `since` puis sert le payload
/// complet (comportement réel du serveur : delta vide si since récent).
class _LoggingPullInterceptor extends Interceptor {
  _LoggingPullInterceptor(this.payload);

  final Map<String, dynamic> payload;
  final List<String> sinceValues = [];

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.uri.path.contains('/sync/pull')) {
      sinceValues.add(options.uri.queryParameters['since']?.toString() ?? '');
      handler.resolve(
        Response(requestOptions: options, statusCode: 200, data: payload),
      );
      return;
    }
    handler.reject(
      DioException.connectionError(
        requestOptions: options,
        reason: 'hors-ligne : ${options.uri.path}',
      ),
    );
  }
}

class _FakeConnectionNotifier extends ConnectionNotifier {
  _FakeConnectionNotifier(super.ref);

  void forceOnline() {
    state = state.copyWith(
      status: ServerStatus.online,
      profileId: 'p-e2e',
      serverUrlOverride: 'http://127.0.0.1:8010/api/v1',
      establishmentCode: 'E2E-01',
      pairingToken: 'e2e-token',
    );
  }

  void forceOffline() {
    state = state.copyWith(
      status: ServerStatus.offline,
      profileId: state.profileId ?? 'p-e2e',
      serverUrlOverride:
          state.serverUrlOverride ?? 'http://127.0.0.1:8010/api/v1',
      establishmentCode: state.establishmentCode ?? 'E2E-01',
      pairingToken: state.pairingToken ?? 'e2e-token',
    );
  }
}

class _FakeAuthNotifier extends AuthNotifier {
  _FakeAuthNotifier(this.initial);
  final AuthState initial;

  @override
  AuthState build() => initial;
}

AuthState _teacherAuth() => AuthState(
      user: const UserDto(id: 2, username: 'e2e_teacher', role: 'TEACHER'),
      token: 'token',
      permissions: const ['GRADE_READ', 'GRADE_EDIT'],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    '[V20] appareil « ancienne APK » (marqueur v3 + curseur récent) → pull '
    'forcé complet → évaluations hors-ligne',
    () async {
    final raw = File(_payloadPath).readAsStringSync();
    final payload = jsonDecode(raw) as Map<String, dynamic>;

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // ── PHASE 1 : simuler l'état laissé par l'ANCIENNE APK ──
    // (a) marqueur de version 3 + curseur « il y a une heure » : c'est ce
    //     que tout appareil ayant synchronisé avec e1e07ef porte en base ;
    // (b) cache périodes RÉPLIQUÉ par l'ancienne app (elle savait le faire)
    //     → c'est pourquoi les périodes s'affichaient déjà hors-ligne ;
    // (c) table assessments VIDE (le bug d'origine de l'ancienne app).
    final ancienCurseur = DateTime.now().subtract(const Duration(hours: 1));
    await (db.into(db.syncMetadata).insert(
          SyncMetadataCompanion.insert(
            tableNameColumn: '__mobile_cache_version__',
            lastSyncedAt: Value(ancienCurseur),
            lastCount: const Value(3), // version de l'ancienne APK
          ),
          mode: InsertMode.insertOrReplace,
        ));
    for (final row in payload['tables']['periods']['rows']
        as List<dynamic>) {
      await (db.into(db.periods).insert(
            PeriodsCompanion.insert(
              id: Value((row['id'] as num).toInt()),
              name: row['name'] as String,
              cycleId: Value(
                (row['cycle_id'] as num?)?.toInt(),
              ),
              syncedAt: Value(ancienCurseur),
            ),
            mode: InsertMode.insertOrReplace,
          ));
    }
    final assessmentsAvant = await db.select(db.assessments).get();
    expect(assessmentsAvant, isEmpty,
        reason: 'précondition : ancienne APK, zéro évaluation en cache');

    // ── PHASE 2 : pull avec la nouvelle APK (serveur = payload complet) ──
    final onlineDio = Dio(BaseOptions());
    final interceptor = _LoggingPullInterceptor(payload);
    onlineDio.interceptors.add(interceptor);
    final online = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith((ref) => onlineDio),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(() => _FakeAuthNotifier(_teacherAuth())),
      ],
    );
    addTearDown(online.dispose);
    (online.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOnline();
    final pull = await online.read(syncEngineProvider).pull();
    expect(pull.errors, isEmpty, reason: 'le pull doit aboutir');

    // Le cœur du correctif : le since envoyé doit être 2000-01-01 (pull
    // complet forcé car le marqueur local 3 ≠ _mobileCacheVersion 4), PAS
    // le curseur récent de l'ancienne APK (delta vide côté serveur).
    expect(interceptor.sinceValues, isNotEmpty);
    expect(
      interceptor.sinceValues.first,
      startsWith('2000-01-01'),
      reason: 'la version de cache a changé → pull COMPLET forcé',
    );

    // ── PHASE 3 : hors-ligne, les évaluations doivent être là ──
    final rows = await db.select(db.assessments).get();
    expect(rows, isNotEmpty,
        reason: 'les évaluations doivent être répliquées par le pull forcé');
    expect(rows.first.title, 'Devoir 1 E2E');

    // Et le marqueur doit maintenant porter la nouvelle version.
    final marqueur = await (db.select(db.syncMetadata)
          ..where((t) => t.tableNameColumn
              .equals('__mobile_cache_version__')))
        .getSingle();
    expect(marqueur.lastCount, 4,
        reason: 'le marqueur doit être passé à la version 4');

    // ── PHASE 4 : le repli provider hors-ligne sert les évaluations ──
    final offlineDio = Dio(BaseOptions(
      connectTimeout: const Duration(milliseconds: 50),
    ));
    offlineDio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.reject(
          DioException.connectionError(
            requestOptions: options,
            reason: 'coupure réseau',
          ),
        ),
      ),
    );
    final offline = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith((ref) => offlineDio),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(() => _FakeAuthNotifier(_teacherAuth())),
      ],
    );
    addTearDown(offline.dispose);
    (offline.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOffline();

    final assessments = await offline.read(
      assessmentsProvider(
        const AssessmentsQuery(classSubjectId: 1, periodId: 1),
      ).future,
    );
    expect(assessments.map((a) => a.name), ['Devoir 1 E2E'],
        reason: 'évaluation visible hors-ligne après pull forcé');
  });
}
