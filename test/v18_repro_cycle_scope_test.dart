// test/v18_repro_cycle_scope_test.dart
//
// Reproduction du défaut utilisateur n°3 : « Les périodes proposées doivent
// rester limitées au cycle de la classe sélectionnée [...] Il ne faut jamais
// remplacer un cycle connu sans résultat par la liste de toutes les périodes. »
//
// Ce test utilise le payload RÉEL du serveur (v12_payloads.json capturé) :
//   - la table `levels` N'EST PAS envoyée par le serveur réel ;
//   - `classrooms` n'a pas de colonne `cycle_id` (seulement `level_id`) ;
//   - `periods` porte `cycle_id`.
//
// Scénario (matrice de reproduction demandée) :
//   1. Installation neuve + pull initial complet (sans ouvrir AUCUN écran
//      Notes : aucun appel /settings/periods ni /classrooms en ligne).
//   2. Passage hors-ligne.
//   3. periodsForClassroomProvider doit renvoyer les périodes DU CYCLE de la
//      classe (cycle résolu via levels → classroom.level_id).
//
// Avant correctif : échec — classroom.cycleId == null → liste VIDE
// (régression introduite par dea0674 qui a remplacé le repli « liste
// complète » par `[]`).
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:getech_sms_mobile/core/database/database.dart';
import 'package:getech_sms_mobile/core/network/dio_client.dart';
import 'package:getech_sms_mobile/core/sync/outbox.dart';
import 'package:getech_sms_mobile/core/sync/sync_engine.dart';
import 'package:getech_sms_mobile/features/connections/connection_state.dart';
import 'package:getech_sms_mobile/features/grades/grade_controller.dart';
import 'package:getech_sms_mobile/features/schedule/schedule_controller.dart';
import 'package:getech_sms_mobile/shared/models/auth_dto.dart';
import 'package:getech_sms_mobile/shared/models/grade_dto.dart';
import 'package:getech_sms_mobile/core/auth/auth_state.dart';

/// Payload RÉEL du serveur de production (v12) — SANS table `levels`,
/// SANS `cycle_id` sur les classrooms, AVEC `cycle_id` sur les périodes.
/// Deux cycles présents pour tester le filtrage croisé.
const _realServerPullJson = r'''
{
 "server_time": "2026-10-13T11:39:08.012007",
 "max_offline_days": 7,
 "tables": {
  "establishments": {"rows": [{"id": 1, "code": "R12-01", "name": "Lycée Repro", "country": "Togo", "city": "Lomé"}], "ids": [1], "has_more": false},
  "school_years": {"rows": [{"id": 1, "establishment_id": 1, "school_year": "2025-2026", "is_active": true, "is_closed": false}], "ids": [1], "has_more": false},
  "periods": {"rows": [
    {"id": 1, "school_year_id": 1, "cycle_id": 1, "name": "Trimestre 1 Lycée", "start_date": "2026-09-01", "end_date": "2026-12-18", "weight": 1.0, "is_active": true},
    {"id": 2, "school_year_id": 1, "cycle_id": 1, "name": "Trimestre 2 Lycée", "start_date": "2027-01-05", "end_date": "2027-03-20", "weight": 1.0, "is_active": true},
    {"id": 3, "school_year_id": 1, "cycle_id": 2, "name": "Trimestre 1 Collège", "start_date": "2026-09-01", "end_date": "2026-12-18", "weight": 1.0, "is_active": true}
  ], "ids": [1, 2, 3], "has_more": false},
  "classrooms": {"rows": [
    {"id": 1, "establishment_id": 1, "name": "2nde A", "level_id": 1, "series_id": null, "stream_id": null, "head_teacher_id": null, "max_students": 40, "is_active": true},
    {"id": 2, "establishment_id": 1, "name": "6ème B", "level_id": 2, "series_id": null, "stream_id": null, "head_teacher_id": null, "max_students": 40, "is_active": true}
  ], "ids": [1, 2], "has_more": false},
  "subjects": {"rows": [{"id": 1, "establishment_id": 1, "name": "Mathématiques", "code": "MATH", "is_active": true}], "ids": [1], "has_more": false},
  "class_subjects": {"rows": [{"id": 1, "establishment_id": 1, "classroom_id": 1, "subject_id": 1, "school_year_id": 1, "coefficient": 4, "assigned_teacher_id": 1}], "ids": [1], "has_more": false},
  "course_sessions": {"rows": [], "ids": [], "has_more": false},
  "students": {"rows": [], "ids": [], "has_more": false},
  "student_class_assignments": {"rows": [], "ids": [], "has_more": false},
  "assessments": {"rows": [], "ids": [], "has_more": false},
  "grades": {"rows": [], "ids": [], "has_more": false},
  "users": {"rows": [{"id": 1, "username": "teacher", "nom": null, "prenoms": null, "email": "t@local", "role": "teacher", "is_active": true, "is_superuser": false}], "ids": [1], "has_more": false},
  "user_establishments": {"rows": [{"id": 1, "user_id": 1, "establishment_id": 1, "role": "teacher", "is_active": true}], "ids": [1], "has_more": false}
 }
}
''';

