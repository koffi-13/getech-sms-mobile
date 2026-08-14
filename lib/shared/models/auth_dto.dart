/// DTOs d'authentification et de connexion (module Connexions).
///
/// ⚠️ Alignés sur les schémas Pydantic du desktop (src/getech_sms/api/schemas.py).
/// Ne pas modifier les noms de champs sans vérifier le contrat serveur.
library;

import '../../core/config/constants.dart';
import '../../core/utils/formatters.dart';

/// Requête de connexion : `POST /auth/login`.
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

/// Aperçu d'un rôle (RoleBrief côté serveur).
class RoleBrief {
  final int id;
  final String code;
  final String name;

  const RoleBrief({required this.id, required this.code, required this.name});

  factory RoleBrief.fromJson(Map<String, dynamic> j) => RoleBrief(
        id: (j['id'] as num).toInt(),
        code: j['code'] as String? ?? '',
        name: j['name'] as String? ?? '',
      );

  @override
  String toString() => name;
}

/// Réponse de connexion (TokenResponse côté serveur).
///
/// `roles` est une liste de [RoleBrief] (pas de simples strings).
class LoginResponse {
  final String accessToken;
  final String tokenType;
  final int expiresIn;
  final UserDto user;
  final List<RoleBrief> roles;
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
        roles: (j['roles'] as List?)
                ?.map((e) => RoleBrief.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        permissions: List<String>.from(j['permissions'] as List? ?? const []),
        establishment: j['establishment'] == null
            ? null
            : EstablishmentDto.fromJson(
                j['establishment'] as Map<String, dynamic>),
      );
}

/// Réponse de `GET /auth/me` (MeResponse côté serveur).
class MeResponse {
  final UserDto user;
  final List<RoleBrief> roles;
  final List<String> permissions;
  final EstablishmentDto? establishment;

  const MeResponse({
    required this.user,
    this.roles = const [],
    this.permissions = const [],
    this.establishment,
  });

  factory MeResponse.fromJson(Map<String, dynamic> j) => MeResponse(
        user: UserDto.fromJson(j['user'] as Map<String, dynamic>),
        roles: (j['roles'] as List?)
                ?.map((e) => RoleBrief.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        permissions: List<String>.from(j['permissions'] as List? ?? const []),
        establishment: j['establishment'] == null
            ? null
            : EstablishmentDto.fromJson(
                j['establishment'] as Map<String, dynamic>),
      );
}

/// Utilisateur (UserResponse côté serveur).
///
/// Champs enrichis : `public_id`, `role` (string), `position`, `last_login_at`.
class UserDto {
  final int id;
  final String publicId;
  final String username;
  final String email;
  final String? firstName;
  final String? lastName;
  final bool isActive;
  final bool isSuperuser;
  final DateTime? lastLoginAt;
  // Champs enrichis (desktop-app parity)
  final String? role;
  final String? phone;
  final String? position;
  final String? photoPath;
  final Sexe? sexe;

  const UserDto({
    required this.id,
    this.publicId = '',
    required this.username,
    this.email = '',
    this.firstName,
    this.lastName,
    this.isActive = true,
    this.isSuperuser = false,
    this.lastLoginAt,
    this.role,
    this.phone,
    this.position,
    this.photoPath,
    this.sexe,
  });

  String get fullName =>
      [firstName, lastName].whereType<String>().where((s) => s.isNotEmpty).join(' ');

  factory UserDto.fromJson(Map<String, dynamic> j) => UserDto(
        id: (j['id'] as num).toInt(),
        publicId: j['public_id'] as String? ?? '',
        username: j['username'] as String? ?? '',
        email: j['email'] as String? ?? '',
        firstName: j['first_name'] as String?,
        lastName: j['last_name'] as String?,
        isActive: (j['is_active'] as bool?) ?? true,
        isSuperuser: (j['is_superuser'] as bool?) ?? false,
        lastLoginAt: DateFormatter.parse(j['last_login_at'] as String?),
        role: j['role'] as String?,
        phone: j['phone'] as String?,
        position: j['position'] as String?,
        photoPath: j['photo_path'] as String?,
        sexe: Sexe.fromCode(j['sexe'] as String?),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'public_id': publicId,
        'username': username,
        'email': email,
        'first_name': firstName,
        'last_name': lastName,
        'is_active': isActive,
        'is_superuser': isSuperuser,
        'last_login_at': DateFormatter.toIso(lastLoginAt),
        'role': role,
        'phone': phone,
        'position': position,
        'photo_path': photoPath,
        'sexe': sexe?.code,
      };
}

/// Requête de changement de mot de passe.
/// `current_password` (pas `old_password`) selon le schéma serveur.
class ChangePasswordRequest {
  final String currentPassword;
  final String newPassword;

