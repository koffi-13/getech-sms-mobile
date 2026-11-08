/// Clés de cache PAR PROFIL de serveur + purge à la bascule.
///
/// [Fix-SERVER-DATA-LEAK] V17 — retour utilisateur (S4) : « je vois les
/// statistiques d'un autre serveur dans l'Accueil d'un autre » puis
/// « Le serveur a signalé une erreur (500) » après un re-appairage.
///
/// CAUSE RACINE : les caches SharedPreferences de l'app étaient GLOBAUX
/// (`getech.cache.dashboard`, `ranking_cache_*`, notifications, devises…)
/// alors que les bases Drift sont, elles, bien séparées par profil
/// (`getech_sms_<id>.db`). Lors d'une bascule ou d'un re-appairage vers un
/// autre serveur, l'Accueil affichait donc les KPIs du PRÉCÉDENT serveur
/// (statistiques croisées entre le serveur de développement et celui de
/// production), et le JWT restauré par les clés legacy globales
/// (`getech.jwt`) était envoyé au NOUVEAU serveur → 401/500 incohérents.
///
/// Désormais :
/// - toute clé de cache sensible est suffixée par l'id de profil ACTIF
///   ([profileScopedKey]) ;
/// - [purgeGlobalCachesFor] supprime les clés GLOBALES legacy d'un profil
///   (dashboard, classements, notifications, last_sync…) à la bascule et au
///   re-appairage : aucune donnée d'un serveur ne peut s'afficher pour un
///   autre serveur ;
/// - l'ancienneté du profil protège des purges intempestives (on ne purge
///   que les clés qui existent réellement).
library;

import 'package:shared_preferences/shared_preferences.dart';

/// Préfixe commun des caches de données scopés par profil.
const String kProfileCachePrefix = 'getech.cache';

/// Suffixe une clé avec l'id de profil de serveur actif.
///
/// Ex : `profileScopedKey('getech.cache.dashboard', 'srv_123-abc')`
/// → `getech.cache.dashboard.srv_123-abc`. Un id null/ vide retombe sur
/// `'default'` (jamais de clé nue globale).
String profileScopedKey(String base, String? profileId) {
  final pid = (profileId == null || profileId.isEmpty) ? 'default' : profileId;
  return '$base.$pid';
}

/// Clés GLOBALES legacy (non scopées) dont les valeurs mélangent les
/// données de tous les serveurs. Elles sont supprimées à chaque bascule /
/// re-appairage — la valeur fraîche sera re-téléchargée depuis le serveur
/// ACTIF dès qu'il est joignable.
const List<String> kGlobalLeakyCacheKeys = [
  'getech.cache.dashboard', // KPIs de l'Accueil
  'getech.notifications.history', // centre de notifications
  'last_sync_at', // horodatage de synchro affiché dans Connexions
  'last_sync_count',
];

/// Préfixes des caches multiples (une entrée par requête/établissement).
const List<String> kGlobalLeakyCachePrefixes = [
  'ranking_cache_', // classement par classe+matière+mode
];

/// [Fix-SERVER-DATA-LEAK] Purge des caches GLOBAUX non scopés.
///
/// Appelée par [MultiServerController] à CHAQUE bascule de profil
/// (switchTo / completePairing / forget) : sans elle, l'Accueil du nouveau
/// serveur afficherait les statistiques du précédent tant que le serveur
/// n'a pas répondu, et les notifications/classements d'un autre
/// établissement resteraient visibles.
///
/// Best-effort : une erreur de purge ne doit JAMAIS casser la bascule.
Future<void> purgeGlobalCaches({String? exceptProfileId}) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final toRemove = <String>{};

    for (final key in kGlobalLeakyCacheKeys) {
      if (prefs.containsKey(key)) toRemove.add(key);
    }
    for (final prefix in kGlobalLeakyCachePrefixes) {
      // containsKey ne liste pas les préfixes : il faut parcourir les clés.
      // getKeys() est le seul moyen de trouver ranking_cache_*.
      for (final key in prefs.getKeys()) {
        if (key.startsWith(prefix)) toRemove.add(key);
      }
    }

    if (toRemove.isEmpty) return;
    for (final key in toRemove) {
      await prefs.remove(key);
    }
  } catch (_) {
    // Best-effort : la bascule doit continuer même si la purge échoue.
  }
}
