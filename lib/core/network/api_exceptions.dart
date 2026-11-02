/// Exceptions réseau et API GeTech-SMS.
library;

/// Erreur de base pour toutes les erreurs API.
class ApiException implements Exception {
  final String message;
  final int? statusCode;
  final String? errorCode;
  final dynamic details;

  const ApiException(
    this.message, {
    this.statusCode,
    this.errorCode,
    this.details,
  });

  @override
  String toString() =>
      'ApiException($statusCode${errorCode != null ? ' $errorCode' : ''}): $message';
}

/// Erreur de connexion (serveur injoignable, timeout, pas de réseau).
class NetworkException extends ApiException {
  const NetworkException(super.message, {super.statusCode, super.details});
}

/// 401 — token JWT invalide/expiré → déconnexion requise.
class UnauthorizedException extends ApiException {
  const UnauthorizedException([super.message = 'Non authentifié'])
      : super(statusCode: 401, errorCode: 'UNAUTHORIZED');
}

/// 403 — permission RBAC insuffisante.
class ForbiddenException extends ApiException {
  const ForbiddenException([super.message = 'Permission insuffisante'])
      : super(statusCode: 403, errorCode: 'FORBIDDEN');
}

/// 404 — ressource introuvable.
class NotFoundException extends ApiException {
  const NotFoundException([super.message = 'Ressource introuvable'])
      : super(statusCode: 404, errorCode: 'NOT_FOUND');
}

/// 409 — conflit de synchro (server-wins).
class ConflictException extends ApiException {
  const ConflictException([super.message = 'Conflit de synchronisation'])
      : super(statusCode: 409, errorCode: 'CONFLICT');
}

/// 422 — erreur de validation.
class ValidationException extends ApiException {
  const ValidationException(super.message, {super.details})
      : super(statusCode: 422, errorCode: 'VALIDATION');
}

/// Erreur de parsing JSON.
class ParseException extends ApiException {
  const ParseException(super.message, {super.details})
      : super(errorCode: 'PARSE_ERROR');
}

/// Convertit une réponse Dio en [ApiException] appropriée.
ApiException dioErrorToApiException(Object error) {
  if (error is ApiException) return error;
  final dynamic e = error;
  final type = error.runtimeType.toString();
  // DioException
  if (type == 'DioException' || type.contains('DioException')) {
    final response = e.response;
    // [Fix-AUTH] Capturer l'erreur sous-jacente (SocketException, etc.)
    // pour donner un message utile au lieu de "Erreur réseau" générique.
    final underlyingError = e.error?.toString() ?? '';
    final message = e.message as String? ??
        (underlyingError.isNotEmpty ? underlyingError : 'Erreur réseau');
    if (response == null) {
      // Pas de réponse serveur → erreur réseau pure.
      // Inclure le détail de l'erreur socket si disponible.
      final detail = underlyingError.isNotEmpty
          ? underlyingError
          : e.type?.toString() ?? 'unknown';
      return NetworkException(message, details: detail);
    }
    final status = response.statusCode as int?;
    final data = response.data;
    String msg = message;
    String? code;
    if (data is Map) {
      // [Fix-AUTH-2] FastAPI retourne 'detail' soit comme un String (erreur
      // simple ex: "Invalid credentials") soit comme une List d'objets de
      // validation (erreur 422 ex: [{type, loc, msg, input}]).
      // Ne pas faire 'as String?' directement — sinon crash type cast.
      final detail = data['detail'];
      if (detail is String) {
        msg = detail;
      } else if (detail is List) {
        // Erreur de validation FastAPI 422 — extraire les messages.
        final errors = <String>[];
        for (final e in detail) {
          if (e is Map) {
            final field = (e['loc'] as List?)?.last?.toString() ?? '';
            final errMsg = e['msg'] as String? ?? '';
            if (field.isNotEmpty && errMsg.isNotEmpty) {
              errors.add('$field: $errMsg');
            } else if (errMsg.isNotEmpty) {
              errors.add(errMsg);
            }
          }
        }
        msg = errors.isNotEmpty ? errors.join('; ') : message;
      } else if (data['message'] is String) {
        msg = data['message'] as String;
      }
      code = data['error_code'] as String?;
    }
    switch (status) {
      case 401:
        return UnauthorizedException(msg);
      case 403:
        return ForbiddenException(msg);
      case 404:
        return NotFoundException(msg);
      case 409:
        return ConflictException(msg);
      case 422:
        return ValidationException(msg, details: data);
      default:
        return ApiException(
          msg,
          statusCode: status,
          errorCode: code,
          details: data,
        );
    }
  }
  return NetworkException(error.toString());
}
