// test/teacher_scope_test.dart
//
// [Fix-DASHBOARD-ZERO] + [Fix-SYNC-FIELD-MAP] V7 :
// 1. Le repli Drift du périmètre enseignant doit s'appliquer dès que le
//    réseau ne fournit rien (même si le serveur répond 200-vide, et pas
//    seulement quand un appel échoue) — sinon l'Accueil affiche
//    « Mes classes : 0 / Mes matières : 0 / Cours aujourd'hui : 0 ».
// 2. Le périmètre local doit fusionner class_subjects (matières assignées)
//    ET weekly_schedules (EDT) — les deux sources de la V5.
// 3. La synchro doit relire `assigned_teacher_id` (class_subjects) et
//    `head_teacher_id` (classrooms) : l'ancienne lecture `teacher_id`
//    était TOUJOURS nulle (le repli local restait vide).
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:getech_sms_mobile/core/auth/auth_state.dart';
import 'package:getech_sms_mobile/core/auth/teacher_scope.dart';
import 'package:getech_sms_mobile/core/database/database.dart';
import 'package:getech_sms_mobile/core/network/dio_client.dart';
import 'package:getech_sms_mobile/core/sync/sync_engine.dart';
import 'package:getech_sms_mobile/features/connections/connection_state.dart';
import 'package:getech_sms_mobile/shared/models/auth_dto.dart';

/// Notifier factice : renvoie l'état enseignant sans passer par la
/// restauration de session (flutter_secure_storage n'existe pas en test).
class _FakeAuthNotifier extends AuthNotifier {
  _FakeAuthNotifier(this.initial);
  final AuthState initial;

  @override
  AuthState build() => initial;
}

const _teacherUserId = 7;

/// Interceptor qui fait échouer toute requête (réseau KO).
class _RejectAllInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    handler.reject(
      DioException.connectionError(
        requestOptions: options,
        reason: 'réseau KO (test)',
      ),
    );
  }
}

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

/// Dio dont toutes les requêtes échouent immédiatement (réseau KO).
Dio _failingDio() {
  final dio = Dio(BaseOptions(connectTimeout: const Duration(milliseconds: 50)));
  dio.interceptors.add(_RejectAllInterceptor());
  return dio;
}

/// Dio qui répond 200 avec un JSON arbitraire pour TOUTE requête.
Dio _jsonDio(Object body) {
  final dio = Dio(BaseOptions());
  dio.interceptors.add(_JsonResponderInterceptor(body));
  return dio;
}

