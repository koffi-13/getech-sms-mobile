/// État d'authentification : JWT, utilisateur courant, permissions, établissement.
///
/// Le JWT est stocké dans le [SecureStorage] (Keystore/Keychain). L'interceptor
/// Dio le lit via `ref.read(authProvider).token` à chaque requête.
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../shared/models/auth_dto.dart'
    show
        LoginRequest,
        LoginResponse,
        MeResponse,
        ChangePasswordRequest,
        UserDto,
        EstablishmentDto,
        RoleBrief;
import '../../features/connections/connection_state.dart';
import '../config/app_config.dart';
import '../config/constants.dart';
import '../network/api_endpoints.dart';
import '../network/api_exceptions.dart';
import '../network/dio_client.dart';
import 'secure_storage.dart';

/// État immuable d'authentification.
class AuthState {
  final UserDto? user;
  final String? token;
  final List<String> permissions;
  final List<String> roles;
  final int? establishmentId;
  final bool isLoading;
  final String? error;

  const AuthState({
    this.user,
    this.token,
    this.permissions = const [],
    this.roles = const [],
    this.establishmentId,
    this.isLoading = false,
    this.error,
  });

  bool get isAuthenticated =>
      token != null && token!.isNotEmpty && user != null;
  bool get isSuperuser => permissions.contains('*');

  bool get hasDeclaredTeacherRole =>
      roles.any(
        (r) =>
            r == RoleCodes.teacher ||
            r == RoleCodes.admin ||
            r == RoleCodes.headmaster,
      ) ||
      user?.role?.toUpperCase() == 'TEACHER';

  bool get isTeacherOnly => hasDeclaredTeacherRole && !isAdminOrHeadmaster;

  bool get isAdminOrHeadmaster =>
      isSuperuser ||
      roles.any(
        (r) => r == RoleCodes.admin || r == RoleCodes.headmaster,
      ) ||
      permissions.contains('ADMIN') ||
      permissions.contains('HEADMASTER') ||
      user?.role?.toUpperCase() == 'ADMIN' ||
      user?.role?.toUpperCase() == 'HEADMASTER';

  AuthState copyWith({
    UserDto? user,
    String? token,
    List<String>? permissions,
    List<String>? roles,
    int? establishmentId,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) =>
      AuthState(
        user: user ?? this.user,
        token: token ?? this.token,
        permissions: permissions ?? this.permissions,
        roles: roles ?? this.roles,
        establishmentId: establishmentId ?? this.establishmentId,
        isLoading: isLoading ?? this.isLoading,
        error: clearError ? null : (error ?? this.error),
      );

  static const initial = AuthState();
}

/// Provider d'authentification.
final authProvider = NotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);

class AuthNotifier extends Notifier<AuthState> {
  @override
  AuthState build() {
    _restoreSession();
    return const AuthState();
  }

  Dio get _dio => ref.read(dioProvider);
  SecureStorage get _storage => ref.read(secureStorageProvider);

  String get _profileId => ref.read(connectionProvider).profileId ?? 'default';
  String? get _serverUrl => ref.read(connectionProvider).serverUrl;

  Future<void> _persistSessionSnapshot(
    LoginResponse login, {
    required String username,
    required String password,
  }) async {
    final profileId = _profileId;
    final payload = {
      'user': login.user.toJson(),
      'permissions': login.permissions,
      'roles': login.roles.map((r) => r.code).toList(),
      'establishmentId': login.establishment?.id,
    };
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('session_snapshot_$profileId', jsonEncode(payload));
    await _storage.saveJwtFor(profileId, login.accessToken);
    await _storage.saveCredentialsFor(profileId, username, password);
    await _storage.saveJwt(login.accessToken);
    await _storage.saveCredentials(username, password);
  }

