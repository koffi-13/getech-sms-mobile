// test/v10_fixes_test.dart
//
// Tests des correctifs V10 :
//
// 1. [Fix-OFFLINE-GRADES-SUBJECT-ID] CAUSE RACINE du retour utilisateur
//    « Il est toujours impossible de noter les élèves en mode hors-ligne…
//    "Aucun élève" pourtant les élèves s'affichent dans Élèves » :
//    la réponse RÉELLE de `GET /grades/assessments` (avant le patch
//    serveur V10) ne contient NI `class_subject_id` NI `period_id` →
//    l'évaluation était mise en cache avec classSubjectId=0 → la
//    chaîne hors-ligne (évaluation → matière → classe → registre →
//    élèves) cassait dès le PREMIER maillon, même quand les élèves
//    étaient parfaitement en cache (page Élèves).
//    Le correctif passe le CONTEXTE de la requête (matière/période
//    sélectionnées) au cache-aside et répare les lignes empoisonnées.
// 2. Les lignes déjà empoisonnées (classSubjectId=0, caches des versions
//    précédentes) sont RÉPARÉES : (a) à la prochaine consultation en
//    ligne de la liste, (b) à chaud lors de l'ouverture hors-ligne via
//    l'indice de matière de la page.
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:getech_sms_mobile/core/database/database.dart';
import 'package:getech_sms_mobile/core/network/dio_client.dart';
import 'package:getech_sms_mobile/features/connections/connection_state.dart';
import 'package:getech_sms_mobile/features/grades/grade_controller.dart';

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

  ConnectionState online() => const ConnectionState(
        status: ServerStatus.online,
        profileId: 'p-test',
        serverUrlOverride: 'http://192.168.1.10:8000/api/v1',
        establishmentCode: 'EST-TEST',
        pairingToken: 'token-test',
      );

  ConnectionState offline() => const ConnectionState(
        status: ServerStatus.offline,
        profileId: 'p-test',
        serverUrlOverride: 'http://192.168.1.10:8000/api/v1',
        establishmentCode: 'EST-TEST',
        pairingToken: 'token-test',
      );

  /// Réponse RÉELLE de `GET /grades/assessments` pour un serveur d'avant
  /// le patch V10 : AUCUN champ class_subject_id / period_id.
  const realPreV10AssessmentsBody = [
    {
      'id': 50,
      'name': 'Devoir 1',
      'assessment_type_id': 1,
      'assessment_type_name': 'Devoir',
      'assessment_type_category': 'REGULAR',
      'max_score': 20.0,
      'date_taken': '2026-10-05',
      'is_counted_on_bulletin': true,
      'grades_entered_count': 0,
      'total_students': 2,
    },
  ];

  /// Réponse d'un serveur À JOUR (V10) : class_subject_id/period_id
  /// présents.
  const patchedAssessmentsBody = [
    {
      'id': 51,
      'name': 'Devoir 2',
      'assessment_type_id': 1,
      'assessment_type_name': 'Devoir',
      'assessment_type_category': 'REGULAR',
      'max_score': 20.0,
      'date_taken': '2026-10-06',
      'is_counted_on_bulletin': true,
      'grades_entered_count': 0,
      'total_students': 2,
      'class_subject_id': 21,
      'period_id': 3,
    },
  ];

  /// Chaîne complète SANS la ligne d'évaluation (elle vient de l'API) —
  /// le registre de classe est en cache (page Élèves / sync pull),
  /// exactement l'état de l'utilisateur qui voit ses élèves dans Élèves.
  Future<void> seedChainWithoutAssessment(
    AppDatabase db, {
    bool poisonedAssessment = false,
  }) async {
    await db.batch((b) {
      b.insert(db.classrooms, ClassroomsCompanion.insert(
        id: const Value(5),
        name: '2nde A',
      ),);
      b.insert(db.subjects, SubjectsCompanion.insert(
        id: const Value(10),
        name: 'Mathématiques',
      ),);
      b.insert(db.classSubjects, ClassSubjectsCompanion.insert(
        id: const Value(21),
        classroomId: 5,
        subjectId: 10,
      ),);
      if (poisonedAssessment) {
        // Cache empoisonné par une version précédente : matière inconnue.
        b.insert(db.assessments, AssessmentsCompanion.insert(
          id: const Value(50),
          classSubjectId: 0,
          periodId: const Value(3),
          title: 'Devoir 1',
          type: const Value('DEVOIR'),
          maxScore: const Value(20),
        ),);
      }
      b.insert(db.students, StudentsCompanion.insert(
        id: const Value(1),
        nom: 'Koffi',
        prenoms: const Value('Ange'),
        matricule: 'M001',
      ),);
      b.insert(db.students, StudentsCompanion.insert(
        id: const Value(2),
        nom: 'Aya',
        prenoms: const Value('Grâce'),
        matricule: 'M002',
      ),);
      // Registre de classe (page Élèves / sync pull).
      b.insert(db.studentClassAssignments,
          StudentClassAssignmentsCompanion.insert(
            studentId: 1,
            classroomId: 5,
          ),);
      b.insert(db.studentClassAssignments,
          StudentClassAssignmentsCompanion.insert(
            studentId: 2,
            classroomId: 5,
          ),);
    });
  }

  group('[Fix-OFFLINE-GRADES-SUBJECT-ID] réponse serveur sans class_subject_id',
      () {
    test('la consultation EN LIGNE de la liste écrit l\'évaluation avec la '
        'matière du CONTEXTE (repli), pas 0', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await seedChainWithoutAssessment(db);

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWith((ref) {
            ref.onDispose(db.close);
            return db;
          }),
          dioProvider.overrideWith(
              (ref) => _jsonDio(realPreV10AssessmentsBody),),
        ],
      );
      addTearDown(container.dispose);
      container.read(connectionProvider.notifier).state = online();

      final list = await container.read(assessmentsProvider(
        const AssessmentsQuery(classSubjectId: 21, periodId: 3),
      ).future,);
      expect(list, hasLength(1));

      final row = await (db.select(db.assessments)
            ..where((t) => t.id.equals(50)))
          .getSingle();
      expect(row.classSubjectId, 21,
          reason: 'l\'évaluation était écrite avec classSubjectId=0 → '
              'chaîne hors-ligne cassée dès le premier maillon',);
      expect(row.periodId, 3);
    });

    test('réponse d\'un serveur à jour (V10) : class_subject_id de la '
        'réponse fait foi', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await seedChainWithoutAssessment(db);

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWith((ref) {
            ref.onDispose(db.close);
            return db;
          }),
          dioProvider.overrideWith((ref) => _jsonDio(patchedAssessmentsBody)),
        ],
      );
      addTearDown(container.dispose);
      container.read(connectionProvider.notifier).state = online();

      await container.read(assessmentsProvider(
        const AssessmentsQuery(classSubjectId: 99, periodId: 3),
      ).future,);

      final row = await (db.select(db.assessments)
            ..where((t) => t.id.equals(51)))
          .getSingle();
      expect(row.classSubjectId, 21,
          reason: 'la valeur du serveur (21) prime sur le contexte (99)',);
    });

    test('É2E : liste consultée en ligne (serveur pré-V10) → hors-ligne → '
        '« Aucun élève » RÉPARÉ : les élèves du registre sont notables',
        () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await seedChainWithoutAssessment(db);

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWith((ref) {
            ref.onDispose(db.close);
            return db;
          }),
          dioProvider.overrideWith(
              (ref) => _jsonDio(realPreV10AssessmentsBody),),
        ],
      );
      addTearDown(container.dispose);

      // 1) En ligne : le prof ouvre Notes → la liste des évaluations.
      container.read(connectionProvider.notifier).state = online();
      await container.read(assessmentsProvider(
        const AssessmentsQuery(classSubjectId: 21, periodId: 3),
      ).future,);

      // 2) Hors-ligne : il ouvre l'évaluation pour saisir les notes.
      //    Aucune note n'existe encore (nouvelle évaluation) — le registre
      //    (page Élèves) doit donc suffire.
      container.read(connectionProvider.notifier).state = offline();
      final entries = await container.read(assessmentGradesProvider(
        (assessmentId: 50, classSubjectId: 21, periodId: 3),
      ).future,);

      expect(entries, hasLength(2),
          reason: '« Aucun élève à noter pour cette évaluation » alors que '
              'les élèves s\'affichent dans Élèves',);
      expect(entries.map((e) => e.studentName), containsAll(
          [contains('Koffi'), contains('Aya')],),);
    });
  });

  group('[Fix-OFFLINE-GRADES-SUBJECT-ID] réparation des caches empoisonnés',
      () {
    test('consultation en ligne de la liste → la ligne classSubjectId=0 est '
        'réparée (sans déclasser une valeur correcte)', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      // Une ligne empoisonnée (50) + une ligne saine (51, autre matière).
      await seedChainWithoutAssessment(db, poisonedAssessment: true);
      await db.batch((b) {
        b.insert(db.assessments, AssessmentsCompanion.insert(
          id: const Value(51),
          classSubjectId: 77,
          periodId: const Value(3),
          title: 'Devoir 2',
          type: const Value('DEVOIR'),
          maxScore: const Value(20),
        ),);
      });

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWith((ref) {
            ref.onDispose(db.close);
            return db;
          }),
          dioProvider.overrideWith((ref) => _jsonDio([
                ...realPreV10AssessmentsBody,
                ...patchedAssessmentsBody,
              ]),),
        ],
      );
      addTearDown(container.dispose);
      container.read(connectionProvider.notifier).state = online();

      await container.read(assessmentsProvider(
        const AssessmentsQuery(classSubjectId: 21, periodId: 3),
      ).future,);

      final rows = {for (final r in await db.select(db.assessments).get()) r.id: r};
      expect(rows[50]!.classSubjectId, 21, reason: 'ligne empoisonnée non réparée');
      expect(rows[51]!.classSubjectId, 77,
          reason: 'valeur correcte écrasée par le contexte',);
    });

    test('hors-ligne : l\'indice de matière de la page répare à chaud → '
        'élèves retrouvés + ligne guérie en base', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await seedChainWithoutAssessment(db, poisonedAssessment: true);

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWith((ref) {
            ref.onDispose(db.close);
            return db;
          }),
          dioProvider.overrideWith((ref) => _jsonDio(const <Never>[])),
        ],
      );
      addTearDown(container.dispose);
      container.read(connectionProvider.notifier).state = offline();

      // Sans indice (ancien appel) : chaîne cassée → vide.
      final withoutHint = await container.read(assessmentGradesProvider(
        (assessmentId: 50, classSubjectId: null, periodId: 3),
      ).future,);
      expect(withoutHint, isEmpty, reason: 'pré-conditions non respectées');

      // Avec l'indice de la page (matière 21) : élèves + guérison.
      final entries = await container.read(assessmentGradesProvider(
        (assessmentId: 50, classSubjectId: 21, periodId: 3),
      ).future,);
      expect(entries, hasLength(2),
          reason: 'l\'indice de matière doit réparer la chaîne hors-ligne',);

      final row = await (db.select(db.assessments)
            ..where((t) => t.id.equals(50)))
          .getSingle();
      expect(row.classSubjectId, 21,
          reason: 'la ligne doit être guérie pour les prochaines fois',);
    });
  });
}
