// test/v23_real_edt_subjects_bulletin_test.dart
//
// [Fix-SYNC-REAL-EDT] + [Fix-SUBJECTS-OFFLINE] + [Fix-BULLETIN-OFFLINE] V23
// — retour utilisateur 2026-11-08 : « le dernier classement synchronisé
// s'affiche hors-ligne mais pas le dernier emploi du temps ; il faut aussi
// Matières et l'affichage des bulletins des élèves hors-ligne ».
//
// Scénario :
//   1. Pull complet EN LIGNE avec le VRAI EDT du serveur
//      (schedule_sessions + schedule_entries + time_slots — les tables que
//      l'éditeur écrit réellement) + matières + notes.
//   2. Coupure réseau SANS consultation préalable.
//   3. L'EDT d'une classe s'affiche depuis le cache (résolution
//      session→class_subject→classe/matière/enseignant et
//      time_slot→jour/horaires, salle de la session, semaine A/B).
//   4. La liste des matières est servie par Drift (recherche incluse).
//   5. Le bulletin de l'élève est recalculé : moyennes par matière
//      ((moy_classe + compo)/2), moyenne générale pondérée par coefficient,
//      rang avec ex-æquo, mention, évaluations détaillées.
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:getech_sms_mobile/core/auth/auth_state.dart';
import 'package:getech_sms_mobile/core/config/constants.dart' show WeekType;
import 'package:getech_sms_mobile/core/database/database.dart';
import 'package:getech_sms_mobile/core/network/dio_client.dart';
import 'package:getech_sms_mobile/core/sync/sync_engine.dart';
import 'package:getech_sms_mobile/features/connections/connection_state.dart';
import 'package:getech_sms_mobile/features/grades/grade_controller.dart';
import 'package:getech_sms_mobile/features/schedule/schedule_controller.dart';
import 'package:getech_sms_mobile/features/subjects/subject_controller.dart';
import 'package:getech_sms_mobile/shared/models/auth_dto.dart';

/// Dio qui ne connaît QUE /sync/pull ; tout le reste est « hors-ligne ».
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

Dio _alwaysOfflineDio() {
  final dio = Dio(BaseOptions());
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.reject(
        DioException.connectionError(
          requestOptions: options,
          reason: 'réseau coupé',
        ),
      ),
    ),
  );
  return dio;
}

class _FakeConnectionNotifier extends ConnectionNotifier {
  _FakeConnectionNotifier(super.ref);

  void forceOnline() {
    state = state.copyWith(
      status: ServerStatus.online,
      profileId: 'p-test',
      serverUrlOverride: 'http://192.168.1.10:8000/api/v1',
      establishmentCode: 'R23-01',
    );
  }

  void forceOffline() {
    state = state.copyWith(
      status: ServerStatus.offline,
      profileId: state.profileId ?? 'p-test',
      serverUrlOverride:
          state.serverUrlOverride ?? 'http://192.168.1.10:8000/api/v1',
      establishmentCode: state.establishmentCode ?? 'R23-01',
    );
  }
}

class _FakeAuthNotifier extends AuthNotifier {
  _FakeAuthNotifier(this.initial);
  final AuthState initial;

  @override
  AuthState build() => initial;
}

AuthState _adminState() => AuthState(
      user: const UserDto(id: 1, username: 'admin', role: 'ADMIN'),
      token: 'token',
      permissions: const ['*'],
    );

