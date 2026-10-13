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
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:getech_sms_mobile/core/auth/auth_state.dart';
import 'package:getech_sms_mobile/core/auth/secure_storage.dart';
import 'package:getech_sms_mobile/core/database/database.dart';
import 'package:getech_sms_mobile/core/network/dio_client.dart';
import 'package:getech_sms_mobile/core/sync/sync_engine.dart';
import 'package:getech_sms_mobile/features/connections/connection_state.dart';
import 'package:getech_sms_mobile/features/grades/grade_controller.dart';

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
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: entry.value,
        ),);
        return;
      }
    }
    handler.reject(DioException.connectionError(
      requestOptions: options,
      reason: 'route inconnue en test : $path',
    ),);
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
    handler.reject(DioException.connectionError(
      requestOptions: options,
      reason: 'hors-ligne',
    ),);
  }
}

/// Notifier de connexion piloté par le test.
class _FakeConnectionNotifier extends ConnectionNotifier {
  _FakeConnectionNotifier(super.ref);

  void forceOnline() {
    state = state.copyWith(
      status: ServerStatus.online,
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
      String profileId,) async {
    final raw = _store[profileKey('getech.credentials', profileId)];
    if (raw == null || !raw.contains(':::')) return null;
    final parts = raw.split(':::');
    return (username: parts[0], password: parts[1]);
  }

  @override
  Future<void> saveCredentialsFor(
      String profileId, String username, String password,) async {
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

  test(
      'login EN LIGNE réel (production : roles=[]) → enseignant détecté par '
      'repli User.role + instantané persisté', () async {
    final storage = _FakeSecureStorage();
    final dio = _routingDio({
      '/auth/login': _realLogin,
    });
    final container = ProviderContainer(overrides: [
      secureStorageProvider.overrideWith((ref) => storage),
      dioProvider.overrideWith((ref) => dio),
      connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
      authProvider.overrideWith(() => _FakeAuthNotifier(const AuthState())),
    ],);
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
    expect(auth.roles, isEmpty,
        reason: 'le serveur legacy ne renvoie AUCUN rôle RBAC',);
    expect(auth.user?.role, 'teacher');
    expect(auth.user?.username, 'r12oc_teacher');

    // Détection enseignant PAR REPLI — les portes UI (Notes, Élèves,
    // EDT) en dépendent.
    expect(auth.hasDeclaredTeacherRole, isTrue,
        reason: 'rôle enseignant détecté via User.role malgré roles=[]',);
    expect(auth.isTeacherOnly, isTrue,
        reason: 'un enseignant legacy doit être traité comme enseignant',);
    expect(auth.permissions, contains('GRADE_EDIT'),
        reason: 'permissions TEACHER servies par le repli legacy serveur',);

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
      '/grades/assessments/1/grades':
          _payloads['assessment_grades'] as Object,
      '/grades/assessments': _payloads['assessments'] as Object,
      '/grades/class-subjects': _payloads['class_subjects'] as Object,
      '/students': _payloads['students'] as Object,
      '/settings/periods': _payloads['settings_periods'] as Object,
      '/classrooms': _payloads['classrooms'] as Object,
    };

    // ---- PHASE EN LIGNE : login réel + synchro + consultation ----
    final online = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) => db),
      secureStorageProvider.overrideWith((ref) => storage),
      dioProvider.overrideWith((ref) => _routingDio(dataRoutes)),
      connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
      authProvider.overrideWith(() => _FakeAuthNotifier(const AuthState())),
    ],);
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

    final assessmentsOnline = await online.read(assessmentsProvider(
      const AssessmentsQuery(classSubjectId: 1, periodId: 1),
    ).future,);
    expect(assessmentsOnline, isNotEmpty, reason: 'évaluation en ligne');

    final rosterOnline = await online.read(assessmentGradesProvider(
      (assessmentId: 1, classSubjectId: 1, periodId: 1),
    ).future,);
    expect(rosterOnline, hasLength(3), reason: 'roster complet en ligne');

    // ---- REDÉMARRAGE HORS-LIGGE : nouveau container, réseau KO ----
    final offline = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) => db),
      secureStorageProvider.overrideWith((ref) => storage),
      dioProvider.overrideWith((ref) {
        final dio = Dio(BaseOptions(
          connectTimeout: const Duration(milliseconds: 50),
        ),);
        dio.interceptors.add(_NetworkDownInterceptor());
        return dio;
      }),
      connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
      authProvider.overrideWith(() => _FakeAuthNotifier(const AuthState())),
    ],);
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
    expect(auth.hasDeclaredTeacherRole, isTrue,
        reason: '[offline] enseignant détecté par repli User.role',);
    expect(auth.isTeacherOnly, isTrue,
        reason: '[offline] les portes enseignant restent ouvertes',);
    expect(auth.permissions, contains('GRADE_EDIT'),
        reason: '[offline] permissions restaurées depuis l\'instantané',);

    // Saisie de notes HORS-LIGNE (le retour utilisateur majeur) :
    // la chaîne doit lister les 3 élèves — « Aucun élève à noter » sinon.
    final assessmentsOffline = await offline.read(assessmentsProvider(
      const AssessmentsQuery(classSubjectId: 1, periodId: 1),
    ).future,);
    expect(assessmentsOffline, isNotEmpty,
        reason: "[offline] l'évaluation doit venir du cache",);

    final rosterOffline = await offline.read(assessmentGradesProvider(
      (assessmentId: 1, classSubjectId: 1, periodId: 1),
    ).future,);
    expect(rosterOffline, hasLength(3),
        reason:
            '[offline] les 3 élèves de la classe doivent être notables',);
    expect(rosterOffline.map((e) => e.studentName), containsAll(
      ['Élève1 Prénom', 'Élève2 Prénom', 'Élève3 Prénom'],
    ),);
  });
}
