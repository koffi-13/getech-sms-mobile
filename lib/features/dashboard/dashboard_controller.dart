/// Contrôleur du module Tableau de bord : KPIs (effectifs, paiements, solde dû),
/// paiements récents et élèves récemment inscrits.
///
/// Expose [dashboardStatsProvider] qui appelle `GET /dashboard/stats` via le
/// [dioProvider] et désérialise la réponse en [DashboardStatsDto]. Le provider
/// ne déclenche l'appel que lorsque le serveur est joignable
/// ([ConnectionState.canReachServer] ; sinon il lève une erreur `offline`
/// afin que l'UI puisse afficher un message « Mode hors-ligne ».
///
/// Aligné sur `DashboardStats` du desktop (schemas.py) :
/// {total_students, total_classrooms, total_teachers, total_payments (count),
/// total_balance_due, total_users, recent_payments[], recent_students[]}.
/// ⚠️ Les champs `studentsBySex`, `classOccupancy`, `absenteeAlerts`,
/// `overduePayments`, `paymentsToday` ont été retirés du contrat serveur et ne
/// sont plus exposés par [DashboardStatsDto].
library;

import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../connections/connection_state.dart';
import '../../shared/models/sync_dto.dart';

const String _keyDashboardCache = 'getech.cache.dashboard';

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
final dashboardStatsProvider =
    FutureProvider.autoDispose<DashboardStatsDto>((ref) async {
  final conn = ref.watch(connectionProvider);
  final prefs = await SharedPreferences.getInstance();

  // Tenter de récupérer le cache
  DashboardStatsDto? cachedStats;
  final cachedStr = prefs.getString(_keyDashboardCache);
  if (cachedStr != null) {
    try {
      cachedStats = DashboardStatsDto.fromJson(jsonDecode(cachedStr));
    } catch (_) {}
  }

  if (!conn.canReachServer || conn.serverUrl == null) {
    if (cachedStats != null) return cachedStats;
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
    
    final stats = DashboardStatsDto.fromJson(Map<String, dynamic>.from(data));
    // Mettre à jour le cache
    await prefs.setString(_keyDashboardCache, jsonEncode(data));
    
    return stats;
  } catch (e) {
    if (cachedStats != null) return cachedStats;
    
    if (e is OfflineDashboardException) rethrow;
    if (e is ApiException) rethrow;
    throw ApiException(
      'Impossible de charger le tableau de bord.',
      details: e.toString(),
    );
  }
});
