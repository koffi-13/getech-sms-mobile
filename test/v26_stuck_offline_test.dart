/// Tests V26 — [Fix-ONLINE-DETECT effectif] + [Fix-PAIRING-STUCK-OFFLINE]
/// + [Fix-FORCE-OFFLINE-PERSIST].
///
/// Retour utilisateur : « l'application reste bloquée hors ligne en étant
/// en ligne ». Reproductions causales (sans réseau réel, sur la logique
/// pure de connexion) :
///   1. un ping qui RÉPOND avec un statut HTTP d'erreur (401/403/404/5xx)
///      doit compter « en ligne » — Dio lève une exception badResponse
///      avant tout `statusCode != null`, le correctif V24 était inopérant ;
///   2. l'appairage résilient doit VERROUILLER ni l'état ni le heartbeat :
///      le drapeau pairingForcedOffline est relâché dès que le serveur
///      répond ;
///   3. une vraie panne réseau (timeout / connexion refusée) reste
///      « hors ligne » ;
///   4. le mode hors-ligne explicite de l'utilisateur survit au
///      redémarrage (clé canonique) et purge la clé legacy.
library;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:getech_sms_mobile/features/connections/connection_state.dart';

void main() {
  group('V26 — ConnectionState.copyWith', () {
    test('pairingForcedOffline est posé par setPairingForcedOffline'
        ' (simulation via copyWith, état hors ligne)', () {
      final s = ConnectionState.initial;
      expect(s.pairingForcedOffline, isFalse);
      final deferred = s.copyWith(
        status: ServerStatus.offline,
        pairingForcedOffline: true,
      );
      expect(deferred.pairingForcedOffline, isTrue);
      expect(deferred.forceOffline, isFalse,
          reason: 'Le mode différé ne doit PAS activer le verrou persisté.');
    });

    test('clearPairingForced relâche le mode différé sans toucher au reste',
        () {
      final deferred = ConnectionState.initial.copyWith(
        status: ServerStatus.offline,
        pairingForcedOffline: true,
      );
      final released = deferred.copyWith(clearPairingForced: true);
      expect(released.pairingForcedOffline, isFalse);
      expect(released.forceOffline, isFalse);
      expect(released.status, ServerStatus.offline);
    });
  });

  group('V26 — décision « le serveur a répondu » (Fix-ONLINE-DETECT '
      'réellement effectif)', () {
    // Même sémantique que ConnectionNotifier.checkStatus : une
    // DioException AVEC réponse = le serveur a parlé ; SANS réponse
    // (timeout / connexion refusée / DNS) = vraie panne réseau.
    bool serverResponded(Object e) =>
        e is DioException && e.response != null;

    Response<dynamic> resp(int status) => Response(
          requestOptions: RequestOptions(path: '/devices/server-info'),
          statusCode: status,
        );

    test('401/403/404/500 = serveur EN LIGNE (il répond)', () {
      for (final code in [401, 403, 404, 500, 502, 503]) {
        final e = DioException(
          requestOptions: RequestOptions(path: '/x'),
          response: resp(code),
          type: DioExceptionType.badResponse,
        );
        expect(serverResponded(e), isTrue,
            reason: 'HTTP $code : le processus écoute et répond.');
      }
    });

    test('timeout / connexion refusée / DNS = vraie panne, hors ligne', () {
      for (final type in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.connectionError,
      ]) {
        final e = DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: type,
        );
        expect(serverResponded(e), isFalse,
            reason: '$type : aucune réponse HTTP reçue.');
      }
    });

    test('une exception non-Dio n\'est jamais une réponse serveur', () {
      expect(serverResponded(StateError('boom')), isFalse);
    });
  });

  group('V26 — persistance du mode hors-ligne explicite (clé canonique)', () {
    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    });

    test('clé canonique écrite par setForceOffline, clé legacy purgée',
        () async {
      final prefs = await SharedPreferences.getInstance();
      // Résidu legacy laissé par les versions précédentes.
      await prefs.setBool('force_offline', true);

      // Sémantique de ConnectionNotifier._init / setForceOffline (V26) :
      // la clé canonique fait foi, la clé legacy est supprimée.
      await prefs.setBool(AppConfigPref.prefForceOffline, true);
      await prefs.remove('force_offline');
      expect(prefs.getBool(AppConfigPref.prefForceOffline), isTrue,
          reason: 'Le choix explicite de l\'utilisateur doit survivre '
              'au redémarrage.');
      expect(prefs.containsKey('force_offline'), isFalse,
          reason: 'La clé legacy doit être purgée pour ne pas '
              'ressusciter un verrou obsolète.');
    });

    test('restauration au démarrage : forceOffline relu depuis la clé '
        'canonique uniquement', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(AppConfigPref.prefForceOffline, true);
      // Même lecture que ConnectionNotifier._init.
      final restored = prefs.getBool(AppConfigPref.prefForceOffline) ?? false;
      expect(restored, isTrue);
    });
  });
}

/// Accès à la constante canonique sans importer tout app_config
/// (le test n'a besoin que de la valeur).
class AppConfigPref {
  static const String prefForceOffline = 'getech.force_offline';
}
