/// Client Dio configuré pour GeTech-SMS : timeouts, interceptors (JWT + erreurs).
///
/// [Fix-BASE-URL] Un intercepteur _BaseUrlInterceptor résout automatiquement
/// les URLs relatives (ex: '/classrooms') en URLs complètes en utilisant
/// le serverUrl du ConnectionState. Cela permet à TOUS les contrôleurs
/// d'utiliser dio.get('/classrooms') sans buildUrl().
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/connections/connection_state.dart';
import '../auth/auth_state.dart';
import '../config/app_config.dart';
import 'api_endpoints.dart';
import 'api_exceptions.dart';
import 'auth_interceptor.dart';

/// Provider du client Dio principal (avec auth + gestion d'erreurs + baseUrl auto).
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

  // [Fix-BASE-URL] Intercepteur qui résout les URLs relatives en URLs complètes.
  // Ordre IMPORTANT : le baseUrl interceptor doit être AVANT les autres
  // pour que l'URL soit résolue avant l'ajout du token JWT.
  dio.interceptors.add(_BaseUrlInterceptor(ref));
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

/// [Fix-BASE-URL] Intercepteur qui résout les URLs relatives.
///
/// Si un contrôleur appelle `dio.get('/classrooms')`, cet intercepteur
/// transforme l'URL en `http://<serverUrl>/api/v1/classrooms` en lisant
/// le `serverUrl` depuis le ConnectionState.
///
/// Si l'URL est déjà absolue (commence par 'http'), elle n'est pas modifiée.
class _BaseUrlInterceptor extends Interceptor {
  _BaseUrlInterceptor(this.ref);
  final Ref ref;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final path = options.path;

    // Si l'URL est déjà absolue (http://...), ne rien faire.
    if (path.startsWith('http://') || path.startsWith('https://')) {
      handler.next(options);
      return;
    }

    // Si l'URL est relative (commence par '/'), résoudre avec le serverUrl.
    final conn = ref.read(connectionProvider);
    final serverUrl = conn.serverUrl;

    if (serverUrl != null && serverUrl.isNotEmpty) {
      // Utiliser buildUrl pour construire l'URL complète.
      options.path = buildUrl(serverUrl, path);
    } else {
      // Pas de serverUrl configuré — l'erreur sera plus claire que
      // "No host specified in URI".
      debugPrint('[DIO] AVERTISSEMENT: serverUrl est null, '
          'impossible de résoudre $path');
    }

    handler.next(options);
  }
}

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
