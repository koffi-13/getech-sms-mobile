/// Registre multi-serveurs : plusieurs établissements GeTech-SMS, bascule
/// à chaud, JWT + token d'appairage + base Drift LOCALE par serveur.
///
/// Remplace l'ancienne configuration mono-serveur (SharedPreferences
/// `server_ip`/`server_url` + SecureStorage à clés uniques) par :
///   - un registre persisté (JSON) : liste de [ServerProfile] ;
///   - un id de profil actif ;
///   - des clés sécurisées PAR PROFIL (`getech.jwt.<id>`,
///     `getech.device_token.<id>`, `getech.credentials.<id>`) ;
///   - un fichier de base Drift PAR PROFIL (`getech_sms.db` pour le profil
///     hérité de l'ancienne config — conservation des données locales —,
///     `getech_sms_<id>.db` pour les nouveaux).
///
/// Migration automatique : au premier chargement, si le registre est vide
/// et qu'une configuration mono-serveur legacy existe, elle devient le
/// profil « main » (actif) sans perte de données.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart' as log_pkg;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/auth/secure_storage.dart';
import '../../core/auth/auth_state.dart';
import '../../core/auth/teacher_scope.dart';
import '../../core/database/database.dart';
import '../../core/sync/sync_engine.dart';
import 'connection_state.dart';
import 'connections_controller.dart';

final log_pkg.Logger _log = log_pkg.Logger(
  printer: log_pkg.PrettyPrinter(noBoxingByDefault: true),
);

/// Profil d'un serveur auquel l'appareil s'est déjà appairé.
class ServerProfile {
  final String id;
  final String serverUrl; // toujours avec /api/v1
  final String establishmentCode;
  final String? establishmentName;
  final String? deviceId;
  final String dbFile; // nom du fichier Drift local
  final DateTime? lastConnectedAt;
  final DateTime? lastSyncAt;

  const ServerProfile({
    required this.id,
    required this.serverUrl,
    required this.establishmentCode,
    this.establishmentName,
    this.deviceId,
    required this.dbFile,
    this.lastConnectedAt,
    this.lastSyncAt,
  });

  /// Nom d'affichage : établissement si connu, sinon code.
  String get displayName => establishmentName?.isNotEmpty == true
      ? establishmentName!
      : establishmentCode;

  ServerProfile copyWith({
    String? serverUrl,
    String? establishmentCode,
    String? establishmentName,
    String? deviceId,
    DateTime? lastConnectedAt,
    DateTime? lastSyncAt,
  }) =>
      ServerProfile(
        id: id,
        serverUrl: serverUrl ?? this.serverUrl,
        establishmentCode: establishmentCode ?? this.establishmentCode,
        establishmentName: establishmentName ?? this.establishmentName,
        deviceId: deviceId ?? this.deviceId,
        dbFile: dbFile,
        lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
        lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'server_url': serverUrl,
        'establishment_code': establishmentCode,
        'establishment_name': establishmentName,
        'device_id': deviceId,
        'db_file': dbFile,
        'last_connected_at': lastConnectedAt?.toIso8601String(),
        'last_sync_at': lastSyncAt?.toIso8601String(),
      };

  static ServerProfile fromJson(Map<String, dynamic> j) => ServerProfile(
        id: j['id'] as String,
        serverUrl: j['server_url'] as String? ?? '',
        establishmentCode: j['establishment_code'] as String? ?? '',
        establishmentName: j['establishment_name'] as String?,
        deviceId: j['device_id'] as String?,
        dbFile: j['db_file'] as String? ?? 'getech_sms.db',
        lastConnectedAt: DateTime.tryParse(j['last_connected_at'] as String? ?? ''),
        lastSyncAt: DateTime.tryParse(j['last_sync_at'] as String? ?? ''),
      );
}

/// Clés du registre (SharedPreferences).
const String _kProfiles = 'getech.server_profiles';
const String _kActiveId = 'getech.active_server_id';

/// Registre des serveurs appairés + profil actif.
class ServerProfileRegistry {
  ServerProfileRegistry(this._prefs, this._storage);

  final SharedPreferences _prefs;
  final SecureStorage _storage;

  List<ServerProfile> _profiles = [];
  String? _activeId;
  bool _migrated = false;

