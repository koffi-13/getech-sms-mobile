/// Planificateur de synchronisation (manuel + arrière-plan).
///
/// Trois déclencheurs de synchro sont prévus dans l'app :
/// 1. **Manuel** — l'utilisateur appuie sur "Synchroniser" (page Connexions) :
///    appel direct à [syncEngineProvider.syncNow] ou via [scheduleNow].
/// 2. **Au lancement** — le tableau de bord déclenche un [scheduleNow] au
///    démarrage de l'app.
/// 3. **Arrière-plan** — WorkManager appelle [runBackgroundSync]
///    périodiquement (cf. `AppConfig.syncInterval`).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/connections/connection_state.dart';
import '../../features/connections/server_profiles.dart';
import 'sync_engine.dart';

/// Planificateur de synchronisation.
///
/// [scheduleNow] lance une synchro immédiate en avant-plan via
/// [syncEngineProvider]. [runBackgroundSync] est destiné au callback
/// WorkManager : elle crée un [ProviderContainer] autonome, effectue la
/// synchro, puis libère les ressources.
class SyncScheduler {
  SyncScheduler(this._ref);

  final Ref _ref;

  /// Lance une synchronisation immédiate (avant-plan).
  ///
  /// Délègue à [SyncEngine.syncNow]. Les erreurs sont loguées mais non
  /// propagées : l'appelant peut ignorer le résultat ou l'attendre.
  Future<void> scheduleNow() async {
    try {
      await _ref.read(syncEngineProvider).syncNow();
    } catch (e) {
      // Les erreurs sont déjà capturées dans SyncResult ; ce catch ne
      // couvre que les exceptions vraiment inattendues.
      // ignore: avoid_print
      print('[SyncScheduler] scheduleNow échoué : $e');
    }
  }

  /// Callback statique pour WorkManager (synchro en arrière-plan).
  ///
  /// WorkManager appelle des fonctions top-level sans `Ref` : cette méthode
  /// crée donc un [ProviderContainer] autonome, effectue la synchro, puis
  /// libère les ressources.
  ///
  /// [Fix-BG-SYNC] Le registre multi-serveurs est bootstrapé AVANT la
  /// synchro : sans cela, l'état de connexion restait `unpaired` (le
  /// profil actif n'était jamais appliqué) et `syncNow` était un no-op —
  /// la tâche périodique ne synchronisait donc JAMAIS rien.
  static Future<void> runBackgroundSync() async {
    final container = ProviderContainer();

    try {
      // 1) Bootstrap multi-serveurs : charge le registre et applique le
      //    profil actif (serverUrl, base Drift, heartbeat).
      try {
        await container.read(serverBootstrapProvider.future);
      } catch (e) {
        // Registre vide / erreur de lecture → pas de serveur appairé.
        // ignore: avoid_print
        print('[SyncScheduler] bootstrap arrière-plan sans serveur : $e');
        return;
      }

      // 2) Attend que le statut quitte "checking" (ping terminé) ou timeout.
      final sw = Stopwatch()..start();
      while (sw.elapsed < const Duration(seconds: 15)) {
        await Future.delayed(const Duration(milliseconds: 500));
        final state = container.read(connectionProvider);
        if (state.status != ServerStatus.checking) break;
      }

      // 3) Lance la synchro (syncNow vérifie canReachServer en interne).
      await container.read(syncEngineProvider).syncNow();
    } catch (e) {
      // ignore: avoid_print
      print('[SyncScheduler] runBackgroundSync échoué : $e');
    } finally {
      container.dispose();
    }
  }
}

/// Provider Riverpod du planificateur de synchro.
final syncSchedulerProvider = Provider<SyncScheduler>((ref) {
  return SyncScheduler(ref);
});
