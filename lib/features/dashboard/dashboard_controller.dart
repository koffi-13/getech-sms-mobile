/// Contrôleur du module Tableau de bord : KPIs, alertes, taux d'occupation.
///
/// Expose [dashboardStatsProvider] qui appelle `GET /dashboard/stats` via le
/// [dioProvider] et désérialise la réponse en [DashboardStatsDto]. Le provider
/// ne déclenche l'appel que lorsque le serveur est joignable
/// ([ConnectionState.canReachServer] ; sinon il lève une erreur `offline`
/// afin que l'UI puisse afficher un message « Mode hors-ligne ».
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../connections/connection_state.dart';
import '../../shared/models/sync_dto.dart';

/// Exception levée quand le serveur n'est pas joignable (hors-ligne forcé,
/// serveur down, ou appareil non appairé). L'UI l'interprète comme un mode
/// hors-ligne et affiche un message dédié plutôt qu'une erreur générique.
class OfflineDashboardException implements Exception {
  const OfflineDashboardException(this.message);
  final String message;

  @override
  String toString() => 'OfflineDashboardException: $message';
}

/// Statistiques du tableau de bord : `GET /dashboard/stats`.
///
/// Auto-dispose : se recalcule à chaque fois que le widget est monté, ce qui
/// permet de rafraîchir les données après une synchro manuelle ou un
/// changement d'établissement. Dépend de [connectionProvider] : si le serveur
/// devient injoignable, le provider lève [OfflineDashboardException].
final dashboardStatsProvider =
    FutureProvider.autoDispose<DashboardStatsDto>((ref) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.canReachServer || conn.serverUrl == null) {
    throw const OfflineDashboardException(
        'Mode hors-ligne — données non disponibles.');
  }
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.getJson(
      buildUrl(conn.serverUrl!, ApiEndpoints.dashboardStats),
    );
    final data = resp.data;
    if (data is! Map) {
      throw const ApiException('Réponse inattendue du serveur (dashboard).');
    }
    return DashboardStatsDto.fromJson(Map<String, dynamic>.from(data));
  } catch (e) {
    if (e is OfflineDashboardException) rethrow;
    if (e is ApiException) rethrow;
    // Erreur réseau (timeout, DNS, etc.) → on l'enveloppe.
    throw ApiException(
      'Impossible de charger le tableau de bord.',
      details: e.toString(),
    );
  }
});
