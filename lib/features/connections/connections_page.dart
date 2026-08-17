/// Page principale du module Connexions (après appairage).
///
/// Affiche :
///  - le statut du serveur (en ligne / hors-ligne, latence, infos établissement) ;
///  - la carte de synchronisation (dernière synchro, bouton « Sync maintenant ») ;
///  - le bascule du mode hors-ligne forcé ;
///  - la liste des appareils appairés (vue admin) ;
///  - l'action « Changer de serveur » (désappairage).
///
/// Toutes les chaînes sont en français. Le thème émeraude est appliqué via
/// [Theme.of(context).colorScheme].
library;

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/sync/sync_engine.dart';
import '../../core/sync/sync_scheduler.dart';
import '../../core/utils/formatters.dart';
import '../../shared/models/auth_dto.dart';
import '../../shared/widgets/app_error_widget.dart';
import '../../shared/widgets/section_header.dart';
import '../../shared/widgets/status_badge.dart';
import 'connection_state.dart';
import 'connections_controller.dart';

/// Page Connexions (statut + actions).
class ConnectionsPage extends ConsumerWidget {
  const ConnectionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider);
    final serverInfo = ref.watch(serverInfoProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Connexions')),
      body: RefreshIndicator(
        onRefresh: () async {
          await ref.read(connectionProvider.notifier).checkStatus();
          ref.invalidate(serverInfoProvider);
          ref.invalidate(pairedDevicesProvider);
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _ServerStatusCard(conn: conn, serverInfo: serverInfo),
            const SizedBox(height: 12),
            const _SyncCard(),
            const SizedBox(height: 12),
            _OfflineModeCard(conn: conn),
            const SizedBox(height: 12),
            const _PairedDevicesCard(),
            const SizedBox(height: 16),
            const _DangerZoneCard(),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Carte : statut serveur
// ---------------------------------------------------------------------------

class _ServerStatusCard extends ConsumerWidget {
  const _ServerStatusCard({required this.conn, required this.serverInfo});
  final ConnectionState conn;
  final AsyncValue<ServerInfoDto?> serverInfo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final establishmentName = serverInfo.maybeWhen(
      data: (info) => info?.establishmentName,
      orElse: () => null,
    ) ?? conn.discoveredServerName ?? conn.establishmentCode ?? '—';

    final apiInfo = serverInfo.maybeWhen(
      data: (info) => info,
      orElse: () => null,
    );

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: 'Serveur GeTech-SMS',
              icon: Icons.dns_outlined,
              actionLabel: 'Vérifier',
              onAction: () => ref.read(connectionProvider.notifier).checkStatus(),
            ),
            const Divider(height: 16),
            _InfoRow(
              icon: Icons.school_outlined,
              label: 'Établissement',
              value: establishmentName,
            ),
            if (apiInfo != null) ...[
              const SizedBox(height: 8),
              _InfoRow(
                icon: Icons.tag,
                label: 'Code',
                value: apiInfo.establishmentCode,
              ),
              const SizedBox(height: 8),
              _InfoRow(
                icon: Icons.code,
                label: 'Version serveur',
                value: apiInfo.serverVersion,
              ),
            ] else ...[
              const SizedBox(height: 8),
              _InfoRow(
                icon: Icons.tag,
                label: 'Code',
                value: conn.establishmentCode ?? '—',
              ),
            ],
            const SizedBox(height: 8),
            _InfoRow(
              icon: Icons.link,
              label: 'URL serveur',
              value: conn.serverUrl ?? '—',
              mono: true,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                StatusBadge.fromServerStatus(conn.status),
                const SizedBox(width: 12),
                if (conn.latency != null)
                  Expanded(
                    child: Row(
                      children: [
                        Icon(Icons.speed, size: 16, color: cs.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Text(
                          '${conn.latency!.inMilliseconds} ms',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  )
                else if (conn.status == ServerStatus.online)
                  Expanded(
                    child: Text(
                      'Latence inconnue',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.mono = false,
  });
  final IconData icon;
  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: cs.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: mono
                    ? theme.textTheme.bodyMedium?.copyWith(
                        fontFamily: 'monospace',
                        fontSize: 13,
                      )
                    : theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Carte : synchronisation (ConsumerStateful pour isSyncing)
// ---------------------------------------------------------------------------

class _SyncCard extends ConsumerStatefulWidget {
  const _SyncCard();
  @override
  ConsumerState<_SyncCard> createState() => _SyncCardState();
}

class _SyncCardState extends ConsumerState<_SyncCard> {
  bool _isSyncing = false;
  String? _error;
  String? _lastResultLabel;

  Future<void> _syncNow() async {
    setState(() {
      _isSyncing = true;
      _error = null;
      _lastResultLabel = null;
    });
    try {
      final engine = ref.read(syncEngineProvider);
      final result = await engine.syncNow();

      final pulled = (result.pulled as int?) ?? 0;
      final pushed = (result.pushed as int?) ?? 0;
      final success = (result.isSuccess as bool?) ?? false;
      final errors = (result.errors as List?)?.length ?? 0;

      if (!success) {
        final msg = errors > 0
            ? 'Synchro terminée avec $errors erreur(s).'
            : 'Échec de la synchronisation.';
        setState(() {
          _error = msg;
          _lastResultLabel = '$pulled tiré(s) • $pushed envoyé(s)';
        });
        return;
      }

      // Enregistre la dernière synchro côté état de connexion.
      await ref
          .read(connectionProvider.notifier)
          .recordSync(count: pulled + pushed);

      // Reprogramme le scheduler (rafraîchit l'intervalle de fond).
      try {
        await ref.read(syncSchedulerProvider).scheduleNow();
      } catch (_) {
        // Non bloquant : la sync manuelle a déjà réussi.
      }

      if (!mounted) return;
      setState(() {
        _lastResultLabel = '$pulled tiré(s) • $pushed envoyé(s)';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Erreur de synchro : $e');
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(connectionProvider);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final canSync = conn.isPaired && !conn.forceOffline;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: 'Synchronisation',
              icon: Icons.sync,
              actionLabel: _isSyncing ? null : 'Sync maintenant',
              onAction: _isSyncing ? null : _syncNow,
            ),
            const Divider(height: 16),
            _InfoRow(
              icon: Icons.history,
              label: 'Dernière synchro',
              value: DateFormatter.relative(conn.lastSync),
            ),
            const SizedBox(height: 8),
            _InfoRow(
              icon: Icons.cloud_download,
              label: 'Dernier volume',
              value: conn.lastSyncCount != null
                  ? '${conn.lastSyncCount} enregistrement(s)'
                  : '—',
            ),
            if (_lastResultLabel != null) ...[
              const SizedBox(height: 8),
              _InfoRow(
                icon: Icons.check_circle_outline,
                label: 'Résultat',
                value: _lastResultLabel!,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              AppErrorWidget(message: _error!, compact: true),
            ],
            if (_isSyncing) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Synchronisation en cours…',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
            if (!canSync && !_isSyncing) ...[
              const SizedBox(height: 8),
              Text(
                conn.forceOffline
                    ? 'Synchro désactivée en mode hors-ligne.'
                    : 'Aucun serveur configuré.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Carte : mode hors-ligne
// ---------------------------------------------------------------------------

class _OfflineModeCard extends ConsumerWidget {
  const _OfflineModeCard({required this.conn});
  final ConnectionState conn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: 'Mode hors-ligne',
              icon: Icons.cloud_off,
            ),
            const SizedBox(height: 8),
            Text(
              conn.forceOffline
                  ? 'L\'application utilise uniquement les données locales. '
                    'Aucune requête réseau ne sera envoyée.'
                  : 'L\'application se synchronise automatiquement avec le serveur.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              value: conn.forceOffline,
              onChanged: (_) =>
                  ref.read(connectionProvider.notifier).toggleForceOffline(),
              title: Text(conn.forceOffline
                  ? 'Mode hors-ligne activé'
                  : 'Mode hors-ligne désactivé'),
              secondary: Icon(
                conn.forceOffline ? Icons.cloud_off : Icons.cloud_done,
                color: conn.forceOffline ? Colors.orange : Colors.green,
              ),
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Carte : appareils appairés (vue admin)
// ---------------------------------------------------------------------------

class _PairedDevicesCard extends ConsumerWidget {
  const _PairedDevicesCard();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devicesAsync = ref.watch(pairedDevicesProvider);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: 'Appareils appairés',
              subtitle: 'Vue administrateur — visibilité selon vos permissions.',
              icon: Icons.devices,
              actionLabel: 'Rafraîchir',
              onAction: () => ref.invalidate(pairedDevicesProvider),
            ),
            const Divider(height: 16),
            devicesAsync.when(
              data: (devices) {
                if (devices.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'Aucun appareil visible (liste réservée aux administrateurs '
                      'ou aucun autre appareil appairé).',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  );
                }
                return Column(
                  children: [
                    for (final d in devices)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          d.deviceType == 'MOBILE'
                              ? Icons.phone_android
                              : Icons.devices,
                          color: cs.primary,
                        ),
                        title: Text(d.deviceName),
                        subtitle: Text(
                          'Appairé ${DateFormatter.relative(d.pairedAt)}'
                          '${d.lastSeen != null ? ' • vu ${DateFormatter.relative(d.lastSeen)}' : ''}',
                        ),
                        trailing: d.isRevoked
                            ? const Chip(
                                label: Text('Révoqué'),
                                visualDensity: VisualDensity.compact,
                              )
                            : Icon(Icons.check_circle,
                                color: Colors.green.shade400, size: 20),
                      ),
                  ],
                );
              },
              loading: () => const SizedBox(
                height: 56,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ),
              error: (e, _) => AppErrorWidget(
                message: 'Impossible de charger la liste : $e',
                compact: true,
                onRetry: () => ref.invalidate(pairedDevicesProvider),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Zone d'action : changer de serveur
// ---------------------------------------------------------------------------

class _DangerZoneCard extends ConsumerWidget {
  const _DangerZoneCard();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded,
                    color: theme.colorScheme.error),
                const SizedBox(width: 8),
                Text('Zone d\'action',
                    style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Désappairer ce terminal supprime l\'URL serveur, le token d\'appairage '
              'et le mode hors-ligne. Vous devrez ré-appairer un nouveau terminal.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                  side: BorderSide(color: theme.colorScheme.error),
                ),
                onPressed: () => _confirmUnpair(context, ref),
                icon: const Icon(Icons.link_off),
                label: const Text('Changer de serveur'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmUnpair(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Changer de serveur ?'),
        content: const Text(
          'Cette action va désappairer ce terminal. Vous serez redirigé vers '
          'l\'écran d\'appairage.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Désappairer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(connectionProvider.notifier).unpair();
    if (!context.mounted) return;
    context.go('/pairing');
  }
}
