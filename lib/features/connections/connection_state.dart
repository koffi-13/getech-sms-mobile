/// État et providers de connexion au serveur (module Connexions).
///
/// Gère : URL serveur, code établissement, token d'appairage, statut
/// en ligne/hors-ligne, latence, dernière synchro, mode hors-ligne forcé.
library;

import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_endpoints.dart';
import '../auth/secure_storage.dart';

/// Statut de la connexion au serveur.
enum ServerStatus {
  checking,
  online,
  offline,
  unpaired,
}

/// État immuable de la connexion.
class ConnectionState {
  final String? serverUrl;
  final String? establishmentCode;
  final String? deviceToken;
  final String? deviceId;
  final ServerStatus status;
  final Duration? latency;
  final DateTime? lastSync;
  final int? lastSyncCount;
  final bool forceOffline;
  final String? discoveredServerName;

  const ConnectionState({
    this.serverUrl,
    this.establishmentCode,
    this.deviceToken,
    this.deviceId,
    this.status = ServerStatus.unpaired,
    this.latency,
    this.lastSync,
    this.lastSyncCount,
    this.forceOffline = false,
    this.discoveredServerName,
  });

  bool get isPaired =>
      serverUrl != null &&
      serverUrl!.isNotEmpty &&
      establishmentCode != null &&
      establishmentCode!.isNotEmpty;

  bool get canReachServer =>
      isPaired && !forceOffline && status == ServerStatus.online;

  ConnectionState copyWith({
    String? serverUrl,
    String? establishmentCode,
    String? deviceToken,
    String? deviceId,
    ServerStatus? status,
    Duration? latency,
    DateTime? lastSync,
    int? lastSyncCount,
    bool? forceOffline,
    String? discoveredServerName,
    bool clearDiscovered = false,
  }) =>
      ConnectionState(
        serverUrl: serverUrl ?? this.serverUrl,
        establishmentCode: establishmentCode ?? this.establishmentCode,
        deviceToken: deviceToken ?? this.deviceToken,
        deviceId: deviceId ?? this.deviceId,
        status: status ?? this.status,
        latency: latency ?? this.latency,
        lastSync: lastSync ?? this.lastSync,
        lastSyncCount: lastSyncCount ?? this.lastSyncCount,
        forceOffline: forceOffline ?? this.forceOffline,
        discoveredServerName: clearDiscovered
            ? null
            : (discoveredServerName ?? this.discoveredServerName),
      );

  static const initial = ConnectionState();
}

/// Provider du storage sécurisé (singleton).
final secureStorageProvider = Provider<SecureStorage>((ref) => SecureStorage());

/// Provider de l'état de connexion.
final connectionProvider =
    NotifierProvider<ConnectionNotifier, ConnectionState>(ConnectionNotifier.new);

/// Dio "nu" sans interceptor d'auth, pour le ping /health et l'appairage.
final _bareDioProvider = Provider<Dio>((ref) {
  return Dio(BaseOptions(
    connectTimeout: AppConfig.connectTimeout,
    receiveTimeout: AppConfig.receiveTimeout,
    sendTimeout: AppConfig.sendTimeout,
    headers: {'Accept': 'application/json'},
  ));
});

class ConnectionNotifier extends Notifier<ConnectionState> {
  @override
  ConnectionState build() {
    _loadFromStorage();
    return const ConnectionState();
  }

  Future<void> _loadFromStorage() async {
    final storage = ref.read(secureStorageProvider);
    final url = await storage.getServerUrl();
    final code = await storage.getEstablishmentCode();
    final token = await storage.getDeviceToken();
    final deviceId = await storage.getDeviceId();
    final lastSync = await storage.getLastSync();
    final prefs = await SharedPreferences.getInstance();
    final forceOffline = prefs.getBool(AppConfig.prefForceOffline) ?? false;
    if (url != null && code != null) {
      state = state.copyWith(
        serverUrl: url,
        establishmentCode: code,
        deviceToken: token,
        deviceId: deviceId,
        lastSync: lastSync,
        forceOffline: forceOffline,
        status: forceOffline
            ? ServerStatus.offline
            : ServerStatus.checking,
      );
      if (!forceOffline) await checkStatus();
    }
  }

