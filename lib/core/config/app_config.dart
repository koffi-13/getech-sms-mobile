/// Configuration globale de l'application GeTech-SMS Mobile.
///
/// Centralise : timeouts, clés de stockage sécurisé, type de service mDNS,
/// limites de synchro, etc. L'URL du serveur est TOUJOURS configurée via
/// le module Connexions (jamais hard-codée).
library;

import 'package:flutter/foundation.dart';

/// Configuration statique de l'application.
class AppConfig {
  AppConfig._();

  /// Nom de l'application.
  static const String appName = 'GeTech-SMS';

  /// Version de l'application.
  static const String appVersion = '1.0.0';

  /// Préfixe de l'API REST (toujours relatif, complété par l'URL serveur).
  static const String apiPrefix = '/api/v1';

  /// Durée de validité du token d'appairage (QR code) côté desktop : 5 min.
  static const Duration pairingTokenTtl = Duration(minutes: 5);

  /// TTL attendu du JWT (24h) — utilisé pour le refresh proactif.
  static const Duration jwtTtl = Duration(hours: 24);

  /// Timeouts réseau.
  /// [Fix-LOGIN-20S] Le connectTimeout était de 20s « pour les réseaux LAN
  /// lents » : sur un serveur desktop injoignable (IP erronée, pare-feu
  /// qui DROPPE — cas fréquent sous Windows), le login patientait 20 s
  /// avant d'afficher « Délai de connexion dépassé après 20s ». Sur un
  /// LAN, une connexion TCP réussie prend < 1 s ; ce qui est lent c'est
  /// la RÉPONSE, couverte par receiveTimeout. 8 s couvre largement les
  /// cas réels (WiFi congesté, pont WiFi↔Ethernet) tout en divisant
  /// l'attente d'erreur par 2,5. Le message d'erreur cite désormais la
  /// constante — plus de « 20s » figé dans le texte.
  static const Duration connectTimeout = Duration(seconds: 8);
  static const Duration receiveTimeout = Duration(seconds: 30);
  static const Duration sendTimeout = Duration(seconds: 30);

  /// Intervalle de synchro automatique en arrière-plan.
  ///
  /// [Fix-SYNC-INTERVAL-HONESTY] Android WorkManager impose un minimum de
  /// 15 min (les valeurs inférieures sont silencieusement clampées à 15 min
  /// par le système — voir [main.dart]) : on déclare donc 15 min au lieu
  /// du 5 min historique pour être honnête avec l'utilisateur sur le
  /// délai MAXIMAL entre deux sync en arrière-plan. La synchro RAPIDE est
  /// assurée par le heartbeat 30 s + [AutoSyncController] sur transition
  /// réseau (cf. [network_state.dart]).
  static const Duration syncInterval = Duration(minutes: 15);

  /// Latence considérée comme "serveur injoignable".
  static const Duration unreachableThreshold = Duration(seconds: 10);

  /// Type de service mDNS/Bonjour publié par le desktop.
  static const String mdnsServiceType = '_getech-sms._tcp';

  /// Nombre maximum d'appareils appairés par établissement (défaut desktop).
  static const int maxPairedDevices = 10;

  /// Nombre maximum de retries par requête réseau.
  static const int maxRetries = 2;

  /// Taille de page par défaut pour les listes paginées.
  static const int defaultPageSize = 50;

  /// Clés de stockage sécurisé (flutter_secure_storage).
  static const String keyJwt = 'getech.jwt';
  static const String keyServerUrl = 'getech.server_url';
  static const String keyEstablishmentCode = 'getech.establishment_code';
  static const String keyDeviceToken = 'getech.device_token';
  static const String keyDeviceId = 'getech.device_id';
  static const String keyLastSync = 'getech.last_sync';
  static const String keyCredentials = 'getech.credentials';

  /// Clés SharedPreferences (préférences non sensibles).
  static const String prefThemeMode = 'getech.theme_mode';
  static const String prefForceOffline = 'getech.force_offline';
  static const String prefCurrentSchoolYearId = 'getech.current_school_year_id';
  static const String prefCurrentPeriodId = 'getech.current_period_id';

  /// Indique si l'app tourne en mode debug.
  static bool get isDebug => kDebugMode;
}
