// test/v19_real_backend_payload_test.dart
//
// [Fix-SYNC-LEVELS-CYCLES-EDT] V19 — le payload de ce test est le JSON
// RÉEL capturé sur le serveur desktop GeTech-SMS (branche
// feature/desktop-control-center, correctif registre sync appliqué) :
//
//   GET /api/v1/sync/pull?since=2000-01-01T00:00:00&reconcile=true
//   (FastAPI + SQLite, seed E2E factice — scripts/seed_e2e.py)
//
// Différences clés avec le payload v12 (AVANT correctif serveur) :
//   - `cycles` (2 lignes) et `levels` (2 lignes AVEC cycle_id) sont
//     désormais envoyés → le mobile peut résoudre le cycle d'une classe
//     depuis le SEUL pull initial ;
//   - `weekly_schedules` (1 ligne) au FORMAT RÉEL : class_subject_id +
//     day_of_week=0 (Lundi=0..Dimanche=6), PAS de week_type ;
//   - `levels` envoie `label` (pas `name`).
//
// Ce test prouve la chaîne complète sur des données serveur authentiques :
//   1. pull initial (aucun écran ouvert) ;
//   2. le cycle de la classe 1 (2nde A) est résolu → cycle 1 ;
//   3. hors-ligne : périodes DU cycle 1 uniquement (2 trimestres lycée,
//      PAS les semestres collège) ;
//   4. hors-ligne : EDT présent (créneau résolu via class_subjects :
//      classe 1 + matière 1 + enseignant 2, Lundi 08:00) ;
//   5. hors-ligne : évaluation + roster + note préexistante (18.0,
//      approuvée par l'admin côté serveur réel).
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
import 'package:getech_sms_mobile/features/schedule/schedule_controller.dart';
import 'package:getech_sms_mobile/shared/models/auth_dto.dart';

/// Chemin du payload réel capturé (généré par l'E2E serveur, hors dépôt).
const _payloadPath =
    '/home/z/my-project/scripts/e2e_pull_real.json';

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
    '[PAYLOAD RÉEL SERVEUR] pull → cycle résolu → périodes du cycle + EDT '
    '+ note préexistante, le tout hors-ligne sans pré-ouverture',
    () async {
    final raw = File(_payloadPath).readAsStringSync();
    final payload = jsonDecode(raw) as Map<String, dynamic>;

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // ── PHASE 1 : pull initial en ligne (AUCUN écran ouvert) ──
    final onlineDio = Dio(BaseOptions());
    onlineDio.interceptors.add(_PullOnlyInterceptor(payload));
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
    expect(pull.errors, isEmpty, reason: 'le pull réel doit être appliqué');

    // ── PHASE 2 : preuve Drift du cycle résolu ──
    final classroom1 = await (db.select(db.classrooms)
          ..where((t) => t.id.equals(1)))
        .getSingle();
    expect(classroom1.name, '2nde A');
    expect(classroom1.cycleId, 1,
        reason: 'le cycle doit être résolu via levels (payload réel)');

    final levels = await db.select(db.levels).get();
    expect(levels, hasLength(2), reason: 'levels doit être répliqué');
    expect(levels.first.name, 'Seconde',
        reason: 'le champ serveur `label` doit mapper vers name');

    // ── PHASE 3 : redémarrage hors-ligne (nouveau container) ──
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

    // Périodes DU cycle de la classe (lycée) : 2 trimestres, pas les
    // semestres du collège.
    final periods = await offline.read(periodsForClassroomProvider(1).future);
    expect(
      periods.map((p) => p.name),
      everyElement(contains('LYC')),
      reason: 'seules les périodes du cycle lycée doivent être proposées',
    );
    expect(periods, hasLength(2));

    // EDT : le créneau serveur (class_subject_id=1, Lundi, 08:00) doit être
    // résolu en classe 1 + matière Mathématiques + enseignant 2.
    final schedule = await offline.read(classroomScheduleProvider(1).future);
    expect(schedule, hasLength(1), reason: 'EDT répliqué depuis le pull');
    final course = schedule.single;
    expect(course.classroomId, 1);
    expect(course.subjectName, 'Mathématiques');
    expect(course.teacherId, 2,
        reason: 'teacherId résolu via class_subjects');
    expect(course.dayOfWeek, 1, reason: 'Lundi serveur (0) → mobile (1)');
    expect(course.startTime, '08:00');
    expect(course.isAllWeeks, isTrue,
        reason: 'sans week_type serveur → cours toutes les semaines');

    // Évaluation + roster + note préexistante (18.0 approuvée serveur).
    final assessments = await offline.read(
      assessmentsProvider(
        const AssessmentsQuery(classSubjectId: 1, periodId: 1),
      ).future,
    );
    expect(assessments.map((a) => a.name), ['Devoir 1 E2E']);

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
    expect(roster, hasLength(2), reason: 'roster complet hors-ligne');
    final noteApprouvee = roster.singleWhere((g) => g.studentId == 1);
    expect(noteApprouvee.value, 18.0,
        reason: 'la note approuvée côté serveur réel doit être visible');
  });
}
