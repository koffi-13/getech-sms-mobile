/// Client Dio configuré pour GeTech-SMS : timeouts, interceptors (JWT + erreurs).
///
/// L'URL de base n'est PAS fixée : chaque requête construit son URL complète
/// via [buildUrl] à partir du `serverUrl` courant (module Connexions), ce qui
/// permet de changer de serveur à chaud sans recréer le client.
///
/// Le token JWT est injecté par [authInterceptor] qui le lit dans
/// `authProvider` à chaque requête (valeur toujours fraîche).
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/connections/connection_state.dart';
import '../auth/auth_state.dart';
import '../config/app_config.dart';
import 'api_exceptions.dart';
import 'auth_interceptor.dart';

/// Provider du client Dio principal (avec auth + gestion d'erreurs).
final dioProvider = Provider<Dio>((ref) {
  final dio = Dio(BaseOptions(
    connectTimeout: AppConfig.connectTimeout,
    receiveTimeout: AppConfig.receiveTimeout,
    sendTimeout: AppConfig.sendTimeout,
    headers: {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    },
    responseType: ResponseType.json,
  ));

  dio.interceptors.add(authInterceptor(ref));
  dio.interceptors.add(ApiExceptionInterceptor());

  if (AppConfig.isDebug) {
    dio.interceptors.add(LogInterceptor(
      requestHeader: false,
      responseHeader: false,
      requestBody: true,
      responseBody: true,
      error: true,
      logPrint: (o) => debugPrint('[DIO] $o'),
    ));
  }

  ref.onDispose(dio.close);
  return dio;
});

/// Wrapper autour de [Dio] pour exécuter une requête et propager les
/// [ApiException] (au lieu de [DioException]).
extension ApiRequestExtension on Dio {
  Future<Response<T>> getJson<T>(
    String url, {
    Map<String, dynamic>? query,
    Options? options,
  }) async {
    try {
      return await get<T>(url,
          queryParameters: query, options: options ?? Options());
    } on DioException catch (e) {
      throw (e.error is ApiException) ? e.error as Object : dioErrorToApiException(e);
    }
  }

  Future<Response<T>> postJson<T>(
    String url, {
    dynamic data,
    Options? options,
  }) async {
    try {
      return await post<T>(url, data: data, options: options ?? Options());
    } on DioException catch (e) {
      throw (e.error is ApiException) ? e.error as Object : dioErrorToApiException(e);
    }
  }

  Future<Response<T>> patchJson<T>(
    String url, {
    dynamic data,
    Options? options,
  }) async {
    try {
      return await patch<T>(url, data: data, options: options ?? Options());
    } on DioException catch (e) {
      throw (e.error is ApiException) ? e.error as Object : dioErrorToApiException(e);
    }
  }

  Future<Response<T>> deleteJson<T>(String url, {Options? options}) async {
    try {
      return await delete<T>(url, options: options ?? Options());
    } on DioException catch (e) {
      throw (e.error is ApiException) ? e.error as Object : dioErrorToApiException(e);
    }
  }
}