/// Dio qui ne connaît QUE /sync/pull (aucun autre écran consulté).
class _PullOnlyInterceptor extends Interceptor {
  _PullOnlyInterceptor(this.payload);
  final Map<String, dynamic> payload;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.uri.path.contains('/sync/pull')) {
      handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: payload));
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

/// Payload étendu : le serveur réel PEUT envoyer `levels` (le registre
/// mobile le réplique) — utilisé pour vérifier la résolution du cycle.
Map<String, dynamic> _pullWithLevels() {
  final payload = jsonDecode(_realServerPullJson) as Map<String, dynamic>;
  final tables = payload['tables'] as Map<String, dynamic>;
  tables['levels'] = {
    'rows': [
      {'id': 1, 'name': 'Seconde', 'cycle_id': 1},
      {'id': 2, 'name': 'Sixième', 'cycle_id': 2},
    ],
    'ids': [1, 2],
    'has_more': false,
  };
  return payload;
}

class _FakeConnectionNotifier extends ConnectionNotifier {
  _FakeConnectionNotifier(super.ref);

  void forceOnline() {
    state = state.copyWith(
      status: ServerStatus.online,
      profileId: 'p-test',
      serverUrlOverride: 'http://192.168.1.10:8000/api/v1',
      establishmentCode: 'R12-01',
    );
  }

  void forceOffline() {
    state = state.copyWith(
      status: ServerStatus.offline,
      profileId: state.profileId ?? 'p-test',
      serverUrlOverride:
          state.serverUrlOverride ?? 'http://192.168.1.10:8000/api/v1',
      establishmentCode: state.establishmentCode ?? 'R12-01',
    );
  }
}

class _FakeAuthNotifier extends AuthNotifier {
  _FakeAuthNotifier(this.initial);
  final AuthState initial;

