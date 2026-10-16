/// État de connectivité réseau de l'appareil — observable via Riverpod.
///
/// [Fix-AUTO-BG-SYNC] V16 — retour utilisateur : « Dès que le serveur et
/// l'application se retrouvent sur réseau, il faut que les opérations
/// s'effectuent en arrière-plan. »
///
/// Avant ce correctif, l'app ne disposait QUE du heartbeat 30 s
/// ([ConnectionNotifier._startHeartbeat]) et du déclencheur
/// [AppLifecycleState.resumed] ([AutoSyncController.onAppResumed]) pour
/// détecter que le serveur était redevenu joignable. Si l'utilisateur
/// gardait l'app en arrière-plan pendant une coupure WiFi puis revenait
/// au réseau, il devait attendre le prochain tick WorkManager (15 min)
/// — ou ressortir l'app au premier plan — pour qu'une synchro se lance.
///
/// `connectivity_plus` était DÉJÀ déclaré dans `pubspec.yaml` mais
/// n'était JAMAIS importé/utilisé. Ce fichier expose un
/// [StreamProvider] qui émet `true` quand l'appareil a un réseau
/// (WiFi/ethernet/mobile) et `false` quand il est totalement hors-ligne.
/// L'[AutoSyncController] s'y abonne et déclenche un ping serveur +
/// synchro automatique sur transition `false → true` — cf.
/// `lib/core/sync/auto_sync.dart`.
library;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Stream émettant `true` quand l'appareil dispose d'un réseau
/// (WiFi/ethernet/mobile), `false` quand il est totalement hors-ligne
/// (n'importe quel `ConnectivityResult.none`).
///
/// La première valeur émise correspond à l'état courant (via
/// [Connectivity.checkConnectivity]) puis les suivantes proviennent de
/// [Connectivity.onConnectivityChanged]. `connectivity_plus` v6 renvoie
/// une LISTE de résultats (un par interface) — on est « en ligne » si
/// au moins une n'est PAS `none`.
final networkStateProvider = StreamProvider<bool>((ref) async* {
  final connectivity = Connectivity();
  // Émettre l'état initial (sinon le stream reste silencieux jusqu'à la
  // première transition réelle — l'AutoSyncController raterait le
  // « démarre en ligne » cas trop tôt pour le heartbeat).
  final initial = await connectivity.checkConnectivity();
  yield initial.any((c) => c != ConnectivityResult.none);
  // Puis les changements.
  yield* connectivity.onConnectivityChanged
      .map((results) => results.any((c) => c != ConnectivityResult.none));
});
