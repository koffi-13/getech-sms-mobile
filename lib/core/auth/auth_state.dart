/// État d'authentification : JWT, utilisateur courant, permissions, établissement.
///
/// Le JWT est stocké dans le [SecureStorage] (Keystore/Keychain). L'interceptor
/// Dio le lit via `ref.read(authProvider).token` à chaque requête.
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/models/auth_dto.dart' show LoginRequest, LoginResponse, MeResponse, ChangePasswordRequest, UserDto, EstablishmentDto, RoleBrief;
import '../../features/connections/connection_state.dart';
import '../config/app_config.dart';
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

  bool get isAuthenticated => token != null && token!.isNotEmpty && user != null;
  bool get isSuperuser => permissions.contains('*');

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
final authProvider =
    NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);

class AuthNotifier extends Notifier<AuthState> {
  @override
  AuthState build() {
    _restoreSession();
    return const AuthState();
  }

  Dio get _dio => ref.read(dioProvider);
  SecureStorage get _storage => ref.read(secureStorageProvider);

  String? get _serverUrl => ref.read(connectionProvider).serverUrl;

  /// Restaure la session JWT depuis le stockage sécurisé au démarrage.
  Future<void> _restoreSession() async {
    final token = await _storage.getJwt();
    if (token == null || token.isEmpty) return;
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
      state = state.copyWith(error: 'Aucun serveur configuré. Appairez d\'abord un terminal.');
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
      await _storage.saveJwt(login.accessToken);
      await _storage.saveCredentials(username, password);
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
      // Message d'erreur actionnable pour les problèmes réseau courants.
      final msg = _humanizeDioError(e, _serverUrl!);
      state = state.copyWith(isLoading: false, error: msg);
      return false;
    } catch (e) {
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
        if (code == 404) return 'Endpoint introuvable (404). L\'API du serveur '
            'desktop ne correspond peut-être pas à la version attendue.';
        return 'Erreur serveur ($code).';
      case DioExceptionType.badCertificate:
        return 'Problème de certificat TLS.';
      case DioExceptionType.cancel:
        return 'Requête annulée.';
      case DioExceptionType.unknown:
        return 'Erreur réseau inconnue : ${e.message}';
    }
  }

  /// Récupère le profil courant : `GET /auth/me`.
  Future<void> fetchMe() async {
    if (_serverUrl == null || state.token == null) return;
    try {
      final resp = await _dio.get(buildUrl(_serverUrl!, ApiEndpoints.authMe));
      final me = MeResponse.fromJson(
          Map<String, dynamic>.from(resp.data as Map));
      state = state.copyWith(
        user: me.user,
        permissions: me.permissions,
        roles: me.roles.map((r) => r.code).toList(),
        establishmentId: me.establishment?.id,
        clearError: true,
      );
    } catch (_) {
      // Token peut être expiré → on déconnecte.
      await logoutLocal();
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
      final api = (e.error is ApiException) ? e.error as ApiException : dioErrorToApiException(e);
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
  void handleUnauthorized() {
    if (state.token != null) {
      logoutLocal();
    }
  }
}
