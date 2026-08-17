/// Contrôleur du module Paramètres : périodes scolaires et établissement courant.
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/constants.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../connections/connection_state.dart';
import '../../shared/models/auth_dto.dart';
import '../../shared/models/classroom_dto.dart';

// ---------------------------------------------------------------------------
// AppSettings
// ---------------------------------------------------------------------------

class AppSettings {
  final ThemeMode themeMode;
  final bool forceOffline;

  AppSettings({
    this.themeMode = ThemeMode.system,
    this.forceOffline = false,
  });

  AppSettings copyWith({ThemeMode? themeMode, bool? forceOffline}) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        forceOffline: forceOffline ?? this.forceOffline,
      );
}

class SettingsNotifier extends StateNotifier<AppSettings> {
  SettingsNotifier() : super(AppSettings());

  void setThemeMode(ThemeMode mode) => state = state.copyWith(themeMode: mode);
  void setForceOffline(bool v) => state = state.copyWith(forceOffline: v);
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, AppSettings>((ref) {
  return SettingsNotifier();
});

// ---------------------------------------------------------------------------
// Providers de lecture
// ---------------------------------------------------------------------------

final periodsProvider =
    FutureProvider.autoDispose<List<PeriodDto>>((ref) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.canReachServer || conn.serverUrl == null) return const [];

  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.getJson(
      buildUrl(conn.serverUrl!, ApiEndpoints.settingsPeriods),
    );
    final data = resp.data;
    if (data is List) {
      return data
          .whereType<Map>()
          .map((e) => PeriodDto.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    return const [];
  } catch (_) {
    return const [];
  }
});

final establishmentProvider =
    FutureProvider<EstablishmentDto?>((ref) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return null;

  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.getJson(
      buildUrl(conn.serverUrl!, ApiEndpoints.settingsEstablishment),
    );
    if (resp.data is Map) {
      return EstablishmentDto.fromJson(Map<String, dynamic>.from(resp.data as Map));
    }
  } catch (_) {}
  return null;
});

class SettingsController {
  SettingsController(this._ref);
  final Ref _ref;

  Future<UserDto> updateProfile({
    String? firstName,
    String? lastName,
    String? email,
    String? phone,
    Sexe? sexe,
  }) async {
    final conn = _ref.read(connectionProvider);
    if (conn.serverUrl == null) throw const ApiException('Aucun serveur configuré.');

    final payload = <String, dynamic>{
      if (firstName != null) 'first_name': firstName,
      if (lastName != null) 'last_name': lastName,
      if (email != null) 'email': email,
      if (phone != null) 'phone': phone,
      if (sexe != null) 'sexe': sexe.code,
    };

    final dio = _ref.read(dioProvider);
    final resp = await dio.patchJson(
      buildUrl(conn.serverUrl!, ApiEndpoints.authUpdateProfile),
      data: payload,
    );
    return UserDto.fromJson(Map<String, dynamic>.from(resp.data));
  }
}

final settingsControllerProvider = Provider<SettingsController>((ref) => SettingsController(ref));
