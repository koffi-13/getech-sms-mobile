// test/v11_offline_login_test.dart
//
// [Fix-OFFLINE-LOGIN] + [Fix-401-RELOGIN] V11 — « la connexion à sa
// session en mode hors-ligne » :
//
// 1. Hors-ligne (échec RÉSEAU du POST /auth/login) + identifiants stockés
//    correspondants + instantané de session → la session est restaurée
//    LOCALEMENT (l'enseignant travaille sur le cache Drift + outbox).
// 2. Mauvais mot de passe hors-ligne → refusé (la comparaison locale
//    reste le garde-fou).
// 3. Un 401 (token périmé, ex. serveur redémarré) avec re-login
//    impossible NE DOIT PLUS effacer l'instantané ni les identifiants :
//    la reconnexion hors-ligne reste possible.
// 4. Un 401 avec re-login réussi (serveur joignable, mot de passe
//    inchangé) → session restaurée SANS interruption.
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:getech_sms_mobile/core/auth/auth_state.dart';
import 'package:getech_sms_mobile/core/auth/secure_storage.dart';
import 'package:getech_sms_mobile/core/network/dio_client.dart';
import 'package:getech_sms_mobile/features/connections/connection_state.dart';
import 'package:getech_sms_mobile/shared/models/auth_dto.dart';

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
      String profileId) async {
    final raw = _store[profileKey('getech.credentials', profileId)];
    if (raw == null || !raw.contains(':::')) return null;
    final parts = raw.split(':::');
    return (username: parts[0], password: parts[1]);
  }

  @override
  Future<void> saveCredentialsFor(
      String profileId, String username, String password) async {
    _store[profileKey('getech.credentials', profileId)] =
        '$username:::$password';
  }

  @override
  Future<void> saveCredentials(String username, String password) async =>
      _store['getech.credentials'] = '$username:::$password';
}

/// Notifier de connexion piloté : état « en ligne » puis « hors-ligne ».
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

/// Interceptor réseau KO pour TOUTE requête.
class _NetworkDownInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    handler.reject(DioException.connectionError(
      requestOptions: options,
      reason: 'hors-ligne',
    ));
  }
}

/// Interceptor : 401 pour toute requête SAUF /auth/login (200 + jeton neuf).
class _UnauthorizedButReloginInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.uri.path.endsWith('/auth/login')) {
      handler.resolve(Response(
        requestOptions: options,
        statusCode: 200,
        data: _loginBody,
      ));
      return;
    }
    handler.reject(DioException(
      requestOptions: options,
      response: Response(
        requestOptions: options,
        statusCode: 401,
        data: {'detail': 'Token invalide'},
      ),
      type: DioExceptionType.badResponse,
    ));
  }
}

/// Interceptor : 401 pour TOUT, y compris /auth/login (mot de passe changé).
class _AllUnauthorizedInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    handler.reject(DioException(
      requestOptions: options,
      response: Response(
        requestOptions: options,
        statusCode: 401,
        data: {'detail': 'Invalid credentials'},
      ),
      type: DioExceptionType.badResponse,
    ));
  }
}

const _loginBody = {
  'access_token': 'jeton-neuf-apres-relogin',
  'token_type': 'bearer',
  'user': {
    'id': 7,
    'username': 'prof',
    'email': 'prof@etab.local',
    'is_active': true,
    'role': 'teacher',
  },
  'roles': [
    {'id': 2, 'code': 'TEACHER', 'name': 'Enseignant'},
  ],
  'permissions': ['GRADE_READ', 'GRADE_EDIT'],
  'establishment': {
    'id': 1,
    'code': 'R11-01',
    'name': 'Lycée Repro V11',
  },
};

const _snapshotBody = {
  'user': {
    'id': 7,
    'username': 'prof',
    'email': 'prof@etab.local',
    'is_active': true,
    'role': 'teacher',
  },
  'permissions': ['GRADE_READ', 'GRADE_EDIT'],
  'roles': ['TEACHER'],
  'establishmentId': 1,
};

class _FakeAuthNotifier extends AuthNotifier {
  _FakeAuthNotifier(this.initial);
  final AuthState initial;

  @override
  AuthState build() => initial;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  ProviderContainer _container({
    required SecureStorage storage,
    required Dio dio,
  }) {
    final container = ProviderContainer(overrides: [
      secureStorageProvider.overrideWith((ref) => storage),
      dioProvider.overrideWith((ref) => dio),
      connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
      authProvider.overrideWith(() => _FakeAuthNotifier(const AuthState())),
    ]);
    return container;
  }

