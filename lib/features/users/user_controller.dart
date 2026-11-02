/// Contrôleur du module Utilisateurs : liste (recherche), détail, et
/// repository (création / mise à jour / activation) offline-first.
///
/// - En ligne : appels REST `/users/*` et cache Drift des listes consultées.
/// - Hors-ligne : lecture du cache local et écritures différées par outbox.
///
/// RBAC : USER_READ pour la lecture, USER_MANAGE pour les écritures.
library;

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' as d;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart' as log_pkg;

import '../../core/config/constants.dart';
import '../../core/database/database.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../../core/sync/outbox.dart';
import '../../core/sync/sync_engine.dart' show syncGenerationProvider;
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
final usersListProvider = FutureProvider.autoDispose
    .family<List<UserDto>, String>((ref, search) async {
  ref.watch(syncGenerationProvider);
  final conn = ref.watch(
    connectionProvider.select(
      (c) => (
        isPaired: c.isPaired,
        serverUrl: c.serverUrl,
        canReachServer: c.canReachServer,
        isChecking: c.isChecking,
      ),
    ),
  );
  if (!conn.isPaired || conn.serverUrl == null) {
    return _usersFromLocal(ref, search);
  }
  if (!conn.canReachServer && !conn.isChecking) {
    return _usersFromLocal(ref, search);
  }

  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.getJson<dynamic>(
      buildUrl(conn.serverUrl!, ApiEndpoints.users),
      query: {
        if (search.trim().isNotEmpty) 'search': search.trim(),
        'per_page': 100,
      },
    );
    final users = _parseUserList(resp.data);
    await _cacheUsersFromDtos(ref, users);
    return users;
  } on ApiException catch (api) {
    if (api.statusCode == 403) return const [];
    _log.w('usersListProvider : ${api.message}');
    if (api is NetworkException) {
      return _usersFromLocal(ref, search);
    }
    rethrow;
  } on DioException catch (e) {
    final api = dioErrorToApiException(e);
    if (api.statusCode == 403) return const [];
    _log.w('usersListProvider : ${api.message}');
    if (api is NetworkException) {
      return _usersFromLocal(ref, search);
    }
    rethrow;
  } catch (e) {
    _log.w('usersListProvider : $e');
    rethrow;
  }
});

Future<List<UserDto>> _usersFromLocal(Ref ref, String search) async {
  final db = ref.read(databaseProvider);
  final query = db.select(db.users)
    ..where((t) => t.isDeleted.equals(false))
    ..orderBy([(t) => d.OrderingTerm.asc(t.username)]);
  final rows = await query.get();
  final needle = search.trim().toLowerCase();
  return rows
      .where((user) {
        if (needle.isEmpty) return true;
        return [
          user.username,
          user.firstName ?? '',
          user.lastName ?? '',
          user.email ?? '',
          user.phone ?? '',
        ].any((field) => field.toLowerCase().contains(needle));
      })
      .map(
        (user) => UserDto(
          id: user.id,
          username: user.username,
          firstName: user.firstName,
          lastName: user.lastName,
          email: user.email ?? '',
          phone: user.phone,
          photoPath: user.photoPath,
          sexe: Sexe.fromCode(user.sexe),
          isActive: user.isActive,
          isSuperuser: user.isSuperuser,
        ),
      )
      .toList();
}

Future<void> _cacheUsersFromDtos(Ref ref, List<UserDto> users) async {
  if (users.isEmpty) return;
  try {
    final db = ref.read(databaseProvider);
    final now = DateTime.now();
    await db.batch((batch) {
      for (final user in users) {
        if (user.username.isEmpty) continue;
        batch.insert(
          db.users,
          UsersCompanion.insert(
            id: d.Value(user.id),
            username: user.username,
            firstName: d.Value(user.firstName),
            lastName: d.Value(user.lastName),
            email: d.Value(user.email.isEmpty ? null : user.email),
            phone: d.Value(user.phone),
            photoPath: d.Value(user.photoPath),
            sexe: d.Value(user.sexe?.code),
            isActive: d.Value(user.isActive),
            isSuperuser: d.Value(user.isSuperuser),
            syncedAt: d.Value(now),
            isDirty: const d.Value(false),
            isDeleted: const d.Value(false),
          ),
          mode: d.InsertMode.insertOrReplace,
        );
      }
    });
  } catch (e) {
    _log.w('Cache local des utilisateurs indisponible : $e');
  }
}

/// [Fix-TEACHERS-DROPDOWN] Liste CANONIQUE des enseignants :
/// `GET /users?role=teacher` (endpoint dédié du serveur — filtre par rôle
/// UserRole, indépendant du « rôle principal » sérialisé).
///
/// L'ancien filtrage client (rôle principal contenant « teacher ») ratait
/// les enseignants dont le rôle principal affiché était un AUTRE rôle
/// (multi-rôles) — d'où un dropdown « Enseignant » de l'EDT incomplet
/// (« 3 chargés sur 7 »). Repli : filtrage client de la liste complète
/// si le serveur ne supporte pas le paramètre `role`.
final teachersListProvider =
    FutureProvider.autoDispose<List<UserDto>>((ref) async {
  final conn = ref.watch(
    connectionProvider
        .select((c) => (isPaired: c.isPaired, serverUrl: c.serverUrl)),
  );
  if (!conn.isPaired || conn.serverUrl == null) return const [];

  final dio = ref.watch(dioProvider);
  final url = buildUrl(conn.serverUrl!, ApiEndpoints.users);

  List<UserDto> clientSideFilter(List<UserDto> users) => users
      .where(
        (u) =>
            u.isActive &&
            ((u.role ?? '').toLowerCase().contains('teacher') ||
                (u.role ?? '').toLowerCase().contains('enseignant')),
      )
      .toList()
    ..sort((a, b) => _teacherLabel(a).compareTo(_teacherLabel(b)));

  try {
    final resp = await dio.getJson<dynamic>(
      url,
      query: {
        'role': 'teacher',
        'per_page': 200,
      },
    );
    final teachers = _parseUserList(resp.data)
      ..sort((a, b) => _teacherLabel(a).compareTo(_teacherLabel(b)));
    if (teachers.isNotEmpty) return teachers;

    // Repli : serveur sans support du paramètre `role` (réponse = tous les
    // utilisateurs, y compris non-enseignants) → filtrage client.
    final all = await dio.getJson<dynamic>(url, query: {'per_page': 200});
    return clientSideFilter(_parseUserList(all.data));
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403) return const [];
    _log.w('teachersListProvider : ${api.message}');
    rethrow;
  } catch (e) {
    _log.w('teachersListProvider : $e');
    rethrow;
  }
});

/// Libellé de tri d'un enseignant (nom complet, sinon username).
String _teacherLabel(UserDto u) => u.fullName.isEmpty ? u.username : u.fullName;

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
  String toString() => 'UserRepositoryException(${statusCode ?? ''}): $message';
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
