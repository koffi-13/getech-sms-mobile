/// Contrôleur du module Tableau de bord.
///
/// **Accueil standard (admin/comptable/…)** : [dashboardStatsProvider] appelle
/// `GET /dashboard/stats` avec cache SharedPreferences, aligné sur
/// `DashboardStats` du desktop (schemas.py) :
/// {total_students, total_classrooms, total_teachers, total_payments (count),
/// total_balance_due, total_users, recent_payments[], recent_students[]}.
///
/// **Accueil enseignant** : [teacherDashboardProvider] remplace complètement
/// l'appel à `/dashboard/stats` — cet endpoint n'est PAS scopé par rôle côté
/// serveur et exposerait des données financières. Les statistiques de
/// l'enseignant sont calculées côté mobile à partir de son périmètre
/// ([TeacherScope]) : ses classes (titulariat + enseignement), ses effectifs,
/// ses matières et ses cours — sans aucune donnée financière ni globale aux
/// autres utilisateurs.
library;

import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/auth/teacher_scope.dart';
import '../../core/config/constants.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../../shared/models/attendance_dto.dart';
import '../../shared/models/classroom_dto.dart';
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

// ===========================================================================
// Accueil ENSEIGNANT — statistiques de ses classes uniquement
// ===========================================================================

/// Données du tableau de bord enseignant (aucune statistique financière ni
/// globale aux autres utilisateurs).
class TeacherDashboardData {
  /// Classes où l'enseignant enseigne ou dont il est titulaire.
  final List<ClassroomDto> classrooms;

  /// Cours planifiés de l'enseignant (toutes classes).
  final List<WeeklyScheduleDto> schedule;

  /// Semaine alternée courante (null si non configurée).
  final WeekType? currentWeek;

  /// Scope complet (pour les helpers de filtrage des cours du jour).
  final TeacherScope scope;

  const TeacherDashboardData({
    required this.classrooms,
    required this.schedule,
    required this.scope,
    this.currentWeek,
  });

  int get classCount => classrooms.length;

  /// Effectif cumulé des classes de l'enseignant.
  int get studentCount =>
      classrooms.fold(0, (sum, c) => sum + c.studentCount);

  /// Matières distinctes enseignées.
  int get subjectCount =>
      schedule.map((s) => s.subjectId).whereType<int>().toSet().length;

  /// Cours du jour (filtrés par la semaine alternée courante).
  List<WeeklyScheduleDto> get todayCourses =>
      scope.coursesForDate(DateTime.now(), currentWeek: currentWeek);
}

/// Accueil enseignant : dérive du périmètre enseignant ([teacherScopeProvider])
/// et de la semaine alternée courante — aucun appel réseau supplémentaire.
final teacherDashboardProvider =
    FutureProvider.autoDispose<TeacherDashboardData>((ref) async {
  final scope = await ref.watch(teacherScopeProvider.future);
  final currentWeek = await ref.watch(currentWeekTypeProvider.future);
  return TeacherDashboardData(
    classrooms: scope.myClassrooms,
    schedule: scope.mySchedule,
    scope: scope,
    currentWeek: currentWeek,
  );
});
