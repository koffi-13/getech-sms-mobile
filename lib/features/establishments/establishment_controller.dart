/// Contrôleur du module Établissements (multi-tenant).
///
/// Expose trois providers de lecture :
/// - [establishmentsListProvider] : `GET /establishments` — liste tous les
///   établissements visibles par l'utilisateur courant (multi-tenant).
/// - [currentEstablishmentProvider] : `GET /establishments/current` avec
///   repli sur `GET /settings/establishment` si l'endpoint renvoie 404.
/// - [establishmentDetailProvider] (family id) : `GET /establishments/{id}`.
///
/// Tous ces providers sont `autoDispose` pour se rafraîchir automatiquement
/// après un changement de connexion (invalidation via `connectionProvider`).
///
/// NB : pas de cache Drift dédié pour `establishments` dans la base locale
/// (V1) — ces providers nécessitent une connexion serveur. Le repli en
/// mode hors-ligne renvoie une liste vide / lève une exception explicite,
/// à charge de l'UI d'afficher la bannière adéquate.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

import '../../core/auth/auth_state.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../../features/connections/connection_state.dart';
import '../../shared/models/auth_dto.dart';

final Logger _log = Logger(
  printer: PrettyPrinter(methodNames: false, noBoxingByDefault: true),
  level: Level.off,
);

// ---------------------------------------------------------------------------
// Helpers de parsing
// ---------------------------------------------------------------------------

List<EstablishmentDto> _parseList(dynamic data) {
  final List items;
  if (data is List) {
    items = data;
  } else if (data is Map && data['items'] is List) {
    items = data['items'] as List;
  } else {
    items = const [];
  }
  return items
      .whereType<Map>()
      .map((e) => EstablishmentDto.fromJson(Map<String, dynamic>.from(e)))
      .toList();
}

EstablishmentDto _parseOne(dynamic data) {
  if (data is Map) {
    return EstablishmentDto.fromJson(Map<String, dynamic>.from(data));
  }
  throw const ApiException('Réponse serveur inattendue (établissement non JSON).');
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

/// Liste de tous les établissements accessibles (`GET /establishments`).
///
/// Requiert une connexion serveur — renvoie une liste vide en mode hors-ligne.
final establishmentsListProvider =
    FutureProvider.autoDispose<List<EstablishmentDto>>((ref) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.canReachServer || conn.serverUrl == null) {
    return const <EstablishmentDto>[];
  }
  try {
    final dio = ref.watch(dioProvider);
    final url = buildUrl(conn.serverUrl!, ApiEndpoints.establishments);
    final resp = await dio.getJson<dynamic>(url);
    return _parseList(resp.data);
  } on ApiException catch (e) {
    _log.w('establishmentsListProvider : ${e.message}');
    rethrow;
  } catch (e) {
    _log.w('establishmentsListProvider : $e');
    throw ApiException('Établissements indisponibles : $e');
  }
});

/// Établissement courant (`GET /establishments/current`).
///
/// En cas d'absence de l'endpoint (404), repli sur
/// `GET /settings/establishment`.
final currentEstablishmentProvider =
    FutureProvider.autoDispose<EstablishmentDto>((ref) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.canReachServer || conn.serverUrl == null) {
    throw const ApiException('Connexion serveur requise pour l\'établissement courant.');
  }
  final dio = ref.watch(dioProvider);
  try {
    final url = buildUrl(conn.serverUrl!, ApiEndpoints.establishmentsCurrent);
    final resp = await dio.getJson<dynamic>(url);
    return _parseOne(resp.data);
  } on ApiException catch (e) {
    // 404 → on tente /settings/establishment comme repli.
    if (e.statusCode == 404) {
      try {
        final url = buildUrl(conn.serverUrl!, ApiEndpoints.settingsEstablishment);
        final resp = await dio.getJson<dynamic>(url);
        return _parseOne(resp.data);
      } catch (e2) {
        _log.w('currentEstablishmentProvider (fallback) : $e2');
        throw ApiException('Établissement courant introuvable : $e2');
      }
    }
    _log.w('currentEstablishmentProvider : ${e.message}');
    rethrow;
  } catch (e) {
    _log.w('currentEstablishmentProvider : $e');
    throw ApiException('Établissement courant indisponible : $e');
  }
});

/// Détail d'un établissement par ID (`GET /establishments/{id}`).
///
/// Si `id` correspond à l'`establishmentId` du user courant
/// (`authProvider.establishmentId`), on peut réutiliser le cache du provider
/// [currentEstablishmentProvider] pour économiser une requête.
final establishmentDetailProvider =
    FutureProvider.autoDispose.family<EstablishmentDto, int>((ref, id) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.canReachServer || conn.serverUrl == null) {
    throw const ApiException('Connexion serveur requise.');
  }

  // Optimisation : si l'ID demandé est l'établissement courant, on réutilise
  // le provider `currentEstablishmentProvider` (cache partagé).
  final auth = ref.watch(authProvider);
  if (auth.establishmentId == id) {
    try {
      return await ref.watch(currentEstablishmentProvider.future);
    } catch (_) {
      // Si le provider courant échoue (ex : 404 sur /current mais /establishments/{id} ok),
      // on retombe sur l'appel direct ci-dessous.
    }
  }

  final dio = ref.watch(dioProvider);
  try {
    final url = '${buildUrl(conn.serverUrl!, ApiEndpoints.establishments)}/$id';
    final resp = await dio.getJson<dynamic>(url);
    return _parseOne(resp.data);
  } on ApiException catch (e) {
    _log.w('establishmentDetailProvider($id) : ${e.message}');
    rethrow;
  } catch (e) {
    _log.w('establishmentDetailProvider($id) : $e');
    throw ApiException('Établissement introuvable : $e');
  }
});
