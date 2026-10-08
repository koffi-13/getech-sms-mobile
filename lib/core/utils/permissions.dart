/// Helper RBAC : vérification des permissions côté mobile.
///
/// Les permissions proviennent du JWT (claim `permissions`) ou de l'endpoint
/// `/auth/me`. Le code `*` (superuser) bypass toutes les vérifications.
///
/// Utilisé pour afficher/cacher les fonctionnalités selon le rôle de l'utilisateur.
library;

import '../config/constants.dart';

/// Vérifie si un utilisateur possède une permission donnée.
///
/// [userPermissions] : liste des codes de permission de l'utilisateur courant.
/// [required] : code requis (ex: [RbacPermissions.studentRead]).
/// Renvoie `true` si l'utilisateur est superuser (`*`) ou possède le code.
bool hasPermission(List<String> userPermissions, String required) {
  if (userPermissions.contains(RbacPermissions.wildcard)) return true;
  return userPermissions.contains(required);
}

/// Vérifie que l'utilisateur possède **au moins une** des permissions requises.
bool hasAnyPermission(List<String> userPermissions, List<String> required) {
  if (userPermissions.contains(RbacPermissions.wildcard)) return true;
  if (required.isEmpty) return true;
  for (final p in required) {
    if (userPermissions.contains(p)) return true;
  }
  return false;
}

/// Vérifie que l'utilisateur possède **toutes** les permissions requises.
bool hasAllPermissions(List<String> userPermissions, List<String> required) {
  if (userPermissions.contains(RbacPermissions.wildcard)) return true;
  for (final p in required) {
    if (!userPermissions.contains(p)) return false;
  }
  return true;
}
