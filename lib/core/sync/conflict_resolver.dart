/// Résolution de conflits de synchronisation (stratégie V1 : server-wins).
///
/// Le terminal desktop (FastAPI) est l'autorité source de vérité : en cas de
/// conflit entre une modification locale et une modification serveur, la
/// version serveur l'emporte systématiquement. La version locale est
/// simplement écrasée lors du prochain pull.
///
/// Cette stratégie simple est adaptée à la V1 où le mobile est principalement
/// un client de consultation/saisie légère, et le desktop le point d'entrée
/// principal des données.
library;

/// Stratégie de résolution de conflit V1 (server-wins).
class ConflictResolver {
  /// Retourne l'enregistrement gagnant.
  ///
  /// V1 : le serveur gagne toujours. La version locale est ignorée et sera
  /// écrasée par la version serveur lors du prochain [SyncEngine.pull].
  Map<String, dynamic> resolve({
    required Map<String, dynamic> local,
    required Map<String, dynamic> server,
    required String table,
  }) {
    // Server-wins : on retourne systématiquement la version serveur.
    return server;
  }

  /// Indique s'il existe un conflit entre une version locale et une version
  /// serveur.
  ///
  /// Un conflit est détecté lorsque le serveur a modifié l'enregistrement
  /// **après** la dernière synchronisation locale ([localSyncedAt]).
  /// Si [localSyncedAt] est `null` (jamais synchronisé), on considère qu'il
  /// n'y a pas de conflit : c'est une première réception.
  bool hasConflict({
    required DateTime? localSyncedAt,
    required DateTime serverUpdatedAt,
  }) {
    if (localSyncedAt == null) return false;
    return serverUpdatedAt.isAfter(localSyncedAt);
  }
}
