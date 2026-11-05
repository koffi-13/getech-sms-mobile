// test/v21_assessments_null_name_test.dart
//
// [Fix-SYNC-ASSESSMENT-NULL-NAME] V21 — régression du retour utilisateur
// du 2026-11-04 (2e itération) : « toujours rien » après le fix v1.0.2
// (pull complet forcé).
//
// Cause racine : l'UI desktop (main_page.py:9155) crée des évaluations avec
// `name = name_field.value.strip() or None` → une évaluation créée sans nom
// (ou par les duplications de période, main_page.py:9419) a `name = NULL`.
// Le modèle serveur l'autorise (`String(255), nullable=True`), mais côté
// mobile :
//   - sync_engine : `title: _rStrN(row, 'title') ?? _rStrN(row, 'name') ?? ''`
//     → titre VIDE ;
//   - Drift : `title => text().withLength(min: 1, max: 255)` ;
//   - → InvalidDataException « Must at least be 1 characters long » ;
//   - → fail-soft V11 par TABLE : TOUTE la table assessments est ignorée
//     (« Pull : table « assessments » ignorée ») → zéro évaluation hors-ligne.
//
// Les périodes fonctionnent (leur `name` serveur est NOT NULL) → symptôme
// asymétrique exact du retour terrain.
//
// Ce test verrouille, sur le payload RÉEL du serveur E2E augmenté d'une
// évaluation `name: null` (le chemin réel de l'UI desktop) :
//   1. la ligne à nom NULL ne fait PAS échouer la table entière ;
//   2. elle est répliquée avec un titre de repli non vide ;
//   3. les évaluations valides restent répliquées ;
//   4. hors-ligne, le provider en sert le nombre complet.
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
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

final String _payloadPath =
    File('test/fixtures/e2e_pull_real.json').existsSync()
        ? 'test/fixtures/e2e_pull_real.json'
        : '/home/z/my-project/scripts/e2e_pull_real.json';

class _PullOnlyInterceptor extends Interceptor {
  _PullOnlyInterceptor(this.payload);

  final Map<String, dynamic> payload;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.uri.path.contains('/sync/pull')) {
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
    '[V21] une évaluation « name: null » (chemin réel UI desktop) ne doit pas '
    'faire ignorer la table assessments entière',
    () async {
    final payload = jsonDecode(File(_payloadPath).readAsStringSync())
        as Map<String, dynamic>;

    // L'évaluation « sans nom » telle que l'UI desktop la crée
    // (main_page.py:9155 — `name_field.value.strip() or None`) : même
    // matière (cs 1), même période (1), name NULL. Le champ `ids` (ids
    // actifs serveur pour la réconciliation des suppressions) doit
    // inclure la nouvelle ligne, sinon la réconciliation la marquerait
    // « supprimée côté serveur ».
    (payload['tables']['assessments']['rows'] as List).add({
      'id': 2,
      'class_subject_id': 1,
      'period_id': 1,
      'assessment_type_id': null,
      'name': null,
      'max_score': 20.0,
      'is_counted_on_bulletin': true,
      'date_taken': '2026-10-20',
    });
    (payload['tables']['assessments']['ids'] as List).add(2);

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final dio = Dio(BaseOptions());
    dio.interceptors.add(_PullOnlyInterceptor(payload));
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith((ref) => dio),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(() => _FakeAuthNotifier(_teacherAuth())),
      ],
    );
    addTearDown(container.dispose);
    (container.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOnline();

    final pull = await container.read(syncEngineProvider).pull();

    // Le pull ne doit PAS signaler la table assessments comme ignorée
    // (l'échec batch est aujourd'hui silencieux — il ne doit juste plus
    // se produire : la ligne à nom NULL est sauvée par le repli de titre).
    expect(
      pull.errors.where((e) => e.contains('assessments')),
      isEmpty,
    );

    // Les DEUX évaluations doivent être en cache : la valide ET celle à nom
    // NULL (avec un titre de repli non vide).
    final rows = await db.select(db.assessments).get();
    expect(rows, hasLength(2),
        reason: 'la ligne à nom NULL ne doit pas sacrifier la table entière');
    expect(rows.any((r) => r.title == 'Devoir 1 E2E'), isTrue);
    final sansNom = rows.firstWhere((r) => r.id == 2);
    expect(sansNom.title, isNotEmpty,
        reason: 'le repli doit fournir un titre non vide (contrainte Drift '
            'min 1 caractère)');
    expect(sansNom.periodId, 1);

    // Hors-ligne : le provider sert les deux évaluations.
    final offline = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith(
          (ref) => Dio(BaseOptions(
            connectTimeout: const Duration(milliseconds: 50),
          )),
        ),
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
    expect(assessments, hasLength(2),
        reason: 'les deux évaluations doivent être visibles hors-ligne');
  });
}
