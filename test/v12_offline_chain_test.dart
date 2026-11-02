// test/v12_offline_chain_test.dart
//
// E2E V12 — « Accès refusé. Permissions insuffisantes. » en production,
// puis chaîne offline complète (session + notes) une fois le serveur
// corrigé (self-heal user_establishments).
//
// Ce test rejoue les payloads RÉELS capturés du serveur (scripts/
// repro_v12_offline_chain.py, commit feature post-V12) avec un
// enseignant FAÇON PRODUCTION : SANS UserRole (login → roles=[]) et
// créé AVANT le correctif du lien user_establishments (le self-heal du
// serveur le répare à la première connexion).
//
// Couverture :
//   1. Login EN LIGNE réel (roles=[]) → l'enseignant doit être détecté
//      par repli sur User.role (hasDeclaredTeacherRole / isTeacherOnly),
//      l'instantané de session persisté, les identifiants stockés.
//   2. Redémarrage HORS-LIGNE (nouveau container) → login local
//      (_tryOfflineLogin) → session restaurée AVEC la forme production
//      (roles=[]) → les portes enseignant restent ouvertes.
//   3. La chaîne notes hors-ligne (l'évaluation → matière → classe →
//      registre → élèves) doit lister les 3 élèves — régression
//      « Aucun élève à noter ».
//
// Les payloads sont embarqués VERBATIM (JSON décodé par jsonDecode) :
// aucune transcription manuelle, fidélité byte-exacte au serveur.
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:getech_sms_mobile/core/auth/auth_state.dart';
import 'package:getech_sms_mobile/core/auth/secure_storage.dart';
import 'package:getech_sms_mobile/core/database/database.dart';
import 'package:getech_sms_mobile/core/network/dio_client.dart';
import 'package:getech_sms_mobile/core/sync/outbox.dart';
import 'package:getech_sms_mobile/core/sync/sync_engine.dart';
import 'package:getech_sms_mobile/features/classrooms/classroom_controller.dart';
import 'package:getech_sms_mobile/features/connections/connection_state.dart';
import 'package:getech_sms_mobile/features/grades/grade_controller.dart';
import 'package:getech_sms_mobile/features/schedule/schedule_controller.dart';
import 'package:getech_sms_mobile/features/users/user_controller.dart';
import 'package:getech_sms_mobile/shared/models/auth_dto.dart';
import 'package:getech_sms_mobile/shared/models/auth_dto.dart';
import 'package:getech_sms_mobile/shared/models/grade_dto.dart';

