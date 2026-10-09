import 'package:flutter/material.dart';

/// Widget d'erreur réutilisable avec bouton de réessai.
///
/// [Fix-ERROR-HUMANIZE] Les messages techniques (DioException, stack traces,
/// « Null check operator »…) ne sont PLUS affichés bruts à l'utilisateur :
/// [AppErrorWidget.humanize] les traduit en messages clairs et actionnables.
class AppErrorWidget extends StatelessWidget {
  const AppErrorWidget({
    super.key,
    required this.message,
    this.onRetry,
    this.compact = false,
  });

  final String message;
  final VoidCallback? onRetry;
  final bool compact;

  /// Convertit un message d'erreur brut (souvent `e.toString()`) en message
  /// compréhensible par un utilisateur non technique.
  ///
  /// Les messages serveur déjà rédigés (ApiException « Erreur : … » avec
  /// texte français) passent tels quels ; seuls les motifs techniques
  /// connus sont réécrits.
  static String humanize(String raw) {
    final m = raw.toLowerCase();

    // Réseau / serveur injoignable.
    if (m.contains('connectiontimeout') ||
        m.contains('connection refused') ||
        m.contains('socketexception') ||
        m.contains('network is unreachable') ||
        m.contains('failed host lookup') ||
        m.contains('connectionerror') ||
        m.contains('software caused connection abort')) {
      return 'Le serveur est injoignable. Vérifiez que le serveur desktop '
          'est démarré et que le mobile est sur le même réseau ; vos '
          'données locales restent consultables.';
    }
    if (m.contains('receivetimeout') || m.contains('sendtimeout') ||
        m.contains('timeoutexception') || m.contains('timed out')) {
      return 'Le serveur a mis trop de temps à répondre. Réessayez dans un '
          'instant ; vos données locales restent consultables.';
    }
    if (m.contains('handshake') || m.contains('badcertificate')) {
      return 'Problème de sécurité de connexion avec le serveur '
          '(certificat).';
    }

    // Erreurs HTTP serveur.
    if (m.contains('status code of 500') || m.contains('internal server')) {
      return 'Le serveur a rencontré une erreur interne (500). '
          'Réessayez plus tard ou contactez l\'administrateur.';
    }
    if (m.contains('status code of 502') || m.contains('status code of 503') ||
        m.contains('status code of 504')) {
      return 'Le serveur est momentanément indisponible. Réessayez dans un '
          'instant.';
    }
    if (m.contains('status code of 404')) {
      return 'Fonctionnalité non disponible sur ce serveur (mise à jour du '
          'serveur desktop GeTech-SMS requise).';
    }
    if (m.contains('status code of 403')) {
      return 'Vous n\'avez pas les droits nécessaires pour cette action.';
    }
    if (m.contains('status code of 401')) {
      return 'Session expirée. Reconnectez-vous.';
    }
    if (m.contains('status code of 422')) {
      return 'Certaines données envoyées sont invalides. Vérifiez les '
          'champs puis réessayez.';
    }

    // Exceptions Dart courantes.
    if (m.contains('null check operator') ||
        m.contains('nullcheckerror') ||
        m.contains('bad state:') ||
        m.contains('rangeerror') ||
        m.contains('formatexception')) {
      return 'Une donnée inattendue a été reçue. Réessayez ou contactez '
          'l\'administrateur si le problème persiste.';
    }
    if (m.contains('offline') || m.contains('hors-ligne') ||
        m.contains('injoignable')) {
      return 'Mode hors-ligne : cette action nécessite une connexion au '
          'serveur. Vos données locales restent consultables.';
    }

    // Messages déjà rédigés (français, ApiException, etc.) → inchangés.
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // [Fix-ERROR-HUMANIZE] plus d'exception brute affichée à l'écran.
    final friendly = humanize(message);
    if (compact) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: theme.colorScheme.error, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                friendly,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: const Text('Réessayer')),
          ],
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(
              'Une erreur est survenue',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              friendly,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Réessayer'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
