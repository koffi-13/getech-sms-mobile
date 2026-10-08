/// Contrôleur du module Utilisateurs : liste (recherche), détail, et
/// repository (création / mise à jour / activation) offline-first.
///
/// - En ligne (`connection.canReachServer`) : appels REST `/users/*` via
///   [dioProvider] + [buildUrl]. Aucun cache Drift en V1 (les utilisateurs
///   sont des données d'administration — surface de codegen limitée).
/// - Hors-ligne : les écritures sont mises en file d'attente via
///   [outboxProvider] pour être poussées ultérieurement par le [SyncEngine].
///
/// RBAC : USER_READ pour la lecture, USER_MANAGE pour les écritures.
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart' as log_pkg;

import '../../core/config/constants.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../../core/sync/outbox.dart';
import '../../features/connections/connection_state.dart';
import '../../shared/models/auth_dto.dart';

final log_pkg.Logger _log = log_pkg.Logger(
  printer: log_pkg.PrettyPrinter(noBoxingByDefault: true),
  level: log_pkg.Level.off,
);

/// Paramètre de requête pour créer / mettre à jour un utilisateur.
///
/// Sérialisé en JSON pour le POST/PATCH `/users` et pour le payload de
/// l'outbox (écritures hors-ligne).
class UserWriteRequest {
  const UserWriteRequest({
    required this.username,
    this.firstName,
    this.lastName,
    this.email,
    this.phone,
    this.sexe,
    this.password,
    this.isActive = true,
    this.isSuperuser = false,
  });

  final String username;
  final String? firstName;
  final String? lastName;
  final String? email;
  final String? phone;
  final Sexe? sexe;
  final String? password;
  final bool isActive;
  final bool isSuperuser;

  Map<String, dynamic> toJson() => {
        'username': username,
        if (firstName != null && firstName!.isNotEmpty) 'first_name': firstName,
        if (lastName != null && lastName!.isNotEmpty) 'last_name': lastName,
        if (email != null && email!.isNotEmpty) 'email': email,
        if (phone != null && phone!.isNotEmpty) 'phone': phone,
        if (sexe != null) 'sexe': sexe!.code,
        if (password != null && password!.isNotEmpty) 'password': password,
        'is_active': isActive,
        'is_superuser': isSuperuser,
      };
}

// ===========================================================================
// Providers de lecture (family FutureProvider.autoDispose).
// ===========================================================================

/// Liste des utilisateurs filtrée par recherche : `GET /users?search=`.
///
/// Renvoie une liste vide si le serveur est non appairé. Les erreurs 403
/// (RBAC insuffisant) sont transformées en liste vide pour ne pas bloquer l'UI.
final usersListProvider =
    FutureProvider.autoDispose.family<List<UserDto>, String>((ref, search) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return const [];

  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.getJson<dynamic>(
      buildUrl(conn.serverUrl!, ApiEndpoints.users),
      query: {
        if (search.trim().isNotEmpty) 'search': search.trim(),
        'per_page': 100,
      },
    );
    return _parseUserList(resp.data);
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403) return const [];
    _log.w('usersListProvider : ${api.message}');
    rethrow;
  } catch (e) {
    _log.w('usersListProvider : $e');
    rethrow;
  }
});

/// Détail d'un utilisateur par ID : `GET /users/{id}`.
final userDetailProvider =
    FutureProvider.autoDispose.family<UserDto, int>((ref, id) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) {
    throw const ApiException('Serveur non configuré');
  }
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.getJson<Map<String, dynamic>>(
      buildUrl(conn.serverUrl!, ApiEndpoints.user(id)),
    );
    return UserDto.fromJson(resp.data ?? const {});
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    _log.w('userDetailProvider : ${api.message}');
    throw api;
  } catch (e) {
    _log.w('userDetailProvider : $e');
    rethrow;
  }
});

// ===========================================================================
// Repository (écritures : create / update / toggleActive).
// ===========================================================================

/// Erreur métier renvoyée par [UserRepository].
class UserRepositoryException implements Exception {
  const UserRepositoryException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'UserRepositoryException(${statusCode ?? ''}): $message';
}

/// Repository des utilisateurs : gère les écritures distantes (POST/PATCH)
/// avec repli hors-ligne via l'outbox (file d'attente).
class UserRepository {
  UserRepository(this._ref);

  final Ref _ref;

  Dio get _dio => _ref.read(dioProvider);
  Outbox get _outbox => _ref.read(outboxProvider);
  String? get _serverUrl => _ref.read(connectionProvider).serverUrl;
  bool get _canReach => _ref.read(connectionProvider).canReachServer;

