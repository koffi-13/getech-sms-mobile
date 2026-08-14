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
  // Note : la période minimale d'Android WorkManager est 15 min.
  await Workmanager().initialize(callbackDispatcher, isInDebugMode: AppConfig.isDebug);
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