// ---------------------------------------------------------------------------
// Payloads RÉELS capturés (scripts/repro_v12_offline_chain.py →
// scripts/v12_payloads.json) — enseignant façon production : le login
// porte roles=[] et user.role='teacher'.
// ---------------------------------------------------------------------------
const _v12PayloadsJson = r'''
{
 "login": {
  "access_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxIiwiZXN0IjoxLCJpYXQiOjE3OTE4OTE1NDcsImV4cCI6MTc5MTk3Nzk0N30.nhqVacsww1V9Y_mo9-H1JB5S2Tlw8btukKoZLFriJ38",
  "token_type": "bearer",
  "expires_in": 86400,
  "user": {
   "id": 1,
   "public_id": "pub-r12oc-teacher",
   "username": "r12oc_teacher",
   "email": "teacher@r12oc.local",
   "first_name": null,
   "last_name": null,
   "is_active": true,
   "is_superuser": false,
   "last_login_at": "2026-10-13T11:39:07.926107",
   "role": "teacher",
   "phone": null,
   "position": null,
   "photo_path": null,
   "sexe": null
  },
  "roles": [],
  "permissions": [
   "ATTENDANCE_MARK",
   "ATTENDANCE_READ",
   "GRADE_EDIT",
   "GRADE_READ",
   "REPORTS_READ",
   "STUDENT_READ"
  ],
  "establishment": {
   "id": 1,
   "code": "R12-01",
   "name": "Lycée Repro V12",
   "email": "r12@getech.local",
   "phone": "+22890000000",
   "city": "Lomé",
   "country": "Togo"
  }
 },
 "me": {
  "user": {
   "id": 1,
   "public_id": "pub-r12oc-teacher",
   "username": "r12oc_teacher",
   "email": "teacher@r12oc.local",
   "first_name": null,
   "last_name": null,
   "is_active": true,
   "is_superuser": false,
   "last_login_at": "2026-10-13T11:39:07.926107",
   "role": "teacher",
   "phone": null,
   "position": null,
   "photo_path": null,
   "sexe": null
  },
  "roles": [],
  "permissions": [
   "ATTENDANCE_MARK",
   "ATTENDANCE_READ",
   "GRADE_EDIT",
   "GRADE_READ",
   "REPORTS_READ",
   "STUDENT_READ"
  ],
  "establishment": {
   "id": 1,
   "code": "R12-01",
   "name": "Lycée Repro V12",
   "email": "r12@getech.local",
   "phone": "+22890000000",
   "city": "Lomé",
   "country": "Togo"
  }
 },
 "sync_pull": {
  "server_time": "2026-10-13T11:39:08.012007",
  "max_offline_days": 7,
  "tables": {
   "establishments": {
    "rows": [
     {
      "id": 1,
      "code": "R12-01",
      "name": "Lycée Repro V12",
      "email": "r12@getech.local",
      "phone": "+22890000000",
      "country": "Togo",
      "city": "Lomé",
      "address": null,
      "facultative_grading_mode": "BONUS",
      "use_period_weights": false
     }
    ],
    "ids": [
     1
    ],
    "has_more": false
   },
   "school_years": {
    "rows": [
     {
      "id": 1,
      "establishment_id": 1,
      "school_year": "2025-2026",
      "max_students": null,
      "period_structure": null,
      "is_active": true,
      "is_closed": false,
      "alternating_week_start_date": null
     }
    ],
    "ids": [
     1
    ],
    "has_more": false
   },
   "periods": {
    "rows": [
     {
      "id": 1,
      "school_year_id": 1,
      "cycle_id": 1,
      "name": "Trimestre 1",
      "period_type": null,
      "start_date": "2026-09-01",
      "end_date": "2026-12-18",
      "weight": 1.0,
      "is_active": true
     }
    ],
    "ids": [
     1
    ],
    "has_more": false
   },
   "classrooms": {
    "rows": [
     {
      "id": 1,
      "establishment_id": 1,
      "name": "2nde A",
      "level_id": 1,
      "series_id": null,
      "stream_id": null,
      "head_teacher_id": null,
      "max_students": 40,
      "is_active": true
     }
    ],
    "ids": [
     1
    ],
    "has_more": false
   },
   "subjects": {
    "rows": [
     {
      "id": 1,
      "establishment_id": 1,
      "name": "Mathématiques",
      "code": "MATH",
      "domain_id": null,
      "is_facultative": false,
      "is_active": true
     }
    ],
    "ids": [
     1
    ],
    "has_more": false
   },
   "class_subjects": {
    "rows": [
     {
      "id": 1,
      "establishment_id": 1,
      "classroom_id": 1,
      "subject_id": 1,
      "school_year_id": 1,
      "coefficient": 4,
      "is_coefficient_customized": false,
      "assigned_teacher_id": 1
     }
    ],
    "ids": [
     1
    ],
    "has_more": false
   },
   "course_sessions": {
    "rows": [],
    "ids": [],
    "has_more": false
   },
   "students": {
    "rows": [
     {
      "id": 1,
      "public_id": "pub-eleve1",
      "establishment_id": 1,
      "matricule": "MAT-2026-001",
      "nom": "Élève1",
      "prenoms": "Prénom",
      "sexe": null,
      "dob": null,
      "birth_place": null,
      "birth_prefecture": null,
      "birth_region": null,
      "birth_country": null,
      "photo_path": null,
      "groupe": null,
      "deleted": false
     },
     {
      "id": 2,
      "public_id": "pub-eleve2",
      "establishment_id": 1,
      "matricule": "MAT-2026-002",
      "nom": "Élève2",
      "prenoms": "Prénom",
      "sexe": null,
      "dob": null,
      "birth_place": null,
      "birth_prefecture": null,
      "birth_region": null,
      "birth_country": null,
      "photo_path": null,
      "groupe": null,
      "deleted": false
     },
     {
      "id": 3,
      "public_id": "pub-eleve3",
      "establishment_id": 1,
      "matricule": "MAT-2026-003",
      "nom": "Élève3",
      "prenoms": "Prénom",
      "sexe": null,
      "dob": null,
      "birth_place": null,
      "birth_prefecture": null,
      "birth_region": null,
      "birth_country": null,
      "photo_path": null,
      "groupe": null,
      "deleted": false
     }
    ],
    "ids": [
     1,
     2,
     3
    ],
    "has_more": false
   },
   "student_class_assignments": {
    "rows": [
     {
      "id": 1,
      "student_id": 1,
      "classroom_id": 1,
      "school_year_id": 1,
      "active": true,
      "inscription_type_id": null,
      "student_status_id": null
     },
     {
      "id": 2,
      "student_id": 2,
      "classroom_id": 1,
      "school_year_id": 1,
      "active": true,
      "inscription_type_id": null,
      "student_status_id": null
     },
     {
      "id": 3,
      "student_id": 3,
      "classroom_id": 1,
      "school_year_id": 1,
      "active": true,
      "inscription_type_id": null,
      "student_status_id": null
     }
    ],
    "ids": [
     1,
     2,
     3
    ],
    "has_more": false
   },
   "assessments": {
    "rows": [
     {
      "id": 1,
      "class_subject_id": 1,
      "period_id": 1,
      "assessment_type_id": 1,
      "name": "Devoir 1",
      "max_score": 20.0,
      "is_counted_on_bulletin": true,
      "date_taken": "2026-10-12"
     }
    ],
    "ids": [
     1
    ],
    "has_more": false
   },
   "grades": {
    "rows": [],
    "ids": [],
    "has_more": false
   },
   "grade_modifications": {
    "rows": [],
    "ids": [],
    "has_more": false
   },
   "student_absences": {
    "rows": [],
    "ids": [],
    "has_more": false
   },
   "users": {
    "rows": [
     {
      "id": 1,
      "public_id": "pub-r12oc-teacher",
      "username": "r12oc_teacher",
      "nom": null,
      "prenoms": null,
      "email": "teacher@r12oc.local",
      "phone": null,
      "role": "teacher",
      "is_active": true,
      "is_superuser": false
     }
    ],
    "ids": [
     1
    ],
    "has_more": false
   },
   "user_establishments": {
    "rows": [
     {
      "id": 1,
      "user_id": 1,
      "establishment_id": 1,
      "role": "teacher",
      "is_active": true
     }
    ],
    "ids": [
     1
    ],
    "has_more": false
   }
  }
 },
 "students": [
  {
   "id": 1,
   "public_id": "pub-eleve1",
   "matricule": "MAT-2026-001",
   "nom": "Élève1",
   "prenoms": "Prénom",
   "establishment_id": 1,
   "dob": null,
   "sexe": null,
   "classroom_id": 1,
   "classroom_name": "2nde A",
   "inscription_type_label": null,
   "student_status_label": null,
   "age": null,
   "photo_path": null
  },
  {
   "id": 2,
   "public_id": "pub-eleve2",
   "matricule": "MAT-2026-002",
   "nom": "Élève2",
   "prenoms": "Prénom",
   "establishment_id": 1,
   "dob": null,
   "sexe": null,
   "classroom_id": 1,
   "classroom_name": "2nde A",
   "inscription_type_label": null,
   "student_status_label": null,
   "age": null,
   "photo_path": null
  },
  {
   "id": 3,
   "public_id": "pub-eleve3",
   "matricule": "MAT-2026-003",
   "nom": "Élève3",
   "prenoms": "Prénom",
   "establishment_id": 1,
   "dob": null,
   "sexe": null,
   "classroom_id": 1,
   "classroom_name": "2nde A",
   "inscription_type_label": null,
   "student_status_label": null,
   "age": null,
   "photo_path": null
  }
 ],
 "class_subjects": [
  {
   "id": 1,
   "subject_id": 1,
   "subject_name": "Mathématiques",
   "subject_code": "MATH",
   "coefficient": 4,
   "is_facultative": false,
   "assigned_teacher_id": 1,
   "assigned_teacher_name": "r12oc_teacher"
  }
 ],
 "assessments": [
  {
   "id": 1,
   "name": "Devoir 1",
   "assessment_type_id": 1,
   "assessment_type_name": "Devoir",
   "assessment_type_category": "CLASS",
   "max_score": 20.0,
   "date_taken": "2026-10-12",
   "is_counted_on_bulletin": true,
   "grades_entered_count": 0,
   "total_students": 3,
   "class_subject_id": 1,
   "period_id": 1
  }
 ],
 "assessment_grades": [
  {
   "student_id": 1,
   "student_name": "Élève1 Prénom",
   "student_matricule": "MAT-2026-001",
   "grade_id": null,
   "value": null,
   "is_absent": false,
   "comment": null,
   "is_locked": false,
   "modification_status": null,
   "modification": null
  },
  {
   "student_id": 2,
   "student_name": "Élève2 Prénom",
   "student_matricule": "MAT-2026-002",
   "grade_id": null,
   "value": null,
   "is_absent": false,
   "comment": null,
   "is_locked": false,
   "modification_status": null,
   "modification": null
  },
  {
   "student_id": 3,
   "student_name": "Élève3 Prénom",
   "student_matricule": "MAT-2026-003",
   "grade_id": null,
   "value": null,
   "is_absent": false,
   "comment": null,
   "is_locked": false,
   "modification_status": null,
   "modification": null
  }
 ],
 "settings_periods": [
  {
   "id": 1,
   "name": "Trimestre 1",
   "start_date": "2026-09-01",
   "end_date": "2026-12-18",
   "is_active": true,
   "cycle_id": 1,
   "cycle_name": "Lycée",
   "school_year_id": 1
  }
 ],
 "classrooms": {
  "items": [
   {
    "id": 1,
    "name": "2nde A",
    "establishment_id": 1,
    "max_students": 40,
    "is_active": true,
    "head_teacher_id": null,
    "head_teacher_name": null,
    "level_name": "Seconde",
    "cycle_name": "Lycée",
    "cycle_id": 1,
    "current_students_count": 3,
    "series_name": null
   }
  ],
  "total": 1
 }
}
''';

