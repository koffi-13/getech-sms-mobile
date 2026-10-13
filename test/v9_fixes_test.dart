// test/v9_fixes_test.dart
//
// Tests des correctifs V9 :
//
// 1. [Fix-SYNC-PULL-SHAPE] Le serveur `/sync/pull` renvoie réellement
//    `{server_time, tables: {name: {rows, ids, has_more}}}` — l'ancien
//    parseur lisait `changes`/`deleted` (deux champs INEXISTANTS) : aucune
//    table n'était jamais répliquée → cache Drift vide → « Aucun élève à
//    noter pour cette évaluation » hors-ligne.
// 2. [Fix-OFFLINE-GRADES-ROSTER] Après UNE consultation en ligne des
//    notes d'une évaluation, la chaîne hors-ligne complète doit tenir :
//    évaluation → matière → classe → ASSIGNATIONS (registre) → élèves →
//    notes. Le registre `student_class_assignments` est désormais écrit
//    par le cache-aside, et la reconstruction hors-ligne a un repli
//    (élèves référencés par les notes déjà répliquées).
// 3. [Présence-V9] Sélection intelligente : cours/classe présélectionnés
//    selon l'heure courante ; parseHm.
// 4. [Notif-V9] Les notifications de synchronisation sont désactivées PAR
//    DÉFAUT (retour utilisateur : « notifications de développement »).
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:getech_sms_mobile/core/auth/teacher_scope.dart';
import 'package:getech_sms_mobile/core/config/constants.dart';
import 'package:getech_sms_mobile/core/database/database.dart';
import 'package:getech_sms_mobile/core/network/dio_client.dart';
import 'package:getech_sms_mobile/core/notifications/notification_service.dart';
import 'package:getech_sms_mobile/core/sync/sync_engine.dart';
import 'package:getech_sms_mobile/features/attendance/course_selection.dart';
import 'package:getech_sms_mobile/features/connections/connection_state.dart';
import 'package:getech_sms_mobile/features/grades/grade_controller.dart';
import 'package:getech_sms_mobile/shared/models/attendance_dto.dart';
import 'package:getech_sms_mobile/shared/models/classroom_dto.dart';
import 'package:getech_sms_mobile/shared/models/sync_dto.dart';

/// Interceptor qui répond 200 avec un JSON arbitraire à toute requête.
class _JsonResponderInterceptor extends Interceptor {
  _JsonResponderInterceptor(this.body);
  final Object body;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    handler.resolve(
      Response(
        requestOptions: options,
        statusCode: 200,
        data: body,
      ),
    );
  }
}