  const ChangePasswordRequest({
    required this.currentPassword,
    required this.newPassword,
  });

  Map<String, dynamic> toJson() => {
        'current_password': currentPassword,
        'new_password': newPassword,
      };
}

/// Requête de mise à jour de profil (PATCH /auth/update-profile).
class UpdateProfileRequest {
  final String? firstName;
  final String? lastName;
  final String? email;
  final String? phone;
  final String? photoPath;
  final Sexe? sexe;

  const UpdateProfileRequest({
    this.firstName,
    this.lastName,
    this.email,
    this.phone,
    this.photoPath,
    this.sexe,
  });

  Map<String, dynamic> toJson() => {
        if (firstName != null) 'first_name': firstName,
        if (lastName != null) 'last_name': lastName,
        if (email != null) 'email': email,
        if (phone != null) 'phone': phone,
        if (photoPath != null) 'photo_path': photoPath,
        if (sexe != null) 'sexe': sexe!.code,
      };
}

/// Établissement scolaire (EstablishmentBrief / EstablishmentResponse).
class EstablishmentDto {
  final int id;
  final String code;
  final String name;
  final String? email;
  final String? phone;
  final String? city;
  final String? country;
  final String? address;
  final String? motto;
  final String? logoPath;
  final String? currency;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const EstablishmentDto({
    required this.id,
    required this.code,
    required this.name,
    this.email,
    this.phone,
    this.city,
    this.country,
    this.address,
    this.motto,
    this.logoPath,
    this.currency,
    this.createdAt,
    this.updatedAt,
  });

  factory EstablishmentDto.fromJson(Map<String, dynamic> j) => EstablishmentDto(
        id: (j['id'] as num).toInt(),
        code: j['code'] as String? ?? '',
        name: j['name'] as String? ?? '',
        email: j['email'] as String?,
        phone: j['phone'] as String?,
        city: j['city'] as String?,
        country: j['country'] as String?,
        address: j['address'] as String?,
        motto: j['motto'] as String?,
        logoPath: j['logo_path'] as String?,
        currency: (j['currency'] as String?) ?? defaultCurrency,
        createdAt: DateFormatter.parse(j['created_at'] as String?),
        updatedAt: DateFormatter.parse(j['updated_at'] as String?),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'code': code,
        'name': name,
        'email': email,
        'phone': phone,
        'city': city,
        'country': country,
        'address': address,
        'motto': motto,
        'logo_path': logoPath,
        'currency': currency,
      };
}

// ─── Module Connexions : appairage et devices ───────────────────────────────

/// Informations serveur renvoyées par `GET /devices/server-info`.
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
        establishmentCode: j['establishment_code'] as String? ?? '',
        establishmentName: j['establishment_name'] as String? ?? '',
        serverVersion: j['server_version'] as String? ?? 'unknown',
        apiUrl: j['api_url'] as String? ?? '',
      );
}

/// Contenu du QR code d'appairage généré par le desktop.
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

/// Requête d'appairage : `POST /devices/pair`.
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

/// Réponse d'appairage.
class PairDeviceResponse {
  final String deviceToken;
  final int deviceId;
  final DateTime? pairedAt;

  const PairDeviceResponse({
    required this.deviceToken,
    required this.deviceId,
    this.pairedAt,
  });

  factory PairDeviceResponse.fromJson(Map<String, dynamic> j) =>
      PairDeviceResponse(
        deviceToken: j['device_token'] as String,
        deviceId: (j['device_id'] as num).toInt(),
        pairedAt: j['paired_at'] == null
            ? null
            : DateTime.tryParse(j['paired_at'] as String),
      );
}

/// Appareil appairé.
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
        deviceName: j['device_name'] as String? ?? '',
        deviceType: j['device_type'] as String? ?? 'MOBILE',
        deviceUuid: j['device_uuid'] as String? ?? '',
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
