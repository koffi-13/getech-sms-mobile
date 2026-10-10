/// État et providers de connexion au serveur (module Connexions).
library;

import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/auth/secure_storage.dart';
import 'server_profiles.dart';

/// Statut de la connexion au serveur.
enum ServerStatus {
  checking,
  online,
  offline,
  unpaired,
}

/// Modèle d'un serveur découvert via mDNS.
class DiscoveredServer {
  final String name;
  final String ip;
  final int port;
  final String? establishmentCode;
  final String? establishmentName;

  const DiscoveredServer({
    required this.name,
    required this.ip,
    required this.port,
    this.establishmentCode,
    this.establishmentName,
  });

  String get url => 'http://$ip:$port';
}

/// État global de la connexion (au serveur ACTIF du registre multi-serveurs).
class ConnectionState {
  final ServerStatus status;
  final String? profileId;
  final String? serverIp;
  final int? serverPort;
  final String? serverUrlOverride;
  final String? establishmentCode;
  final String? establishmentName;
  final String? pairingToken;
  final Duration? latency;
  final DateTime? lastSyncAt;
  final int? lastSyncCount;
  final String? errorMessage;
  final bool forceOffline;
  final bool tolerateClockSkew;
  final String? discoveredServerName;

  const ConnectionState({
    this.status = ServerStatus.unpaired,
    this.profileId,
    this.serverIp,
    this.serverPort,
    this.serverUrlOverride,
    this.establishmentCode,
    this.establishmentName,
    this.pairingToken,
    this.latency,
    this.lastSyncAt,
    this.lastSyncCount,
    this.errorMessage,
    this.forceOffline = false,
    this.tolerateClockSkew = true,
    this.discoveredServerName,
  });

  bool get isPaired => pairingToken != null && (serverIp != null || serverUrlOverride != null);
  bool get isOnline => status == ServerStatus.online && !forceOffline;
  bool get canReachServer => isOnline && status != ServerStatus.offline;

  /// Vrai tant que le premier heartbeat n'a pas tranché (au démarrage à
  /// froid) : les pages ne doivent PAS bloquer sur cet état — les requêtes
  /// réelles échoueront d'elles-mêmes si le serveur est injoignable.
  bool get isChecking => status == ServerStatus.checking;

  /// URL complète du serveur, TOUJOURS avec le préfixe `/api/v1`.
  /// - Si `serverUrlOverride` est défini (appairage manuel), il contient déjà
  ///   `/api/v1` (via `_normalizeServerUrl`).
  /// - Sinon (mDNS), on construit `http://<ip>:<port>/api/v1`.
  String? get serverUrl {
    if (serverUrlOverride != null) {
      // S'assurer que l'override contient bien /api/v1.
      final u = serverUrlOverride!;
      return u.contains('/api/v1') ? u : '$u/api/v1';
    }
    if (serverIp != null) return 'http://$serverIp:$serverPort/api/v1';
    return null;
  }

  /// URL de base pour Dio (même valeur que [serverUrl] — déjà avec `/api/v1`).
  String get baseUrl => serverUrl ?? '';
  DateTime? get lastSync => lastSyncAt;

  ConnectionState copyWith({
    ServerStatus? status,
    String? profileId,
    String? serverIp,
    int? serverPort,
    String? serverUrlOverride,
    String? establishmentCode,
    String? establishmentName,
    String? pairingToken,
    Duration? latency,
    DateTime? lastSyncAt,
    int? lastSyncCount,
    String? errorMessage,
    bool? forceOffline,
    bool? tolerateClockSkew,
    String? discoveredServerName,
    bool clearError = false,
  }) {
    return ConnectionState(
      status: status ?? this.status,
      profileId: profileId ?? this.profileId,
      serverIp: serverIp ?? this.serverIp,
      serverPort: serverPort ?? this.serverPort,
      serverUrlOverride: serverUrlOverride ?? this.serverUrlOverride,
      establishmentCode: establishmentCode ?? this.establishmentCode,
      establishmentName: establishmentName ?? this.establishmentName,
      pairingToken: pairingToken ?? this.pairingToken,
      latency: latency ?? this.latency,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      lastSyncCount: lastSyncCount ?? this.lastSyncCount,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      forceOffline: forceOffline ?? this.forceOffline,
      tolerateClockSkew: tolerateClockSkew ?? this.tolerateClockSkew,
      discoveredServerName: discoveredServerName ?? this.discoveredServerName,
    );
  }