final Map<String, dynamic> _payloads =
    jsonDecode(_v12PayloadsJson) as Map<String, dynamic>;

/// Login capturé : roles=[] (legacy sans UserRole) + user.role='teacher'.
final Map<String, dynamic> _realLogin =
    _payloads['login'] as Map<String, dynamic>;

/// Dio qui route chaque requête vers le payload RÉEL (et rejette le reste).
class _RoutingInterceptor extends Interceptor {
  _RoutingInterceptor(this.routes);
  final Map<String, Object> routes;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final path = options.uri.path;
    for (final entry in routes.entries) {
      if (path.contains(entry.key)) {
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: entry.value,
          ),
        );
        return;
      }
    }
    handler.reject(
      DioException.connectionError(
        requestOptions: options,
        reason: 'route inconnue en test : $path',
      ),
    );
  }
}

Dio _routingDio(Map<String, Object> routes) {
  final dio = Dio(BaseOptions());
  dio.interceptors.add(_RoutingInterceptor(routes));
  return dio;
}

/// Réseau KO pour toute requête (bascule hors-ligne).
class _NetworkDownInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    handler.reject(
      DioException.connectionError(
        requestOptions: options,
        reason: 'hors-ligne',
      ),
    );
  }
}

/// Notifier de connexion piloté par le test.
class _FakeConnectionNotifier extends ConnectionNotifier {
  _FakeConnectionNotifier(super.ref);

  void forceOnline({DateTime? lastSyncAt}) {
    state = state.copyWith(
      status: ServerStatus.online,
      lastSyncAt: lastSyncAt,
      profileId: 'p-test',
      serverUrlOverride: 'http://192.168.1.10:8000/api/v1',
      establishmentCode: 'R12-01',
      pairingToken: 'token-test',
    );
  }

  void forceOffline() {
    state = state.copyWith(
      status: ServerStatus.offline,
      profileId: state.profileId ?? 'p-test',
      serverUrlOverride:
          state.serverUrlOverride ?? 'http://192.168.1.10:8000/api/v1',
      establishmentCode: state.establishmentCode ?? 'R12-01',
      pairingToken: state.pairingToken ?? 'token-test',
    );
  }
}