  List<ServerProfile> get profiles => List.unmodifiable(_profiles);
  String? get activeId => _activeId;
  ServerProfile? get active =>
      _activeId == null ? null : byId(_activeId!);
  bool get hasProfiles => _profiles.isNotEmpty;

  ServerProfile? byId(String id) {
    for (final p in _profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Chargement + migration legacy
  // ---------------------------------------------------------------------------

  Future<void> load() async {
    if (_migrated) return;
    _migrated = true;

    _profiles = _readProfiles();
    _activeId = _prefs.getString(_kActiveId);

    if (_profiles.isEmpty) {
      await _migrateLegacy();
    }
    if (_activeId != null && byId(_activeId!) == null) {
      _activeId = _profiles.isNotEmpty ? _profiles.first.id : null;
      await _prefs.setString(_kActiveId, _activeId ?? '');
    }
  }

  /// Convertit l'ancienne config mono-serveur en profil « main ».
  ///
  /// Le fichier de base reste `getech_sms.db` : les données locales de
  /// l'utilisateur (cache Drift, outbox) sont intégralement conservées.
  /// Le token d'appairage legacy est copié vers la clé par profil.
  Future<void> _migrateLegacy() async {
    final legacyUrl = _prefs.getString('server_url');
    final legacyIp = _prefs.getString('server_ip');
    final legacyPort = _prefs.getInt('server_port');
    final legacyCode = _prefs.getString('establishment_code') ?? '';
    final legacyToken = await _storage.getPairingToken();
    final legacyDeviceId = await _storage.getDeviceId();

    String? url;
    if (legacyUrl != null && legacyUrl.isNotEmpty) {
      url = legacyUrl.contains('/api/v1') ? legacyUrl : '$legacyUrl/api/v1';
    } else if (legacyIp != null && legacyIp.isNotEmpty) {
      url = 'http://$legacyIp:${legacyPort ?? 8000}/api/v1';
    }
    if (url == null || legacyToken == null || legacyToken.isEmpty) return;

    final profile = ServerProfile(
      id: 'main',
      serverUrl: url,
      establishmentCode: legacyCode,
      deviceId: legacyDeviceId,
      dbFile: 'getech_sms.db',
      lastConnectedAt: DateTime.now(),
    );
    _profiles = [profile];
    _activeId = 'main';
    await _storage.write(
      _storage.profileKey('getech.device_token', 'main'),
      legacyToken,
    );
    await _persist();
    _log.i('Migration mono-serveur -> profil « main » ($url)');
  }

  List<ServerProfile> _readProfiles() {
    final raw = _prefs.getString(_kProfiles);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((e) => ServerProfile.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _persist() async {
    await _prefs.setString(
      _kProfiles,
      jsonEncode(_profiles.map((p) => p.toJson()).toList()),
    );
    if (_activeId != null) {
      await _prefs.setString(_kActiveId, _activeId!);
    } else {
      await _prefs.remove(_kActiveId);
    }
  }

  // ---------------------------------------------------------------------------
  // Mutation
  // ---------------------------------------------------------------------------

  /// Génère un nouvel id de profil.
  static String newProfileId() {
    final ms = DateTime.now().millisecondsSinceEpoch;
    final rand = Random.secure().nextInt(1 << 20).toRadixString(36);
    return 'srv_$ms-$rand';
  }

  /// Enregistre (ou met à jour) un profil issu d'un appairage réussi et le
  /// définit comme actif. Renvoie le profil (nouveau ou existant).
  Future<ServerProfile> upsertFromPairing({
    required String serverUrl,
    required String establishmentCode,
    required String deviceToken,
    String? deviceId,
  }) async {
    // Un re-appairage du même serveur (même URL + code) réutilise le profil
    // (et donc sa base locale) au lieu d'en créer un doublon.
    ServerProfile? existing;
    for (final p in _profiles) {
      if (p.serverUrl == serverUrl && p.establishmentCode == establishmentCode) {
        existing = p;
        break;
      }
    }

    final profile = existing?.copyWith(
          deviceId: deviceId,
          lastConnectedAt: DateTime.now(),
        ) ??
        ServerProfile(
          id: newProfileId(),
          serverUrl: serverUrl,
          establishmentCode: establishmentCode,
          deviceId: deviceId,
          dbFile: 'getech_sms_${newProfileId()}.db',
          lastConnectedAt: DateTime.now(),
        );

    if (existing != null) {
      _profiles[_profiles.indexOf(existing)] = profile;
    } else {
      _profiles.add(profile);
    }
    _activeId = profile.id;

    // Token d'appairage PAR PROFIL.
    await _storage.write(
      _storage.profileKey('getech.device_token', profile.id),
      deviceToken,
    );
    await _persist();
    return profile;
  }

  Future<void> setActive(String id) async {
    if (byId(id) == null) return;
    _activeId = id;
    await _persist();
  }

  Future<void> updateEstablishmentName(String id, String? name) async {
    final p = byId(id);
    if (p == null || name == null || name.isEmpty) return;
    if (p.establishmentName == name) return;
    _profiles[_profiles.indexOf(p)] = p.copyWith(establishmentName: name);
    await _persist();
  }

  Future<void> recordConnected(String id) async {
    final p = byId(id);
    if (p == null) return;
    _profiles[_profiles.indexOf(p)] =
        p.copyWith(lastConnectedAt: DateTime.now());
    await _persist();
  }

  Future<void> recordSync(String id) async {
    final p = byId(id);
    if (p == null) return;
    _profiles[_profiles.indexOf(p)] = p.copyWith(lastSyncAt: DateTime.now());
    await _persist();
  }

  /// Oublie un profil : clés sécurisées + base locale supprimées.
  /// Renvoie l'id du prochain actif suggéré (premier restant), sinon null.
  Future<String?> forget(String id) async {
    final prof = byId(id);
    if (prof == null) return _activeId;
    _profiles.remove(prof);

    await _storage.delete(_storage.profileKey('getech.jwt', id));
    await _storage.delete(_storage.profileKey('getech.device_token', id));
    await _storage.delete(_storage.profileKey('getech.credentials', id));
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File(p.join(dir.path, prof.dbFile));
      if (await f.exists()) await f.delete();
      for (final suffix in ['-wal', '-shm']) {
        final side = File('${f.path}$suffix');
        if (await side.exists()) await side.delete();
      }
    } catch (e) {
      _log.w('Suppression base locale ${prof.dbFile} impossible : $e');
    }

    if (_activeId == id) {
      _activeId = _profiles.isNotEmpty ? _profiles.first.id : null;
    }
    await _persist();
    return _activeId;
  }
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

/// Provider du registre (singleton).
final serverProfileRegistryProvider = FutureProvider<ServerProfileRegistry>(
  (ref) async {
    final prefs = await SharedPreferences.getInstance();
    final storage = ref.watch(secureStorageProvider);
    final registry = ServerProfileRegistry(prefs, storage);
    await registry.load();
    return registry;
  },
);

/// Id du profil actif (null = aucun serveur).
///
/// Mis à jour par [MultiServerController] ; les providers dépendants
/// (base Drift, auth) se reconstruisent automatiquement via watch.
final activeProfileIdProvider = StateProvider<String?>((ref) => null);

/// Profil actif (null tant que le registre n'est pas chargé).
final activeProfileProvider = Provider<ServerProfile?>((ref) {
  final id = ref.watch(activeProfileIdProvider);
  if (id == null) return null;
  final regAsync = ref.watch(serverProfileRegistryProvider);
  return regAsync.maybeWhen(
    data: (reg) => reg.byId(id),
    orElse: () => null,
  );
});

/// Contrôleur multi-serveurs : bascule, oubli, appairage.
class MultiServerController {
  MultiServerController(this._ref);

  final Ref _ref;

  ServerProfileRegistry? get _registry =>
      _ref.read(serverProfileRegistryProvider).valueOrNull;

  ConnectionState get _conn => _ref.read(connectionProvider);

  /// Charge le registre au démarrage et applique le profil actif à
  /// [ConnectionNotifier]. Sans profil : état non appairé (onboarding).
  Future<void> bootstrap() async {
    final reg = _registry;
    if (reg == null) return;
    await _applyProfile(reg.active);
  }

  /// Applique un profil à l'état de connexion (sans persister).
  Future<void> _applyProfile(ServerProfile? profile) async {
    if (profile == null) {
      _ref.read(connectionProvider.notifier).markUnpaired();
      return;
    }
    _ref.read(activeProfileIdProvider.notifier).state = profile.id;
    // Base Drift du profil (les providers dépendants se reconstruisent).
    _ref.read(activeDbFileNameProvider.notifier).state = profile.dbFile;
    await _ref.read(connectionProvider.notifier).applyProfile(profile);
  }

  /// Bascule vers un autre serveur :
  ///   1. persiste l'id actif ;
  ///   2. ré-applique le profil à la connexion (heartbeat relancé) ;
  ///   3. invalide la session (le JWT du NOUVEAU serveur est restauré par
  ///      authProvider rebuild) ;
  ///   4. invalide la base Drift (fichier par profil) et les caches de
  ///      données dérivés.
  /// Ne fait rien si l'id est inconnu ou déjà actif.
  Future<void> switchTo(String id) async {
    final reg = _registry;
    if (reg == null) return;
    if (id == reg.activeId) return;
    final profile = reg.byId(id);
    if (profile == null) return;

    await reg.setActive(id);
    await reg.recordConnected(id);
    await _applyProfile(profile);
    await _resetSession();
  }

  /// Enregistre un appairage réussi (nouveau serveur ou re-appairage) et
  /// bascule dessus.
  Future<ServerProfile> completePairing({
    required String serverUrl,
    required String establishmentCode,
    required String deviceToken,
    String? deviceId,
  }) async {
    final reg = _registry;
    if (reg == null) {
      throw StateError('Registre multi-serveurs non initialisé');
    }
    final profile = await reg.upsertFromPairing(
      serverUrl: serverUrl,
      establishmentCode: establishmentCode,
      deviceToken: deviceToken,
      deviceId: deviceId,
    );
    await _applyProfile(profile);
    await _resetSession();
    return profile;
  }

  /// Oublie un serveur. Si c'était l'actif : bascule sur le premier
  /// restant (et reset de session), ou passe en non appairé.
  Future<void> forget(String id) async {
    final reg = _registry;
    if (reg == null) return;
    final nextId = await reg.forget(id);
    if (nextId == null) {
      _ref.read(activeProfileIdProvider.notifier).state = null;
      _ref.read(connectionProvider.notifier).markUnpaired();
      await _resetSession();
      return;
    }
    if (id == _conn.profileId) {
      await switchTo(nextId);
    }
  }

  /// Réinitialise les caches de session : auth (JWT par serveur), base
  /// Drift (fichier par serveur), scope enseignant, données de modules.
  Future<void> _resetSession() async {
    final ref = _ref;
    // La base Drift se ferme (onDispose) et se rouvre sur le nouveau fichier.
    ref.invalidate(databaseProvider);
    ref.invalidate(authProvider);
    // Caches de données.
    ref.invalidate(teacherScopeProvider);
    ref.invalidate(serverInfoProvider);
    ref.invalidate(pairedDevicesProvider);
    // Tentative de restauration de session + pull initial (non bloquant).
    try {
      final engine = ref.read(syncEngineProvider);
      engine.pull().catchError((e) {
        _log.d('Pull post-bascule différé : $e');
      });
    } catch (_) {}
  }

  /// Met à jour le nom d'établissement du profil actif (depuis server-info).
  Future<void> updateActiveEstablishmentName(String? name) async {
    final reg = _registry;
    final id = _ref.read(activeProfileIdProvider);
    if (reg == null || id == null) return;
    await reg.updateEstablishmentName(id, name);
  }

  /// Enregistre une synchro réussie sur le profil actif.
  Future<void> recordSync() async {
    final reg = _registry;
    final id = _ref.read(activeProfileIdProvider);
    if (reg == null || id == null) return;
    await reg.recordSync(id);
  }
}

/// Provider du contrôleur multi-serveurs.
final multiServerControllerProvider = Provider<MultiServerController>(
  (ref) => MultiServerController(ref),
);

/// Bootstrap appelé au démarrage (main/app) : charge le registre et
/// applique le profil actif.
///
/// Renvoie true dès qu'un profil actif existe (connexion en cours de
/// vérification), false si aucun serveur enregistré (onboarding pairing).
Future<bool> bootstrapServers(Ref ref) async {
  final controller = ref.read(multiServerControllerProvider);
  await ref.read(serverProfileRegistryProvider.future);
  await controller.bootstrap();
  return ref.read(activeProfileIdProvider) != null;
}

/// Provider de bootstrap consommé par [GeTechApp] (déclenche le redirect
/// du routeur dès que le registre est prêt).
final serverBootstrapProvider = FutureProvider<bool>((ref) async {
  return bootstrapServers(ref);
});