/// Payload : 1 classe, 2 matières (coeff 4 et 2), 1 élève, notes,
/// EDT RÉEL : time_slots + schedule_sessions + schedule_entries
/// (les tables que l'éditeur écrit — PAS weekly_schedules, vide).
const _pullJson = r'''
{
 "server_time": "2026-11-08T08:00:00",
 "max_offline_days": 7,
 "tables": {
  "establishments": {"rows": [{"id": 1, "code": "R23-01", "name": "Lycée V23"}], "ids": [1], "has_more": false},
  "school_years": {"rows": [{"id": 1, "establishment_id": 1, "school_year": "2026-2027", "is_active": true, "is_closed": false}], "ids": [1], "has_more": false},
  "periods": {"rows": [
    {"id": 1, "school_year_id": 1, "cycle_id": 1, "name": "Trimestre 1", "start_date": "2026-09-01", "end_date": "2026-12-18", "weight": 1.0, "is_active": true}
  ], "ids": [1], "has_more": false},
  "cycles": {"rows": [{"id": 1, "code": "LYC", "label": "Lycée", "is_active": true}], "ids": [1], "has_more": false},
  "levels": {"rows": [{"id": 1, "cycle_id": 1, "code": "2ND", "label": "Seconde", "is_active": true}], "ids": [1], "has_more": false},
  "classrooms": {"rows": [{"id": 1, "establishment_id": 1, "name": "2nde A", "level_id": 1, "head_teacher_id": 3, "max_students": 40, "is_active": true}], "ids": [1], "has_more": false},
  "subjects": {"rows": [
    {"id": 1, "establishment_id": 1, "name": "Mathématiques", "code": "MATH", "is_active": true},
    {"id": 2, "establishment_id": 1, "name": "Français", "code": "FR", "is_active": true}
  ], "ids": [1, 2], "has_more": false},
  "class_subjects": {"rows": [
    {"id": 1, "establishment_id": 1, "classroom_id": 1, "subject_id": 1, "school_year_id": 1, "coefficient": 4, "assigned_teacher_id": 2},
    {"id": 2, "establishment_id": 1, "classroom_id": 1, "subject_id": 2, "school_year_id": 1, "coefficient": 2, "assigned_teacher_id": 4}
  ], "ids": [1, 2], "has_more": false},
  "assessment_types": {"rows": [
    {"id": 1, "code": "DEVOIR", "name": "Devoir", "category": "CLASS"},
    {"id": 2, "code": "COMPO", "name": "Composition", "category": "EXAM"}
  ], "ids": [1, 2], "has_more": false},
  "assessments": {"rows": [
    {"id": 1, "class_subject_id": 1, "period_id": 1, "assessment_type_id": 1, "name": "Devoir 1", "max_score": 20.0, "date_taken": "2026-09-20"},
    {"id": 2, "class_subject_id": 1, "period_id": 1, "assessment_type_id": 2, "name": "Compo 1", "max_score": 20.0, "date_taken": "2026-10-01"},
    {"id": 3, "class_subject_id": 2, "period_id": 1, "assessment_type_id": 1, "name": "Dictée", "max_score": 10.0, "date_taken": "2026-09-25"}
  ], "ids": [1, 2, 3], "has_more": false},
  "grades": {"rows": [
    {"id": 1, "assessment_id": 1, "student_id": 1, "value": 12.0, "is_absent": false},
    {"id": 2, "assessment_id": 2, "student_id": 1, "value": 16.0, "is_absent": false},
    {"id": 3, "assessment_id": 3, "student_id": 1, "value": 8.0, "is_absent": false}
  ], "ids": [1, 2, 3], "has_more": false},
  "students": {"rows": [
    {"id": 1, "matricule": "MAT-001", "nom": "Alpha", "prenoms": "Jean", "sexe": "M", "deleted": false}
  ], "ids": [1], "has_more": false},
  "student_class_assignments": {"rows": [
    {"id": 1, "student_id": 1, "classroom_id": 1, "school_year_id": 1, "active": true}
  ], "ids": [1], "has_more": false},
  "time_slots": {"rows": [
    {"id": 1, "establishment_id": 1, "day_of_week": 1, "slot_order": 1, "start_time": "08:00:00", "end_time": "10:00:00", "label": "Cours 1", "is_break": false, "is_active": true},
    {"id": 2, "establishment_id": 1, "day_of_week": 3, "slot_order": 1, "start_time": "08:00:00", "end_time": "10:00:00", "label": "Cours 1", "is_break": false, "is_active": true},
    {"id": 3, "establishment_id": 1, "day_of_week": 1, "slot_order": 2, "start_time": "10:00:00", "end_time": "12:00:00", "label": "Cours 2", "is_break": false, "is_active": true}
  ], "ids": [1, 2, 3], "has_more": false},
  "weekly_schedules": {"rows": [], "ids": [], "has_more": false},
  "schedule_sessions": {"rows": [
    {"id": 1, "class_subject_id": 1, "school_year_id": 1, "room": "Salle 12", "is_active": true},
    {"id": 2, "class_subject_id": 2, "school_year_id": 1, "room": "Salle 7", "is_active": true},
    {"id": 3, "class_subject_id": 1, "school_year_id": 1, "room": "Salle 12", "is_active": false}
  ], "ids": [1, 2, 3], "has_more": false},
  "schedule_entries": {"rows": [
    {"id": 1, "session_id": 1, "time_slot_id": 1, "week_type": null, "is_active": true},
    {"id": 2, "session_id": 1, "time_slot_id": 2, "week_type": "B", "is_active": true},
    {"id": 3, "session_id": 2, "time_slot_id": 3, "week_type": null, "is_active": true},
    {"id": 4, "session_id": 3, "time_slot_id": 1, "week_type": null, "is_active": true}
  ], "ids": [1, 2, 3, 4], "has_more": false},
  "course_sessions": {"rows": [], "ids": [], "has_more": false},
  "student_absences": {"rows": [], "ids": [], "has_more": false},
  "users": {"rows": [
    {"id": 1, "username": "admin", "nom": "Direction", "prenoms": "Adm", "role": "admin", "is_active": true, "is_superuser": true},
    {"id": 2, "username": "m_dupont", "nom": "Dupont", "prenoms": "Marc", "role": "teacher", "is_active": true, "is_superuser": false},
    {"id": 3, "username": "titulaire", "nom": "Titu", "prenoms": "Léa", "role": "teacher", "is_active": true, "is_superuser": false},
    {"id": 4, "username": "m_durand", "nom": "Durand", "prenoms": "Sophie", "role": "teacher", "is_active": true, "is_superuser": false}
  ], "ids": [1, 2, 3, 4], "has_more": false},
  "user_establishments": {"rows": [
    {"id": 1, "user_id": 1, "establishment_id": 1, "role": "admin", "is_active": true},
    {"id": 2, "user_id": 2, "establishment_id": 1, "role": "teacher", "is_active": true},
    {"id": 3, "user_id": 3, "establishment_id": 1, "role": "teacher", "is_active": true},
    {"id": 4, "user_id": 4, "establishment_id": 1, "role": "teacher", "is_active": true}
  ], "ids": [1, 2, 3, 4], "has_more": false}
 }
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
      '[Fix-SYNC-REAL-EDT] pull du VRAI EDT (schedule_entries/sessions) → '
      'hors-ligne : la grille EDT de la classe se remplit (matière, salle, '
      'jour/horaires, semaine A/B) et l\'entrée désactivée est masquée',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // 1. Pull complet EN LIGNE.
    final payload = jsonDecode(_pullJson) as Map<String, dynamic>;
    final onlineDio = Dio(BaseOptions());
    onlineDio.interceptors.add(_PullOnlyInterceptor(payload));
    final online = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith((ref) => onlineDio),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(() => _FakeAuthNotifier(_adminState())),
      ],
    );
    addTearDown(online.dispose);
    (online.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOnline();
    final pull = await online.read(syncEngineProvider).pull();
    expect(pull.errors, isEmpty, reason: 'le pull doit réussir');

    // 2. Hors-ligne, sans consultation préalable de l'EDT en ligne.
    final offline = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith((ref) => _alwaysOfflineDio()),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(() => _FakeAuthNotifier(_adminState())),
      ],
    );
    addTearDown(offline.dispose);
    (offline.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOffline();

    // 3. EDT de la classe 1 depuis le cache Drift.
    final entries =
        await offline.read(classroomScheduleProvider(1).future);
    expect(entries.length, 3,
        reason: '3 entrées actives (entry 4 = session inactive → masquée)');

    final byId = {for (final e in entries) e.id: e};
    final e1 = byId[1]!;
    expect(e1.subjectName, 'Mathématiques',
        reason: 'matière résolue via session→class_subject');
    expect(e1.classroomName, '2nde A');
    expect(e1.room, 'Salle 12', reason: 'salle portée par la session');
    expect(e1.dayOfWeek, 1, reason: 'lundi via time_slot');
    expect(e1.startTime, '08:00');
    expect(e1.endTime, '10:00');
    expect(e1.isAllWeeks, isTrue, reason: 'week_type NULL → toutes semaines');

    // Semaine B : entrée 2 (maths mercredi, week_type B).
    final e2 = byId[2]!;
    expect(e2.dayOfWeek, 3, reason: 'mercredi');
    expect(e2.matchesWeek(WeekType.b), isTrue);
    expect(e2.matchesWeek(WeekType.a), isFalse);

    // Entrée 3 : français lundi 10:00-12:00, salle 7.
    final e3 = byId[3]!;
    expect(e3.subjectName, 'Français');
    expect(e3.dayOfWeek, 1);
    expect(e3.startTime, '10:00');
    expect(e3.room, 'Salle 7');

    // L'entrée 4 (session désactivée) ne doit PAS apparaître.
    expect(byId.containsKey(4), isFalse,
        reason: 'session is_active=false → entrée marquée supprimée');
  });

  test(
      '[Fix-SUBJECTS-OFFLINE] hors-ligne : la liste des matières (recherche '
      'incluse) et les matières d\'une classe sont servies par le cache Drift',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final payload = jsonDecode(_pullJson) as Map<String, dynamic>;
    final onlineDio = Dio(BaseOptions());
    onlineDio.interceptors.add(_PullOnlyInterceptor(payload));
    final online = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith((ref) => onlineDio),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(() => _FakeAuthNotifier(_adminState())),
      ],
    );
    addTearDown(online.dispose);
    (online.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOnline();
    await online.read(syncEngineProvider).pull();

    // Hors-ligne : les GET /subjects et /class-subjects sont coupés.
    final offline = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith((ref) => _alwaysOfflineDio()),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(() => _FakeAuthNotifier(_adminState())),
      ],
    );
    addTearDown(offline.dispose);
    (offline.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOffline();

    final subjects = await offline.read(subjectsListProvider('').future);
    expect(subjects.length, 2, reason: 'les 2 matières du cache Drift');
    expect(subjects.map((s) => s.name),
        containsAll(['Mathématiques', 'Français']));

    // Recherche insensible à la casse.
    final searched = await offline.read(subjectsListProvider('math').future);
    expect(searched.length, 1);
    expect(searched.first.name, 'Mathématiques');

    // Matières de la classe 1 (avec coefficients et enseignants résolus).
    final classSubjects =
        await offline.read(classSubjectsForClassroomProvider(1).future);
    expect(classSubjects.length, 2);
    final math =
        classSubjects.firstWhere((cs) => cs.subjectName == 'Mathématiques');
    expect(math.coefficient, 4);
    expect(math.assignedTeacherName, 'Dupont Marc',
        reason: 'enseignant résolu via users (convention NOM Prénoms)');
  });

  test(
      '[Fix-BULLETIN-OFFLINE] hors-ligne : le bulletin de l\'élève est '
      'recalculé (moyennes par matière (moy+compo)/2, générale pondérée, '
      'rang, mention, évaluations détaillées)',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final payload = jsonDecode(_pullJson) as Map<String, dynamic>;
    final onlineDio = Dio(BaseOptions());
    onlineDio.interceptors.add(_PullOnlyInterceptor(payload));
    final online = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith((ref) => onlineDio),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(() => _FakeAuthNotifier(_adminState())),
      ],
    );
    addTearDown(online.dispose);
    (online.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOnline();
    await online.read(syncEngineProvider).pull();

    final offline = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith((ref) => _alwaysOfflineDio()),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(() => _FakeAuthNotifier(_adminState())),
      ],
    );
    addTearDown(offline.dispose);
    (offline.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOffline();

    final bulletin = await offline.read(
      bulletinProvider(
        const BulletinQuery(studentId: 1, classroomId: 1, periodId: 1),
      ).future,
    );

    expect(bulletin.studentName, 'Alpha Jean');
    expect(bulletin.classroomName, '2nde A');
    expect(bulletin.periodName, 'Trimestre 1');
    expect(bulletin.rank, '1');
    expect(bulletin.totalStudents, 1);
    expect(bulletin.mention, isNotNull);

    // Math (coeff 4) : devoir 12 (CLASS) + compo 16 (EXAM) → (12+16)/2 = 14.
    final math = bulletin.subjects
        .firstWhere((s) => s.subjectName == 'Mathématiques');
    expect(math.moyenneClasse, closeTo(12.0, 0.01));
    expect(math.noteComposition, closeTo(16.0, 0.01));
    expect(math.average, closeTo(14.0, 0.01));
    expect(math.coefficient, 4);
    expect(math.assessments.length, 2,
        reason: 'devoir + compo détaillés sur le bulletin');
    expect(math.teacher, 'Dupont Marc');

    // Français (coeff 2) : dictée 8/10 → 16/20 (CLASS) → 16.
    final fr =
        bulletin.subjects.firstWhere((s) => s.subjectName == 'Français');
    expect(fr.average, closeTo(16.0, 0.01));

    // Moyenne générale = (14×4 + 16×2)/6 = 88/6 ≈ 14.67.
    expect(bulletin.overallAverage, closeTo(88 / 6, 0.01));
  });
}
