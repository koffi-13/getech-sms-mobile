/// DTOs d'authentification et de connexion (module Connexions).
///
/// Reflètent les contrats Pydantic de l'API FastAPI documentés dans PROMPT.md.
library;

import '../../core/config/constants.dart';

/// Requête de connexion.
class LoginRequest {
  final String username;
  final String password;
  final String establishmentCode;

  const LoginRequest({
    required this.username,
    required this.password,
    required this.establishmentCode,
  });

  Map<String, dynamic> toJson() => {
        'username': username,
        'password': password,
        'establishment_code': establishmentCode,
      };
}

/// Réponse de connexion (JWT + utilisateur + permissions + établissement).
class LoginResponse {
  final String accessToken;
  final String tokenType;
  final int expiresIn;
  final UserDto user;
  final List<String> roles;
  final List<String> permissions;
  final EstablishmentDto? establishment;

  const LoginResponse({
    required this.accessToken,
    this.tokenType = 'bearer',
    this.expiresIn = 86400,
    required this.user,
    this.roles = const [],
    this.permissions = const [],
    this.establishment,
  });

  factory LoginResponse.fromJson(Map<String, dynamic> j) => LoginResponse(
        accessToken: j['access_token'] as String,
        tokenType: (j['token_type'] as String?) ?? 'bearer',
        expiresIn: (j['expires_in'] as num?)?.toInt() ?? 86400,
        user: UserDto.fromJson(j['user'] as Map<String, dynamic>),
        roles: List<String>.from(j['roles'] as List? ?? const []),
        permissions: List<String>.from(j['permissions'] as List? ?? const []),
        establishment: j['establishment'] == null
            ? null
            : EstablishmentDto.fromJson(
                j['establishment'] as Map<String, dynamic>),
      );
}

/// Utilisateur (cache local + DTO API).
class UserDto {
  final int id;
  final String username;
  final String? firstName;
  final String? lastName;
  final String? email;
  final String? phone;
  final String? photoPath;
  final Sexe? sexe;
  final bool isActive;
  final bool isSuperuser;

  const UserDto({
    required this.id,
    required this.username,
    this.firstName,
    this.lastName,
    this.email,
    this.phone,
    this.photoPath,
    this.sexe,
    this.isActive = true,
    this.isSuperuser = false,
  });

  String get fullName =>
      [firstName, lastName].whereType<String>().where((s) => s.isNotEmpty).join(' ');

