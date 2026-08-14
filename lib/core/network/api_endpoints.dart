/// Constantes des chemins de l'API REST GeTech-SMS (préfixe `/api/v1`).
///
/// L'URL de base (hôte serveur) est configurable via le module Connexions
/// et stockée dans [AppConfig.keyServerUrl].
library;

import '../config/app_config.dart';

/// Construit l'URL complète d'un endpoint à partir du chemin relatif.
///
/// [serverUrl] doit inclure le préfixe `/api/v1`.
String buildUrl(String serverUrl, String path) {
  if (path.startsWith('http')) return path;
  final base = serverUrl.endsWith('/') ? serverUrl : '$serverUrl/';
  final p = path.startsWith('/') ? path.substring(1) : path;
  // Évite le double /api/v1 si serverUrl l'inclut déjà.
  if (base.contains(AppConfig.apiPrefix) && p.startsWith(AppConfig.apiPrefix)) {
    return '$base${p.substring(AppConfig.apiPrefix.length)}';
  }
  return '$base$p';
}

/// Chemins d'API (relatifs au préfixe `/api/v1`).
class ApiEndpoints {
  ApiEndpoints._();

  // --- Health ---
  static const String health = '/health';

  // --- Auth ---
  static const String authLogin = '/auth/login';
  static const String authMe = '/auth/me';
  static const String authLogout = '/auth/logout';
  static const String authChangePassword = '/auth/change-password';
  static const String authUpdateProfile = '/auth/update-profile';

  // --- Établissements ---
  static const String establishments = '/establishments';
  static const String establishmentsCurrent = '/establishments/current';
  static const String settingsEstablishment = '/settings/establishment';

  // --- Utilisateurs ---
  static const String users = '/users';

  // --- Élèves ---
  static const String students = '/students';
  static const String studentsExport = '/students/export';
  static const String studentsImport = '/students/import';
  static String student(int id) => '/students/$id';

  // --- Classes ---
  static const String classrooms = '/classrooms';
  static String classroom(int id) => '/classrooms/$id';

  // --- Matières ---
  static const String subjects = '/subjects';

  // --- Notes ---
  static const String grades = '/grades';
  static const String gradesRanking = '/grades/ranking';
  static const String gradesClassSubjects = '/grades/class-subjects';
  static const String gradesAssessments = '/grades/assessments';
  static String assessment(int id) => '/grades/assessments/$id';
  static String assessmentGrades(int id) => '/grades/assessments/$id/grades';
  static String bulletin(int studentId) => '/grades/bulletin/$studentId';

  // --- Finances ---
  static const String financePayments = '/finance/payments';
  static const String financeBalances = '/finance/balances';

  // --- Tableau de bord ---
  static const String dashboardStats = '/dashboard/stats';

  // --- Paramètres ---
  static const String settingsPeriods = '/settings/periods';

  // --- Emploi du temps (À CRÉER côté serveur) ---
  static const String schedule = '/schedule';

  // --- Présence (À CRÉER côté serveur) ---
  static const String attendanceSession = '/attendance/session';
  static String attendanceAbsences(int sessionId) =>
      '/attendance/session/$sessionId/absences';
  static const String attendanceAbsencesHistory = '/attendance/absences';

  // --- Synchro (À CRÉER côté serveur) ---
  static const String syncPull = '/sync/pull';
  static const String syncPush = '/sync/push';

  // --- Appareils / Connexions (À CRÉER côté serveur) ---
  static const String devicesPair = '/devices/pair';
  static const String devices = '/devices';
  static const String devicesServerInfo = '/devices/server-info';
  static String device(int id) => '/devices/$id';
}