  /// Configure la connexion serveur après appairage.
  Future<void> configure({
    required String serverUrl,
    required String establishmentCode,
    String? deviceToken,
    String? deviceId,
  }) async {
    final storage = ref.read(secureStorageProvider);
    await storage.saveServerUrl(serverUrl);
    await storage.saveEstablishmentCode(establishmentCode);
    if (deviceToken != null) await storage.saveDeviceToken(deviceToken);
    if (deviceId != null) await storage.saveDeviceId(deviceId);
    state = state.copyWith(
      serverUrl: serverUrl,
      establishmentCode: establishmentCode,
      deviceToken: deviceToken,
      deviceId: deviceId,
      status: ServerStatus.checking,
    );
    await checkStatus();
  }

  /// Enregistre la dernière synchro réussie.
  Future<void> recordSync({required int count}) async {
    final storage = ref.read(secureStorageProvider);
    final now = DateTime.now().toUtc();
    await storage.saveLastSync(now);
    state = state.copyWith(lastSync: now, lastSyncCount: count);
  }

  /// Bascule le mode hors-ligne forcé.
  Future<void> toggleForceOffline() async {
    final next = !state.forceOffline;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConfig.prefForceOffline, next);
    state = state.copyWith(
      forceOffline: next,
      status: next ? ServerStatus.offline : ServerStatus.checking,
    );
    if (!next) await checkStatus();
  }

  /// Vérifie la joignabilité du serveur (ping /health) et mesure la latence.
  Future<void> checkStatus() async {
    if (!state.isPaired || state.forceOffline) {
      state = state.copyWith(
        status: state.forceOffline
            ? ServerStatus.offline
            : (state.isPaired ? ServerStatus.offline : ServerStatus.unpaired),
      );
      return;
    }
    state = state.copyWith(status: ServerStatus.checking);
    try {
      final dio = ref.read(_bareDioProvider);
      final sw = Stopwatch()..start();
      await dio.get(
        buildUrl(state.serverUrl!, ApiEndpoints.health),
        options: Options(
          sendTimeout: AppConfig.unreachableThreshold,
          receiveTimeout: AppConfig.unreachableThreshold,
        ),
      );
      sw.stop();
      state = state.copyWith(
        status: ServerStatus.online,
        latency: Duration(milliseconds: sw.elapsedMilliseconds),
      );
    } catch (_) {
      state = state.copyWith(status: ServerStatus.offline, latency: null);
    }
  }

  /// Désappaire le mobile du serveur.
  Future<void> unpair() async {
    final storage = ref.read(secureStorageProvider);
    await storage.delete(key: AppConfig.keyServerUrl);
    await storage.delete(key: AppConfig.keyEstablishmentCode);
    await storage.delete(key: AppConfig.keyDeviceToken);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConfig.prefForceOffline, false);
    state = const ConnectionState();
  }
}

// --- mDNS discovery ---

/// Serveur découvert via mDNS/Bonjour.
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

  String get serverUrl => 'http://$ip:$port/api/v1';
}

/// Provider de découverte mDNS (stream des serveurs détectés sur le réseau local).
///
/// Le desktop publie le service `_getech-sms._tcp.local`. Ce provider écoute
/// les événements Bonsoir et résout les serveurs en [DiscoveredServer].
final mdnsDiscoveryProvider =
    StreamProvider.autoDispose<List<DiscoveredServer>>((ref) async* {
  final discovery = BonsoirDiscovery(serviceType: AppConfig.mdnsServiceType);
  await discovery.ready;
  final controller = StreamController<List<DiscoveredServer>>();
  final found = <String, DiscoveredServer>{};

  discovery.eventStream?.listen((event) async {
    if (event.service == null) return;
    final bs = event.service!;
    if (event.type == BonsoirDiscoveryEventType.discoveryServiceFound) {
      await bs.resolve();
    }
    if (event.type == BonsoirDiscoveryEventType.discoveryServiceResolved ||
        event.type == BonsoirDiscoveryEventType.discoveryServiceFound) {
      final ip = bs.ip;
      final port = bs.port;
      if (ip != null && ip.isNotEmpty) {
        final server = DiscoveredServer(
          name: bs.name,
          ip: ip,
          port: port,
          establishmentCode: bs.attributes?['establishment_code'],
          establishmentName: bs.attributes?['establishment_name'],
        );
        found[bs.name] = server;
        controller.add(found.values.toList());
      }
    } else if (event.type == BonsoirDiscoveryEventType.discoveryServiceLost) {
      found.remove(bs.name);
      controller.add(found.values.toList());
    }
  }, onDone: () => controller.close());

  // Émet une liste vide initiale pendant la recherche.
  yield const [];
  await for (final list in controller.stream) {
    yield list;
  }
  await discovery.stop();
});