/// Le VRAI AuthNotifier (login réel) avec build() neutralisé : pas de
/// _restoreSession au démarrage, mais TOUTE la logique de login réelle.
class _FakeAuthNotifier extends AuthNotifier {
  _FakeAuthNotifier(this.initial);
  final AuthState initial;

  @override
  AuthState build() => initial;
}

/// Stockage sécurisé factice (flutter_secure_storage indisponible en test).
class _FakeSecureStorage extends SecureStorage {
  final Map<String, String> _store = {};

  @override
  Future<String?> read(String key) async => _store[key];
  @override
  Future<void> write(String key, String value) async => _store[key] = value;
  @override
  Future<void> delete(String key) async => _store.remove(key);

  @override
  String profileKey(String base, String profileId) => '$base.$profileId';
  @override
  Future<String?> getJwtFor(String profileId) async =>
      _store[profileKey('getech.jwt', profileId)];
  @override
  Future<void> saveJwtFor(String profileId, String token) async =>
      _store[profileKey('getech.jwt', profileId)] = token;
  @override
  Future<void> deleteJwtFor(String profileId) async =>
      _store.remove(profileKey('getech.jwt', profileId));
  @override
  Future<void> deleteJwt() async => _store.remove('getech.jwt');
  @override
  Future<void> saveJwt(String token) async => _store['getech.jwt'] = token;

  @override
  Future<({String username, String password})?> getCredentialsFor(
    String profileId,
  ) async {
    final raw = _store[profileKey('getech.credentials', profileId)];
    if (raw == null || !raw.contains(':::')) return null;
    final parts = raw.split(':::');
    return (username: parts[0], password: parts[1]);
  }

  @override
  Future<void> saveCredentialsFor(
    String profileId,
    String username,
    String password,
  ) async {
    _store[profileKey('getech.credentials', profileId)] =
        '$username:::$password';
  }

