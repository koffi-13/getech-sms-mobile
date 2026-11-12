// test/v22_offline_ranking_attendance_test.dart
//
// [Fix-RANKING-OFFLINE] + [Fix-ATTENDANCE-REVIEW] + [Fix-EDT-TEACHERS-OFFLINE]
// V22 — chaîne complète hors-ligne, retour utilisateur 2026-11-07 :
// « il reste le classement et l'emploi du temps qui doivent s'afficher
// hors-ligne ; les admins ne saisissent pas de présence mais affichent
// les présences des autres ».
//
// Scénario :
//   1. Installation neuve + pull complet EN LIGNE. Le serveur envoie
//      désormais `assessment_types` (référentiel CLASS/EXAM), les notes,
//      les sessions de cours et les absences.
//   2. Passage hors-ligne SANS avoir consulté le classement ni les
//      présences en ligne (aucun cache SharedPreferences d'écrit).
//   3. Le classement se RECALCULE depuis Drift avec la même formule que
//      le serveur : moyenne_matière = (moyenne_classe + composition) / 2,
//      pondérée par le coefficient de matière ; ex-æquo avec lettres ;
//      périodes précédentes + moyenne annuelle pondérée par Period.weight.
//   4. La consultation des présences (admins) liste les sessions avec
//      classe/matière/enseignant RÉSOLUS (course_sessions portait
//      class_subject_id) et le décompte d'absences.
//   5. Le dropdown « Par enseignant » de l'EDT est servi hors-ligne
//      (users.role répliqué).
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:getech_sms_mobile/core/auth/auth_state.dart';
import 'package:getech_sms_mobile/core/database/database.dart';
import 'package:getech_sms_mobile/core/network/dio_client.dart';
import 'package:getech_sms_mobile/core/sync/sync_engine.dart';
import 'package:getech_sms_mobile/features/attendance/attendance_review_controller.dart';
import 'package:getech_sms_mobile/features/connections/connection_state.dart';
import 'package:getech_sms_mobile/features/grades/grade_controller.dart';
import 'package:getech_sms_mobile/features/users/user_controller.dart';
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
      establishmentCode: 'R22-01',
    );
  }

  void forceOffline() {
    state = state.copyWith(
      status: ServerStatus.offline,
      profileId: state.profileId ?? 'p-test',
      serverUrlOverride:
          state.serverUrlOverride ?? 'http://192.168.1.10:8000/api/v1',
      establishmentCode: state.establishmentCode ?? 'R22-01',
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

/// Payload complet : 2 périodes, 1 classe, 2 matières (coeff 4 et 2),
/// 3 élèves, évaluations CLASS/EXAM (types DEVOIR + COMPO), notes,
/// sessions + absences, users avec rôle.
const _pullJson = r'''
{
 "server_time": "2026-11-07T08:00:00",
 "max_offline_days": 7,
 "tables": {
  "establishments": {"rows": [{"id": 1, "code": "R22-01", "name": "Lycée V22"}], "ids": [1], "has_more": false},
  "school_years": {"rows": [{"id": 1, "establishment_id": 1, "school_year": "2026-2027", "is_active": true, "is_closed": false}], "ids": [1], "has_more": false},
  "periods": {"rows": [
    {"id": 1, "school_year_id": 1, "cycle_id": 1, "name": "Trimestre 1", "weight": 1.0, "is_active": true},
    {"id": 2, "school_year_id": 1, "cycle_id": 1, "name": "Trimestre 2", "weight": 2.0, "is_active": false}
  ], "ids": [1, 2], "has_more": false},
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
    {"id": 3, "class_subject_id": 2, "period_id": 1, "assessment_type_id": 1, "name": "Dictée", "max_score": 10.0, "date_taken": "2026-09-25"},
    {"id": 4, "class_subject_id": 1, "period_id": 2, "assessment_type_id": 1, "name": "Devoir T2", "max_score": 20.0, "date_taken": "2026-11-05"}
  ], "ids": [1, 2, 3, 4], "has_more": false},
  "grades": {"rows": [
    {"id": 1, "assessment_id": 1, "student_id": 1, "value": 12.0, "is_absent": false},
    {"id": 2, "assessment_id": 2, "student_id": 1, "value": 16.0, "is_absent": false},
    {"id": 3, "assessment_id": 3, "student_id": 1, "value": 8.0, "is_absent": false},
    {"id": 4, "assessment_id": 1, "student_id": 2, "value": 12.0, "is_absent": false},
    {"id": 5, "assessment_id": 2, "student_id": 2, "value": 16.0, "is_absent": false},
    {"id": 6, "assessment_id": 3, "student_id": 2, "value": 8.0, "is_absent": false},
    {"id": 7, "assessment_id": 4, "student_id": 1, "value": 18.0, "is_absent": false},
    {"id": 8, "assessment_id": 4, "student_id": 3, "value": 14.0, "is_absent": false}
  ], "ids": [1, 2, 3, 4, 5, 6, 7, 8], "has_more": false},
  "students": {"rows": [
    {"id": 1, "matricule": "MAT-001", "nom": "Alpha", "prenoms": "Jean", "sexe": "M", "deleted": false},
    {"id": 2, "matricule": "MAT-002", "nom": "Beta", "prenoms": "Marie", "sexe": "F", "deleted": false},
    {"id": 3, "matricule": "MAT-003", "nom": "Gamma", "prenoms": "Paul", "sexe": "M", "deleted": false}
  ], "ids": [1, 2, 3], "has_more": false},
  "student_class_assignments": {"rows": [
    {"id": 1, "student_id": 1, "classroom_id": 1, "school_year_id": 1, "active": true},
    {"id": 2, "student_id": 2, "classroom_id": 1, "school_year_id": 1, "active": true},
    {"id": 3, "student_id": 3, "classroom_id": 1, "school_year_id": 1, "active": true}
  ], "ids": [1, 2, 3], "has_more": false},
  "time_slots": {"rows": [], "ids": [], "has_more": false},
  "weekly_schedules": {"rows": [], "ids": [], "has_more": false},
  "course_sessions": {"rows": [
    {"id": 1, "class_subject_id": 1, "teacher_id": 2, "date": "2026-11-06T08:00:00", "scheduled_start_time": "08:00:00", "start_time": "08:00:00", "end_time": "10:00:00", "state": "COMPLETED"},
    {"id": 2, "class_subject_id": 2, "teacher_id": 4, "date": "2026-11-06T10:00:00", "start_time": "10:00:00", "end_time": "12:00:00", "state": "PENDING"}
  ], "ids": [1, 2], "has_more": false},
  "student_absences": {"rows": [
    {"id": 1, "establishment_id": 1, "session_id": 1, "student_id": 1, "is_justified": false, "reason": "Absent"},
    {"id": 2, "establishment_id": 1, "session_id": 1, "student_id": 3, "is_justified": true, "reason": "Certificat"}
  ], "ids": [1, 2], "has_more": false},
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
      '[Fix-RANKING-OFFLINE] pull complet → hors-ligne sans consultation '
      'préalable → classement recalculé depuis Drift (formule serveur : '
      '(moy_classe + compo)/2, coefficients, ex-æquo, annuelle pondérée)',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // 1. Pull initial EN LIGNE.
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

    // 2. Hors-ligne : NOUVEAU container, réseau coupé, AUCUNE consultation
    //    du classement en ligne avant la coupure (pas de cache prefs).
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

    // 3. Classement période 1, classe 1.
    //    Élèves 1 et 2 ont exactement les MÊMES notes → ex-æquo (1 A / 1 B).
    //    Formule attendue par élève 1 :
    //      Math (coeff 4) : devoir 12 (CLASS) + compo 16 (EXAM) → (12+16)/2 = 14
    //      Français (coeff 2) : dictée 8/10 → 16/20 (CLASS) → 16
    //      Moyenne = (14×4 + 16×2) / 6 = (56 + 32) / 6 = 88/6 ≈ 14.6667
    //    Élève 3 : aucune note période 1 → moyenne null, rang non classé.
    final rows = await offline.read(
      rankingProvider(const RankingQuery(
        classroomId: 1,
        periodId: 1,
        rankingMode: RankingMode.period,
      )).future,
    );

    expect(rows, isNotEmpty, reason: 'le classement hors-ligne doit sortir');
    expect(rows.length, 3, reason: 'les 3 élèves de la classe sont listés');

    final byStudent = {for (final r in rows) r.studentId: r};
    final e1 = byStudent[1]!;
    final e2 = byStudent[2]!;
    final e3 = byStudent[3]!;

    // Ex-æquo : mêmes moyennes, rang 1 avec lettres A et B.
    expect(e1.average, closeTo(88 / 6, 0.01));
    expect(e2.average, closeTo(88 / 6, 0.01));
    expect(e1.rank, 1);
    expect(e2.rank, 1);
    expect(e1.rankLabel, contains('A'));
    expect(e2.rankLabel, contains('B'));

    // Élève 3 sans note : pas de moyenne, pas de rang.
    expect(e3.average, isNull);
    expect(e3.rank, 0);

    // Périodes précédentes (élève 3 : devoir T2 = 18 en période 2 —
    // la période 2 est APRÈS la 1, donc pas de « précédente » pour elle ;
    // pour la période 2, la 1 est précédente).
    expect(e1.previousPeriodAverages, isEmpty,
        reason: 'période 1 = première période, aucune précédente');

    // 4. Classement période 2 : élève 1 (18 en devoir) devant élève 3 (14).
    final rowsT2 = await offline.read(
      rankingProvider(const RankingQuery(
        classroomId: 1,
        periodId: 2,
        rankingMode: RankingMode.period,
      )).future,
    );
    final byStudentT2 = {for (final r in rowsT2) r.studentId: r};
    expect(byStudentT2[1]!.average, closeTo(18.0, 0.01));
    expect(byStudentT2[3]!.average, closeTo(14.0, 0.01));
    expect(byStudentT2[1]!.rank, 1);
    expect(byStudentT2[3]!.rank, 2);

    // Période précédente (élève 1, période 2) : moyenne de la période 1.
    expect(byStudentT2[1]!.previousPeriodAverages[1], closeTo(88 / 6, 0.01));

    // Moyenne annuelle pondérée (weights 1.0 et 2.0) :
    //   élève 1 : (14.6667×1 + 18×2) / 3 = (14.6667 + 36)/3 ≈ 16.8889
    expect(byStudentT2[1]!.annualAverage, closeTo((88 / 6 + 36) / 3, 0.01));

    // 5. Mode SUBJECT (matière 1 = Math, coeff 4) :
    //    élève 1 période 1 : (12+16)/2 = 14.
    final rowsSubject = await offline.read(
      rankingProvider(const RankingQuery(
        classroomId: 1,
        periodId: 1,
        rankingMode: RankingMode.subject,
        subjectId: 1,
      )).future,
    );
    final byStudentSubject = {for (final r in rowsSubject) r.studentId: r};
    expect(byStudentSubject[1]!.average, closeTo(14.0, 0.01));
  });

  test(
      '[Fix-ATTENDANCE-REVIEW] consultation des présences (admin) servie '
      'par Drift hors-ligne : sessions résolues + décompte d\'absences + '
      'récapitulatif par élève',
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

    // Hors-ligne : consultation PUREMENT locale.
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

    // Sessions : course_sessions porte class_subject_id → résolution
    // classe/matière via class_subjects, enseignant via users.
    final sessions = await offline.read(attendanceSessionsProvider.future);
    expect(sessions.length, 2, reason: 'les 2 sessions du pull');

    final s1 = sessions.firstWhere((s) => s.id == 1);
    expect(s1.classroomName, '2nde A',
        reason: 'classe résolue via class_subjects');
    expect(s1.subjectName, 'Mathématiques',
        reason: 'matière résolue via class_subjects');
    expect(s1.teacherName, 'Dupont Marc',
        reason: 'enseignant résolu via users');
    expect(s1.isCompleted, isTrue);
    expect(s1.absentCount, 2);
    expect(s1.justifiedCount, 1);

    // Détail des absences de la session 1 (noms d'élèves résolus).
    final details = await offline.read(
      sessionAbsenceDetailsProvider(1).future,
    );
    expect(details.length, 2);
    final names = details.map((d) => d.studentName).toSet();
    expect(names, containsAll(['Alpha Jean', 'Gamma Paul']));
    final justified =
        details.where((d) => d.isJustified).map((d) => d.studentName).toList();
    expect(justified, ['Gamma Paul']);

    // Récapitulatif par élève : Alpha 1 absence (non justifiée),
    // Gamma 1 absence (justifiée).
    final summaries = await offline.read(
      attendanceStudentSummariesProvider.future,
    );
    expect(summaries.length, 2);
    final alpha = summaries.firstWhere((s) => s.studentId == 1);
    expect(alpha.totalAbsences, 1);
    expect(alpha.unjustifiedAbsences, 1);
    final gamma = summaries.firstWhere((s) => s.studentId == 3);
    expect(gamma.justifiedAbsences, 1);
  });

  test(
      '[Fix-EDT-TEACHERS-OFFLINE] dropdown « Par enseignant » hors-ligne : '
      'users.role répliqué sert teachersListProvider',
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

    // Hors-ligne : le GET /users?role=teacher est coupé → repli Drift.
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

    final teachers = await offline.read(teachersListProvider.future);
    expect(teachers.length, 3,
        reason: '3 enseignants (Dupont, Titu, Durand) — pas l\'admin');
    expect(
      teachers.map((t) => t.username).toSet(),
      containsAll(['m_dupont', 'titulaire', 'm_durand']),
    );
  });
}