Dio _jsonDio(Object body) {
  final dio = Dio(BaseOptions());
  dio.interceptors.add(_JsonResponderInterceptor(body));
  return dio;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  ConnectionOnline() => ConnectionState(
        status: ServerStatus.online,
        profileId: 'p-test',
        serverUrlOverride: 'http://192.168.1.10:8000/api/v1',
        establishmentCode: 'EST-TEST',
        pairingToken: 'token-test',
      );

  ConnectionOffline() => ConnectionState(
        status: ServerStatus.offline,
        profileId: 'p-test',
        serverUrlOverride: 'http://192.168.1.10:8000/api/v1',
        establishmentCode: 'EST-TEST',
        pairingToken: 'token-test',
      );

  group('[Fix-SYNC-PULL-SHAPE] SyncPullResponse — forme réelle du serveur', () {
    test('tables.{name}.{rows, ids, has_more} est parsée (pas `changes`)', () {
      final resp = SyncPullResponse.fromJson({
        'server_time': DateTime.utc(2025, 11, 10, 8).toIso8601String(),
        'max_offline_days': 30,
        'tables': {
          'students': {
            'rows': [
              {'id': 1, 'nom': 'Koffi', 'matricule': 'M001'},
              {'id': 2, 'nom': 'Aya', 'matricule': 'M002'},
            ],
            'ids': [1, 2],
            'has_more': false,
          },
          'classrooms': {
            'rows': [
              {'id': 5, 'name': '2nde A'},
            ],
            'ids': [5],
            'has_more': true,
          },
        },
      });

      expect(resp.changes['students'], hasLength(2));
      expect(resp.changes['classrooms'], hasLength(1));
      expect(resp.totalChanges, 3);
      expect(resp.hasMoreByTable['students'], isFalse);
      expect(resp.hasMoreByTable['classrooms'], isTrue);
      expect(resp.anyHasMore, isTrue);
      expect(resp.activeIdsByTable['students'], [1, 2]);
      // Pagination en cours → ids à null (pas de réconciliation possible).
      expect(resp.activeIdsByTable['classrooms'], isNull);
    });

    test('forme legacy `changes` reste acceptée (compatibilité)', () {
      final resp = SyncPullResponse.fromJson({
        'server_time': DateTime.utc(2025, 11, 10, 8).toIso8601String(),
        'changes': {
          'students': [
            {'id': 1, 'nom': 'Koffi'},
          ],
        },
        'deleted': [],
      });

      expect(resp.changes['students'], hasLength(1));
      expect(resp.anyHasMore, isFalse);
    });

    test('pull() réplique les tables de la forme `tables` dans Drift', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      final serverTime = DateTime.utc(2025, 11, 10, 8).toIso8601String();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWith((ref) {
            ref.onDispose(db.close);
            return db;
          }),
          dioProvider.overrideWith((ref) => _jsonDio({
                'server_time': serverTime,
                'max_offline_days': 30,
                'tables': {
                  'students': {
                    'rows': [
                      {
                        'id': 1,
                        'establishment_id': 1,
                        'matricule': 'M001',
                        'nom': 'Koffi',
                        'prenoms': 'Ange',
                        'deleted': false,
                      },
                    ],
                    'ids': [1],
                    'has_more': false,
                  },
                  'student_class_assignments': {
                    'rows': [
                      {
                        'id': 100,
                        'student_id': 1,
                        'classroom_id': 5,
                        'school_year_id': 2,
                      },
                    ],
                    'ids': [100],
                    'has_more': false,
                  },
                },
              })),
        ],
      );
      addTearDown(container.dispose);

      container.read(connectionProvider.notifier).state = ConnectionOnline();

      final result = await container.read(syncEngineProvider).pull();
      expect(result.isSuccess, isTrue, reason: result.errors.join('; '));
      expect(result.pulled, 2);

      // Le registre élève ↔ classe doit être répliqué : c'est le maillon
      // qui manquait à la chaîne hors-ligne des notes.
      final assigns = await db.select(db.studentClassAssignments).get();
      expect(assigns, hasLength(1));
      expect(assigns.single.studentId, 1);
      expect(assigns.single.classroomId, 5);

      final students = await db.select(db.students).get();
      expect(students, hasLength(1));
      expect(students.single.nom, 'Koffi');
    });
  });

  group('[Fix-OFFLINE-GRADES-ROSTER] chaîne notes hors-ligne', () {
    test('consultation en ligne → cache complet → reconstruction hors-ligne',
        () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      // Réponse serveur : une ligne PAR ÉLÈVE de la classe (contrat réel
      // de list_assessment_grades), notes existantes pour certains.
      final entriesBody = [
        {
          'student_id': 1,
          'student_name': 'Koffi Ange',
          'student_matricule': 'M001',
          'grade_id': 11,
          'value': 14.0,
          'is_absent': false,
          'is_locked': false,
        },
        {
          'student_id': 2,
          'student_name': 'Aya Grâce',
          'student_matricule': 'M002',
          'grade_id': null,
          'value': null,
          'is_absent': false,
          'is_locked': false,
        },
      ];

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWith((ref) {
            ref.onDispose(db.close);
            return db;
          }),
          dioProvider.overrideWith((ref) => _jsonDio(entriesBody)),
        ],
      );
      addTearDown(container.dispose);

      // 1) En ligne : les notes de l'évaluation 50 sont consultées.
      //    Pré-requis de la chaîne : évaluation 50 + matière 21 + classe 5
      //    déjà en cache (écrits par les cache-aside des listes).
      await seedGradesChain(db);
      container.read(connectionProvider.notifier).state = ConnectionOnline();

      final online = await container.read(assessmentGradesProvider(
        (assessmentId: 50, classSubjectId: 21, periodId: 3),
      ).future);
      expect(online, hasLength(2));

      // Le registre a été écrit par le cache-aside (le maillon manquant).
      var assigns = await db.select(db.studentClassAssignments).get();
      expect(assigns, hasLength(2), reason: 'registre de classe vide');
      expect(assigns.map((a) => a.classroomId).toSet(), {5});

      // 2) Hors-ligne : la reconstruction doit retrouver les DEUX élèves.
      container.read(connectionProvider.notifier).state = ConnectionOffline();
      container.invalidate(assessmentGradesProvider(
        (assessmentId: 50, classSubjectId: 21, periodId: 3),
      ));

      final offline = await container.read(assessmentGradesProvider(
        (assessmentId: 50, classSubjectId: 21, periodId: 3),
      ).future);
      expect(offline, hasLength(2),
          reason: '« Aucun élève à noter » hors-ligne alors que les élèves '
              'existent en base');
      expect(offline.map((e) => e.studentId), containsAll([1, 2]));
      // Valeur répliquée conservée.
      final koffi = offline.firstWhere((e) => e.studentId == 1);
      expect(koffi.value, 14.0);
    });

    test('repli : aucune assignation → élèves des notes répliquées seules',
        () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      // Cache partiel : évaluation + matière + notes répliquées MAIS AUCUNE
      // assignation (état d'un ancien cache avant le fix).
      await seedGradesChain(db, withRoster: false, withGrades: true);

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWith((ref) {
            ref.onDispose(db.close);
            return db;
          }),
          // Hors-ligne : aucun appel réseau ne doit aboutir de toute façon
          // (l'état de connexion force le chemin local).
          dioProvider.overrideWith((ref) => _jsonDio(const <Never>[])),
        ],
      );
      addTearDown(container.dispose);
      container.read(connectionProvider.notifier).state = ConnectionOffline();

      final offline = await container.read(assessmentGradesProvider(
        (assessmentId: 50, classSubjectId: 21, periodId: 3),
      ).future);
      // Meilleur effort : liste partielle (l'élève noté) > liste vide.
      expect(offline, isNotEmpty);
      expect(offline.map((e) => e.studentId), contains(1));
    });
  });

  group('[Présence-V9] sélection intelligente', () {
    final monday = DateTime(2025, 11, 10); // lundi

    WeeklyScheduleDto course(String start, String end, {int id = 1}) =>
        WeeklyScheduleDto(
          id: id,
          timeSlotId: 1,
          dayOfWeek: 1,
          startTime: start,
          endTime: end,
          subjectName: 'Maths',
          classroomId: 5,
        );

    test('parseHm : « HH:mm » → (h, m) ; formats invalides → null', () {
      expect(parseHm('08:30'), (8, 30));
      expect(parseHm('14:00:00'), (14, 0));
      expect(parseHm(''), isNull);
      expect(parseHm(null), isNull);
      expect(parseHm('8h30'), isNull);
    });

    test('autoCourseFor : à 09h → créneau en cours (08-10) sélectionné', () {
      final courses = [course('08:00', '10:00', id: 1), course('15:00', '17:00', id: 2)];
      final picked = autoCourseFor(courses,
          date: monday, now: DateTime(2025, 11, 10, 9, 0));
      expect(picked?.id, 1);
    });

    test('autoCourseFor : à 11h → créneau à VENIR (15-17), pas le 1er', () {
      final courses = [course('08:00', '10:00', id: 1), course('15:00', '17:00', id: 2)];
      final picked = autoCourseFor(courses,
          date: monday, now: DateTime(2025, 11, 10, 11, 0));
      expect(picked?.id, 2,
          reason: 'l\'ancien code sélectionnait le 1er créneau même fini');
    });

    test('autoCourseFor : journée finie → dernier créneau (rattrapage)', () {
      final courses = [course('08:00', '10:00', id: 1), course('15:00', '17:00', id: 2)];
      final picked = autoCourseFor(courses,
          date: monday, now: DateTime(2025, 11, 10, 18, 0));
      expect(picked?.id, 2);
    });

    test('autoCourseFor : autre date → 1er créneau de la journée', () {
      final courses = [course('08:00', '10:00', id: 1), course('15:00', '17:00', id: 2)];
      final picked = autoCourseFor(courses,
          date: DateTime(2025, 11, 11), now: DateTime(2025, 11, 10, 9, 0));
      expect(picked?.id, 1);
    });

    test('defaultClassroomId : classe du créneau en cours (enseignant)', () {
      final scope = TeacherScope(
        isTeacher: true,
        mySchedule: [
          WeeklyScheduleDto(
            id: 1,
            timeSlotId: 1,
            dayOfWeek: DateTime(2025, 11, 10).weekday,
            startTime: '08:00',
            endTime: '10:00',
            subjectName: 'Maths',
            classroomId: 5,
          ),
          WeeklyScheduleDto(
            id: 2,
            timeSlotId: 2,
            dayOfWeek: DateTime(2025, 11, 10).weekday,
            startTime: '15:00',
            endTime: '17:00',
            subjectName: 'Physique',
            classroomId: 8,
          ),
        ],
      );
      final classes = [
        const ClassroomDto(id: 5, name: '2nde A'),
        const ClassroomDto(id: 8, name: '1ère C'),
        const ClassroomDto(id: 9, name: 'Tle D'),
      ];
      // 09h → créneau 08-10 en cours → classe 5.
      expect(
        defaultClassroomId(classes, scope, DateTime(2025, 11, 10, 9, 0),
            effectiveWeek: WeekType.a),
        5,
      );
      // 11h → créneau 15-17 à venir → classe 8.
      expect(
        defaultClassroomId(classes, scope, DateTime(2025, 11, 10, 11, 0),
            effectiveWeek: WeekType.a),
        8,
      );
      // Admin / scope nul → pas de présélection (1re classe de la liste).
      expect(
        defaultClassroomId(classes, null, DateTime(2025, 11, 10, 9, 0),
            effectiveWeek: WeekType.a),
        isNull,
      );
    });
  });

  group('[Notif-V9] réglages par défaut', () {
    test('les notifications de synchronisation sont OFF par défaut', () async {
      // Aucune préférence enregistrée → défauts.
      final settings = await NotificationSettings.load();
      expect(settings.syncUpdates, isFalse,
          reason: 'perçues comme des « notifications de développement »');
      expect(settings.courseReminders, isTrue);
      expect(settings.gradesValidation, isTrue);
    });
  });
}

