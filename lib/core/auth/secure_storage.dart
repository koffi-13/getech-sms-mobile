/// Wrapper sécurisé pour le stockage du JWT, du token d'appairage et des
/// informations de connexion via `flutter_secure_storage`.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/app_config.dart';

/// Service de stockage sécurisé (Android Keystore / iOS Keychain).
class SecureStorage {
  SecureStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
          iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
        );

  final FlutterSecureStorage _storage;

  // --- Accès génériques ---
  Future<String?> read(String key) => _storage.read(key: key);
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  Future<void> delete(String key) => _storage.delete(key: key);

  // --- Clés PAR PROFIL DE SERVEUR (multi-serveurs) ---

  /// Clé suffixée par l'id de profil : `getech.jwt.srv_123-abc`.
  String profileKey(String base, String profileId) => '$base.$profileId';

  Future<String?> getJwtFor(String profileId) =>
      _storage.read(key: profileKey(AppConfig.keyJwt, profileId));
  Future<void> saveJwtFor(String profileId, String token) =>
      _storage.write(key: profileKey(AppConfig.keyJwt, profileId), value: token);
  Future<void> deleteJwtFor(String profileId) =>
      _storage.delete(key: profileKey(AppConfig.keyJwt, profileId));

  Future<String?> getDeviceTokenFor(String profileId) =>
      _storage.read(key: profileKey(AppConfig.keyDeviceToken, profileId));
  Future<void> saveDeviceTokenFor(String profileId, String token) =>
      _storage.write(
          key: profileKey(AppConfig.keyDeviceToken, profileId), value: token);

  Future<({String username, String password})?> getCredentialsFor(
      String profileId) async {
    final raw =
        await _storage.read(key: profileKey(AppConfig.keyCredentials, profileId));
    if (raw == null || !raw.contains(':::')) return null;
    final parts = raw.split(':::');
    return (username: parts[0], password: parts[1]);
  }

  Future<void> saveCredentialsFor(
      String profileId, String username, String password) =>
      _storage.write(
        key: profileKey(AppConfig.keyCredentials, profileId),
        value: '$username:::$password',
      );

  // --- Accès legacy (mono-serveur : migration uniquement) ---

  Future<String?> getJwt() => _storage.read(key: AppConfig.keyJwt);
  Future<void> saveJwt(String token) =>
      _storage.write(key: AppConfig.keyJwt, value: token);
  Future<void> deleteJwt() => _storage.delete(key: AppConfig.keyJwt);

  Future<String?> getServerUrl() => _storage.read(key: AppConfig.keyServerUrl);
  Future<void> saveServerUrl(String url) =>
      _storage.write(key: AppConfig.keyServerUrl, value: url);

  Future<String?> getEstablishmentCode() =>
      _storage.read(key: AppConfig.keyEstablishmentCode);
  Future<void> saveEstablishmentCode(String code) =>
      _storage.write(key: AppConfig.keyEstablishmentCode, value: code);

  Future<String?> getDeviceToken() =>
      _storage.read(key: AppConfig.keyDeviceToken);
  Future<void> saveDeviceToken(String token) =>
      _storage.write(key: AppConfig.keyDeviceToken, value: token);

  Future<String?> getPairingToken() => getDeviceToken();
  Future<void> savePairingToken(String token) => saveDeviceToken(token);
  Future<void> deletePairingToken() => _storage.delete(key: AppConfig.keyDeviceToken);

  Future<String?> getDeviceId() => _storage.read(key: AppConfig.keyDeviceId);
  Future<void> saveDeviceId(String id) =>
      _storage.write(key: AppConfig.keyDeviceId, value: id);

  Future<DateTime?> getLastSync() async {
    final s = await _storage.read(key: AppConfig.keyLastSync);
    if (s == null) return null;
    return DateTime.tryParse(s);
  }

  Future<void> saveLastSync(DateTime dt) =>
      _storage.write(key: AppConfig.keyLastSync, value: dt.toUtc().toIso8601String());

  /// Efface toutes les données d'authentification (déconnexion / désappairage).
  Future<void> clearAuth() async {
    await _storage.delete(key: AppConfig.keyJwt);
    await _storage.delete(key: AppConfig.keyLastSync);
  }

  /// Efface toutes les données de connexion (désappairage complet).
  Future<void> clearAll() async {
    await _storage.deleteAll();
  }

  /// Stocke les credentials (pour reconnexion automatique, optionnel).
  Future<void> saveCredentials(String username, String password) =>
      _storage.write(
        key: AppConfig.keyCredentials,
        value: '$username:::$password',
      );

  Future<({String username, String password})?> getCredentials() async {
    final raw = await _storage.read(key: AppConfig.keyCredentials);
    if (raw == null || !raw.contains(':::')) return null;
    final parts = raw.split(':::');
    return (username: parts[0], password: parts[1]);
  }
}
