/// État et providers de connexion au serveur (module Connexions).
library;

import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/config/app_config.dart';
import '../../core/cache/profile_scoped_cache.dart';
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

  /// [Fix-PAIRING-STUCK-OFFLINE] V26 — Mode « appairage différé » (appairage
  /// résilient) : le serveur était injoignable (ou a rejeté le token sur un
  /// décalage d'horloge) au moment de l'appairage. Contrairement à
  /// [forceOffline] (choix EXPLICITE de l'utilisateur, persisté), ce drapeau
  /// transitoire n'empêche PAS le heartbeat de re-pinger le serveur — dès que
  /// le serveur répond, il est relâché et l'état bascule « en ligne ».
  final bool pairingForcedOffline;
  final bool tolerateClockSkew;
  final String? discoveredServerName;

  /// [Fix-BAD-LAN-IP] URLs de REPLI du serveur (les autres IPs LAN du poste,
  /// reçues du QR d'appairage `ips[]` ou du server-info `api_urls`). La
  /// principale (serverUrl) peut désigner un adaptateur virtuel du desktop
  /// (vEthernet Hyper-V/WSL, VPN, pont Docker) : le heartbeat la ping en
  /// timeout à chaque battement et la carte resterait « hors ligne » à vie
  /// — les candidates sont essayées à chaque cycle.
  final List<String> alternateServerUrls;

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
    this.pairingForcedOffline = false,
    this.tolerateClockSkew = true,
    this.discoveredServerName,
    this.alternateServerUrls = const [],
  });

  bool get isPaired =>
      pairingToken != null && (serverIp != null || serverUrlOverride != null);
  bool get isOnline => status == ServerStatus.online && !forceOffline;
  // [Fix-ONLINE-DETECT] V24 — était `isOnline && status != offline` :
  // redondant (isOnline implique déjà online) mais surtout FRAGILE — tout
  // statut intermédiaire (checking après bascule multi-serveurs) coupait
  // l'accès aux données en ligne alors que le serveur répondait. Un appel
  // réseau réel reste l'arbitre final (timeout → ApiException).
  bool get canReachServer => isOnline;

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

  /// [Fix-BAD-LAN-IP] Toutes les URLs candidates à pinger, DANS L'ORDRE
  /// d'essai : une URL de repli ayant déjà RÉPONDU est promue en tête
  /// (elle est re-pingée d'abord aux battements suivants, ce qui divise
  /// la latence de reprise), puis l'URL principale du profil, puis le
  /// reste. Utilisé par [ConnectionNotifier.checkStatus].
  List<String> get allServerUrls {
    final primary = serverUrl;
    if (primary == null) return const [];
    final alternates = alternateServerUrls.where((u) => u != primary);
    // La première entrée de alternateServerUrls est l'URL gagnante du
    // battement précédent (promue par checkStatus) : l'honorer d'abord.
    final promoted = alternateServerUrls.isNotEmpty &&
            alternateServerUrls.first != primary
        ? alternateServerUrls.first
        : null;
    return [
      if (promoted != null) promoted,
      primary,
      ...alternates.where((u) => u != promoted),
    ];
  }

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
    bool? pairingForcedOffline,
    bool clearPairingForced = false,
    String? discoveredServerName,
    List<String>? alternateServerUrls,
    bool clearAlternates = false,
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
      pairingForcedOffline:
          clearPairingForced ? false : (pairingForcedOffline ?? this.pairingForcedOffline),
      discoveredServerName: discoveredServerName ?? this.discoveredServerName,
      alternateServerUrls: clearAlternates
          ? const []
          : (alternateServerUrls ?? this.alternateServerUrls),
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
    //
    // [Fix-SERVER-DATA-LEAK] V17 — last_sync_at/count sont désormais SCOPÉS
    // par profil : l'horodatage affiché dans Connexions doit être celui du
    // serveur ACTIF, pas celui du dernier serveur synchronisé (retour S4 :
    // données d'un autre serveur visibles après bascule).
    final conn = state;
    final pid = conn.profileId;
    final prefs = await SharedPreferences.getInstance();
    // [Fix-FORCE-OFFLINE-PERSIST] V26 — restaure le mode hors-ligne EXPLICITE
    // de l'utilisateur (clé canonique). L'ancienne clé 'force_offline' (sans
    // préfixe) n'était jamais relue au démarrage : le choix utilisateur se
    // perdait à chaque redémarrage. On la purge aussi — elle était écrite
    // autant par l'appairage résilient que par le commutateur, et ressusciter
    // un « true » obsolète réintroduirait le verrou « bloquée hors-ligne »
    // corrigé par [Fix-PAIRING-STUCK-OFFLINE].
    final userForcedOffline = prefs.getBool(AppConfig.prefForceOffline) ?? false;
    if (prefs.containsKey('force_offline')) {
      await prefs.remove('force_offline');
    }
    if (userForcedOffline) {
      state = state.copyWith(forceOffline: true);
    }
    final lastSync = prefs.getString(profileScopedKey('last_sync_at', pid));
    final lastCount = prefs.getInt(profileScopedKey('last_sync_count', pid));
    // [Fix-RESILIENT-PAIRING-REVIVAL] La préférence « force_offline »
    // (posée par l'appairage résilient ou le switch Réglages) était
    // écrite mais JAMAIS relue : après un redémarrage de l'app, le mode
    // repassait à false sans que la carte « Serveur injoignable » du
    // dernier échec soit réellement re-vérifiée. On la restaure ici.
    final forceOffline = prefs.getBool('force_offline') ?? false;
    if (lastSync != null || lastCount != null || forceOffline) {
      state = state.copyWith(
        lastSyncAt: lastSync != null ? DateTime.tryParse(lastSync) : null,
        lastSyncCount: lastCount,
        forceOffline: forceOffline,
      );
    }
  }

  /// Applique un profil du registre multi-serveurs (bascule ou démarrage).
  Future<void> applyProfile(ServerProfile profile) async {
    final storage = _ref.read(secureStorageProvider);
    final token = await storage.read(
          storage.profileKey(AppConfig.keyDeviceToken, profile.id),
        ) ??
        '';

    // [Fix-SERVER-DATA-LEAK] V17 — recharge l'horodatage de synchro du
    // PROFIL appliqué (clé scopée), sinon l'ancien serveur restait
    // affiché dans Connexions après une bascule.
    final prefs = await SharedPreferences.getInstance();
    final pid = profile.id;
    final lastSync = prefs.getString(profileScopedKey('last_sync_at', pid));
    final lastCount = prefs.getInt(profileScopedKey('last_sync_count', pid));

    state = state.copyWith(
      status: ServerStatus.checking,
      profileId: profile.id,
      serverUrlOverride: profile.serverUrl,
      establishmentCode: profile.establishmentCode,
      establishmentName: profile.establishmentName,
      pairingToken: token.isEmpty ? null : token,
      lastSyncAt:
          lastSync != null ? DateTime.tryParse(lastSync) : state.lastSyncAt,
      lastSyncCount: lastCount ?? state.lastSyncCount,
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

  /// [Fix-BAD-LAN-IP] Définit les URLs de repli du serveur actif (autres
  /// IPs LAN du poste desktop, reçues du QR `ips[]` ou du server-info
  /// `api_urls`). Le heartbeat les essaie quand l'URL principale timeout :
  /// sans elles, un desktop dont la route par défaut passe par un
  /// adaptateur virtuel (vEthernet Hyper-V/WSL, VPN) laisse la carte
  /// « hors ligne » à vie alors que l'API répond sur une autre IP.
  void setAlternateServerUrls(List<String> urls) {
    final primary = state.serverUrl;
    final cleaned = urls
        .map((u) => u.contains('/api/v1') ? u : '$u/api/v1')
        .where((u) => u != primary)
        .toSet()
        .toList();
    if (listEquals(_lastAlternateUrls, cleaned) && 
        listEquals(state.alternateServerUrls, cleaned)) {
      return;
    }
    _lastAlternateUrls = cleaned;
    state = state.copyWith(alternateServerUrls: cleaned);
  }

  List<String> _lastAlternateUrls = const [];

  Future<void> checkStatus() async {
    if (!state.isPaired || state.forceOffline) return;
    final urls = state.allServerUrls;
    if (urls.isEmpty) return;

    // [Fix-BAD-LAN-IP] Ping la principale, puis les URLs de repli (autres
    // IPs LAN du poste, reçues du QR `ips[]` / server-info `api_urls`)
    // UNIQUEMENT si elle échoue en réseau pur : si la principale désigne
    // un adaptateur virtuel du desktop (vEthernet Hyper-V/WSL, VPN), elle
    // timeout à chaque battement — sans repli, la carte resterait
    // « hors ligne » à vie alors que le serveur répond sur une autre IP.
    // Une candidate qui RÉPOND fait basculer l'état en ligne ; de plus
    // l'URL gagnante est mémorisée pour les cycles suivants (prioritaire).
    Object? lastNetworkError;
    for (var i = 0; i < urls.length; i++) {
      final isPrimary = i == 0;
      final outcome = await _pingServerInfo(urls[i]);
      if (outcome.reachable) {
        if (!isPrimary && mounted) {
          // Une URL de repli répond : la promouvoir en tête de liste pour
          // les battements suivants (allServerUrls l'essayera d'abord).
          final winner = urls[i];
          final current = state.alternateServerUrls;
          final promoted = [winner, ...current.where((u) => u != winner)];
          if (!listEquals(current, promoted)) {
            state = state.copyWith(alternateServerUrls: promoted);
          }
        }
        return;
      }
      if (!outcome.isNetworkFailure) {
        // Le serveur a répondu avec un statut d'erreur HTTP (ex. 5xx) :
        // panne côté serveur, pas d'adresse — inutile d'essayer les autres.
        if (mounted && state.status != ServerStatus.offline) {
          state = state.copyWith(status: ServerStatus.offline);
        }
        return;
      }
      lastNetworkError = outcome.error;
    }
    if (!mounted) return;
    if (state.status != ServerStatus.offline) {
      state = state.copyWith(
        status: ServerStatus.offline,
        errorMessage: _humanizeTimeoutError(lastNetworkError ??
            StateError('toutes les URLs candidates ont échoué')),
      );
    }
  }

/// Résultat d'un ping `GET /devices/server-info` sur UNE URL candidate.
class _PingOutcome {
  const _PingOutcome({
    required this.reachable,
    required this.isNetworkFailure,
    this.error,
  });

  /// True si le serveur a répondu (2xx ou statut HTTP d'erreur — le
  /// processus écoute et répond dans les deux cas).
  final bool reachable;

  /// True quand l'échec est réseau pur (timeout/refus/DNS) : une AUTRE
  /// candidate peut alors encore fonctionner.
  final bool isNetworkFailure;

  final Object? error;
}

  /// Ping une URL : 2xx → en ligne ; réponse HTTP d'erreur → serveur
  /// vivant (panne applicative) ; exception réseau → candidate suivante.
  Future<_PingOutcome> _pingServerInfo(String url) async {
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
      // [Fix-LATE-STATE-WRITE] Le ping est async et peut être lancé en
      // arrière-plan (login [Fix-LOGIN-REFRESH-STATE], heartbeat, resume) :
      // si le notifier a été libéré pendant l'attente, écrire `state` après
      // `dispose` lève « Bad state: used after dispose » — en test cela
      // fait échouer la suite APRES son terme ; en production cela
      // remonterait la même exception dans la zone racine. Garde `mounted`.
      if (!mounted) {
        return const _PingOutcome(reachable: true, isNetworkFailure: false);
      }
      _markServerReachable(stopwatch.elapsed);
      return const _PingOutcome(reachable: true, isNetworkFailure: false);
    } catch (e) {
      // [Fix-ONLINE-DETECT] V24 (réellement effectif) — une réponse HTTP
      // avec un statut d'erreur (401/403/404/5xx…) lève une DioException
      // badResponse AVANT d'atteindre le code ci-dessus : le correctif
      // historique « toute réponse HTTP = en ligne » (`statusCode != null`)
      // était donc INOPÉRANT et tout statut non-2xx continuait de marquer
      // le serveur « hors ligne » alors qu'il répondait. On rattrape ici :
      // dès que le serveur a RÉPONDU (quel que soit le code), le processus
      // écoute et répond → en ligne. Seules les vraies pannes réseau
      // (timeout, connexion refusée, DNS…) maintiennent « hors ligne ».
      final serverResponded = e is DioException && e.response != null;
      if (serverResponded) {
        stopwatch.stop();
        if (mounted) _markServerReachable(stopwatch.elapsed);
        return const _PingOutcome(reachable: true, isNetworkFailure: false);
      }
      final isNetwork = e is DioException &&
          (e.type == DioExceptionType.connectionTimeout ||
              e.type == DioExceptionType.receiveTimeout ||
              e.type == DioExceptionType.sendTimeout ||
              e.type == DioExceptionType.connectionError ||
              e.type == DioExceptionType.unknown);
      return _PingOutcome(
        reachable: false,
        isNetworkFailure: isNetwork,
        error: e,
      );
    }
  }

  /// Consigne « serveur en ligne ». Ne ré-émet l'état que sur transition
  /// significative — [Fix-HEARTBEAT-REBUILD] : le heartbeat tourne toutes
  /// les 30 s ; ré-émètre un nouvel objet à chaque battement (latence
  /// différente) invalidait TOUS les providers qui watchent la connexion
  /// et réinitialisait les saisies en cours (notes notamment).
  void _markServerReachable(Duration latency) {
    final prev = state;
    final isTransition = prev.status != ServerStatus.online ||
        prev.errorMessage != null ||
        prev.latency == null ||
        prev.pairingForcedOffline;
    if (!isTransition) return;
    state = prev.copyWith(
      status: ServerStatus.online,
      latency: latency,
      clearPairingForced: true,
      clearError: true,
    );
  }

  /// [Fix-PAIRING-STUCK-OFFLINE] V26 — Active le mode « appairage différé »
  /// après un appairage résilient (serveur injoignable, ou token rejeté sur
  /// un décalage d'horloge) : l'app reste utilisable hors ligne, mais SANS
  /// verrouiller l'état. Transitoire et non persisté : le heartbeat continue
  /// de pinger, et dès que le serveur répond, ce mode est relâché
  /// automatiquement et l'état bascule « en ligne » (l'utilisateur devra
  /// alors re-appairer pour obtenir un vrai jeton d'appareil).
  ///
  /// Avant : l'appairage résilient appelait `setForceOffline(true)` —
  /// drapeau persisté qu'aucun mécanisme ne relâchait (heartbeat, retour au
  /// premier plan, retour réseau et checkStatus sont tous conditionnés à
  /// `!forceOffline`) → « l'application restait bloquée hors ligne en étant
  /// en ligne », jusqu'à ce que l'utilisateur trouve le commutateur caché.
  void setPairingForcedOffline() {
    final online = state.status == ServerStatus.online;
    state = online
        ? state.copyWith(pairingForcedOffline: true)
        : state.copyWith(
            status: ServerStatus.offline,
            pairingForcedOffline: true,
            errorMessage: 'Serveur injoignable lors de l\'appairage — '
                'l\'application reste utilisable hors ligne et réessaie '
                'automatiquement.',
          );
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

  /// Force ou relâche le mode hors-ligne EXPLICITE de l'utilisateur (page
  /// Connexions / Réglages). Persisté sous la clé canonique — et relâche
  /// toujours l'éventuel mode « appairage différé ».
  Future<void> setForceOffline(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    // [Fix-FORCE-OFFLINE-PERSIST] V26 — clé canonique : l'ancienne clé
    // 'force_offline' n'était jamais relue au démarrage (choix perdu) et
    // polluait aussi la persistance de l'appairage résilient.
    await prefs.setBool(AppConfig.prefForceOffline, value);
    state = state.copyWith(
      forceOffline: value,
      clearPairingForced: true,
      clearError: true,
    );
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
    // [Fix-SERVER-DATA-LEAK] V17 — horodatage SCOPÉ au profil actif : la
    // date « dernière synchro » affichée doit correspondre au serveur
    // courant, pas au dernier serveur synchronisé.
    final prefs = await SharedPreferences.getInstance();
    final pid = state.profileId;
    await prefs.setString(
      profileScopedKey('last_sync_at', pid),
      now.toIso8601String(),
    );
    await prefs.setInt(profileScopedKey('last_sync_count', pid), count);
    state = state.copyWith(lastSyncAt: now, lastSyncCount: count);
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      // [Fix-PAIRING-STUCK-OFFLINE] V26 — seul le choix EXPLICITE de
      // l'utilisateur (forceOffline) suspend le ping : en mode
      // « appairage différé », le heartbeat continue — dès que le
      // serveur répond, l'état bascule « en ligne » (checkStatus).
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
