/// Orchestrateur de synchronisation AUTOMATIQUE.
///
/// [Fix-AUTO-SYNC] V15 — retour utilisateur : « tant que le serveur est en
/// ligne avec l'application mobile, la connexion et la synchronisation
/// s'effectuent automatiquement ».
///
/// Avant ce correctif, l'outbox (notes saisies hors-ligne, mutations
/// d'élèves…) n'était poussé QUE par le bouton « Synchroniser » ou par la
/// tâche WorkManager (15 min minimum) : un enseignant qui revenait à
/// portée du serveur devait synchroniser À LA MAIN, sinon ses notes
/// restaient bloquées dans l'outbox indéfiniment.
///
/// Désormais :
/// - à CHAQUE transition « serveur injoignable → serveur en ligne »
///   (détectée par le heartbeat 30 s, au démarrage, ou au retour au
///   premier plan via [AutoSyncController.onAppResumed]), une synchro
///   complète (pull → push → pull) est lancée automatiquement ;
/// - les exécutions sont débouncées (2 s) et sans recouvrement
///   (single-flight) pour survivre aux rafales de transitions ;
/// - à la fin d'une synchro qui a transféré des données, le moteur
///   incrémente [syncGenerationProvider] : les providers de données qui
///   la surveillent (classement, évaluations, notes, classes…) se
///   rafraîchissent tous seuls — « s'actualise automatiquement à la
///   connexion ».
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/connections/connection_state.dart';
import 'sync_engine.dart';

/// Décision pure (testable) : faut-il déclencher une synchro automatique
/// sur cette transition d'état de connexion ?
///
/// Vrai uniquement pour un passage « injoignable → joignable » (le premier
/// état — démarrage à froid — est considéré injoignable : la première
/// détection du serveur déclenche donc bien une synchro de rattrapage).
bool shouldAutoSync(ConnectionState? prev, ConnectionState next) {
  final wasReachable = prev?.canReachServer ?? false;
  return !wasReachable && next.canReachServer && !next.forceOffline;
}

/// Contrôleur de la synchronisation automatique.
class AutoSyncController {
  AutoSyncController(this._ref);

  final Ref _ref;

  /// Garde single-flight : une seule synchro auto à la fois (le moteur
  /// n'est de toute façon pas réentrant, mais on évite aussi les
  /// débounces empilés pendant une synchro en cours).
  bool _running = false;

  /// Debounce des transitions (le heartbeat peut émettre plusieurs
  /// transitions rapprochées au réveil réseau).
  Timer? _debounce;

  /// Appelé à CHAQUE changement d'état de la connexion (heartbeat 30 s,
  /// appairage, bascule de profil, retour au premier plan…).
  void handleConnectionChange(ConnectionState? prev, ConnectionState next) {
    if (shouldAutoSync(prev, next)) {
      _schedule();
    }
  }

  /// Retour au premier plan : re-pingue le serveur IMMÉDIATEMENT (le
  /// heartbeat ne passe que toutes les 30 s — c'était jusqu'à 30 s
  /// d'attente avant de détecter un serveur revenu en ligne). Si le ping
  /// fait basculer l'état vers « en ligne », la transition déclenchera
  /// [handleConnectionChange] → synchro automatique.
  void onAppResumed() {
    final conn = _ref.read(connectionProvider);
    if (conn.isPaired && !conn.forceOffline) {
      unawaited(_ref.read(connectionProvider.notifier).checkStatus());
    }
  }

  void _schedule() {
    _debounce?.cancel();
    // Petit délai : laisse le heartbeat/serveur se stabiliser (le ping
    // de /devices/server-info peut réussir pendant que l'API auth met
    // encore quelques centaines de ms à accepter les requêtes après un
    // redémarrage du service desktop).
    _debounce = Timer(const Duration(seconds: 2), () {
      unawaited(syncIfIdle());
    });
  }

  /// Lance la synchronisation si aucune n'est déjà en cours et que le
  /// serveur est joignable. Les erreurs sont portées par [SyncResult]
  /// (jamais propagées : la synchro auto est silencieuse).
  Future<void> syncIfIdle() async {
    if (_running) return;
    final conn = _ref.read(connectionProvider);
    if (!conn.canReachServer) return;
    _running = true;
    try {
      await _ref.read(syncEngineProvider).syncNow();
    } catch (_) {
      // Les erreurs attendues sont déjà dans SyncResult ; on avale les
      // exceptions vraiment inattendues pour ne jamais crasher l'app.
    } finally {
      _running = false;
    }
  }

  /// Le registre de serveurs vient de basculer (changement de profil) :
  /// annule une synchro auto en attente qui viserait l'ancien serveur.
  void cancelPending() {
    _debounce?.cancel();
    _debounce = null;
  }

  void dispose() {
    cancelPending();
  }
}

/// Provider de l'orchestrateur (vivant toute la durée de l'app).
final autoSyncControllerProvider = Provider<AutoSyncController>((ref) {
  final controller = AutoSyncController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});