  @override
  Future<void> saveCredentials(String username, String password) async =>
      _store['getech.credentials'] = '$username:::$password';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('un cache hérité sans version force une resynchronisation complète',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final previousSyncAt = DateTime.utc(2026, 10, 10);
    final requests = <RequestOptions>[];
    final dio = _routingDio({
      '/sync/pull': _payloads['sync_pull'] as Object,
    });
    dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          handler.next(options);
        },
      ),
    );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith((ref) => dio),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
      ],
    );
    addTearDown(container.dispose);
    (container.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOnline(lastSyncAt: previousSyncAt);

    final result = await container.read(syncEngineProvider).pull();

    expect(result.errors, isEmpty);
    expect(
      requests.single.queryParameters['since'],
      DateTime(2000, 1, 1).toUtc().toIso8601String(),
    );
    expect(await db.select(db.studentClassAssignments).get(), isNotEmpty);
    final marker = await (db.select(db.syncMetadata)
          ..where((t) => t.tableNameColumn.equals('__mobile_cache_version__')))
        .getSingleOrNull();
    expect(marker?.lastCount, 3);
  });

  test('le pull utilise le watermark du cache du profil actif', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final profileWatermark = DateTime.utc(2026, 10, 10);
    final globalWatermark = DateTime.utc(2026, 10, 18);
    await db.into(db.syncMetadata).insert(
          SyncMetadataCompanion.insert(
            tableNameColumn: '__mobile_cache_version__',
            lastSyncedAt: Value(profileWatermark),
            lastCount: const Value(3),
          ),
        );

    final requests = <RequestOptions>[];
    final dio = _routingDio({
      '/sync/pull': _payloads['sync_pull'] as Object,
    });
    dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          handler.next(options);
        },
      ),
    );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith((ref) => dio),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
      ],
    );
    addTearDown(container.dispose);
    (container.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOnline(lastSyncAt: globalWatermark);

    final result = await container.read(syncEngineProvider).pull();

    expect(result.errors, isEmpty);
    expect(
      requests.single.queryParameters['since'],
      profileWatermark.toIso8601String(),
    );
  });

  test('le pull seul permet la saisie des notes hors-ligne', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith(
          (ref) => _routingDio({
            '/sync/pull': _payloads['sync_pull'] as Object,
          }),
        ),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
      ],
    );
    addTearDown(container.dispose);
    final connection =
        container.read(connectionProvider.notifier) as _FakeConnectionNotifier;
    connection.forceOnline();

    final pull = await container.read(syncEngineProvider).pull();
    expect(pull.errors, isEmpty);

    connection.forceOffline();
    final roster = await container.read(
      assessmentGradesProvider(
        (
          assessmentId: 1,
          classSubjectId: 1,
          periodId: 1,
          classroomId: 1,
        ),
      ).future,
    );

    expect(roster, hasLength(3));
    expect(
      roster.map((entry) => entry.studentMatricule),
      containsAll(['MAT-2026-001', 'MAT-2026-002', 'MAT-2026-003']),
    );
  });

  test('le score du pull est affiché comme note hors-ligne', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final payload = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(_payloads['sync_pull'])) as Map,
    );
    final tables = payload['tables'] as Map<String, dynamic>;
    final grades = tables['grades'] as Map<String, dynamic>;
    grades['rows'] = [
      {
        'id': 501,
        'assessment_id': 1,
        'student_id': 1,
        'score': 14.5,
        'is_absent': false,
        'comments': 'Bonne réponse',
      },
    ];
    grades['ids'] = [501];

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith(
          (ref) => _routingDio({'/sync/pull': payload}),
        ),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
      ],
    );
    addTearDown(container.dispose);
    final connection =
        container.read(connectionProvider.notifier) as _FakeConnectionNotifier;
    connection.forceOnline();
    final pull = await container.read(syncEngineProvider).pull();
    expect(pull.errors, isEmpty);

    connection.forceOffline();
    final roster = await container.read(
      assessmentGradesProvider(
        (
          assessmentId: 1,
          classSubjectId: 1,
          periodId: 1,
          classroomId: 1,
        ),
      ).future,
    );

    final entry = roster.singleWhere((grade) => grade.studentId == 1);
    expect(entry.gradeId, 501);
    expect(entry.value, 14.5);
    expect(entry.comment, 'Bonne réponse');
  });

  test('les périodes chargées en ligne restent disponibles hors-ligne',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.classrooms).insert(
          ClassroomsCompanion.insert(
            id: const Value(1),
            name: '2nde A',
            cycleId: const Value(1),
          ),
        );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith(
          (ref) => _routingDio({
            '/settings/periods': _payloads['settings_periods'] as Object,
          }),
        ),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(() => _FakeAuthNotifier(const AuthState())),
      ],
    );
    addTearDown(container.dispose);
    final connection =
        container.read(connectionProvider.notifier) as _FakeConnectionNotifier;
    connection.forceOnline();

    final online = await container.read(periodsProvider.future);
    expect(online, hasLength(1));
    expect(await db.select(db.periods).get(), hasLength(1));

    connection.forceOffline();
    final offline = await container.read(periodsForClassroomProvider(1).future);
    expect(offline, hasLength(1));
    expect(offline.single.id, online.single.id);
  });

  test('les classes récupérées en ligne alimentent les sélecteurs hors-ligne',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    const classroomPayload = {
      'items': [
        {
          'id': 1,
          'name': '2nde A',
          'head_teacher_id': 7,
          'max_students': 40,
          'is_active': true,
        },
      ],
    };
    final online = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith(
          (ref) => _routingDio({'/classrooms': classroomPayload}),
        ),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(
          () => _FakeAuthNotifier(
            const AuthState(
              user: UserDto(id: 1, username: 'admin', role: 'ADMIN'),
              token: 'token',
            ),
          ),
        ),
      ],
    );
    addTearDown(online.dispose);
    (online.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOnline();

    expect(await online.read(classroomsForGradesProvider.future), hasLength(1));
    expect(
        await online.read(classroomsForScheduleProvider.future), hasLength(1));
    expect(await db.select(db.classrooms).get(), hasLength(1));

    final offline = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith((ref) => _routingDio(const {})),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(
          () => _FakeAuthNotifier(
            const AuthState(
              user: UserDto(id: 1, username: 'admin', role: 'ADMIN'),
              token: 'token',
            ),
          ),
        ),
      ],
    );
    addTearDown(offline.dispose);
    (offline.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOffline();

    expect(
      (await offline.read(classroomsForGradesProvider.future)).single.name,
      '2nde A',
    );
    expect(
      (await offline.read(classroomsForScheduleProvider.future)).single.name,
      '2nde A',
    );
  });

  test(
      'le pull initial rend notes, évaluations et périodes filtrées disponibles hors-ligne',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final payload = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(_payloads['sync_pull'])) as Map,
    );
    final tables = payload['tables'] as Map<String, dynamic>;
    tables['levels'] = {
      'rows': [
        {'id': 1, 'name': 'Seconde', 'cycle_id': 1},
      ],
      'ids': [1],
      'has_more': false,
    };
    final periods = tables['periods'] as Map<String, dynamic>;
    (periods['rows'] as List).add({
      'id': 2,
      'school_year_id': 1,
      'cycle_id': 2,
      'name': 'Trimestre collège',
      'start_date': '2026-09-01',
      'end_date': '2026-12-18',
      'weight': 1.0,
      'is_active': true,
    });
    (periods['ids'] as List).add(2);
    final assessments = tables['assessments'] as Map<String, dynamic>;
    (assessments['rows'] as List).add({
      'id': 2,
      'class_subject_id': 1,
      'period_id': 2,
      'name': 'Évaluation autre cycle',
      'max_score': 20,
      'date_taken': '2026-10-12',
    });
    (assessments['ids'] as List).add(2);
    tables['grades'] = {
      'rows': [
        {
          'id': 21,
          'assessment_id': 1,
          'student_id': 1,
          'score': 15.5,
          'is_absent': false,
          'comment': 'Note synchronisée',
        },
      ],
      'ids': [21],
      'has_more': false,
    };
    tables['weekly_schedules'] = {
      'rows': [
        {
          'id': 31,
          'classroom_id': 1,
          'subject_id': 1,
          'teacher_id': 1,
          'time_slot_id': 1,
          'day_of_week': 1,
          'start_time': '08:00',
          'end_time': '09:00',
          'week_type': null,
        },
      ],
      'ids': [31],
      'has_more': false,
    };

    final authState = AuthState(
      user: const UserDto(id: 1, username: 'teacher', role: 'TEACHER'),
      token: 'token',
      permissions: const ['GRADE_READ', 'GRADE_EDIT'],
    );
    final online = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith((ref) => _routingDio({'/sync/pull': payload})),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(() => _FakeAuthNotifier(authState)),
      ],
    );
    addTearDown(online.dispose);
    (online.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOnline();
    final pull = await online.read(syncEngineProvider).pull();
    expect(pull.errors, isEmpty);

    final offline = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith((ref) => _routingDio(const {})),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(() => _FakeAuthNotifier(authState)),
      ],
    );
    addTearDown(offline.dispose);
    (offline.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOffline();

    final classrooms = await offline.read(classroomsForGradesProvider.future);
    expect(classrooms.map((c) => c.id), contains(1));
    final periodList =
        await offline.read(periodsForClassroomProvider(1).future);
    expect(periodList.map((p) => p.id), [1]);
    final subjects = await offline.read(classSubjectsProvider(1).future);
    expect(subjects.map((s) => s.subjectName), ['Mathématiques']);
    final localAssessments = await offline.read(
      assessmentsProvider(
        const AssessmentsQuery(classSubjectId: 1, periodId: 1),
      ).future,
    );
    expect(localAssessments.map((a) => a.name), ['Devoir 1']);
    final grades = await offline.read(
      assessmentGradesProvider(
        (
          assessmentId: 1,
          classSubjectId: 1,
          periodId: 1,
          classroomId: 1,
        ),
      ).future,
    );
    final studentGrade = grades.singleWhere((grade) => grade.studentId == 1);
    expect(studentGrade.value, 15.5);
    expect(studentGrade.comment, 'Note synchronisée');
    final schedule = await offline.read(classroomScheduleProvider(1).future);
    expect(schedule.map((entry) => entry.id), [31]);
  });

  test('matières, évaluations et EDT retombent sur Drift si le serveur tombe',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.classrooms).insert(
          ClassroomsCompanion.insert(
            id: const Value(1),
            name: '2nde A',
            cycleId: const Value(1),
          ),
        );
    await db.into(db.subjects).insert(
          SubjectsCompanion.insert(
            id: const Value(2),
            name: 'Mathématiques',
          ),
        );
    await db.into(db.classSubjects).insert(
          ClassSubjectsCompanion.insert(
            id: const Value(20),
            classroomId: 1,
            subjectId: 2,
            coefficient: const Value(3),
            teacherId: const Value(7),
          ),
        );
    await db.into(db.assessments).insert(
          AssessmentsCompanion.insert(
            id: const Value(30),
            classSubjectId: 20,
            periodId: const Value(1),
            title: 'Interrogation',
          ),
        );
    await db.into(db.weeklySchedules).insert(
          WeeklySchedulesCompanion.insert(
            id: const Value(40),
            classroomId: const Value(1),
            subjectId: const Value(2),
            teacherId: const Value(7),
            timeSlotId: 1,
            dayOfWeek: 1,
            startTime: const Value('08:00'),
            endTime: const Value('09:00'),
            weekType: const Value('ALL'),
          ),
        );

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith((ref) => _routingDio(const {})),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(
          () => _FakeAuthNotifier(
            const AuthState(
              user: UserDto(id: 7, username: 'teacher', role: 'TEACHER'),
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    (container.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOnline();

    final subjects = await container.read(classSubjectsProvider(1).future);
    expect(subjects.single.subjectName, 'Mathématiques');

    final assessments = await container.read(
      assessmentsProvider(
        const AssessmentsQuery(classSubjectId: 20, periodId: 1),
      ).future,
    );
    expect(assessments.single.name, 'Interrogation');

    final schedule = await container.read(classroomScheduleProvider(1).future);
    expect(schedule.single.id, 40);
    expect(schedule.single.subjectName, 'Mathématiques');
  });

  test('la liste Utilisateurs replie sur Drift après un timeout réseau',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: const Value(7),
            username: 'awa.k',
            firstName: const Value('Awa'),
            lastName: const Value('Koffi'),
            email: const Value('awa@example.org'),
          ),
        );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith((ref) => _routingDio(const {})),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
      ],
    );
    addTearDown(container.dispose);
    (container.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOnline();

    final users = await container.read(usersListProvider('awa').future);

    expect(users, hasLength(1));
    expect(users.single.username, 'awa.k');
    expect(users.single.fullName, 'Awa Koffi');
  });

  test('une note saisie hors-ligne est rejouée à la reconnexion', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.classSubjects).insert(
          ClassSubjectsCompanion.insert(
            id: const Value(10),
            classroomId: 1,
            subjectId: 2,
          ),
        );
    await db.into(db.assessments).insert(
          AssessmentsCompanion.insert(
            id: const Value(100),
            classSubjectId: 10,
            title: 'Devoir local',
          ),
        );
    await db.into(db.students).insert(
          StudentsCompanion.insert(
            id: const Value(7),
            matricule: 'MAT-7',
            nom: 'Élève',
          ),
        );
    await db.into(db.studentClassAssignments).insert(
          StudentClassAssignmentsCompanion.insert(
            studentId: 7,
            classroomId: 1,
          ),
        );

    final requests = <RequestOptions>[];
    final dio = _routingDio({
      '/grades/assessments/100/grades': {
        'saved_count': 1,
        'results': [
          {'student_id': 7, 'action': 'saved', 'grade_id': 700},
        ],
      },
    });
    dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          handler.next(options);
        },
      ),
    );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith((ref) => dio),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
      ],
    );
    addTearDown(container.dispose);
    final connection =
        container.read(connectionProvider.notifier) as _FakeConnectionNotifier;
    connection.forceOffline();

    final save = await container.read(gradeControllerProvider).saveGrades(
      100,
      const [
        GradeEntryDto(studentId: 7, value: 16.5),
      ],
    );
    expect(save.offlineQueued, isTrue);
    final offlineRoster = await container.read(
      assessmentGradesProvider(
        (
          assessmentId: 100,
          classSubjectId: 10,
          periodId: null,
          classroomId: 1,
        ),
      ).future,
    );
    expect(offlineRoster.single.value, 16.5);

    connection.forceOnline();
    final push = await container.read(syncEngineProvider).push();

    expect(push.errors, isEmpty);
    expect(push.pushed, 1);
    expect(await container.read(outboxProvider).pendingCount(), 0);
    expect(requests, hasLength(1));
    expect(requests.single.data['grades'].single['value'], 16.5);
  });

  test('un profil non connecté lit aussi le roster Drift des notes', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.classSubjects).insert(
          ClassSubjectsCompanion.insert(
            id: const Value(10),
            classroomId: 1,
            subjectId: 2,
          ),
        );
    await db.into(db.assessments).insert(
          AssessmentsCompanion.insert(
            id: const Value(100),
            classSubjectId: 10,
            title: 'Devoir local',
          ),
        );
    await db.into(db.students).insert(
          StudentsCompanion.insert(
            id: const Value(7),
            matricule: 'MAT-7',
            nom: 'Élève',
          ),
        );
    await db.into(db.studentClassAssignments).insert(
          StudentClassAssignmentsCompanion.insert(
            studentId: 7,
            classroomId: 1,
          ),
        );

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
      ],
    );
    addTearDown(container.dispose);

    final roster = await container.read(
      assessmentGradesProvider(
        (
          assessmentId: 100,
          classSubjectId: 10,
          periodId: null,
          classroomId: 1,
        ),
      ).future,
    );

    expect(roster, hasLength(1));
    expect(roster.single.studentId, 7);
  });

  test('un pull partiel ne valide pas le curseur de synchronisation', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final previousSyncAt = DateTime.utc(2026, 1, 1);
    final payload = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(_payloads['sync_pull'])) as Map,
    );
    final tables = payload['tables'] as Map<String, dynamic>;
    final classrooms = tables['classrooms'] as Map<String, dynamic>;
    final classroomRows = classrooms['rows'] as List<dynamic>;
    (classroomRows.first as Map<String, dynamic>)['name'] = '';

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        dioProvider.overrideWith(
          (ref) => _routingDio({
            '/sync/pull': payload,
          }),
        ),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
      ],
    );
    addTearDown(container.dispose);
    (container.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOnline(lastSyncAt: previousSyncAt);

    final result = await container.read(syncEngineProvider).pull();

    expect(
      result.errors,
      isNotEmpty,
      reason: 'la ligne invalide doit signaler un pull partiel',
    );
    expect(
      container.read(connectionProvider).lastSyncAt,
      previousSyncAt,
      reason: 'le prochain pull doit retenter les lignes non répliquées',
    );

    (classroomRows.first as Map<String, dynamic>)['name'] = '2nde A';
    final retry = await container.read(syncEngineProvider).pull();
    expect(retry.errors, isEmpty);
    expect(
      container.read(connectionProvider).lastSyncAt!.isAfter(previousSyncAt),
      isTrue,
    );
    expect((await db.select(db.classrooms).get()).single.name, '2nde A');
  });

  test('effectif hors-ligne reflète les assignations locales actives',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.schoolYears).insert(
          SchoolYearsCompanion.insert(
            name: '2025-2026',
            isActive: const Value(true),
          ),
        );
    await db.into(db.classrooms).insert(
          ClassroomsCompanion.insert(
            id: const Value(1),
            name: '2nde A',
            currentStudentsCount: const Value(9),
          ),
        );
    for (var studentId = 1; studentId <= 2; studentId++) {
      await db.into(db.studentClassAssignments).insert(
            StudentClassAssignmentsCompanion.insert(
              studentId: studentId,
              classroomId: 1,
              schoolYearId: const Value(1),
            ),
          );
    }

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
      ],
    );
    addTearDown(container.dispose);
    (container.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOffline();

    await container.read(classroomsProvider.notifier).refresh();

    final classrooms = container.read(classroomsProvider).requireValue;
    expect(classrooms.single.currentStudentsCount, 2);
  });

  test(
      'login EN LIGNE réel (production : roles=[]) → enseignant détecté par '
      'repli User.role + instantané persisté', () async {
    final storage = _FakeSecureStorage();
    final dio = _routingDio({
      '/auth/login': _realLogin,
    });
    final container = ProviderContainer(
      overrides: [
        secureStorageProvider.overrideWith((ref) => storage),
        dioProvider.overrideWith((ref) => dio),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(() => _FakeAuthNotifier(const AuthState())),
      ],
    );
    addTearDown(container.dispose);
    (container.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOnline();

    final ok = await container.read(authProvider.notifier).login(
          username: 'r12oc_teacher',
          password: 'motdepasse',
          establishmentCode: 'R12-01',
        );

    // Le login doit réussir — c'est la régression « Accès refusé.
    // Permissions insuffisantes. » (403 lien manquant) côté serveur,
    // désormais réparée par le self-heal ; côté mobile, le payload
    // production doit être consommé tel quel.
    expect(ok, isTrue, reason: 'le login production doit réussir');
    final auth = container.read(authProvider);
    expect(auth.isAuthenticated, isTrue);
    expect(auth.error, isNull);

    // FORME PRODUCTION : roles vide, User.role='teacher'.
    expect(
      auth.roles,
      isEmpty,
      reason: 'le serveur legacy ne renvoie AUCUN rôle RBAC',
    );
    expect(auth.user?.role, 'teacher');
    expect(auth.user?.username, 'r12oc_teacher');

    // Détection enseignant PAR REPLI — les portes UI (Notes, Élèves,
    // EDT) en dépendent.
    expect(
      auth.hasDeclaredTeacherRole,
      isTrue,
      reason: 'rôle enseignant détecté via User.role malgré roles=[]',
    );
    expect(
      auth.isTeacherOnly,
      isTrue,
      reason: 'un enseignant legacy doit être traité comme enseignant',
    );
    expect(
      auth.permissions,
      contains('GRADE_EDIT'),
      reason: 'permissions TEACHER servies par le repli legacy serveur',
    );

    // Instantané + identifiants persistés (prérequis de la connexion
    // hors-ligne ultérieure).
    expect(storage._store, contains('getech.credentials.p-test'));
    final prefs = await SharedPreferences.getInstance();
    final snap = prefs.getString('session_snapshot_p-test');
    expect(snap, isNotNull, reason: "l'instantané doit être persisté");
    final snapJson = jsonDecode(snap!) as Map<String, dynamic>;
    expect(snapJson['roles'], isEmpty);
    expect((snapJson['user'] as Map)['role'], 'teacher');
  });

  test(
      'EN LIGNE (login réel + sync) → REDÉMARRAGE hors-ligne → login local '
      '→ session production restaurée + les 3 élèves notables', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final storage = _FakeSecureStorage();

    // Ordre IMPORTANT : le roster AVANT /grades/assessments (contains).
    final dataRoutes = <String, Object>{
      '/auth/login': _realLogin,
      '/sync/pull': _payloads['sync_pull'] as Object,
      '/grades/assessments/1/grades': _payloads['assessment_grades'] as Object,
      '/grades/assessments': _payloads['assessments'] as Object,
      '/grades/class-subjects': _payloads['class_subjects'] as Object,
      '/students': _payloads['students'] as Object,
      '/settings/periods': _payloads['settings_periods'] as Object,
      '/classrooms': _payloads['classrooms'] as Object,
    };

    // ---- PHASE EN LIGNE : login réel + synchro + consultation ----
    final online = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        secureStorageProvider.overrideWith((ref) => storage),
        dioProvider.overrideWith((ref) => _routingDio(dataRoutes)),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(() => _FakeAuthNotifier(const AuthState())),
      ],
    );
    addTearDown(online.dispose);
    (online.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOnline();

    final ok = await online.read(authProvider.notifier).login(
          username: 'r12oc_teacher',
          password: 'motdepasse',
          establishmentCode: 'R12-01',
        );
    expect(ok, isTrue, reason: 'login en ligne (self-heal serveur)');

    final pull = await online.read(syncEngineProvider).pull();
    expect(pull.errors, isEmpty, reason: 'le sync pull ne doit pas échouer');

    final assessmentsOnline = await online.read(
      assessmentsProvider(
        const AssessmentsQuery(classSubjectId: 1, periodId: 1),
      ).future,
    );
    expect(assessmentsOnline, isNotEmpty, reason: 'évaluation en ligne');

    final rosterOnline = await online.read(
      assessmentGradesProvider(
        (
          assessmentId: 1,
          classSubjectId: 1,
          periodId: 1,
          classroomId: 1,
        ),
      ).future,
    );
    expect(rosterOnline, hasLength(3), reason: 'roster complet en ligne');

    // ---- REDÉMARRAGE HORS-LIGGE : nouveau container, réseau KO ----
    final offline = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        secureStorageProvider.overrideWith((ref) => storage),
        dioProvider.overrideWith((ref) {
          final dio = Dio(
            BaseOptions(
              connectTimeout: const Duration(milliseconds: 50),
            ),
          );
          dio.interceptors.add(_NetworkDownInterceptor());
          return dio;
        }),
        connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
        authProvider.overrideWith(() => _FakeAuthNotifier(const AuthState())),
      ],
    );
    addTearDown(offline.dispose);
    (offline.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOffline();

    // Connexion à sa session EN MODE HORS-LIGNE (le retour utilisateur) :
    // échec réseau → identifiants stockés → instantané → session locale.
    final okOffline = await offline.read(authProvider.notifier).login(
          username: 'r12oc_teacher',
          password: 'motdepasse',
          establishmentCode: 'R12-01',
        );
    expect(okOffline, isTrue, reason: 'la connexion hors-ligne doit réussir');
    final auth = offline.read(authProvider);
    expect(auth.isAuthenticated, isTrue);
    expect(auth.roles, isEmpty, reason: 'forme production conservée');
    expect(
      auth.hasDeclaredTeacherRole,
      isTrue,
      reason: '[offline] enseignant détecté par repli User.role',
    );
    expect(
      auth.isTeacherOnly,
      isTrue,
      reason: '[offline] les portes enseignant restent ouvertes',
    );
    expect(
      auth.permissions,
      contains('GRADE_EDIT'),
      reason: '[offline] permissions restaurées depuis l\'instantané',
    );

    // Saisie de notes HORS-LIGNE (le retour utilisateur majeur) :
    // la chaîne doit lister les 3 élèves — « Aucun élève à noter » sinon.
    final assessmentsOffline = await offline.read(
      assessmentsProvider(
        const AssessmentsQuery(classSubjectId: 1, periodId: 1),
      ).future,
    );
    expect(
      assessmentsOffline,
      isNotEmpty,
      reason: "[offline] l'évaluation doit venir du cache",
    );

    final rosterOffline = await offline.read(
      assessmentGradesProvider(
        (
          assessmentId: 1,
          classSubjectId: 1,
          periodId: 1,
          classroomId: 1,
        ),
      ).future,
    );
    expect(
      rosterOffline,
      hasLength(3),
      reason: '[offline] les 3 élèves de la classe doivent être notables',
    );
    expect(
      rosterOffline.map((e) => e.studentName),
      containsAll(
        ['Élève1 Prénom', 'Élève2 Prénom', 'Élève3 Prénom'],
      ),
    );
  });
}
