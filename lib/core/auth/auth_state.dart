/// État d'authentification : JWT, utilisateur courant, permissions, établissement.
///
/// Le JWT est stocké dans le [SecureStorage] (Keystore/Keychain). L'interceptor
/// Dio le lit via `ref.read(authProvider).token` à chaque requête.
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../shared/models/auth_dto.dart'
    show ChangePasswordRequest, LoginRequest, LoginResponse, MeResponse, UserDto;
import '../config/app_config.dart';
import '../config/constants.dart';
import '../network/api_endpoints.dart';
import '../network/api_exceptions.dart';
import '../network/dio_client.dart';
import 'secure_storage.dart';
import '../../features/connections/connection_state.dart';
import '../../features/connections/server_profiles.dart';

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

  /// Vrai si l'utilisateur possède le rôle [role] (code MAJUSCULES, ex. `TEACHER`).
  bool hasRole(String role) => roles.contains(role);

  /// Administrateur au sens large : superuser, `ADMIN` ou `HEADMASTER`.
  ///
  /// Miroir de `_user_is_admin_or_headmaster` du desktop : accès à toutes les
  /// classes/matières, suppression d'évaluations, modification des notes
  /// existantes (non verrouillées pour un enseignant).
  bool get isAdminOrHeadmaster =>
      isSuperuser || roles.any(RoleCodes.adminLike.contains);

  /// Le rôle « enseignant » est déclaré sur le compte (rôle `TEACHER` ou
  /// `UserDto.role` contenant teacher/enseignant).
  bool get hasDeclaredTeacherRole {
    if (roles.contains(RoleCodes.teacher)) return true;
    final r = user?.role?.toLowerCase();
    return r != null && (r.contains('teacher') || r.contains('enseignant'));
  }

  /// Enseignant « pur » : rôle enseignant déclaré SANS droits admin élargis.
  /// (Un admin qui enseigne aussi garde son statut admin.)
  bool get isTeacherOnly => !isAdminOrHeadmaster && hasDeclaredTeacherRole;

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
    // [Fix-SESSION-RESTORE] Régression v2 corrigée : au démarrage à froid,
    // le registre multi-serveurs n'est PAS encore chargé (bootstrap async)
    // donc `activeProfileIdProvider` vaut null et l'ancien code sortait
    // immédiatement de _restoreSession → l'utilisateur était renvoyé au
    // login à CHAQUE lancement de l'app (et bloqué hors-ligne).
    // On SURVEILLE le profil actif : dès que le bootstrap le pose, ce
    // provider se reconstruit et restaure la session.
    // select(profileId) : ne pas se reconstruire au heartbeat 30 s.
    ref.watch(activeProfileIdProvider);
    ref.watch(connectionProvider.select((c) => c.profileId));
    _restoreSession();
    return const AuthState();
  }

  Dio get _dio => ref.read(dioProvider);
  SecureStorage get _storage => ref.read(secureStorageProvider);

  String? get _serverUrl => ref.read(connectionProvider).serverUrl;

  /// Restaure la session JWT du serveur ACTIF (clé par profil) au démarrage
  /// ou après une bascule de serveur.
  ///
  /// [Fix-OFFLINE-SESSION] Un instantané de session (utilisateur,
  /// permissions, rôles, établissement) est persisté par profil : il est
  /// réhydraté AVANT l'appel réseau → l'app reste utilisable hors-ligne
  /// (modules + données locales). `/auth/me` n'est plus qu'un refresh
  /// silencieux quand le serveur est joignable.
  Future<void> _restoreSession() async {
    final pid = ref.read(activeProfileIdProvider) ??
        ref.read(connectionProvider).profileId;
    if (pid == null) return;
    final token = await _storage.getJwtFor(pid);
    if (token == null || token.isEmpty) return;

    // 1) Réhydratation locale immédiate (hors-ligne OK).
    final snap = await _readSnapshot(pid);
    state = state.copyWith(
      token: token,
      user: snap?['user'],
      permissions: (snap?['permissions'] as List<String>? ?? const []),
      roles: (snap?['roles'] as List<String>? ?? const []),
      establishmentId: snap?['establishmentId'] as int?,
    );

    // 2) Refresh silencieux si le serveur répond (les erreurs réseau
    //    sont ignorées : la session locale reste valide).
    await fetchMe();
  }

  /// Clé de l'instantané de session pour un profil serveur.
  static String _snapshotKey(String pid) => 'session_snapshot_$pid';

  /// Lit l'instantané de session persisté pour [pid] (null si absent/corrompu).
  Future<Map<String, dynamic>?> _readSnapshot(String pid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_snapshotKey(pid));
      if (raw == null || raw.isEmpty) return null;
      final j = Map<String, dynamic>.from(
          jsonDecode(raw) as Map<String, dynamic>);
      return {
        'user': UserDto.fromJson(
            Map<String, dynamic>.from(j['user'] as Map<String, dynamic>)),
        'permissions': (j['permissions'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const <String>[],
        'roles': (j['roles'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const <String>[],
        'establishmentId': j['establishmentId'] as int?,
      };
    } catch (_) {
      return null;
    }
  }

  /// Persiste l'instantané de session courant pour [pid].
  Future<void> _writeSnapshot(String pid) async {
    try {
      final user = state.user;
      if (user == null) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _snapshotKey(pid),
        jsonEncode({
          'user': user.toJson(),
          'permissions': state.permissions,
          'roles': state.roles,
          'establishmentId': state.establishmentId,
        }),
      );
    } catch (_) {
      // Best-effort : la persistance ne doit jamais casser la connexion.
    }
  }

  /// Permissions effectives : un super-utilisateur dont le RBAC serveur
  /// n'est pas seedé reçoit quand même tous les droits (le serveur envoie
  /// normalement '*', ce repli couvre les serveurs non patchés).
  List<String> _effectivePermissions(UserDto user, List<String> permissions) {
    if (permissions.contains('*')) return permissions;
    if (user.isSuperuser) return const ['*'];
    return permissions;
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
      // [Multi-serveurs] JWT + identifiants stockés PAR PROFIL : la session
      // d'un autre serveur n'est jamais écrasée.
      final pid = ref.read(activeProfileIdProvider) ??
          ref.read(connectionProvider).profileId;
      if (pid != null) {
        await _storage.saveJwtFor(pid, login.accessToken);
        await _storage.saveCredentialsFor(pid, username, password);
      } else {
        await _storage.saveJwt(login.accessToken);
        await _storage.saveCredentials(username, password);
      }
      state = state.copyWith(
        token: login.accessToken,
        user: login.user,
        permissions: _effectivePermissions(
            login.user, login.permissions),
        roles: login.roles.map((r) => r.code).toList(),
        establishmentId: login.establishment?.id,
        isLoading: false,
      );
      // [Fix-OFFLINE-SESSION] persister l'instantané pour ce profil.
      if (pid != null) await _writeSnapshot(pid);
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
      default:
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
        permissions: _effectivePermissions(me.user, me.permissions),
        roles: me.roles.map((r) => r.code).toList(),
        establishmentId: me.establishment?.id,
        clearError: true,
      );
      // [Fix-OFFLINE-SESSION] mettre à jour l'instantané persisté.
      final pid = ref.read(activeProfileIdProvider) ??
          ref.read(connectionProvider).profileId;
      if (pid != null) await _writeSnapshot(pid);
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
      final api = (e.error is ApiException) ? e.error as ApiException : dioErrorToApiException(e);
      state = state.copyWith(error: api.message);
      return false;
    }
  }

  /// Déconnexion locale — efface UNIQUEMENT le JWT du serveur actif
  /// (les sessions des autres serveurs enregistrés sont conservées).
  Future<void> logoutLocal() async {
    final pid = ref.read(activeProfileIdProvider) ??
        ref.read(connectionProvider).profileId;
    if (pid != null) {
      await _storage.deleteJwtFor(pid);
      // [Fix-OFFLINE-SESSION] effacer aussi l'instantané de session.
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_snapshotKey(pid));
      } catch (_) {}
    } else {
      await _storage.deleteJwt();
    }
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
