/// Interceptor Dio : injecte le JWT `Authorization: Bearer <token>` et gère
/// les erreurs 401 (token expiré) en déclenchant la déconnexion.
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/connections/connection_state.dart';
import '../auth/auth_state.dart';
import 'api_exceptions.dart';

/// Crée un interceptor d'authentification lié à l'état d'auth Riverpod.
///
/// Le token est lu à chaque requête (via `ref.read`) pour toujours utiliser
/// la valeur courante, sans recréer l'instance [Dio].
Interceptor authInterceptor(Ref ref) => _AuthInterceptor(ref);

class _AuthInterceptor extends Interceptor {
  _AuthInterceptor(this.ref);
  final Ref ref;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final token = ref.read(authProvider).token;
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    // En-tête d'appareil appairé (si disponible).
    final deviceToken = ref.read(connectionProvider.select((c) => c.pairingToken));
    if (deviceToken != null) {
      options.headers['X-Device-Token'] = deviceToken;
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final status = err.response?.statusCode;
    if (status == 401) {
      // Token invalide/expiré → déconnexion applicative.
      ref.read(authProvider.notifier).handleUnauthorized();
    }
    handler.next(err);
  }
}

/// Convertit les erreurs Dio en [ApiException] lisibles.
class ApiExceptionInterceptor extends Interceptor {
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    handler.reject(
      DioException(
        requestOptions: err.requestOptions,
        response: err.response,
        type: err.type,
        error: dioErrorToApiException(err),
        stackTrace: err.stackTrace,
        message: err.message,
      ),
    );
  }
}
