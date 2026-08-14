/// Contrôleur du module Paramètres : périodes scolaires et établissement
/// courant.
///
/// Expose :
/// - [periodsProvider] : `GET /settings/periods` → `List<PeriodDto>`.
/// - [establishmentProvider] : `GET /settings/establishment` (fallback
///   `/establishments/current`) → `EstablishmentDto`.
/// - [updateProfileProvider] : helper (Provider) qui exécute le PATCH
///   `/auth/update-profile` à la demande (le ProfilePage l'utilise).
///
/// Tous ces providers dépendent de [connectionProvider] (ré-exécution si
/// l'URL serveur change ou si le serveur redevient joignable).
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/constants.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../connections/connection_state.dart';
import '../../shared/models/auth_dto.dart';
import '../../shared/models/classroom_dto.dart';

/// Périodes scolaires disponibles : `GET /settings/periods`.
///
/// Auto-dispose : se rafraîchit lorsque la page Paramètres est remontée.
/// Renvoie une liste vide si le serveur est injoignable (non bloquant).
final periodsProvider =
    FutureProvider.autoDispose<List<PeriodDto>>((ref) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.canReachServer || conn.serverUrl == null) return const [];

  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.getJson(
      buildUrl(conn.serverUrl!, ApiEndpoints.settingsPeriods),
    );
    final data = resp.data;
    if (data is List) {
      return data
          .whereType<Map>()
          .map((e) => PeriodDto.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    if (data is Map && data['items'] is List) {
      return (data['items'] as List)
          .whereType<Map>()
          .map((e) => PeriodDto.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    return const [];
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    // Non bloquant : on retourne une liste vide si le serveur est injoignable.
    if (api.statusCode == null) return const [];
    throw api;
  } catch (_) {
    return const [];
  }
});

/// Établissement courant : `GET /settings/establishment`
/// (fallback `/establishments/current`).
///
/// Non auto-dispose : garde l'établissement en cache pendant toute la session
/// utilisateur. L'UI peut l'invalider via `ref.invalidate(establishmentProvider)`
/// après une mise à jour du profil établissement.
final establishmentProvider =
    FutureProvider<EstablishmentDto?>((ref) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return null;

  final dio = ref.watch(dioProvider);
  for (final path in [
    ApiEndpoints.settingsEstablishment,
    ApiEndpoints.establishmentsCurrent,
  ]) {
    try {
      final resp = await dio.getJson(
        buildUrl(conn.serverUrl!, path),
      );
      if (resp.data is Map) {
        return EstablishmentDto.fromJson(
          Map<String, dynamic>.from(resp.data as Map),
        );
      }
    } on DioException catch (e) {
      final api = (e.error is ApiException)
          ? e.error as ApiException
          : dioErrorToApiException(e);
      // 404 → essaie l'endpoint alternatif ; autres erreurs → remontée.
      if (api.statusCode != 404) {
        if (api.statusCode == null) return null; // réseau : non bloquant
        throw api;
      }
    } catch (_) {
      // Continue vers l'endpoint alternatif.
    }
  }
  return null;
});

/// Helper de mise à jour du profil utilisateur (`PATCH /auth/update-profile`).
///
/// Stateless Provider (pas d'AsyncNotifier) : la page appelante gère son
/// propre indicateur de chargement. Renvoie le DTO utilisateur mis à jour.
class SettingsController {
  SettingsController(this._ref);

  final Ref _ref;

  Dio get _dio => _ref.read(dioProvider);

  String? get _serverUrl => _ref.read(connectionProvider).serverUrl;

  /// Met à jour le profil de l'utilisateur courant.
  ///
  /// [sexe] peut être `null` (non renseigné). Seuls les champs fournis
  /// (non-null) sont envoyés au serveur.
  Future<UserDto> updateProfile({
    String? firstName,
    String? lastName,
    String? email,
    String? phone,
    Sexe? sexe,
  }) async {
    if (_serverUrl == null) {
      throw const ApiException('Aucun serveur configuré.');
    }
    final payload = <String, dynamic>{};
    if (firstName != null) payload['first_name'] = firstName;
    if (lastName != null) payload['last_name'] = lastName;
    if (email != null) payload['email'] = email;
    if (phone != null) payload['phone'] = phone;
    if (sexe != null) payload['sexe'] = sexe.code;

    try {
      final resp = await _dio.patchJson(
        buildUrl(_serverUrl!, ApiEndpoints.authUpdateProfile),
        data: payload,
      );
      final data = resp.data;
      if (data is Map) {
        // Le serveur peut renvoyer soit directement l'utilisateur, soit
        // enveloppé dans `{user: {...}}`.
        final userJson = data['user'] is Map
            ? Map<String, dynamic>.from(data['user'] as Map)
            : Map<String, dynamic>.from(data);
        return UserDto.fromJson(userJson);
      }
      throw const ApiException('Réponse inattendue du serveur (profil).');
    } on DioException catch (e) {
      throw (e.error is ApiException)
          ? e.error as ApiException
          : dioErrorToApiException(e);
    }
  }
}

/// Provider du contrôleur de paramètres (stateless).
final settingsControllerProvider =
    Provider<SettingsController>((ref) => SettingsController(ref));