  factory UserDto.fromJson(Map<String, dynamic> j) => UserDto(
        id: (j['id'] as num).toInt(),
        username: j['username'] as String,
        firstName: j['first_name'] as String?,
        lastName: j['last_name'] as String?,
        email: j['email'] as String?,
        phone: j['phone'] as String?,
        photoPath: j['photo_path'] as String?,
        sexe: Sexe.fromCode(j['sexe'] as String?),
        isActive: (j['is_active'] as bool?) ?? true,
        isSuperuser: (j['is_superuser'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'first_name': firstName,
        'last_name': lastName,
        'email': email,
        'phone': phone,
        'photo_path': photoPath,
        'sexe': sexe?.code,
        'is_active': isActive,
        'is_superuser': isSuperuser,
      };
}

/// Établissement scolaire (multi-tenant — scopage par `establishment_id`).
class EstablishmentDto {
  final int id;
  final String code;
  final String name;
  final String? address;
  final String? city;
  final String? phone;
  final String? email;
  final String? logoPath;
  final String? currency;
  final String? country;

  const EstablishmentDto({
    required this.id,
    required this.code,
    required this.name,
    this.address,
    this.city,
    this.phone,
    this.email,
    this.logoPath,
    this.currency,
    this.country,
  });

  factory EstablishmentDto.fromJson(Map<String, dynamic> j) => EstablishmentDto(
        id: (j['id'] as num).toInt(),
        code: j['code'] as String,
        name: j['name'] as String,
        address: j['address'] as String?,
        city: j['city'] as String?,
        phone: j['phone'] as String?,
        email: j['email'] as String?,
        logoPath: j['logo_path'] as String?,
        currency: (j['currency'] as String?) ?? defaultCurrency,
        country: j['country'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'code': code,
        'name': name,
        'address': address,
        'city': city,
        'phone': phone,
        'email': email,
        'logo_path': logoPath,
        'currency': currency,
        'country': country,
      };
}

/// Informations serveur renvoyées par `GET /devices/server-info`
/// (découverte / appairage).
class ServerInfoDto {
  final String establishmentCode;
  final String establishmentName;
  final String serverVersion;
  final String apiUrl;

  const ServerInfoDto({
    required this.establishmentCode,
    required this.establishmentName,
    required this.serverVersion,
    required this.apiUrl,
  });

  factory ServerInfoDto.fromJson(Map<String, dynamic> j) => ServerInfoDto(
        establishmentCode: j['establishment_code'] as String,
        establishmentName: j['establishment_name'] as String,
        serverVersion: j['server_version'] as String? ?? 'unknown',
        apiUrl: j['api_url'] as String? ?? '',
      );
}

/// Contenu du QR code d'appairage généré par le desktop.
///
/// Format : `{ip, port, establishment_code, pairing_token}`.
class PairingPayload {
  final String ip;
  final int port;
  final String establishmentCode;
  final String pairingToken;

  const PairingPayload({
    required this.ip,
    required this.port,
    required this.establishmentCode,
    required this.pairingToken,
  });

  /// URL serveur dérivée : `http://<ip>:<port>/api/v1`.
  String get serverUrl => 'http://$ip:$port/api/v1';

  factory PairingPayload.fromJson(Map<String, dynamic> j) => PairingPayload(
        ip: j['ip'] as String,
        port: (j['port'] as num).toInt(),
        establishmentCode: j['establishment_code'] as String,
        pairingToken: j['pairing_token'] as String,
      );

  Map<String, dynamic> toJson() => {
        'ip': ip,
        'port': port,
        'establishment_code': establishmentCode,
        'pairing_token': pairingToken,
      };
}

/// Requête d'appairage d'un appareil : `POST /devices/pair`.
class PairDeviceRequest {
  final String pairingToken;
  final String deviceName;
  final String deviceType;
  final String deviceUuid;

  const PairDeviceRequest({
    required this.pairingToken,
    required this.deviceName,
    this.deviceType = 'MOBILE',
    required this.deviceUuid,
  });

  Map<String, dynamic> toJson() => {
        'pairing_token': pairingToken,
        'device_name': deviceName,
        'device_type': deviceType,
        'device_uuid': deviceUuid,
      };
}

/// Réponse d'appairage : token persistant de l'appareil.
class PairDeviceResponse {
  final String deviceToken;
  final int deviceId;
  final DateTime? pairedAt;

  const PairDeviceResponse({
    required this.deviceToken,
    required this.deviceId,
    this.pairedAt,
  });

  factory PairDeviceResponse.fromJson(Map<String, dynamic> j) => PairDeviceResponse(
        deviceToken: j['device_token'] as String,
        deviceId: (j['device_id'] as num).toInt(),
        pairedAt: j['paired_at'] == null
            ? null
            : DateTime.tryParse(j['paired_at'] as String),
      );
}

/// Appareil appairé (liste côté serveur / affichage).
class PairedDeviceDto {
  final int id;
  final String deviceName;
  final String deviceType;
  final String deviceUuid;
  final DateTime? pairedAt;
  final DateTime? lastSeen;
  final bool isRevoked;
  final int? userId;

  const PairedDeviceDto({
    required this.id,
    required this.deviceName,
    required this.deviceType,
    required this.deviceUuid,
    this.pairedAt,
    this.lastSeen,
    this.isRevoked = false,
    this.userId,
  });

  factory PairedDeviceDto.fromJson(Map<String, dynamic> j) => PairedDeviceDto(
        id: (j['id'] as num).toInt(),
        deviceName: j['device_name'] as String,
        deviceType: j['device_type'] as String? ?? 'MOBILE',
        deviceUuid: j['device_uuid'] as String,
        pairedAt: j['paired_at'] == null
            ? null
            : DateTime.tryParse(j['paired_at'] as String),
        lastSeen: j['last_seen'] == null
            ? null
            : DateTime.tryParse(j['last_seen'] as String),
        isRevoked: (j['is_revoked'] as bool?) ?? false,
        userId: (j['user_id'] as num?)?.toInt(),
      );
}