  static const initial = ConnectionState();
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

final connectionProvider =
    StateNotifierProvider<ConnectionNotifier, ConnectionState>((ref) {
  return ConnectionNotifier(ref);
});

final secureStorageProvider = Provider<SecureStorage>((ref) => SecureStorage());

/// Contrôleur gérant l'état de la connexion.
class ConnectionNotifier extends StateNotifier<ConnectionState> {
  final Ref _ref;
  Timer? _heartbeatTimer;

  ConnectionNotifier(this._ref) : super(ConnectionState.initial) {
    _init();
  }

  Future<void> _init() async {
    // [Multi-serveurs] Le chargement est piloté par le registre
    // (serverProfileRegistryProvider -> MultiServerController.bootstrap) :
    // il applique le profil actif via applyProfile(). On ne lit plus les
    // clés legacy ici.
    final prefs = await SharedPreferences.getInstance();
    final lastSync = prefs.getString('last_sync_at');
    final lastCount = prefs.getInt('last_sync_count');
    if (lastSync != null || lastCount != null) {
      state = state.copyWith(
        lastSyncAt: lastSync != null ? DateTime.tryParse(lastSync) : null,
        lastSyncCount: lastCount,
      );
    }
  }

  /// Applique un profil du registre multi-serveurs (bascule ou démarrage).
  Future<void> applyProfile(ServerProfile profile) async {
    final storage = _ref.read(secureStorageProvider);
    final token = await storage.read(
          storage.profileKey(AppConfig.keyDeviceToken, profile.id)) ??
      '';

    state = state.copyWith(
      status: ServerStatus.checking,
      profileId: profile.id,
      serverUrlOverride: profile.serverUrl,
      establishmentCode: profile.establishmentCode,
      establishmentName: profile.establishmentName,
      pairingToken: token.isEmpty ? null : token,
      clearError: true,
    );
    if (!state.forceOffline) checkStatus();
    _startHeartbeat();
  }

  /// Plus aucun serveur enregistré : retour à l'onboarding d'appairage.
  void markUnpaired() {
    _heartbeatTimer?.cancel();
    state = ConnectionState.initial;
  }

  Future<void> checkStatus() async {
    if (!state.isPaired || state.forceOffline) return;
    final url = state.serverUrl;
    if (url == null) return;

    final stopwatch = Stopwatch()..start();
    try {
      // Dio "nu" sans interceptor d'auth, pour le ping /devices/server-info.
      // ⚠️ On utilise buildUrl (pas baseUrl + path) pour éviter le piège Dio
      // où un path commençant par '/' fait perdre le préfixe /api/v1.
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      final fullUrl = buildUrl(url, ApiEndpoints.devicesServerInfo);

      final response = await dio.get(fullUrl);
      stopwatch.stop();

      if (response.statusCode == 200) {
        final prev = state;
        // [Fix-HEARTBEAT-REBUILD] Le heartbeat tourne toutes les 30 s : ne
        // ré-émettre QUE si l'état significatif change (transition de statut
        // ou disparition d'une erreur). Avant, chaque battement produisait un
        // nouvel objet (latence différente) → invalidation de TOUS les
        // providers qui watchent la connexion → chargements brusques qui
        // réinitialisaient les saisies en cours (notes notamment).
        final isTransition = prev.status != ServerStatus.online ||
            prev.errorMessage != null ||
            prev.latency == null;
        if (isTransition) {
          state = prev.copyWith(
            status: ServerStatus.online,
            latency: stopwatch.elapsed,
            clearError: true,
          );
        }
      } else {
        if (state.status != ServerStatus.offline) {
          state = state.copyWith(status: ServerStatus.offline);
        }
      }
    } catch (e) {
      if (state.status != ServerStatus.offline) {
        state = state.copyWith(
          status: ServerStatus.offline,
          errorMessage: _humanizeTimeoutError(e),
        );
      }
    }
  }