  /// Crée un utilisateur : `POST /users` (RBAC USER_MANAGE).
  ///
  /// Hors-ligne : enqueue outbox (INSERT) avec un payload JSON. La création
  /// locale d'un ID négatif temporaire est évitée — le serveur attribue l'ID.
  Future<UserDto> createUser(UserWriteRequest req) async {
    if (!_canReach || _serverUrl == null) {
      await _outbox.enqueue(
        table: 'users',
        operation: 'INSERT',
        recordId: null,
        payload: req.toJson(),
      );
      // Retourne un DTO "fantôme" (id 0) pour permettre à l'UI de continuer.
      return UserDto(
        id: 0,
        username: req.username,
        firstName: req.firstName,
        lastName: req.lastName,
        email: req.email ?? '',
        phone: req.phone,
        sexe: req.sexe,
        isActive: req.isActive,
        isSuperuser: req.isSuperuser,
      );
    }
    try {
      final resp = await _dio.postJson<Map<String, dynamic>>(
        buildUrl(_serverUrl!, ApiEndpoints.users),
        data: req.toJson(),
      );
      final created = UserDto.fromJson(resp.data ?? const {});
      _ref.invalidate(usersListProvider);
      return created;
    } on DioException catch (e) {
      final api = (e.error is ApiException)
          ? e.error as ApiException
          : dioErrorToApiException(e);
      throw UserRepositoryException(api.message, statusCode: api.statusCode);
    } catch (e) {
      throw UserRepositoryException('Échec de la création : $e');
    }
  }

  /// Met à jour un utilisateur : `PATCH /users/{id}` (RBAC USER_MANAGE).
  ///
  /// Le mot de passe n'est inclus que s'il est non vide (champ optionnel en
  /// édition). Hors-ligne : enqueue outbox (UPDATE).
  Future<UserDto> updateUser(int id, UserWriteRequest req) async {
    if (!_canReach || _serverUrl == null) {
      await _outbox.enqueue(
        table: 'users',
        operation: 'UPDATE',
        recordId: id,
        payload: req.toJson(),
      );
      return UserDto(
        id: id,
        username: req.username,
        firstName: req.firstName,
        lastName: req.lastName,
        email: req.email ?? '',
        phone: req.phone,
        sexe: req.sexe,
        isActive: req.isActive,
        isSuperuser: req.isSuperuser,
      );
    }
    try {
      final resp = await _dio.patchJson<Map<String, dynamic>>(
        buildUrl(_serverUrl!, ApiEndpoints.user(id)),
        data: req.toJson(),
      );
      final saved = UserDto.fromJson(resp.data ?? const {});
      _ref.invalidate(usersListProvider);
      _ref.invalidate(userDetailProvider(id));
      return saved;
    } on DioException catch (e) {
      final api = (e.error is ApiException)
          ? e.error as ApiException
          : dioErrorToApiException(e);
      throw UserRepositoryException(api.message, statusCode: api.statusCode);
    } catch (e) {
      throw UserRepositoryException('Échec de la mise à jour : $e');
    }
  }

  /// Active / désactive un utilisateur : `PATCH /users/{id}` avec
  /// `{is_active: !isActive}` (RBAC USER_MANAGE).
  ///
  /// Hors-ligne : enqueue outbox (UPDATE) avec uniquement le champ `is_active`.
  Future<void> toggleActive(UserDto user) async {
    final payload = <String, dynamic>{
      'is_active': !user.isActive,
    };
    if (!_canReach || _serverUrl == null) {
      await _outbox.enqueue(
        table: 'users',
        operation: 'UPDATE',
        recordId: user.id,
        payload: payload,
      );
      return;
    }
    try {
      await _dio.patchJson<Map<String, dynamic>>(
        buildUrl(_serverUrl!, ApiEndpoints.user(user.id)),
        data: payload,
      );
      _ref.invalidate(usersListProvider);
      _ref.invalidate(userDetailProvider(user.id));
    } on DioException catch (e) {
      final api = (e.error is ApiException)
          ? e.error as ApiException
          : dioErrorToApiException(e);
      throw UserRepositoryException(api.message, statusCode: api.statusCode);
    } catch (e) {
      throw UserRepositoryException('Échec du changement de statut : $e');
    }
  }
}

final userRepositoryProvider =
    Provider<UserRepository>((ref) => UserRepository(ref));

// ===========================================================================
// Helpers de parsing
// ===========================================================================

List<UserDto> _parseUserList(dynamic data) {
  if (data is List) {
    return data
        .whereType<Map>()
        .map((e) => UserDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  if (data is Map && data['items'] is List) {
    return (data['items'] as List)
        .whereType<Map>()
        .map((e) => UserDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  return const [];
}
