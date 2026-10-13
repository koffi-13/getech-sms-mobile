// test/v11_offline_chain_test.dart
//
// E2E V11 — « connexion à la session + saisie de notes en mode hors-ligne ».
//
// Ce test rejoue les payloads RÉELS capturés du serveur (scripts/
// repro_v11_offline_chain.py, commit feature 23042a1) à travers les VRAIS
// providers du module Notes, puis bascule hors-ligne et vérifie la chaîne
// complète : évaluation → matière → classe → registre → élèves.
//
// Leçon V10 : toujours tester les cache-aside avec la réponse RÉELLE du
// serveur, champ par champ — jamais avec des données seedées idéales.
//
// Variantes couvertes :
//   A. Serveur À JOUR (V10+) : assessments porte class_subject_id/period_id.
//   B. Serveur AVANT V10 (main déployé) : SANS ces champs → le contexte
//      de la requête (matière/période sélectionnées) doit réparer le cache.
//   C. Redémarrage offline complet : NOUVEAU container (l'utilisateur
//      rouvre l'app hors-ligne) → la chaîne doit se reconstruire de Drift.
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

const _teacherUserId = 1;

/// Interceptor qui rejette toute requête (réseau KO).
class _RejectAllInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    handler.reject(DioException.connectionError(
      requestOptions: options,
      reason: 'hors-ligne',
    ));
  }
}

/// Dio qui route chaque requête vers le payload RÉEL capturé du serveur.
class _RoutingInterceptor extends Interceptor {
  _RoutingInterceptor(this.routes);
  final Map<String, Object> routes; // substring du path → body

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final path = options.uri.path;
    for (final entry in routes.entries) {
      if (path.contains(entry.key)) {
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: entry.value,
        ));
        return;
      }
    }
    handler.reject(DioException.connectionError(
      requestOptions: options,
      reason: 'route inconnue en test : $path',
    ));
  }
}

Dio _routingDio(Map<String, Object> routes) {
  final dio = Dio(BaseOptions());
  dio.interceptors.add(_RoutingInterceptor(routes));
  return dio;
}

/// Notifier de connexion piloté par le test (online ↔ offline).
class _FakeConnectionNotifier extends ConnectionNotifier {
  _FakeConnectionNotifier(super.ref);

  void forceOnline() {
    state = state.copyWith(
      status: ServerStatus.online,
      profileId: 'p-test',
      serverUrlOverride: 'http://192.168.1.10:8000/api/v1',
      establishmentCode: 'R11-01',
      pairingToken: 'token-test',
    );
  }

