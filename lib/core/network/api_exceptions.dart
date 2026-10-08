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
  const NetworkException(String message, {int? statusCode, dynamic details})
      : super(message, statusCode: statusCode, details: details);
}

/// 401 — token JWT invalide/expiré → déconnexion requise.
class UnauthorizedException extends ApiException {
  const UnauthorizedException([String message = 'Non authentifié'])
      : super(message, statusCode: 401, errorCode: 'UNAUTHORIZED');
}

/// 403 — permission RBAC insuffisante.
class ForbiddenException extends ApiException {
  const ForbiddenException([String message = 'Permission insuffisante'])
      : super(message, statusCode: 403, errorCode: 'FORBIDDEN');
}

/// 404 — ressource introuvable.
class NotFoundException extends ApiException {
  const NotFoundException([String message = 'Ressource introuvable'])
      : super(message, statusCode: 404, errorCode: 'NOT_FOUND');
}

/// 409 — conflit de synchro (server-wins).
class ConflictException extends ApiException {
  const ConflictException([String message = 'Conflit de synchronisation'])
      : super(message, statusCode: 409, errorCode: 'CONFLICT');
}

/// 422 — erreur de validation.
class ValidationException extends ApiException {
  const ValidationException(String message, {dynamic details})
      : super(message, statusCode: 422, errorCode: 'VALIDATION', details: details);
}

/// Erreur de parsing JSON.
class ParseException extends ApiException {
  const ParseException(String message, {dynamic details})
      : super(message, errorCode: 'PARSE_ERROR', details: details);
}

/// Convertit une réponse Dio en [ApiException] appropriée.
ApiException dioErrorToApiException(Object error) {
  if (error is ApiException) return error;
  final dynamic e = error;
  final type = error.runtimeType.toString();
  // DioException
  if (type == 'DioException' || type.contains('DioException')) {
    final response = e.response;
    final message = e.message as String? ?? 'Erreur réseau';
    if (response == null) {
      return NetworkException(message, details: e.type?.toString());
    }
    final status = response.statusCode as int?;
    final data = response.data;
    String msg = message;
    String? code;
    if (data is Map) {
      msg = (data['detail'] as String?) ??
          (data['message'] as String?) ??
          message;
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
        return ApiException(msg, statusCode: status, errorCode: code, details: data);
    }
  }
  return NetworkException(error.toString());
}
