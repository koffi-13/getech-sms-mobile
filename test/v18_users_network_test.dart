// test/v18_users_network_test.dart
//
// Symptôme n°6 : « Les erreurs réseau de modules comme "Utilisateurs" ne
// doivent pas apparaître comme des erreurs brutes de timeout si un repli
// local prévu est disponible. Ne masque cependant pas les erreurs
// fonctionnelles ou d'autorisation sous une liste vide. »
//
// Vérifie le comportement de usersListProvider quand :
//   1. la requête TIMEOUT (receiveTimeout) → repli local Drift, PAS
//      d'erreur brute remontée à l'UI ;
//   2. la connexion échoue (connectionError / connection refused) → repli
//      local Drift ;
//   3. le serveur répond 403 → liste vide (autorisation : le repli local
//      ne doit PAS contourner la restriction serveur) ;
//   4. le serveur répond 422 (erreur fonctionnelle) → l'erreur remonte
//      (pas de masquage sous une liste vide).
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:getech_sms_mobile/core/database/database.dart';
import 'package:getech_sms_mobile/core/network/auth_interceptor.dart';
import 'package:getech_sms_mobile/core/network/dio_client.dart';
import 'package:getech_sms_mobile/core/network/api_exceptions.dart';
import 'package:getech_sms_mobile/features/connections/connection_state.dart';
import 'package:getech_sms_mobile/features/users/user_controller.dart';

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
}

/// Dio qui rejette chaque requête avec l'erreur réseau demandée (mêmes
/// types DioException que ceux produits par un vrai timeout / une vraie
/// coupure réseau), puis convertit via ApiExceptionInterceptor (chaîne
/// identique au dioProvider de production).
Dio _networkDownDio(DioExceptionType type) {
  final dio = Dio(BaseOptions());
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.reject(
          DioException(
            requestOptions: options,
            type: type,
            error: type == DioExceptionType.receiveTimeout
                ? 'Receive timeout after 30000ms'
                : SocketExceptionSim('Connection refused'),
          ),
        );
      },
    ),
  );
  dio.interceptors.add(ApiExceptionInterceptor());
  return dio;
}

/// Simule l'erreur socket sous-jacente (toString réaliste).
class SocketExceptionSim {
  const SocketExceptionSim(this.message);
  final String message;

  @override
  String toString() => 'SocketException: $message';
}

/// Dio qui rejette avec une réponse HTTP du statut donné.
Dio _httpErrorDio(int status, Map<String, dynamic> body) {
  final dio = Dio(BaseOptions());
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.reject(
          DioException(
            requestOptions: options,
            type: DioExceptionType.badResponse,
            response: Response(
              requestOptions: options,
              statusCode: status,
              data: body,
            ),
          ),
        );
      },
    ),
  );
  dio.interceptors.add(ApiExceptionInterceptor());
  return dio;
}

Future<void> _seedLocalUser(AppDatabase db) async {
  await db.into(db.users).insert(
        UsersCompanion.insert(
          id: const Value(7),
          username: 'awa.k',
          firstName: const Value('Awa'),
          lastName: const Value('Koffi'),
          email: const Value('awa@example.org'),
        ),
      );
}

ProviderContainer _container(AppDatabase db, Dio dio) {
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWith((ref) => db),
      dioProvider.overrideWith((ref) => dio),
      connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
    ],
  );
  (container.read(connectionProvider.notifier) as _FakeConnectionNotifier)
      .forceOnline();
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('timeout réseau (receiveTimeout) → repli Drift, pas d\'erreur brute',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedLocalUser(db);

    final container = _container(
      db,
      _networkDownDio(DioExceptionType.receiveTimeout),
    );
    addTearDown(container.dispose);

    final users = await container.read(usersListProvider('').future);
    expect(users, hasLength(1),
        reason: 'timeout réseau : repli local Drift (pas d\'erreur brute)');
    expect(users.single.username, 'awa.k');
    expect(users.single.fullName, 'Awa Koffi');
  });

  test('connexion refusée (connectionError) → repli Drift', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedLocalUser(db);

    final container = _container(
      db,
      _networkDownDio(DioExceptionType.connectionError),
    );
    addTearDown(container.dispose);

    final users = await container.read(usersListProvider('').future);
    expect(users, hasLength(1),
        reason: 'connexion refusée : repli local Drift (pas d\'erreur brute)');
  });

  test('403 serveur → liste vide (autorisation, PAS un repli local)', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedLocalUser(db);

    final container = _container(
      db,
      _httpErrorDio(403, {'detail': 'Permission insuffisante'}),
    );
    addTearDown(container.dispose);

    final users = await container.read(usersListProvider('').future);
    expect(users, isEmpty,
        reason: '403 = refus d\'autorisation : le repli local ne doit PAS '
            'contourner la restriction serveur');
  });

  test('422 serveur (erreur fonctionnelle) → l\'erreur remonte à l\'UI',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedLocalUser(db);

    final container = _container(
      db,
      _httpErrorDio(
        422,
        {
          'detail': [
            {
              'type': 'missing',
              'loc': ['body', 'search'],
              'msg': 'Field required',
            },
          ],
        },
      ),
    );
    addTearDown(container.dispose);

    await expectLater(
      container.read(usersListProvider('').future),
      throwsA(isA<ApiException>()),
      reason: 'une erreur fonctionnelle serveur ne doit pas être masquée '
          'sous une liste vide',
    );
  });
}