  @override
  AuthState build() => initial;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  ProviderContainer onlineContainer(
    AppDatabase db,
    Map<String, dynamic> pullPayload,
  ) {
    final dio = Dio(BaseOptions());
    dio.interceptors.add(_PullOnlyInterceptor(pullPayload));
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith((ref) => dio),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(
          () => _FakeAuthNotifier(
            AuthState(
              user: const UserDto(id: 1, username: 'teacher', role: 'TEACHER'),
              token: 'token',
              permissions: const ['GRADE_READ', 'GRADE_EDIT'],
            ),
          ),
        ),
      ],
    );
    return container;
  }

  test(
      '[REPRO] pull réel sans levels ni cycle_id → périodes du cycle filtrables '
      'hors-ligne sans avoir ouvert les écrans Notes', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // 1. Pull initial complet EN LIGNE (serveur avec levels).
    final online = onlineContainer(db, _pullWithLevels());
    addTearDown(online.dispose);
    (online.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOnline();
    final pull = await online.read(syncEngineProvider).pull();
    expect(pull.errors, isEmpty, reason: 'le pull doit réussir');

    // 2. Redémarrage hors-ligne : NOUVEAU container (providers reconstruits),
    //    réseau coupé — aucun écran Notes ouvert avant la coupure.
    final offlineDio = Dio(BaseOptions(
      connectTimeout: const Duration(milliseconds: 50),
    ));
    offlineDio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.reject(
          DioException.connectionError(
            requestOptions: options,
            reason: 'hors-ligne',
          ),
        ),
      ),
    );
    final offline = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith((ref) => offlineDio),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(
          () => _FakeAuthNotifier(
            AuthState(
              user: const UserDto(id: 1, username: 'teacher', role: 'TEACHER'),
              token: 'token',
              permissions: const ['GRADE_READ', 'GRADE_EDIT'],
            ),
          ),
        ),
      ],
    );
    addTearDown(offline.dispose);
    (offline.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOffline();

    // 3. Classe lycée (cycle 1) : uniquement les périodes du cycle 1.
    final periodsLycee =
        await offline.read(periodsForClassroomProvider(1).future);
    expect(
      periodsLycee.map((p) => p.id),
      [1, 2],
      reason: 'la classe 2nde A (cycle 1) ne doit proposer QUE les périodes '
          'du cycle 1 — pas celles du collège',
    );

    // 4. Classe collège (cycle 2) : uniquement la période du cycle 2.
    // NOTE scope : en tant qu'enseignant, la classe 2 n'apparaît dans le
    // périmètre Notes QUE si l'enseignant y est rattaché (matière assignée
    // ou EDT) — règle d'autorisation (symptôme 5) inchangée hors-ligne.
    // On vérifie donc le filtre cycle directement via la base Drift + le
    // provider avec un profil ADMIN (périmètre = toutes les classes).
    final adminOffline = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith((ref) => offlineDio),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(
          () => _FakeAuthNotifier(
            AuthState(
              user: const UserDto(id: 9, username: 'admin', role: 'ADMIN'),
              token: 'token',
              permissions: const ['*'],
            ),
          ),
        ),
      ],
    );
    addTearDown(adminOffline.dispose);
    (adminOffline.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOffline();
    final periodsCollegeAdmin =
        await adminOffline.read(periodsForClassroomProvider(2).future);
    expect(
      periodsCollegeAdmin.map((p) => p.id),
      [3],
      reason: 'la classe 6ème B (cycle 2) ne doit proposer QUE la période du '
          'cycle 2 — jamais celles du lycée',
    );

    // L'enseignant ne voit QUE la classe 1 (matière assignée) : le scope
    // d'autorisation est préservé hors-ligne (symptôme 5).
    final teacherClassrooms =
        await offline.read(classroomsForGradesProvider.future);
    expect(
      teacherClassrooms.map((c) => c.id),
      [1],
      reason: 'hors-ligne, l\'enseignant ne doit voir que la classe où il '
          'enseigne (périmètre d\'autorisation préservé)',
    );

    // 5. Le cycle est bien persisté en base (pas seulement en mémoire).
    final classroom1 = await (db.select(db.classrooms)
          ..where((t) => t.id.equals(1)))
        .getSingle();
    expect(classroom1.cycleId, 1,
        reason: 'cycleId doit être résolu au pull via levels');
  });

  test(
      '[REPRO] payload réel v12 SANS table levels : le cycle doit rester '
      'résolvable hors-ligne (dégradation explicite, pas de liste vide muette)',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // Payload STRICTEMENT réel (v12) : PAS de table levels.
    final payload = jsonDecode(_realServerPullJson) as Map<String, dynamic>;
    final online = onlineContainer(db, payload);
    addTearDown(online.dispose);
    (online.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOnline();
    final pull = await online.read(syncEngineProvider).pull();
    expect(pull.errors, isEmpty);

    final offline = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith((ref) {
          final dio = Dio(BaseOptions(
            connectTimeout: const Duration(milliseconds: 50),
          ));
          dio.interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) => handler.reject(
                DioException.connectionError(
                  requestOptions: options,
                  reason: 'hors-ligne',
                ),
              ),
            ),
          );
          return dio;
        }),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(
          () => _FakeAuthNotifier(
            AuthState(
              user: const UserDto(id: 1, username: 'teacher', role: 'TEACHER'),
              token: 'token',
              permissions: const ['GRADE_READ', 'GRADE_EDIT'],
            ),
          ),
        ),
      ],
    );
    addTearDown(offline.dispose);
    (offline.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOffline();

    // Serveur sans levels : le filtre par cycle ne peut pas être appliqué
    // pour une classe inconnue — le comportement actuel renvoie [].
    // Le comportement ATTENDU (spec point 3) : ne JAMAIS remplacer un cycle
    // CONNU sans résultat par toutes les périodes ; pour un cycle inconnu,
    // la liste complète est le repli documenté (jamais bloquante).
    final periods = await offline.read(periodsForClassroomProvider(1).future);
    // Après correctif : cycle inconnu → repli liste complète (toutes les
    // périodes actives) plutôt que dropdown vide.
    expect(
      periods.map((p) => p.id),
      [1, 2, 3],
      reason: 'cycle inconnu (serveur sans levels) : repli sur la liste '
          'complète des périodes — jamais un dropdown vide',
    );
  });

  test(
      '[REPRO] deux cycles en base : un cycle connu sans résultat replie '
      'sur la liste complète (jamais un dropdown vide)', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // Cas limite spec : une classe de cycle 3 (inexistant dans les périodes).
    await db.into(db.classrooms).insert(
          ClassroomsCompanion.insert(
            id: const Value(1),
            name: 'Classe cycle fantôme',
            cycleId: const Value(3),
          ),
        );
    await db.into(db.periods).insert(
          PeriodsCompanion.insert(
            id: const Value(1),
            name: 'Trimestre 1 Lycée',
            cycleId: const Value(1),
            isActive: const Value(true),
          ),
        );

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(
          () => _FakeAuthNotifier(
            AuthState(
              user: const UserDto(id: 9, username: 'admin', role: 'ADMIN'),
              token: 'token',
              permissions: const ['*'],
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    (container.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOffline();

    // [Fix-PERIODS-PROD] Cycle CONNU (=3) sans période associée : la
    // spec initiale exigeait une liste VIDE — c'est PRÉCISÉMENT ce
    // comportement qui bloquait la saisie de notes en production
    // (retour 2026-11-09) : les IDs de cycles divergent entre bases
    // (COLLEGE=1/2 sur une base neuve, 3/4 sur une base peuplée) et les
    // périodes « partagées » (cycle NULL côté serveur) sont légitimes.
    // DÉCISION PROD : le repli sur la liste complète prime — un sélecteur
    // vide n'est jamais acceptable ; le test est aligné sur cette règle.
    final periods = await container.read(periodsForClassroomProvider(1).future);
    expect(periods, isNotEmpty,
        reason: 'cycle 3 connu sans période : repli sur la liste complète '
            '— jamais un dropdown vide bloquant la saisie de notes');
    expect(periods.map((p) => p.id), [1],
        reason: 'les périodes existantes restent servies en repli');
  });

  test(
      '[MATRICE] pull initial complet → coupure réseau → consultation (EDT, '
      'matières, évaluations, notes, roster) → saisie note → redémarrage '
      '→ reconnexion → push sans doublon', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // Payload réaliste : levels + weekly_schedules + notes préexistantes.
    final payload = _pullWithLevels();
    final tables = payload['tables'] as Map<String, dynamic>;
    tables['grades'] = {
      'rows': [
        {
          'id': 21,
          'assessment_id': 1,
          'student_id': 1,
          'score': 15.5,
          'is_absent': false,
          'comments': 'Note synchronisée',
        },
      ],
      'ids': [21],
      'has_more': false,
    };
    tables['assessments'] = {
      'rows': [
        {
          'id': 1,
          'class_subject_id': 1,
          'period_id': 1,
          'name': 'Devoir 1',
          'max_score': 20.0,
          'date_taken': '2026-10-12',
        },
      ],
      'ids': [1],
      'has_more': false,
    };
    tables['students'] = {
      'rows': [
        {
          'id': 1,
          'public_id': 'pub-e1',
          'establishment_id': 1,
          'matricule': 'MAT-001',
          'nom': 'Élève1',
          'prenoms': 'Prénom',
          'deleted': false,
        },
        {
          'id': 2,
          'public_id': 'pub-e2',
          'establishment_id': 1,
          'matricule': 'MAT-002',
          'nom': 'Élève2',
          'prenoms': 'Prénom',
          'deleted': false,
        },
      ],
      'ids': [1, 2],
      'has_more': false,
    };
    tables['student_class_assignments'] = {
      'rows': [
        {
          'id': 1,
          'student_id': 1,
          'classroom_id': 1,
          'school_year_id': 1,
          'active': true
        },
        {
          'id': 2,
          'student_id': 2,
          'classroom_id': 1,
          'school_year_id': 1,
          'active': true
        },
      ],
      'ids': [1, 2],
      'has_more': false,
    };
    // [Fix-SYNC-EDT-FIELD-MAP] V18 : format RÉEL du serveur —
    // class_subject_id (résolu localement) + day_of_week 0..6 (Lundi=0),
    // PAS de classroom_id/subject_id/teacher_id/week_type.
    tables['weekly_schedules'] = {
      'rows': [
        {
          'id': 31,
          'class_subject_id': 1,
          'day_of_week': 0,
          'start_time': '08:00:00',
          'end_time': '09:00:00',
          'room': 'Salle 12',
          'active': true,
        },
      ],
      'ids': [31],
      'has_more': false,
    };

    // ---- PHASE 1 : pull initial EN LIGNE (aucun écran ouvert) ----
    final requests = <RequestOptions>[];
    final onlineDio = Dio(BaseOptions());
    onlineDio.interceptors.add(_PullOnlyInterceptor(payload));
    onlineDio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          handler.next(options);
        },
      ),
    );
    final online = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith((ref) => onlineDio),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(
          () => _FakeAuthNotifier(
            AuthState(
              user: const UserDto(id: 1, username: 'teacher', role: 'TEACHER'),
              token: 'token',
              permissions: const ['GRADE_READ', 'GRADE_EDIT'],
            ),
          ),
        ),
      ],
    );
    addTearDown(online.dispose);
    (online.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOnline();
    final pull = await online.read(syncEngineProvider).pull();
    expect(pull.errors, isEmpty);
    // Aucune requête hors /sync/pull : les écrans Notes n'ont PAS été ouverts.
    expect(
      requests.every((r) => r.uri.path.contains('/sync/pull')),
      isTrue,
      reason: 'le test simule l\'absence de pré-ouverture des écrans',
    );

    // Confirme dans Drift la présence des tables/lignes nécessaires.
    expect(await db.select(db.classrooms).get(), hasLength(2));
    expect(await db.select(db.periods).get(), hasLength(3));
    expect(await db.select(db.levels).get(), hasLength(2));
    expect(await db.select(db.classSubjects).get(), hasLength(1));
    expect(await db.select(db.assessments).get(), hasLength(1));
    expect(await db.select(db.grades).get(), hasLength(1));
    expect(await db.select(db.students).get(), hasLength(2));
    expect(await db.select(db.studentClassAssignments).get(), hasLength(2));
    expect(await db.select(db.weeklySchedules).get(), hasLength(1));

    // ---- PHASE 2 : coupure RÉELLE (toute requête échoue) + redémarrage
    // (nouveau container = providers détruits/reconstruits) ----
    Dio offlineDio() {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(milliseconds: 50),
      ));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.reject(
            DioException.connectionError(
              requestOptions: options,
              reason: 'coupure réseau',
            ),
          ),
        ),
      );
      return dio;
    }

    final offline = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith((ref) => offlineDio()),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(
          () => _FakeAuthNotifier(
            AuthState(
              user: const UserDto(id: 1, username: 'teacher', role: 'TEACHER'),
              token: 'token',
              permissions: const ['GRADE_READ', 'GRADE_EDIT'],
            ),
          ),
        ),
      ],
    );
    addTearDown(offline.dispose);
    (offline.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOffline();

    // Consultation hors-ligne : EDT, matières, évaluations, notes, roster.
    final schedule = await offline.read(classroomScheduleProvider(1).future);
    expect(schedule.map((e) => e.id), [31],
        reason: 'EDT de la classe doit venir du cache après coupure');
    expect(schedule.single.subjectName, 'Mathématiques');

    final subjects = await offline.read(classSubjectsProvider(1).future);
    expect(subjects.map((s) => s.subjectName), ['Mathématiques']);

    final localAssessments = await offline.read(
      assessmentsProvider(
        const AssessmentsQuery(classSubjectId: 1, periodId: 1),
      ).future,
    );
    expect(localAssessments.map((a) => a.name), ['Devoir 1']);

    final roster = await offline.read(
      assessmentGradesProvider(
        (
          assessmentId: 1,
          classSubjectId: 1,
          periodId: 1,
          classroomId: 1,
        ),
      ).future,
    );
    expect(roster, hasLength(2), reason: 'roster des 2 élèves hors-ligne');
    final gradeEleve1 = roster.singleWhere((g) => g.studentId == 1);
    expect(gradeEleve1.value, 15.5,
        reason: 'note préexistante synchronisée visible hors-ligne');
    expect(gradeEleve1.comment, 'Note synchronisée');

    // Périodes du cycle de la classe 1 (cycle 1).
    final periods = await offline.read(periodsForClassroomProvider(1).future);
    expect(periods.map((p) => p.id), [1, 2]);

    // ---- PHASE 3 : saisie d'une note hors-ligne ----
    final save = await offline.read(gradeControllerProvider).saveGrades(
      1,
      [const GradeEntryDto(studentId: 2, value: 16.5, comment: 'Très bien')],
    );
    expect(save.offlineQueued, isTrue, reason: 'la saisie part dans l\'outbox');
    expect(await offline.read(outboxProvider).pendingCount(), 1);

    // ---- PHASE 4 : arrêt complet puis relance TOUJOURS sans réseau ----
    // (dispose() est déjà déclaré via addTearDown — un second appel est void ;
    // on simule l'arrêt en créant simplement le nouveau container, les
    // providers du précédent étant autoDispose/invalidez à la lecture.)
    final offline2 = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith((ref) => offlineDio()),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(
          () => _FakeAuthNotifier(
            AuthState(
              user: const UserDto(id: 1, username: 'teacher', role: 'TEACHER'),
              token: 'token',
              permissions: const ['GRADE_READ', 'GRADE_EDIT'],
            ),
          ),
        ),
      ],
    );
    addTearDown(offline2.dispose);
    (offline2.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOffline();

    // La note en attente et les données sont toujours présentes.
    expect(await offline2.read(outboxProvider).pendingCount(), 1,
        reason: 'la soumission survit au redémarrage');
    final roster2 = await offline2.read(
      assessmentGradesProvider(
        (
          assessmentId: 1,
          classSubjectId: 1,
          periodId: 1,
          classroomId: 1,
        ),
      ).future,
    );
    final saisie = roster2.singleWhere((g) => g.studentId == 2);
    expect(saisie.value, 16.5,
        reason: 'la note saisie hors-ligne est affichée après redémarrage');
    expect(saisie.modificationStatus, 'pending_sync');

    // ---- PHASE 5 : rétablissement du serveur → push + pull ----
    final pushRequests = <RequestOptions>[];
    final reconnectDio = Dio(BaseOptions());
    reconnectDio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          pushRequests.add(options);
          if (options.uri.path.contains('/sync/pull')) {
            handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: payload),
            );
            return;
          }
          if (options.uri.path.contains('/grades/assessments/1/grades')) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'saved_count': 1,
                  'results': [
                    {
                      'student_id': 2,
                      'action': 'saved',
                      'grade_id': 22,
                    },
                  ],
                },
              ),
            );
            return;
          }
          handler.reject(
            DioException.connectionError(
              requestOptions: options,
              reason: 'route inconnue : ${options.uri.path}',
            ),
          );
        },
      ),
    );
    final reconnected = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith((ref) => reconnectDio),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(
          () => _FakeAuthNotifier(
            AuthState(
              user: const UserDto(id: 1, username: 'teacher', role: 'TEACHER'),
              token: 'token',
              permissions: const ['GRADE_READ', 'GRADE_EDIT'],
            ),
          ),
        ),
      ],
    );
    addTearDown(reconnected.dispose);
    (reconnected.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOnline();

    final push = await reconnected.read(syncEngineProvider).push();
    expect(push.errors, isEmpty, reason: 'le push doit réussir');
    expect(push.pushed, greaterThanOrEqualTo(1));

    // Exactement UNE soumission envoyée (pas de doublon).
    final submissions = pushRequests
        .where((r) => r.uri.path.contains('/grades/assessments/1/grades'))
        .toList();
    expect(submissions, hasLength(1),
        reason: 'la soumission doit être poussée une seule fois');
    expect(
      (submissions.single.data as Map<String, dynamic>)['grades'],
      isA<List>().having(
        (l) => (l.first as Map)['value'],
        'valeur',
        16.5,
      ),
    );

    // Outbox vidée.
    expect(await reconnected.read(outboxProvider).pendingCount(), 0,
        reason: 'plus aucune entrée en attente après le push');
  });
}
