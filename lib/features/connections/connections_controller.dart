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
import 'package:logger/logger.dart' as log_pkg;

import '../../core/auth/secure_storage.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../../core/sync/sync_engine.dart';
import '../../shared/models/auth_dto.dart';
import 'connection_state.dart';

final log_pkg.Logger _log = log_pkg.Logger(
  printer: log_pkg.PrettyPrinter(noBoxingByDefault: true),
);

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
  Future<PairDeviceResponse> pairWithPayload(PairingPayload payload, {bool tolerateClockSkew = true}) {
    return _doPair(
      serverUrl: payload.serverUrl,
      establishmentCode: payload.establishmentCode,
      pairingToken: payload.pairingToken,
      tolerateClockSkew: tolerateClockSkew,
    );
  }

  /// Appairage manuel : [serverUrl] doit déjà contenir le préfixe
  /// `/api/v1` (ex : `http://192.168.1.10:8000/api/v1`).
  Future<PairDeviceResponse> pairManual({
    required String serverUrl,
    required String establishmentCode,
    required String pairingToken,
    bool tolerateClockSkew = true,
  }) {
    return _doPair(
      serverUrl: serverUrl,
      establishmentCode: establishmentCode,
      pairingToken: pairingToken,
      tolerateClockSkew: tolerateClockSkew,
    );
  }

  /// Appairage commun : POST /devices/pair puis configure la connexion.
  Future<PairDeviceResponse> _doPair({
    required String serverUrl,
    required String establishmentCode,
    required String pairingToken,
    bool tolerateClockSkew = true,
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
          establishmentCode: establishmentCode.trim(),
        ).toJson(),
      );

      final data = resp.data is Map ? resp.data as Map<String, dynamic> : <String, dynamic>{};
      final pairResp = PairDeviceResponse.fromJson(data);

      // Succès immédiat : Persiste l'état de connexion normal.
      await _ref.read(connectionProvider.notifier).configure(
            serverUrl: serverUrl,
            establishmentCode: establishmentCode,
            deviceToken: pairResp.deviceToken,
            deviceId: pairResp.deviceId.toString(),
            tolerateClockSkew: tolerateClockSkew,
          );

      // Invalide les caches dépendant de l'appairage.
      _ref.invalidate(serverInfoProvider);
      _ref.invalidate(pairedDevicesProvider);

      // DÉCLENCHER UNE SYNCHRO INITIALE (PULL)
      // On ne l'attend pas pour ne pas bloquer l'UI, mais on la lance.
      _ref.read(syncEngineProvider).pull().catchError((e) {
        _log.w('Échec synchro initiale post-appairage : $e');
        return SyncResult(timestamp: DateTime.now()); // Dummy result
      });

      return pairResp;
    } on DioException catch (e) {
      // MODE RÉSILIENT : Si le serveur est injoignable ou renvoie une erreur de token
      // potentiellement due à un décalage d'horloge (400), on sauve quand même localement.
      final isNetworkError = e.type != DioExceptionType.badResponse;
      final isClockSkewSuspect = e.response?.statusCode == 400;

      if (isNetworkError || isClockSkewSuspect) {
        // On configure en mode "Force Offline" pour permettre l'accès à l'app
        // en attendant la synchro.
        await _ref.read(connectionProvider.notifier).configure(
              serverUrl: serverUrl,
              establishmentCode: establishmentCode,
              deviceToken: pairingToken.trim(), // On utilise le pairing token comme token temporaire
              deviceId: 'pending',
              forceOffline: true,
              tolerateClockSkew: tolerateClockSkew,
            );

        return PairDeviceResponse(
          deviceToken: pairingToken.trim(),
          deviceId: 0,
          pairedAt: DateTime.now(),
        );
      }

      final msg = _humanizePairingError(e, serverUrl);
      throw PairingException(msg, statusCode: e.response?.statusCode);
    } on PairingException {
      rethrow;
    } catch (e) {
      throw PairingException('Échec de l\'appairage : $e');
    }
  }

  /// Message d'erreur actionnable pour les échecs d'appairage.
  /// Détecte localhost, les timeouts et les connexions refusées.
  String _humanizePairingError(DioException e, String serverUrl) {
    if (serverUrl.contains('localhost') || serverUrl.contains('127.0.0.1')) {
      return 'L\'adresse « localhost » ou « 127.0.0.1 » désigne le mobile '
          'lui-même, pas le serveur desktop. Utilisez l\'IP LAN du desktop '
          '(ex: 192.168.1.10:8000).';
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return 'Délai de connexion dépassé. Vérifiez que le serveur desktop '
            'est démarré, sur le même réseau Wi-Fi, et que l\'IP:port est '
            'correcte. Le pare-feu du desktop doit autoriser le port.';
      case DioExceptionType.connectionError:
        return 'Connexion refusée ou serveur injoignable. Vérifiez l\'IP et '
            'le port. Assurez-vous que l\'endpoint /api/v1/devices/pair '
            'existe sur le serveur desktop.';
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode;
        if (code == 404) {
          return 'Endpoint /devices/pair introuvable (404). '
              'Le serveur desktop doit implémenter cet endpoint.';
        }
        if (code == 400) return 'Token d\'appairage invalide ou expiré.';
        if (code == 422) {
          final detail = e.response?.data?['detail'];
          return 'Erreur de validation (422) : ${detail ?? "Format de requête incorrect"}';
        }
        return 'Erreur serveur lors de l\'appairage ($code).';
      default:
        return 'Erreur réseau lors de l\'appairage : ${e.message ?? e.type.name}';
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
    // En cas d'erreur serveur (500) ou autre, on renvoie une liste vide 
    // plutôt que de bloquer l'UI de la page Connexions.
    _log.w('Erreur récupération appareils : ${api.message}');
    return const [];
  } catch (e) {
    _log.w('Erreur inattendue récupération appareils : $e');
    return const [];
  }
});
