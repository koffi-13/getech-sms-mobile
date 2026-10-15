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
  ///
  /// [Fix-ROLE-CODE-CASE] Comparaison insensible à la casse : une base
  /// serveur seedée par l'ancien script porte des codes minuscules
  /// (« teacher », « admin ») — le profil doit être reconnu quelle que
  /// soit la convention du serveur.
  bool hasRole(String role) =>
      roles.any((r) => r.toUpperCase() == role.toUpperCase());

  /// Administrateur au sens large : superuser, `ADMIN` ou `HEADMASTER`.
  ///
  /// Miroir de `_user_is_admin_or_headmaster` du desktop : accès à toutes les
  /// classes/matières, suppression d'évaluations, modification des notes
  /// existantes (non verrouillées pour un enseignant).
  bool get isAdminOrHeadmaster =>
      isSuperuser ||
      roles.any((r) => RoleCodes.adminLike
          .map((a) => a.toUpperCase())
          .contains(r.toUpperCase())) ||
      _adminLegacyUserRole;

  /// Détection admin via la colonne legacy ``User.role`` (« admin »,
  /// « administrateur », « headmaster », « directeur ») — certains comptes
  /// de production ne portent AUCUN rôle RBAC et aucune permission, la
  /// navigation restait alors limitée à Accueil/Plus.
  bool get _adminLegacyUserRole {
    final r = user?.role?.toLowerCase();
    if (r == null) return false;
    return r.contains('admin') ||
        r.contains('headmaster') ||
        r.contains('directeur') ||
        r.contains('proviseur');
  }

  /// Le rôle « enseignant » est déclaré sur le compte (rôle `TEACHER` ou
  /// `UserDto.role` contenant teacher/enseignant).
  bool get hasDeclaredTeacherRole {
    if (roles.any((r) => r.toUpperCase() == RoleCodes.teacher)) return true;
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

  /// Id du profil serveur actif (ou null si registre non chargé).
  String? get _activeProfileId =>
      ref.read(activeProfileIdProvider) ??
          ref.read(connectionProvider).profileId;

  // [Fix-401-RELOGIN] V11 — garde de réentrance : le re-login silencieux
  // déclenché par un 401 ne doit pas se relancer sur l'échec de SA propre
  // requête (sinon boucle infinie 401 → re-login → 401 → …).
  bool _silentReloginInFlight = false;

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
  ///
  /// [Fix-OFFLINE-LOGIN] V11 — repli hors-ligne : si la requête échoue pour
  /// une RAISON RÉSEAU (serveur injoignable, délai dépassé — PAS un 401/403
  /// « mauvais identifiants ») et que les identifiants saisis correspondent
  /// EXACTEMENT à ceux stockés pour ce profil serveur (Keystore), la session
  /// locale est restaurée depuis l'instantané persisté : l'enseignant peut
  /// travailler hors-ligne (cache Drift + outbox) comme sur son poste.
  /// Un mauvais mot de passe reste refusé (comparaison locale).
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
      // [Fix-OFFLINE-LOGIN] V11 — échec RÉSEAU (pas mauvais identifiants)
      // → tentative de connexion locale si les identifiants correspondent.
      final isNetworkFailure = e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout;
      if (isNetworkFailure) {
        final offlineOk = await _tryOfflineLogin(username, password);
        if (offlineOk) return true;
        state = state.copyWith(
          isLoading: false,
          error: 'Serveur injoignable et aucune session locale ne '
              'correspond à ces identifiants. Connectez-vous au moins une '
              'fois avec le serveur démarré, ou vérifiez le module '
              'Connexions.',
        );
        return false;
      }
      // Logger l'erreur complète pour diagnostic.
      debugPrint('[AUTH] Login DioException: type=${e.type}, message=${e.message}, '
          'error=${e.error}, statusCode=${e.response?.statusCode}, '
          'response=${e.response?.data}');
      // Message d'erreur actionnable pour les problèmes réseau courants.
      final msg = _humanizeDioError(e, _serverUrl!);
      state = state.copyWith(isLoading: false, error: msg);
      return false;
    } catch (e) {
      debugPrint('[AUTH] Login unexpected error: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
      return false;
    }
  }

  /// [Fix-OFFLINE-LOGIN] V11 — restaure la session depuis l'instantané
  /// local si les identifiants saisis correspondent à ceux stockés pour le
  /// profil actif. Retourne true si la session offline est ouverte.
  Future<bool> _tryOfflineLogin(String username, String password) async {
    try {
      final pid = _activeProfileId;
      if (pid == null) return false;
      final creds = await _storage.getCredentialsFor(pid);
      if (creds == null) return false;
      if (creds.username != username || creds.password != password) {
        return false;
      }
      final snap = await _readSnapshot(pid);
      final user = snap?['user'];
      if (user is! UserDto) return false; // aucun instantané → impossible

      final token = await _storage.getJwtFor(pid);
      state = state.copyWith(
        token: token ?? 'offline-session',
        user: user,
        permissions: (snap?['permissions'] as List<String>? ?? const []),
        roles: (snap?['roles'] as List<String>? ?? const []),
        establishmentId: snap?['establishmentId'] as int?,
        isLoading: false,
        clearError: true,
      );
      return true;
    } catch (e) {
      debugPrint('[AUTH] Offline login échoué : $e');
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
      //
      // [Fix-401-RELOGIN] V11 — un 401 ne détruit PLUS la session locale :
      // d'abord un re-login TRANSPARENT avec les identifiants stockés (le
      // serveur vient de répondre, il est joignable : c'est le token qui est
      // périmé — ex. serveur desktop redémarré). Sans ce correctif, chaque
      // redémarrage du serveur déconnectait l'enseignant ET effaçait son
      // instantané → plus aucune connexion possible hors-ligne.
      if (e.response?.statusCode == 401) {
        await handleUnauthorized();
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
  ///
  /// [Fix-401-RELOGIN] V11 — un 401 signifie que le token n'est plus
  /// accepté (expiré OU serveur redémarré avec un nouveau secret) mais le
  /// serveur EST joignable (il vient de répondre). Avant de déconnecter :
  /// 1. re-login silencieux avec les identifiants stockés du profil actif
  ///    → session restaurée SANS interruption pour l'utilisateur ;
  /// 2. si le re-login échoue (mot de passe changé, compte désactivé) :
  ///    on efface UNIQUEMENT le JWT — l'instantané de session et les
  ///    identifiants restent en place pour permettre la connexion
  ///    hors-ligne (cf. [Fix-OFFLINE-LOGIN]) depuis l'écran de login.
  Future<void> handleUnauthorized() async {
    if (state.token == null) return;

    // 1) Re-login silencieux (une seule tentative, pas de boucle).
    if (!_silentReloginInFlight) {
      _silentReloginInFlight = true;
      try {
        final healed = await _silentRelogin();
        if (healed) return; // session restaurée, aucune interruption.
      } finally {
        _silentReloginInFlight = false;
      }
    }

    // 2) Re-login impossible → on ne garde PAS un token refusé, mais on
    //    CONSERVE l'instantané + les identifiants (reconnexion hors-ligne
    //    possible avec le bon mot de passe).
    final pid = _activeProfileId;
    if (pid != null) {
      await _storage.deleteJwtFor(pid);
    } else {
      await _storage.deleteJwt();
    }
    state = const AuthState();
  }

  /// [Fix-401-RELOGIN] V11 — re-login transparent avec les identifiants
  /// stockés (profil actif). Réussit si le mot de passe n'a pas changé.
  Future<bool> _silentRelogin() async {
    try {
      final pid = _activeProfileId;
      final url = _serverUrl;
      if (pid == null || url == null) return false;
      final creds = await _storage.getCredentialsFor(pid);
      if (creds == null) return false;
      final estab =
          ref.read(connectionProvider).establishmentCode ?? '';
      if (estab.isEmpty) return false;

      final resp = await _dio.post(
        buildUrl(url, ApiEndpoints.authLogin),
        data: LoginRequest(
          username: creds.username,
          password: creds.password,
          establishmentCode: estab,
        ).toJson(),
      );
      final login = LoginResponse.fromJson(
          Map<String, dynamic>.from(resp.data as Map));
      await _storage.saveJwtFor(pid, login.accessToken);
      await _storage.saveCredentialsFor(pid, creds.username, creds.password);
      state = state.copyWith(
        token: login.accessToken,
        user: login.user,
        permissions:
            _effectivePermissions(login.user, login.permissions),
        roles: login.roles.map((r) => r.code).toList(),
        establishmentId: login.establishment?.id,
        clearError: true,
      );
      await _writeSnapshot(pid);
      debugPrint('[AUTH] 401 → session restaurée par re-login silencieux');
      return true;
    } catch (e) {
      debugPrint('[AUTH] Re-login silencieux impossible : $e');
      return false;
    }
  }
}