  Dio _networkDownDio() {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(milliseconds: 50),
    ));
    dio.interceptors.add(_NetworkDownInterceptor());
    return dio;
  }

  test(
      'hors-ligne + identifiants corrects + instantané → session locale '
      'restaurée (isAuthenticated)', () async {
    final storage = _FakeSecureStorage();
    await storage.saveCredentialsFor('p-test', 'prof', 'motdepasse');
    await storage.saveJwtFor('p-test', 'jeton-avant-hors-ligne');
    SharedPreferences.setMockInitialValues({
      'session_snapshot_p-test': _snapshotBodyEncoded,
    });

    final container = _container(storage: storage, dio: _networkDownDio());
    addTearDown(container.dispose);
    (container.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOffline();

    final ok = await container.read(authProvider.notifier).login(
          username: 'prof',
          password: 'motdepasse',
          establishmentCode: 'R11-01',
        );

    expect(ok, isTrue, reason: 'la connexion hors-ligne doit réussir');
    final auth = container.read(authProvider);
    expect(auth.isAuthenticated, isTrue);
    expect(auth.user?.username, 'prof');
    expect(auth.permissions, contains('GRADE_EDIT'));
    expect(auth.roles, contains('TEACHER'));
  });

  test('hors-ligne + MAUVAIS mot de passe → refusé', () async {
    final storage = _FakeSecureStorage();
    await storage.saveCredentialsFor('p-test', 'prof', 'motdepasse');
    SharedPreferences.setMockInitialValues({
      'session_snapshot_p-test': _snapshotBodyEncoded,
    });

    final container = _container(storage: storage, dio: _networkDownDio());
    addTearDown(container.dispose);
    (container.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOffline();

    final ok = await container.read(authProvider.notifier).login(
          username: 'prof',
          password: 'MAUVAIS',
          establishmentCode: 'R11-01',
        );

    expect(ok, isFalse);
    final auth = container.read(authProvider);
    expect(auth.isAuthenticated, isFalse);
    expect(auth.error, isNotNull);
  });

  test(
      '401 avec re-login IMPOSSIBLE → le JWT est retiré mais l\'instantané '
      'et les identifiants SONT CONSERVÉS (reconnexion hors-ligne possible)',
      () async {
    final storage = _FakeSecureStorage();
    await storage.saveCredentialsFor('p-test', 'prof', 'motdepasse');
    await storage.saveJwtFor('p-test', 'jeton-perime');
    SharedPreferences.setMockInitialValues({
      'session_snapshot_p-test': _snapshotBodyEncoded,
    });

    final dio = Dio(BaseOptions());
    dio.interceptors.add(_AllUnauthorizedInterceptor());

    // Session OUVERTE avec le token périmé (le 401 frappe un utilisateur
    // connecté, pas un état vide).
    final container = ProviderContainer(overrides: [
      secureStorageProvider.overrideWith((ref) => storage),
      dioProvider.overrideWith((ref) => dio),
      connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
      authProvider.overrideWith(() => _FakeAuthNotifier(const AuthState(
        token: 'jeton-perime',
        user: UserDto(id: 7, username: 'prof', role: 'teacher'),
        permissions: ['GRADE_READ'],
        roles: ['TEACHER'],
      ))),
    ]);
    addTearDown(container.dispose);
    (container.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOnline();

    final notifier = container.read(authProvider.notifier);
    await notifier.handleUnauthorized();

    final auth = container.read(authProvider);
    expect(auth.isAuthenticated, isFalse,
        reason: 'le token refusé ne doit plus être utilisé');
    // L'instantané DOIT survivre : reconnexion hors-ligne possible.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('session_snapshot_p-test'), isNotNull,
        reason:
            '[Fix-401-RELOGIN] l\'instantané ne doit plus être effacé par un 401');
    final creds = await storage.getCredentialsFor('p-test');
    expect(creds, isNotNull,
        reason: 'les identifiants stockés doivent survivre au 401');
  });

  test(
      '401 avec re-login RÉUSSI (serveur joignable, mot de passe inchangé) '
      '→ session restaurée sans interruption', () async {
    final storage = _FakeSecureStorage();
    await storage.saveCredentialsFor('p-test', 'prof', 'motdepasse');
    await storage.saveJwtFor('p-test', 'jeton-perime');

    final dio = Dio(BaseOptions());
    dio.interceptors.add(_UnauthorizedButReloginInterceptor());

    // Session OUVERTE avec le token périmé (le 401 frappe un utilisateur
    // connecté, pas un état vide).
    final container = ProviderContainer(overrides: [
      secureStorageProvider.overrideWith((ref) => storage),
      dioProvider.overrideWith((ref) => dio),
      connectionProvider.overrideWith((ref) => _FakeConnectionNotifier(ref)),
      authProvider.overrideWith(() => _FakeAuthNotifier(const AuthState(
        token: 'jeton-perime',
        user: UserDto(id: 7, username: 'prof', role: 'teacher'),
        permissions: ['GRADE_READ'],
        roles: ['TEACHER'],
      ))),
    ]);
    addTearDown(container.dispose);
    (container.read(connectionProvider.notifier) as _FakeConnectionNotifier)
        .forceOnline();

    // État initial : session ouverte avec le token périmé (comme en vrai —
    // le 401 arrive alors que l'utilisateur EST connecté).
    final notifier = container.read(authProvider.notifier);
    await notifier.handleUnauthorized();

    final auth = container.read(authProvider);
    expect(auth.isAuthenticated, isTrue,
        reason: 'le re-login silencieux doit restaurer la session');
    expect(auth.token, 'jeton-neuf-apres-relogin');
    expect(auth.user?.username, 'prof');
    // Le nouveau jeton est persisté pour les prochains démarrages.
    expect(await storage.getJwtFor('p-test'), 'jeton-neuf-apres-relogin');
  });
}

/// Instantané sérialisé (JSON) tel que persisté par _writeSnapshot.
const String _snapshotBodyEncoded =
    '{"user":{"id":7,"public_id":"","username":"prof","email":"prof@etab.local",'
    '"is_active":true,"is_superuser":false,"role":"teacher"},'
    '"permissions":["GRADE_READ","GRADE_EDIT"],"roles":["TEACHER"],'
    '"establishmentId":1}';
