/// Contrôleur du module Connexions : appairage (manuel / QR / mDNS),
/// récupération des informations serveur et de la liste des appareils appairés.
///
/// Centralise les appels API `/devices/*` (FastAPI desktop) et délègue à
/// [ConnectionNotifier] la persistance de l'état de connexion après appairage.
library;

import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart' as log_pkg;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../core/auth/secure_storage.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../../core/sync/sync_engine.dart';
import '../../shared/models/auth_dto.dart';
import 'connection_state.dart';
import 'server_profiles.dart';

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

  /// [Fix-BAD-LAN-IP] Candidates de l'appairage en cours (toutes les URLs
  /// du QR) : persistées comme replis du profil au moment du succès.
  List<String>? _pairingCandidateUrls;

  /// Replis en attente de persistance post-completePairing.
  List<String>? _pendingAltUrls;

  /// Appairage à partir d'un payload QR code (`{ip, port, establishment_code, pairing_token}`).
  ///
  /// Construit l'URL serveur `http://<ip>:<port>/api/v1` et délègue à [_doPair].
  Future<PairDeviceResponse> pairWithPayload(PairingPayload payload, {bool tolerateClockSkew = true}) {
    // [Fix-BAD-LAN-IP] Le QR transporte désormais TOUTES les IPs LAN du
    // poste (ips[]) : la route par défaut du desktop désigne souvent un
    // adaptateur virtuel (vEthernet Hyper-V/WSL, VPN, pont Docker)
    // injoignable depuis le téléphone — au lieu de s'enliser 8 s en timeout
    // sur la première IP, on essaie chaque candidate AVANT le repli
    // résilient. Une candidate qui répond donne un appairage réel.
    final urls = payload.serverUrls;
    _pairingCandidateUrls = urls;
    return _pairOverCandidates(
      urls: urls,
      establishmentCode: payload.establishmentCode,
      pairingToken: payload.pairingToken,
      tolerateClockSkew: tolerateClockSkew,
    );
  }

  /// Essaie chaque URL candidate ; ne bascule en repli résilient qu'après
  /// épuisement de la liste.
  Future<PairDeviceResponse> _pairOverCandidates({
    required List<String> urls,
    required String establishmentCode,
    required String pairingToken,
    bool tolerateClockSkew = true,
  }) async {
    Object? lastError;
    for (var i = 0; i < urls.length; i++) {
      final isLast = i == urls.length - 1;
      try {
        return await _doPair(
          serverUrl: urls[i],
          establishmentCode: establishmentCode,
          pairingToken: pairingToken,
          tolerateClockSkew: tolerateClockSkew,
        );
      } on PairingException catch (e) {
        // Une erreur métier (token refusé, 404 module absent, 422…)
        // ne dépend PAS de l'adresse : inutile d'essayer les autres.
        if (e.statusCode != null && e.statusCode! < 500) rethrow;
        lastError = e;
        _log.w('Appairage : candidate ${urls[i]} en échec ($e)'
            '${isLast ? '' : ' — essai suivant'}');
      } catch (e) {
        lastError = e;
        _log.w('Appairage : candidate ${urls[i]} en échec ($e)'
            '${isLast ? '' : ' — essai suivant'}');
      }
    }
    if (lastError is PairingException) rethrow;
    throw PairingException('Échec de l\'appairage : $lastError');
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

      // [Fix-BAD-LAN-IP] Persiste les URLs de repli reçues du QR (autres
      // IPs LAN du poste) pour le profil actif : le heartbeat les pinguera
      // si l'URL principale timeout (adaptateur virtuel du desktop).
      // ⚠ AVANT completePairing : au retour, le profil est déjà appliqué
      // et les replis doivent être relus par _applyProfile.
      try {
        final candidateUrls = <String>[serverUrl];
        for (final u in _pairingCandidateUrls ?? const <String>[]) {
          if (u.isNotEmpty && u != serverUrl) candidateUrls.add(u);
        }
        final prefs = await SharedPreferences.getInstance();
        // Le profil n'existe pas encore : la clé est dérivée du serverUrl
        // (id de profil = hash stable de l'URL, cf. upsertFromPairing).
        // On écrit donc APRÈS completePairing via l'id actif.
        _pendingAltUrls = candidateUrls;
      } catch (_) {/* non bloquant */}

      // [Multi-serveurs] L'appairage réussi est enregistré dans le registre
      // (nouveau profil ou re-appairage du même serveur) et devient actif.
      await _ref
          .read(multiServerControllerProvider)
          .completePairing(
            serverUrl: serverUrl,
            establishmentCode: establishmentCode,
            deviceToken: pairResp.deviceToken,
            deviceId: pairResp.deviceId.toString(),
          );

      // [Fix-BAD-LAN-IP] Maintenant le profil est actif : persister les
      // replis sous sa clé ET les injecter dans l'état de connexion.
      try {
        final activeId = _ref.read(activeProfileIdProvider);
        if (activeId != null && _pendingAltUrls != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setStringList(
            'profile_${activeId}_alt_urls',
            _pendingAltUrls!,
          );
          _ref
              .read(connectionProvider.notifier)
              .setAlternateServerUrls(_pendingAltUrls!);
        }
      } catch (_) {/* non bloquant */}
      _pendingAltUrls = null;

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
        // Mode résilient : le serveur est injoignable ou le token est
        // rejeté (décalage d'horloge). On enregistre quand même le serveur
        // dans le registre (token d'appairage temporaire) en mode forcé
        // hors-ligne — l'accès à l'app reste possible en attendant.
        await _ref
            .read(multiServerControllerProvider)
            .completePairing(
              serverUrl: serverUrl,
              establishmentCode: establishmentCode,
              deviceToken: pairingToken.trim(),
            );
        // [Fix-PAIRING-STUCK-OFFLINE] V26 — mode « appairage différé » :
        // transitoire et non persisté (l'ancien setForceOffline(true)
        // verrouillait l'app « hors ligne » sans qu'aucun mécanisme ne le
        // relâche — heartbeat, retour réseau et checkStatus sont tous
        // conditionnés à !forceOffline). Ici le heartbeat continue de
        // pinger et le mode est relâché dès que le serveur répond.
        _ref.read(connectionProvider.notifier).setPairingForcedOffline();

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
            'le port, et que le serveur desktop est démarré.';
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode;
        if (code == 404) {
          // [Fix-ERROR-DEV-INFO] pas de jargon d'endpoint côté utilisateur.
          return 'La fonctionnalité d\'appairage n\'est pas disponible sur '
              'ce serveur. Mettez le serveur GeTech-SMS à jour puis '
              'réessayez.';
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
    if (existing != null && existing.isNotEmpty) {
      // [Fix-SYNC-IDEMPOTENCE] Migration : les anciens device_uuid au format
      // 'mobile-<ms>-<randhex>' sont remplacés par un UUID v4 standard
      // pour assurer la compatibilité avec le serveur (qui attend un UUID
      // canonique pour les contraintes d'unicité).
      if (_isLegacyDeviceUuid(existing)) {
        final newUuid = _generateDeviceUuid();
        await _storage.saveDeviceId(newUuid);
        _log.i('device_uuid migré : $existing → $newUuid');
        return newUuid;
      }
      return existing;
    }
    final uuid = _generateDeviceUuid();
    await _storage.saveDeviceId(uuid);
    return uuid;
  }

  /// Détecte les anciens device_uuid au format pseudo-UUID.
  /// Format legacy : 'mobile-<ms>-<randhex>' (ex: 'mobile-1725900000000-a3f2c1d0').
  /// Format UUID v4 canonique : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.
  static bool _isLegacyDeviceUuid(String uuid) {
    if (uuid.startsWith('mobile-')) return true;
    // Vérifier le format UUID v4 canonique (8-4-4-4-12 hex digits).
    final uuidV4Regex = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      caseSensitive: false,
    );
    return !uuidV4Regex.hasMatch(uuid);
  }

  /// Génère un UUID v4 standard via le package `uuid`.
  ///
  /// [Fix-SYNC-IDEMPOTENCE] Avant : format pseudo-UUID 'mobile-<ms>-<randhex>'
  /// qui n'était pas canonique et pouvait causer des problèmes de tri/unicité
  /// côté serveur. Maintenant : UUID v4 RFC 4122 standard, universellement
  /// reconnu par toutes les plateformes et bases de données.
  static String _generateDeviceUuid() {
    return const Uuid().v4();
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
