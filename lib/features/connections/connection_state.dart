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

/// État global de la connexion.
class ConnectionState {
  final ServerStatus status;
  final String? serverIp;
  final int? serverPort;
  final String? serverUrlOverride;
  final String? establishmentCode;
  final String? pairingToken;
  final Duration? latency;
  final DateTime? lastSyncAt;
  final int? lastSyncCount;
  final String? errorMessage;
  final bool forceOffline;
  final String? discoveredServerName;

  const ConnectionState({
    this.status = ServerStatus.unpaired,
    this.serverIp,
    this.serverPort,
    this.serverUrlOverride,
    this.establishmentCode,
    this.pairingToken,
    this.latency,
    this.lastSyncAt,
    this.lastSyncCount,
    this.errorMessage,
    this.forceOffline = false,
    this.discoveredServerName,
  });

  bool get isPaired => pairingToken != null && (serverIp != null || serverUrlOverride != null);
  bool get isOnline => status == ServerStatus.online && !forceOffline;
  bool get canReachServer => isOnline && status != ServerStatus.offline;

  String? get serverUrl {
    if (serverUrlOverride != null) return serverUrlOverride;
    if (serverIp != null) return 'http://$serverIp:$serverPort';
    return null;
  }

  String get baseUrl => serverUrl != null ? '$serverUrl/api/v1' : '';
  DateTime? get lastSync => lastSyncAt;

  ConnectionState copyWith({
    ServerStatus? status,
    String? serverIp,
    int? serverPort,
    String? serverUrlOverride,
    String? establishmentCode,
    String? pairingToken,
    Duration? latency,
    DateTime? lastSyncAt,
    int? lastSyncCount,
    String? errorMessage,
    bool? forceOffline,
    String? discoveredServerName,
    bool clearError = false,
  }) {
    return ConnectionState(
      status: status ?? this.status,
      serverIp: serverIp ?? this.serverIp,
      serverPort: serverPort ?? this.serverPort,
      serverUrlOverride: serverUrlOverride ?? this.serverUrlOverride,
      establishmentCode: establishmentCode ?? this.establishmentCode,
      pairingToken: pairingToken ?? this.pairingToken,
      latency: latency ?? this.latency,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      lastSyncCount: lastSyncCount ?? this.lastSyncCount,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      forceOffline: forceOffline ?? this.forceOffline,
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
    final prefs = await SharedPreferences.getInstance();
    final storage = _ref.read(secureStorageProvider);

    final ip = prefs.getString('server_ip');
    final port = prefs.getInt('server_port');
    final url = prefs.getString('server_url');
    final code = prefs.getString('establishment_code');
    final force = prefs.getBool('force_offline') ?? false;
    final lastSync = prefs.getString('last_sync_at');
    final lastCount = prefs.getInt('last_sync_count');
    final token = await storage.getPairingToken();

    if (token != null && (ip != null || url != null)) {
      state = state.copyWith(
        status: ServerStatus.checking,
        serverIp: ip,
        serverPort: port ?? 8000,
        serverUrlOverride: url,
        establishmentCode: code,
        pairingToken: token,
        forceOffline: force,
        lastSyncAt: lastSync != null ? DateTime.tryParse(lastSync) : null,
        lastSyncCount: lastCount,
      );
      if (!force) checkStatus();
      _startHeartbeat();
    }
  }

  Future<void> configure({
    required String serverUrl,
    required String establishmentCode,
    required String deviceToken,
    String? deviceId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final storage = _ref.read(secureStorageProvider);

    await prefs.setString('server_url', serverUrl);
    await prefs.setString('establishment_code', establishmentCode);
    await storage.savePairingToken(deviceToken);
    if (deviceId != null) await storage.saveDeviceId(deviceId);

    state = state.copyWith(
      status: ServerStatus.checking,
      serverUrlOverride: serverUrl,
      establishmentCode: establishmentCode,
      pairingToken: deviceToken,
    );
    await checkStatus();
    _startHeartbeat();
  }

  Future<void> unpair() async {
    final prefs = await SharedPreferences.getInstance();
    final storage = _ref.read(secureStorageProvider);

    await prefs.remove('server_ip');
    await prefs.remove('server_port');
    await prefs.remove('server_url');
    await prefs.remove('establishment_code');
    await storage.deletePairingToken();

    _heartbeatTimer?.cancel();
    state = ConnectionState.initial;
  }

  Future<void> checkStatus() async {
    if (!state.isPaired || state.forceOffline) return;

    final stopwatch = Stopwatch()..start();
    try {
      final dio = Dio(BaseOptions(
        baseUrl: state.baseUrl,
        connectTimeout: const Duration(seconds: 3),
      ));

      final response = await dio.get('/devices/server-info');
      stopwatch.stop();

      if (response.statusCode == 200) {
        state = state.copyWith(
          status: ServerStatus.online,
          latency: stopwatch.elapsed,
          clearError: true,
        );
      } else {
        state = state.copyWith(status: ServerStatus.offline);
      }
    } catch (e) {
      state = state.copyWith(
        status: ServerStatus.offline,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> toggleForceOffline() async {
    final prefs = await SharedPreferences.getInstance();
    final next = !state.forceOffline;
    await prefs.setBool('force_offline', next);
    state = state.copyWith(forceOffline: next);
    if (!next) checkStatus();
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
