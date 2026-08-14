/// Contrôleur du module Connexions : appairage (manuel / QR / mDNS),
/// récupération des informations serveur et de la liste des appareils appairés.
///
/// Centralise les appels API `/devices/*` (FastAPI desktop) et délègue à
/// [ConnectionNotifier] la persistance de l'état de connexion après appairage.
library;

import 'dart:io' show Platform;
import 'dart:math' show Random;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/secure_storage.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../../shared/models/auth_dto.dart';
import 'connection_state.dart';

/// Erreur métier renvoyée par [ConnectionsController] en cas d'échec d'appairage.
class PairingException implements Exception {
  const PairingException(this.message, {this.statusCode, this.code});
  final String message;
  final int? statusCode;
  final String? code;

  @override
  String toString() =>
      'PairingException($statusCode${code != null ? ' $code' : ''}): $message';
}

/// Contrôleur Riverpod exposant les opérations d'appairage.
///
/// Stateless : la page appelante gère son propre indicateur de chargement.
/// En cas de succès, l'état de connexion est mis à jour via
/// [ConnectionNotifier.configure], ce qui déclenche ensuite le `checkStatus`.
class ConnectionsController {
  ConnectionsController(this._ref);

  final Ref _ref;

  Dio get _dio => _ref.read(dioProvider);
  SecureStorage get _storage => _ref.read(secureStorageProvider);

  /// Appairage à partir d'un payload QR code (`{ip, port, establishment_code, pairing_token}`).
  ///
  /// Construit l'URL serveur `http://<ip>:<port>/api/v1` et délègue à [_doPair].
  Future<PairDeviceResponse> pairWithPayload(PairingPayload payload) {
    return _doPair(
      serverUrl: payload.serverUrl,
      establishmentCode: payload.establishmentCode,
      pairingToken: payload.pairingToken,
    );
  }

  /// Appairage manuel : [serverUrl] doit déjà contenir le préfixe
  /// `/api/v1` (ex : `http://192.168.1.10:8000/api/v1`).
  Future<PairDeviceResponse> pairManual({
    required String serverUrl,
    required String establishmentCode,
    required String pairingToken,
  }) {
    return _doPair(
      serverUrl: serverUrl,
      establishmentCode: establishmentCode,
      pairingToken: pairingToken,
    );
  }

  /// Appairage commun : POST /devices/pair puis configure la connexion.
  Future<PairDeviceResponse> _doPair({
    required String serverUrl,
    required String establishmentCode,
    required String pairingToken,
  }) async {
    if (pairingToken.trim().isEmpty) {
      throw const PairingException('Token d\'appairage requis.');
    }
    try {
      final deviceUuid = await _ensureDeviceUuid();
      final deviceName = _defaultDeviceName();
      final url = buildUrl(serverUrl, ApiEndpoints.devicesPair);

      final resp = await _dio.post(
        url,
        data: PairDeviceRequest(
          pairingToken: pairingToken.trim(),
          deviceName: deviceName,
          deviceUuid: deviceUuid,
        ).toJson(),
      );

      final data = resp.data is Map ? resp.data as Map<String, dynamic> : <String, dynamic>{};
      final pairResp = PairDeviceResponse.fromJson(data);

      // Persiste l'état de connexion (serverUrl, code, token, deviceId).
      await _ref.read(connectionProvider.notifier).configure(
            serverUrl: serverUrl,
            establishmentCode: establishmentCode,
            deviceToken: pairResp.deviceToken,
            deviceId: pairResp.deviceId.toString(),
          );

      // Invalide les caches dépendant de l'appairage.
      _ref.invalidate(serverInfoProvider);
      _ref.invalidate(pairedDevicesProvider);

      return pairResp;
    } on DioException catch (e) {
      final api = (e.error is ApiException)
          ? e.error as ApiException
          : dioErrorToApiException(e);
      throw PairingException(
        api.message,
        statusCode: api.statusCode,
        code: api.errorCode,
      );
    } on PairingException {
      rethrow;
    } catch (e) {
      throw PairingException('Échec de l\'appairage : $e');
    }
  }

  /// Récupère ou génère un UUID d'appareil persistant (Keystore/Keychain).
  Future<String> _ensureDeviceUuid() async {
    final existing = await _storage.getDeviceId();
    if (existing != null && existing.isNotEmpty) return existing;
    final uuid = _generateDeviceUuid();
    await _storage.saveDeviceId(uuid);
    return uuid;
  }

  /// Génère un UUID pseudo-aléatoire : `mobile-<ms>-<randhex>`.
  static String _generateDeviceUuid() {
    final ms = DateTime.now().millisecondsSinceEpoch;
    final rand = Random.secure().nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    return 'mobile-$ms-$rand';
  }

  /// Nom d'appareil affiché côté serveur.
  static String _defaultDeviceName() {
    if (Platform.isIOS) return 'Mobile iOS';
    if (Platform.isAndroid) return 'Mobile Android';
    return 'Mobile';
  }
}

/// Provider du contrôleur d'appairage.
final connectionsControllerProvider =
    Provider<ConnectionsController>((ref) => ConnectionsController(ref));

/// Informations serveur : `GET /devices/server-info`.
///
/// Disponible uniquement lorsque l'appareil est appairé. En cas d'erreur
/// réseau (serveur hors-ligne), renvoie `null` plutôt que de planter.
final serverInfoProvider = FutureProvider.autoDispose<ServerInfoDto?>((ref) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return null;

  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.get(
      buildUrl(conn.serverUrl!, ApiEndpoints.devicesServerInfo),
    );
    if (resp.data is! Map) return null;
    return ServerInfoDto.fromJson(resp.data as Map<String, dynamic>);
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    // 401/403/404/5xx → on ignore silencieusement (non bloquant pour l'UI).
    if (api.statusCode != null && api.statusCode! >= 500) {
      throw api; // Erreur serveur → affichée par l'UI.
    }
    return null;
  } catch (_) {
    return null;
  }
});

/// Liste des appareils appairés (vue admin) : `GET /devices`.
///
/// Renvoie une liste vide si l'utilisateur n'est pas admin (403) ou si le
/// serveur n'est pas joignable.
final pairedDevicesProvider =
    FutureProvider.autoDispose<List<PairedDeviceDto>>((ref) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return const [];

  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.get(
      buildUrl(conn.serverUrl!, ApiEndpoints.devices),
    );
    final list = resp.data;
    if (list is List) {
      return list
          .whereType<Map>()
          .map((e) => PairedDeviceDto.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    if (list is Map && list['items'] is List) {
      return (list['items'] as List)
          .whereType<Map>()
          .map((e) => PairedDeviceDto.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    return const [];
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403) return const []; // Non-admin : liste masquée.
    return const [];
  } catch (_) {
    return const [];
  }
});