AuthState _teacherAuth() => AuthState(
      user: const UserDto(
        id: _teacherUserId,
        username: 'prof',
        role: 'teacher',
      ),
      token: 'test-token',
      permissions: const ['GRADE_READ'], // GRADE_EDIT ABSENT (RBAC incomplet)
      roles: const ['TEACHER'],
      establishmentId: 1,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('teacherScopeProvider — [Fix-DASHBOARD-ZERO]', () {
    test('réseau KO → repli Drift : classes (matières + EDT) + titulariat + cours',
        () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      await seedLocalScope(db);

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWith((ref) {
            ref.onDispose(db.close);
            return db;
          }),
          dioProvider.overrideWith((ref) => _failingDio()),
          authProvider.overrideWith(() => _FakeAuthNotifier(_teacherAuth())),
        ],
      );
      addTearDown(container.dispose);

      // Connexion appairée (l'état réseau lui-même n'entre pas en compte :
      // le scope tente les appels et échoue — c'est le repli qui parle).
      container.read(connectionProvider.notifier).state = ConnectionState(
        status: ServerStatus.offline,
        profileId: 'p-test',
        serverUrlOverride: 'http://192.168.1.10:8000/api/v1',
        establishmentCode: 'EST-TEST',
        pairingToken: 'token-test',
      );

      final scope = await container.read(teacherScopeProvider.future);

      // Classes : 2nde A (matière assignée via class_subjects) +
      // 1ère C (EDT via weekly_schedules) + titulariat détecté.
      expect(scope.isTeacher, isTrue);
      final names = scope.myClassrooms.map((c) => c.name).toList();
      expect(names, containsAll(['2nde A', '1ère C']));

      // Titulariat : la classe locale dont teacherId == moi.
      expect(scope.headClassrooms.map((c) => c.name), contains('2nde A'));

      // EDT : le cours Physique du lundi est dans le périmètre.
      expect(scope.mySchedule, isNotEmpty);
      expect(scope.mySubjectCount, greaterThanOrEqualTo(1));

      // Cours du jour : lundi (semaine A par défaut en cache local).
      final monday = DateTime(2025, 11, 10); // un lundi
      final courses = scope.coursesForDate(monday);
      expect(courses.map((c) => c.subjectName), contains('Physique'));
    });

    test('serveur 200-vide (aucune classe réseau) → le cache local parle quand même',
        () async {
      // Variante : le serveur répond mais avec des listes VIDES. Le repli
      // Drift doit combler les champs vides (l'ancienne condition exigeait
      // un échec d'appel — un serveur ancien renvoyant vide laissait
      // l'Accueil à 0 sans aucune erreur détectable).
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      await seedLocalScope(db);

      final dio = _jsonDio({'items': [], 'total': 0});

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWith((ref) {
            ref.onDispose(db.close);
            return db;
          }),
          dioProvider.overrideWith((ref) => dio),
          authProvider.overrideWith(() => _FakeAuthNotifier(_teacherAuth())),
        ],
      );
      addTearDown(container.dispose);

      container.read(connectionProvider.notifier).state = ConnectionState(
        status: ServerStatus.online,
        profileId: 'p-test',
        serverUrlOverride: 'http://192.168.1.10:8000/api/v1',
        establishmentCode: 'EST-TEST',
        pairingToken: 'token-test',
      );

      final scope = await container.read(teacherScopeProvider.future);

      expect(scope.myClassrooms.map((c) => c.name),
          containsAll(['2nde A', '1ère C']));
      expect(scope.mySchedule, isNotEmpty);
    });
  });

  group('SyncEngine pull — [Fix-SYNC-FIELD-MAP]', () {
    test('class_subjects lit assigned_teacher_id et classrooms lit head_teacher_id',
        () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());

      // Réponse de pull simulée : colonnes EXACTES du serveur
      // (sync_registry._SYNC_COLUMNS) — pas `teacher_id`.
      final serverTime = DateTime.utc(2025, 11, 10, 8).toIso8601String();
      final dio = _jsonDio({
        'server_time': serverTime,
        'max_offline_days': 30,
        'changes': {
          'classrooms': [
            {
              'id': 1,
              'establishment_id': 1,
              'name': '2nde A',
              'level_id': null,
              'series_id': null,
              'stream_id': null,
              'head_teacher_id': _teacherUserId, // ← colonne serveur
              'is_active': true,
            },
          ],
          'class_subjects': [
            {
              'id': 11,
              'establishment_id': 1,
              'classroom_id': 1,
              'subject_id': 3,
              'school_year_id': 2,
              'coefficient': 4.0,
              'is_coefficient_customized': false,
              'assigned_teacher_id': _teacherUserId, // ← colonne serveur
            },
          ],
        },
        'deleted': [],
      });

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWith((ref) {
            ref.onDispose(db.close);
            return db;
          }),
          dioProvider.overrideWith((ref) => dio),
        ],
      );
      addTearDown(container.dispose);

      container.read(connectionProvider.notifier).state = ConnectionState(
        status: ServerStatus.online,
        profileId: 'p-test',
        serverUrlOverride: 'http://192.168.1.10:8000/api/v1',
        establishmentCode: 'EST-TEST',
        pairingToken: 'token-test',
        // lastSyncAt null → since=2000 → une seule page.
      );

      final result = await container.read(syncEngineProvider).pull();
      expect(result.isSuccess, isTrue, reason: result.errors.join('; '));

      final cs = await db.select(db.classSubjects).get();
      expect(cs, hasLength(1));
      expect(cs.single.teacherId, _teacherUserId,
          reason: 'assigned_teacher_id doit atterrir dans teacherId local');

      final classrooms = await db.select(db.classrooms).get();
      expect(classrooms, hasLength(1));
      expect(classrooms.single.teacherId, _teacherUserId,
          reason: 'head_teacher_id doit atterrir dans teacherId local');
    });
  });
}

/// Jeu de données local Drift : matière assignée + EDT + titulariat.
Future<void> seedLocalScope(AppDatabase db) async {
  await db.batch((b) {
    b.insert(db.classrooms, ClassroomsCompanion.insert(
      id: const Value(1),
      name: '2nde A',
      teacherId: const Value(_teacherUserId), // titulaire
    ));
    b.insert(db.classrooms, ClassroomsCompanion.insert(
      id: const Value(2),
      name: '1ère C',
    ));
    b.insert(db.subjects, SubjectsCompanion.insert(
      id: const Value(10),
      name: 'Mathématiques',
    ));
    b.insert(db.subjects, SubjectsCompanion.insert(
      id: const Value(11),
      name: 'Physique',
    ));
    b.insert(db.classSubjects, ClassSubjectsCompanion.insert(
      id: const Value(21),
      classroomId: 1,
      subjectId: 10,
      teacherId: const Value(_teacherUserId),
    ));
    // EDT : cours de Physique en 1ère C le lundi, semaine A.
    b.insert(db.weeklySchedules, WeeklySchedulesCompanion.insert(
      id: const Value(31),
      classroomId: const Value(2),
      subjectId: const Value(11),
      teacherId: const Value(_teacherUserId),
      timeSlotId: 1,
      dayOfWeek: 1,
      startTime: const Value('08:00'),
      endTime: const Value('10:00'),
      weekType: const Value('A'),
    ));
  });
}