  /// Message d'erreur humain et actionnable pour les erreurs réseau.
  /// Détecte les timeouts, les refus de connexion et les problèmes DNS.
  String _humanizeTimeoutError(Object e) {
    final msg = e.toString();
    if (e is DioException) {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
          return 'Délai de connexion dépassé. Vérifiez que le serveur desktop '
              'est démarré, sur le même réseau Wi-Fi que ce mobile, et que '
              'l\'adresse IP:port est correcte.';
        case DioExceptionType.connectionError:
          return 'Connexion refusée ou injoignable. Vérifiez l\'IP du serveur '
              'et que le pare-feu autorise le port.';
        case DioExceptionType.badCertificate:
          return 'Problème de certificat TLS.';
        case DioExceptionType.badResponse:
          return 'Réponse serveur invalide (${e.response?.statusCode}).';
        default:
          return 'Erreur réseau : ${e.message}';
      }
    }
    return msg;
  }

  Future<void> toggleForceOffline() async {
    final next = !state.forceOffline;
    await setForceOffline(next);
  }

  /// Force ou relâche le mode hors-ligne (utilisé par l'appairage résilient
  /// et la page Connexions).
  Future<void> setForceOffline(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('force_offline', value);
    state = state.copyWith(forceOffline: value);
    if (!value) checkStatus();
  }

  Future<void> toggleTolerateClockSkew() async {
    final prefs = await SharedPreferences.getInstance();
    final next = !state.tolerateClockSkew;
    await prefs.setBool('tolerate_clock_skew', next);
    state = state.copyWith(tolerateClockSkew: next);
  }

  Future<void> recordSync({int count = 0}) async {
    final now = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_sync_at', now.toIso8601String());
    await prefs.setInt('last_sync_count', count);
    state = state.copyWith(lastSyncAt: now, lastSyncCount: count);
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!state.forceOffline) checkStatus();
    });
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    super.dispose();
  }
}

/// Provider de découverte mDNS.
final mdnsDiscoveryProvider =
    StreamProvider.autoDispose<List<DiscoveredServer>>((ref) async* {
  final discovery = BonsoirDiscovery(type: AppConfig.mdnsServiceType);
  await discovery.ready;

  final controller = StreamController<List<DiscoveredServer>>();
  final found = <String, DiscoveredServer>{};

  discovery.eventStream?.listen((event) {
    if (event.service == null) return;
    final bs = event.service!;

    if (event.type == BonsoirDiscoveryEventType.discoveryServiceFound ||
        event.type == BonsoirDiscoveryEventType.discoveryServiceResolved) {

      final String resolvedIp;
      if (bs is ResolvedBonsoirService) {
        resolvedIp = bs.host ?? bs.attributes['ip'] ?? '';
      } else {
        resolvedIp = bs.attributes['ip'] ?? '';
      }

      found[bs.name] = DiscoveredServer(
        name: bs.name,
        ip: resolvedIp,
        port: bs.port,
        establishmentCode: bs.attributes['est_code'],
        establishmentName: bs.attributes['est_name'],
      );
    } else if (event.type == BonsoirDiscoveryEventType.discoveryServiceLost) {
      found.remove(bs.name);
    }
    controller.add(found.values.toList());
  });

  discovery.start();

  ref.onDispose(() {
    discovery.stop();
    controller.close();
  });

  yield* controller.stream;
});