  Future<AuthState?> _restoreSessionFromSnapshot() async {
    final profileId = _profileId;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('session_snapshot_$profileId');
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final user = UserDto.fromJson(
        Map<String, dynamic>.from(map['user'] as Map? ?? const {}),
      );
      final roles =
          (map['roles'] as List? ?? const []).map((e) => e.toString()).toList();
      final permissions = (map['permissions'] as List? ?? const [])
          .map((e) => e.toString())
          .toList();
      final establishmentId = (map['establishmentId'] as num?)?.toInt();
      final token =
          await _storage.getJwtFor(profileId) ?? await _storage.getJwt();
      if (token == null || token.isEmpty) return null;
      return AuthState(
        token: token,
        user: user,
        permissions: permissions,
        roles: roles,
        establishmentId: establishmentId,
      );
    } catch (_) {
      return null;
    }
  }

  /// Restaure la session JWT depuis le stockage sécurisé au démarrage.
  Future<void> _restoreSession() async {
    final token = await _storage.getJwt();
    if (token == null || token.isEmpty) {
      final snapshot = await _restoreSessionFromSnapshot();
      if (snapshot != null) {
        state = snapshot;
      }
      return;
    }
    state = state.copyWith(token: token);
    // Vérifie la validité du token via /auth/me.
    await fetchMe();
  }

  /// Connexion : `POST /auth/login`.
  Future<bool> login({
    required String username,
    required String password,
    required String establishmentCode,
  }) async {
    if (_serverUrl == null) {
      state = state.copyWith(
        error: 'Aucun serveur configuré. Appairez d\'abord un terminal.',
      );
      return false;
    }
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final resp = await _dio.post(
        buildUrl(_serverUrl!, ApiEndpoints.authLogin),
        data: LoginRequest(
          username: username,
          password: password,
          establishmentCode: establishmentCode,
        ).toJson(),
      );
      final login = LoginResponse.fromJson(resp.data as Map<String, dynamic>);
      await _persistSessionSnapshot(
        login,
        username: username,
        password: password,
      );
      state = state.copyWith(
        token: login.accessToken,
        user: login.user,
        permissions: login.permissions,
        roles: login.roles.map((r) => r.code).toList(),
        establishmentId: login.establishment?.id,
        isLoading: false,
      );
      return true;
    } on DioException catch (e) {
      final profileId = _profileId;
      final stored = await _storage.getCredentialsFor(profileId) ??
          await _storage.getCredentials();
      final snapshot = await _restoreSessionFromSnapshot();
      final isNetworkProblem = e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.response == null;
      if (isNetworkProblem && snapshot != null && stored != null) {
        final credsMatch =
            stored.username == username && stored.password == password;
        if (credsMatch) {
          state = state.copyWith(
            token: snapshot.token,
            user: snapshot.user,
            permissions: snapshot.permissions,
            roles: snapshot.roles,
            establishmentId: snapshot.establishmentId,
            isLoading: false,
            error: null,
          );
          return true;
        }
      }
      // [Fix-AUTH] Logger l'erreur complète pour diagnostic.
      debugPrint(
        '[AUTH] Login DioException: type=${e.type}, message=${e.message}, '
        'error=${e.error}, statusCode=${e.response?.statusCode}, '
        'response=${e.response?.data}',
      );
      // Message d'erreur actionnable pour les problèmes réseau courants.
      final msg = _humanizeDioError(e, _serverUrl ?? '');
      state = state.copyWith(isLoading: false, error: msg);
      return false;
    } catch (e) {
      debugPrint('[AUTH] Login unexpected error: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
      return false;
    }
  }

  /// Transforme une [DioException] en message d'erreur clair et actionnable,
  /// avec détection des causes courantes (localhost sur appareil physique,
  /// serveur injoignable, délai dépassé).
  String _humanizeDioError(DioException e, String serverUrl) {
    // Détecter l'usage de localhost/127.0.0.1 sur un appareil physique.
    if (serverUrl.contains('localhost') || serverUrl.contains('127.0.0.1')) {
      return 'L\'adresse « localhost » ou « 127.0.0.1 » désigne le mobile '
          'lui-même, pas le serveur desktop. Utilisez l\'IP LAN du desktop '
          '(ex: 192.168.1.10).';
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return 'Délai de connexion dépassé après ${AppConfig.connectTimeout.inSeconds}s. '
            'Causes possibles :\n'
            '• Le serveur desktop n\'est pas démarré\n'
            '• Le mobile et le desktop ne sont pas sur le même réseau Wi-Fi\n'
            '• L\'IP ou le port est incorrect\n'
            '• Le pare-feu du desktop bloque le port';
      case DioExceptionType.connectionError:
        return 'Connexion refusée ou serveur injoignable. Vérifiez l\'IP et '
            'le port, et que le serveur desktop est démarré.';
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode;
        if (code == 401) return 'Nom d\'utilisateur ou mot de passe incorrect.';
        if (code == 403) return 'Accès refusé. Permissions insuffisantes.';
        if (code == 404) {
          return 'Endpoint introuvable (404). L\'API du serveur '
              'desktop ne correspond peut-être pas à la version attendue.';
        }
        if (code == 422) {
          final apiError = dioErrorToApiException(e);
          return 'Requête de connexion invalide : ${apiError.message}';
        }
        return 'Erreur serveur ($code).';
      case DioExceptionType.badCertificate:
        return 'Problème de certificat TLS.';
      case DioExceptionType.cancel:
        return 'Requête annulée.';
      case DioExceptionType.unknown:
      default:
        // [Fix-AUTH] Inclure e.error (l'exception sous-jacente) car e.message
        // est souvent null pour les erreurs socket (connection refused, reset,
        // server crash). Sans cela, l'utilisateur voit "null" sans info utile.
        final underlying = e.error?.toString() ?? e.message ?? 'Aucun détail';
        // Si l'erreur sous-jacente est une ApiException, extraire son message.
        if (e.error is ApiException) {
          return (e.error as ApiException).message;
        }
        // Tronquer les erreurs trop longues (stack traces de socket).
        final short = underlying.length > 200
            ? '${underlying.substring(0, 200)}...'
            : underlying;
        return 'Erreur réseau : $short';
    }
  }

  /// Récupère le profil courant : `GET /auth/me`.
  Future<void> fetchMe() async {
    if (_serverUrl == null || state.token == null) return;
    try {
      final resp = await _dio.get(buildUrl(_serverUrl!, ApiEndpoints.authMe));
      final me = MeResponse.fromJson(
        Map<String, dynamic>.from(resp.data as Map),
      );
      state = state.copyWith(
        user: me.user,
        permissions: me.permissions,
        roles: me.roles.map((r) => r.code).toList(),
        establishmentId: me.establishment?.id,
        clearError: true,
      );
    } on DioException catch (e) {
      // On ne déconnecte QUE si c'est une erreur 401 (token invalide/expiré).
      // Les erreurs réseau (503, timeout, etc.) ne doivent pas forcer le logout.
      if (e.response?.statusCode == 401) {
        await logoutLocal();
      }
    } catch (_) {
      // Erreur inattendue → on reste sur l'état actuel (cache).
    }
  }

  /// Change le mot de passe : `POST /auth/change-password`.
  Future<bool> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    if (_serverUrl == null) return false;
    try {
      await _dio.post(
        buildUrl(_serverUrl!, ApiEndpoints.authChangePassword),
        data: ChangePasswordRequest(
          currentPassword: currentPassword,
          newPassword: newPassword,
        ).toJson(),
      );
      return true;
    } on DioException catch (e) {
      final api = (e.error is ApiException)
          ? e.error as ApiException
          : dioErrorToApiException(e);
      state = state.copyWith(error: api.message);
      return false;
    }
  }

  /// Déconnexion locale (efface le JWT).
  Future<void> logoutLocal() async {
    await _storage.deleteJwt();
    state = const AuthState();
  }

  /// Déconnexion serveur + locale : `POST /auth/logout`.
  Future<void> logout() async {
    if (_serverUrl != null && state.token != null) {
      try {
        await _dio.post(buildUrl(_serverUrl!, ApiEndpoints.authLogout));
      } catch (_) {
        // Ignoré : on déconnecte quand même localement.
      }
    }
    await logoutLocal();
  }

  /// Appelé par l'interceptor Dio en cas de 401.
  Future<void> handleUnauthorized() async {
    if (state.token == null) return;

    final profileId = _profileId;
    final saved = await _storage.getCredentialsFor(profileId) ??
        await _storage.getCredentials();
    final estabCode = ref.read(connectionProvider).establishmentCode ?? '';
    if (saved != null && estabCode.isNotEmpty) {
      final ok = await login(
        username: saved.username,
        password: saved.password,
        establishmentCode: estabCode,
      );
      if (ok) return;
    }

    await logoutLocal();
  }
}
