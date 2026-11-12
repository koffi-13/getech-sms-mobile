/// Point d'entrée de l'application GeTech-SMS Mobile.
///
/// Initialise :
/// - les bindings Flutter ;
/// - le moteur de synchro en arrière-plan (workmanager) ;
/// - le [ProviderScope] Riverpod contenant [GeTechApp].
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';

import 'app.dart';
import 'core/config/app_config.dart';
import 'core/sync/sync_scheduler.dart';

/// Callback du workmanager : exécuté par le système d'exploitation en
/// arrière-plan pour déclencher la synchronisation.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      await SyncScheduler.runBackgroundSync();
    } catch (e) {
      if (kDebugMode) debugPrint('[Workmanager] sync failed: $e');
    }
    return true;
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialisation de la synchro en arrière-plan.
  // [Fix-SYNC-INTERVAL-HONESTY] Android WorkManager impose un minimum de
  // 15 min : AppConfig.syncInterval vaut désormais 15 min (et non plus 5 min)
  // — Android clampe silencieusement toute valeur inférieure, le déclarer
  // honnêtement évite les retours « la synchro de fond est plus espacée que
  // prévu ». La synchro RAPIDE reste assurée par le heartbeat 30 s +
  // AutoSyncController (transition réseau) et la synchro post-login.
  //
  // [Fix-DEV-NOTIFS] V10 : `isInDebugMode` TOUJOURS false — en mode debug,
  // le plugin workmanager affiche des NOTIFICATIONS DE DÉVELOPPEMENT
  // (« Result », « dartTask », « inputData », « Elapsed time »…) à chaque
  // exécution de la tâche périodique (retour utilisateur : « on voit
  // s'afficher les notifications de développement »). Le suivi du fond
  // reste disponible via les logs (debugPrint) sans polluer l'utilisateur.
  await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
  await Workmanager().registerPeriodicTask(
    'getech-sms-sync',
    'syncTask',
    frequency: AppConfig.syncInterval,
    constraints: Constraints(
      networkType: NetworkType.connected,
    ),
    existingWorkPolicy: ExistingWorkPolicy.keep,
  );

  runApp(
    const ProviderScope(
      child: GeTechApp(),
    ),
  );
}