  void forceOffline() {
    // Un redémarrage hors-ligne CONSERVE l'appairage (profils en stockage) :
    // on établit les champs de profil s'ils manquent (état initial).
    state = state.copyWith(
      status: ServerStatus.offline,
      profileId: state.profileId ?? 'p-test',
      serverUrlOverride:
          state.serverUrlOverride ?? 'http://192.168.1.10:8000/api/v1',
      establishmentCode: state.establishmentCode ?? 'R11-01',
      pairingToken: state.pairingToken ?? 'token-test',
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
      user: const UserDto(
        id: _teacherUserId,
        username: 'r11_teacher',
        role: 'teacher',
      ),
      token: 'test-token',
      permissions: const ['GRADE_READ', 'GRADE_EDIT'],
      roles: const ['TEACHER'],
      establishmentId: 1,
    );

// ---------------------------------------------------------------------------
// Payloads RÉELS capturés (scripts/repro_v11_offline_chain.py).
// ---------------------------------------------------------------------------

/// GET /sync/pull — forme réelle `tables: {name: {rows, ids, has_more}}`.
const _realSyncPull = {
  'server_time': '2026-10-13T08:56:50.308901',
  'max_offline_days': 7,
  'tables': {
    'establishments': {
      'rows': [
        {
          'id': 1,
          'code': 'R11-01',
          'name': 'Lycée Repro V11',
          'email': 'r11@getech.local',
          'phone': '+22890000000',
          'country': 'Togo',
          'city': 'Lomé',
          'address': null,
          'facultative_grading_mode': 'BONUS',
          'use_period_weights': false,
        }
      ],
      'ids': [1],
      'has_more': false,
    },
    'school_years': {
      'rows': [
        {
          'id': 1,
          'establishment_id': 1,
          'school_year': '2025-2026',
          'max_students': null,
          'period_structure': null,
          'is_active': true,
          'is_closed': false,
          'alternating_week_start_date': null,
        }
      ],
      'ids': [1],
      'has_more': false,
    },
    'periods': {
      'rows': [
        {
          'id': 1,
          'school_year_id': 1,
          'cycle_id': 1,
          'name': 'Trimestre 1',
          'period_type': null,
          'start_date': '2026-09-01',
          'end_date': '2026-12-18',
          'weight': 1.0,
          'is_active': true,
        }
      ],
      'ids': [1],
      'has_more': false,
    },
    'classrooms': {
      'rows': [
        {
          'id': 1,
          'establishment_id': 1,
          'name': '2nde A',
          'level_id': 1,
          'series_id': null,
          'stream_id': null,
          'head_teacher_id': null,
          'is_active': true,
        }
      ],
      'ids': [1],
      'has_more': false,
    },
    'subjects': {
      'rows': [
        {
          'id': 1,
          'establishment_id': 1,
          'name': 'Mathématiques',
          'code': 'MATH',
          'domain_id': null,
          'is_facultative': false,
          'is_active': true,
        }
      ],
      'ids': [1],
      'has_more': false,
    },
    'class_subjects': {
      'rows': [
        {
          'id': 1,
          'establishment_id': 1,
          'classroom_id': 1,
          'subject_id': 1,
          'school_year_id': 1,
          'coefficient': 4,
          'is_coefficient_customized': false,
          'assigned_teacher_id': _teacherUserId,
        }
      ],
      'ids': [1],
      'has_more': false,
    },
    'students': {
      'rows': [
        {
          'id': 1,
          'public_id': 'pub-eleve1',
          'establishment_id': 1,
          'matricule': 'MAT-2026-001',
          'nom': 'Élève1',
          'prenoms': 'Prénom',
          'sexe': null,
          'date_naissance': null,
          'deleted': false,
          'is_active': true,
        },
        {
          'id': 2,
          'public_id': 'pub-eleve2',
          'establishment_id': 1,
          'matricule': 'MAT-2026-002',
          'nom': 'Élève2',
          'prenoms': 'Prénom',
          'sexe': null,
          'date_naissance': null,
          'deleted': false,
          'is_active': true,
        },
        {
          'id': 3,
          'public_id': 'pub-eleve3',
          'establishment_id': 1,
          'matricule': 'MAT-2026-003',
          'nom': 'Élève3',
          'prenoms': 'Prénom',
          'sexe': null,
          'date_naissance': null,
          'deleted': false,
          'is_active': true,
        },
      ],
      'ids': [1, 2, 3],
      'has_more': false,
    },
    'student_class_assignments': {
      'rows': [
        {
          'id': 1,
          'student_id': 1,
          'classroom_id': 1,
          'school_year_id': 1,
          'active': true,
          'inscription_type_id': null,
          'student_status_id': null,
        },
        {
          'id': 2,
          'student_id': 2,
          'classroom_id': 1,
          'school_year_id': 1,
          'active': true,
          'inscription_type_id': null,
          'student_status_id': null,
        },
        {
          'id': 3,
          'student_id': 3,
          'classroom_id': 1,
          'school_year_id': 1,
          'active': true,
          'inscription_type_id': null,
          'student_status_id': null,
        },
      ],
      'ids': [1, 2, 3],
      'has_more': false,
    },
    'assessments': {
      'rows': [
        {
          'id': 1,
          'class_subject_id': 1,
          'period_id': 1,
          'assessment_type_id': 1,
          'name': 'Devoir 1',
          'max_score': 20.0,
          'weight': null,
          'is_counted_on_bulletin': true,
          'date_taken': '2026-10-12',
        }
      ],
      'ids': [1],
      'has_more': false,
    },
    'grades': {'rows': [], 'ids': [], 'has_more': false},
    'grade_modifications': {'rows': [], 'ids': [], 'has_more': false},
    'course_sessions': {'rows': [], 'ids': [], 'has_more': false},
    'student_absences': {'rows': [], 'ids': [], 'has_more': false},
    'users': {
      'rows': [
        {
          'id': _teacherUserId,
          'public_id': 'pub-r11-teacher',
          'username': 'r11_teacher',
          'email': 'teacher@r11.local',
          'role': 'teacher',
          'first_name': null,
          'last_name': null,
          'is_active': true,
          'is_superuser': false,
        }
      ],
      'ids': [_teacherUserId],
      'has_more': false,
    },
  },
};

/// GET /students — page Élèves (avec classroom_id).
const _realStudents = {
  'items': [
    {
      'id': 1,
      'public_id': 'pub-eleve1',
      'matricule': 'MAT-2026-001',
      'nom': 'Élève1',
      'prenoms': 'Prénom',
      'establishment_id': 1,
      'dob': null,
      'sexe': null,
      'classroom_id': 1,
      'classroom_name': '2nde A',
      'inscription_type_label': null,
      'student_status_label': null,
      'age': null,
      'photo_path': null,
    },
    {
      'id': 2,
      'public_id': 'pub-eleve2',
      'matricule': 'MAT-2026-002',
      'nom': 'Élève2',
      'prenoms': 'Prénom',
      'establishment_id': 1,
      'dob': null,
      'sexe': null,
      'classroom_id': 1,
      'classroom_name': '2nde A',
      'inscription_type_label': null,
      'student_status_label': null,
      'age': null,
      'photo_path': null,
    },
    {
      'id': 3,
      'public_id': 'pub-eleve3',
      'matricule': 'MAT-2026-003',
      'nom': 'Élève3',
      'prenoms': 'Prénom',
      'establishment_id': 1,
      'dob': null,
      'sexe': null,
      'classroom_id': 1,
      'classroom_name': '2nde A',
      'inscription_type_label': null,
      'student_status_label': null,
      'age': null,
      'photo_path': null,
    },
  ],
  'total': 3,
};

/// GET /grades/class-subjects?classroom_id=1
const _realClassSubjects = [
  {
    'id': 1,
    'subject_id': 1,
    'subject_name': 'Mathématiques',
    'subject_code': 'MATH',
    'coefficient': 4,
    'is_facultative': false,
    'assigned_teacher_id': _teacherUserId,
    'assigned_teacher_name': 'r11_teacher',
  }
];

/// GET /grades/assessments — serveur À JOUR (V10+ : ids de contexte).
const _realAssessmentsPatched = [
  {
    'id': 1,
    'name': 'Devoir 1',
    'assessment_type_id': 1,
    'assessment_type_name': 'Devoir',
    'assessment_type_category': 'CLASS',
    'max_score': 20.0,
    'date_taken': '2026-10-12',
    'is_counted_on_bulletin': true,
    'grades_entered_count': 0,
    'total_students': 3,
    'class_subject_id': 1,
    'period_id': 1,
  }
];

/// GET /grades/assessments — serveur AVANT V10 (main déployé de
/// l'utilisateur) : NI class_subject_id NI period_id.
const _realAssessmentsPreV10 = [
  {
    'id': 1,
    'name': 'Devoir 1',
    'assessment_type_id': 1,
    'assessment_type_name': 'Devoir',
    'assessment_type_category': 'CLASS',
    'max_score': 20.0,
    'date_taken': '2026-10-12',
    'is_counted_on_bulletin': true,
    'grades_entered_count': 0,
    'total_students': 3,
  }
];

/// GET /grades/assessments/1/grades — roster complet, AUCUNE note saisie.
const _realRoster = [
  {
    'student_id': 1,
    'student_name': 'Élève1 Prénom',
    'student_matricule': 'MAT-2026-001',
    'grade_id': null,
    'value': null,
    'is_absent': false,
    'comment': null,
    'is_locked': false,
    'modification_status': null,
    'modification': null,
  },
  {
    'student_id': 2,
    'student_name': 'Élève2 Prénom',
    'student_matricule': 'MAT-2026-002',
    'grade_id': null,
    'value': null,
    'is_absent': false,
    'comment': null,
    'is_locked': false,
    'modification_status': null,
    'modification': null,
  },
  {
    'student_id': 3,
    'student_name': 'Élève3 Prénom',
    'student_matricule': 'MAT-2026-003',
    'grade_id': null,
    'value': null,
    'is_absent': false,
    'comment': null,
    'is_locked': false,
    'modification_status': null,
    'modification': null,
  },
];

/// GET /settings/periods
const _realPeriods = [
  {
    'id': 1,
    'name': 'Trimestre 1',
    'start_date': '2026-09-01',
    'end_date': '2026-12-18',
    'is_active': true,
    'cycle_id': 1,
    'cycle_name': 'Lycée',
    'school_year_id': 1,
  }
];

/// GET /classrooms
const _realClassrooms = {
  'items': [
    {
      'id': 1,
      'name': '2nde A',
      'level_id': 1,
      'is_active': true,
      'current_students_count': 3,
    }
  ],
  'total': 1,
};

Map<String, Object> _routesFor({required bool serverPatched}) => {
      '/sync/pull': _realSyncPull,
      '/students': _realStudents,
      '/grades/class-subjects': _realClassSubjects,
      '/grades/assessments/1/grades': _realRoster,
      '/grades/assessments': serverPatched
          ? _realAssessmentsPatched
          : _realAssessmentsPreV10,
      '/settings/periods': _realPeriods,
      '/classrooms': _realClassrooms,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// Exécute la phase EN LIGNE complète (sync pull + consultation Notes)
  /// sur [container], comme le ferait l'enseignant au matin.
  Future<void> runOnlinePhase(ProviderContainer container) async {
    final conn = container.read(connectionProvider.notifier)
        as _FakeConnectionNotifier;
    conn.forceOnline();

    // 1. Sync pull (dashboard au démarrage).
    final result = await container.read(syncEngineProvider).pull();
    expect(result.errors, isEmpty, reason: 'le pull ne doit pas échouer');

    // 2. Page Notes : cascade complète en ligne.
    final classrooms =
        await container.read(classroomsForGradesProvider.future);
    expect(classrooms, isNotEmpty, reason: 'la classe doit être listée');

    final periods = await container.read(periodsProvider.future);
    expect(periods, isNotEmpty, reason: 'la période doit être listée');

    final subjects =
        await container.read(classSubjectsProvider(1).future);
    expect(subjects, isNotEmpty, reason: 'la matière doit être listée');

    final assessments = await container
        .read(assessmentsProvider(
            const AssessmentsQuery(classSubjectId: 1, periodId: 1))
            .future);
    expect(assessments, isNotEmpty,
        reason: "l'évaluation doit être listée en ligne");

    // 3. Ouverture de l'évaluation → roster complet (3 élèves, 0 note).
    final roster = await container.read(assessmentGradesProvider(
      (assessmentId: 1, classSubjectId: 1, periodId: 1),
    ).future);
    expect(roster, hasLength(3), reason: 'le roster complet doit être servi');
  }

  for (final variant in [true, false]) {
    group(
        'E2E offline notes — serveur ${variant ? 'À JOUR (V10+)' : 'AVANT V10 (main déployé)'}',
        () {
      test(
          'sync pull réel → consultation en ligne → bascule hors-ligne → '
          'la saisie doit lister les 3 élèves', () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        final container = ProviderContainer(overrides: [
          databaseProvider.overrideWith((ref) => db),
          dioProvider.overrideWith((ref) => _routingDio(_routesFor(
                serverPatched: variant,
              ))),
          connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
          authProvider.overrideWith(() => _FakeAuthNotifier(_teacherAuth())),
        ]);
        addTearDown(container.dispose);
        addTearDown(db.close);

        // ---- PHASE EN LIGNE (matin, serveur joignable) ----
        await runOnlinePhase(container);

        // ---- BASCULE HORS-LIGNE (le serveur devient injoignable) ----
        final conn =
            container.read(connectionProvider.notifier) as _FakeConnectionNotifier;
        conn.forceOffline();

        // La cascade complète doit fonctionner depuis Drift.
        final classroomsOffline =
            await container.read(classroomsForGradesProvider.future);
        expect(classroomsOffline, isNotEmpty,
            reason: '[offline] la classe doit venir du cache');

        final periodsOffline = await container.read(periodsProvider.future);
        expect(periodsOffline, isNotEmpty,
            reason: '[offline] la période doit venir du cache');

        final subjectsOffline =
            await container.read(classSubjectsProvider(1).future);
        expect(subjectsOffline, isNotEmpty,
            reason: '[offline] la matière doit venir du cache');

        final assessmentsOffline = await container.read(assessmentsProvider(
          const AssessmentsQuery(classSubjectId: 1, periodId: 1),
        ).future);
        expect(assessmentsOffline, isNotEmpty,
            reason: "[offline] l'évaluation doit venir du cache");

        // LE test du retour utilisateur : la feuille de saisie hors-ligne
        // doit lister les élèves (« Aucun élève à noter » sinon).
        final rosterOffline = await container.read(assessmentGradesProvider(
          (assessmentId: 1, classSubjectId: 1, periodId: 1),
        ).future);
        expect(rosterOffline, hasLength(3),
            reason:
                "[offline] les 3 élèves de la classe doivent être notables");
        expect(rosterOffline.map((e) => e.studentName),
            containsAll(['Élève1 Prénom', 'Élève2 Prénom', 'Élève3 Prénom']));
      });

      test(
          'redémarrage de l\'app hors-ligne (nouveau container) → la chaîne '
          'doit se reconstruire uniquement depuis Drift', () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());

        // Phase en ligne : premier container (l'app d'hier).
        {
          final container = ProviderContainer(overrides: [
            databaseProvider.overrideWith((ref) => db),
            dioProvider.overrideWith(
                (ref) => _routingDio(_routesFor(serverPatched: variant))),
            connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
            authProvider.overrideWith(() => _FakeAuthNotifier(_teacherAuth())),
          ]);
          addTearDown(container.dispose);
          await runOnlinePhase(container);
        }

        // L'app est fermée puis rouverte HORS-LIGNE : nouveau container,
        // AUCUN appel réseau possible (routes vides → rejet).
        final containerOffline = ProviderContainer(overrides: [
          databaseProvider.overrideWith((ref) => db),
          dioProvider.overrideWith((ref) {
            final dio = Dio(BaseOptions(
              connectTimeout: const Duration(milliseconds: 50),
            ));
            dio.interceptors.add(_RejectAllInterceptor());
            return dio;
          }),
          connectionProvider.overrideWith((ref) {
            final n = _FakeConnectionNotifier(ref);
            return n;
          }),
          authProvider.overrideWith(() => _FakeAuthNotifier(_teacherAuth())),
        ]);
        addTearDown(containerOffline.dispose);
        addTearDown(db.close);

        // IMPORTANT : poser l'état offline AVANT la première lecture.
        (containerOffline.read(connectionProvider.notifier)
                as _FakeConnectionNotifier)
            .forceOffline();

        final assessmentsOffline = await containerOffline
            .read(assessmentsProvider(
                const AssessmentsQuery(classSubjectId: 1, periodId: 1))
                .future);
        expect(assessmentsOffline, isNotEmpty,
            reason: "[redémarrage offline] l'évaluation doit être en cache");

        final rosterOffline = await containerOffline
            .read(assessmentGradesProvider(
          (assessmentId: 1, classSubjectId: 1, periodId: 1),
        ).future);
        expect(rosterOffline, hasLength(3),
            reason:
                '[redémarrage offline] les élèves doivent être notables');
      });
    });
  }
}