/// Jeu de données Drift pour la chaîne des notes : évaluation 50 →
/// matière-par-classe 21 (classe 5) + élèves (1, 2) + éventuellement
/// registre et notes répliquées.
Future<void> seedGradesChain(
  AppDatabase db, {
  bool withRoster = true,
  bool withGrades = false,
}) async {
  await db.batch((b) {
    b.insert(db.classrooms, ClassroomsCompanion.insert(
      id: const Value(5),
      name: '2nde A',
    ));
    b.insert(db.subjects, SubjectsCompanion.insert(
      id: const Value(10),
      name: 'Mathématiques',
    ));
    b.insert(db.classSubjects, ClassSubjectsCompanion.insert(
      id: const Value(21),
      classroomId: 5,
      subjectId: 10,
    ));
    b.insert(db.assessments, AssessmentsCompanion.insert(
      id: const Value(50),
      classSubjectId: 21,
      periodId: const Value(3),
      title: 'Devoir 1',
      type: const Value('DEVOIR'),
      maxScore: const Value(20),
    ));
    b.insert(db.students, StudentsCompanion.insert(
      id: const Value(1),
      nom: 'Koffi',
      prenoms: const Value('Ange'),
      matricule: 'M001',
    ));
    b.insert(db.students, StudentsCompanion.insert(
      id: const Value(2),
      nom: 'Aya',
      prenoms: const Value('Grâce'),
      matricule: 'M002',
    ));
    if (withRoster) {
      b.insert(db.studentClassAssignments,
          StudentClassAssignmentsCompanion.insert(
            studentId: 1,
            classroomId: 5,
          ));
      b.insert(db.studentClassAssignments,
          StudentClassAssignmentsCompanion.insert(
            studentId: 2,
            classroomId: 5,
          ));
    }
    if (withGrades) {
      b.insert(db.grades, GradesCompanion.insert(
        id: const Value(11),
        assessmentId: 50,
        studentId: 1,
        value: const Value(14.0),
      ));
    }
  });
}
