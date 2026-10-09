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

import '../../core/database/backup_service.dart';
import '../../core/database/database.dart';
import '../../core/notifications/notification_service.dart';
import '../../core/sync/outbox.dart';
import '../../core/sync/sync_engine.dart';
import '../../core/sync/sync_scheduler.dart';
import '../../core/utils/formatters.dart';
import '../../shared/models/auth_dto.dart';
import '../../shared/widgets/app_error_widget.dart';
import '../../shared/widgets/section_header.dart';
import '../../shared/widgets/status_badge.dart';
import 'connection_state.dart';
import 'connections_controller.dart';
import 'server_profiles.dart';

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
          ref.invalidate(serverProfileRegistryProvider);
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _MyServersCard(conn: conn),
            const SizedBox(height: 12),
            _ServerStatusCard(conn: conn, serverInfo: serverInfo),
            const SizedBox(height: 12),
            const _SyncCard(),
            const SizedBox(height: 12),
            _OfflineModeCard(conn: conn),
            const SizedBox(height: 12),
            const _OutboxCard(),
            const SizedBox(height: 12),
            const _PairedDevicesCard(),
            const SizedBox(height: 12),
            const _BackupRestoreCard(),
            const SizedBox(height: 12),
            const _ResetDataCard(),
            const SizedBox(height: 16),
            const _DangerZoneCard(),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Carte : mes serveurs (registre multi-établissements)
// ---------------------------------------------------------------------------

class _MyServersCard extends ConsumerWidget {
  const _MyServersCard({required this.conn});
  final ConnectionState conn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final regAsync = ref.watch(serverProfileRegistryProvider);

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.dns_rounded, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Mes serveurs',
                      style: theme.textTheme.titleMedium),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => context.push('/pairing'),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Appairer'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Basculez d’un établissement à l’autre — chaque serveur conserve '
              'sa session et ses données locales.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            regAsync.maybeWhen(
              data: (reg) {
                final profiles = reg.profiles;
                if (profiles.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'Aucun serveur enregistré. Appairez votre premier serveur.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  );
                }
                return Column(
                  children: [
                    for (final p in profiles)
                      _ServerTile(
                        profile: p,
                        active: p.id == conn.profileId,
                        online: p.id == conn.profileId &&
                            conn.status == ServerStatus.online,
                        latency: p.id == conn.profileId ? conn.latency : null,
                      ),
                  ],
                );
              },
              orElse: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerTile extends ConsumerWidget {
  const _ServerTile({
    required this.profile,
    required this.active,
    required this.online,
    this.latency,
  });

  final ServerProfile profile;
  final bool active;
  final bool online;
  final Duration? latency;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final subtitle = profile.serverUrl
        .replaceAll(RegExp(r'^https?://'), '')
        .replaceAll(RegExp(r'/api/v1/?$'), '');

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        active
            ? (online ? Icons.check_circle : Icons.dns_rounded)
            : Icons.dns_outlined,
        color: active
            ? (online ? Colors.green : theme.colorScheme.primary)
            : theme.colorScheme.outline,
      ),
      title: Text(
        profile.displayName,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: active ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      subtitle: Text(
        active
            ? '$subtitle • en cours d\'utilisation'
            : subtitle,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!active)
            TextButton(
              onPressed: () => _confirmSwitch(context, ref),
              child: const Text('Basculer'),
            ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'forget') _confirmForget(context, ref);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'forget',
                child: Text('Oublier ce serveur'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmSwitch(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Basculer vers « ${profile.displayName} » ?'),
        content: const Text(
          'L’app va se reconnecter à ce serveur. Les données locales de '
          'chaque établissement sont conservées séparément.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Basculer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await ref.read(multiServerControllerProvider).switchTo(profile.id);
    if (!context.mounted) return;
    // La garde du routeur redirige d'elle-même (login si session absente).
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Basculé vers « ${profile.displayName} ».'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _confirmForget(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Oublier « ${profile.displayName} » ?'),
        content: const Text(
          'Supprime ce serveur, sa session et ses données LOCALES sur cet '
          'appareil. Les données du serveur ne sont pas affectées.',
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
            child: const Text('Oublier'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await ref.read(multiServerControllerProvider).forget(profile.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Serveur oublié.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

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
  String? _error;
  String? _lastResultLabel;

  Future<void> _syncNow() async {
    setState(() {
      _error = null;
      _lastResultLabel = null;
    });
    try {
      final engine = ref.read(syncEngineProvider);
      final result = await engine.syncNow();
      // Trace la synchro sur le profil actif (registre multi-serveurs).
      ref.read(multiServerControllerProvider).recordSync();
      // [Notifications] Suivi validation/rejet + résultat utile.
      if (result.isSuccess) {
        await ref.read(notificationServiceProvider).maybeCheckGradeModifications();
      }
      await ref.read(notificationServiceProvider).notifySyncResult(result);

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
    }
  }

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(connectionProvider);
    final sync = ref.watch(syncProgressProvider);
    final isSyncing = sync.status != SyncStatus.idle &&
        sync.status != SyncStatus.success &&
        sync.status != SyncStatus.error;

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
              actionLabel: isSyncing ? null : 'Sync maintenant',
              onAction: isSyncing ? null : _syncNow,
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
            if (_error != null || sync.status == SyncStatus.error) ...[
              const SizedBox(height: 12),
              AppErrorWidget(
                message: _error ?? sync.message,
                compact: true,
              ),
            ],
            if (isSyncing) ...[
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: sync.progress,
                  minHeight: 8,
                  backgroundColor: cs.primaryContainer.withOpacity(0.3),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      sync.message,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    '${(sync.progress * 100).toInt()}%',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
            if (!canSync && !isSyncing) ...[
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
            const SectionHeader(
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
              title: Text(
                conn.forceOffline
                    ? 'Mode hors-ligne activé'
                    : 'Mode hors-ligne désactivé',
              ),
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
// Carte : Outbox (file d'attente)
// ---------------------------------------------------------------------------

class _OutboxCard extends ConsumerWidget {
  const _OutboxCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outboxAsync = ref.watch(pendingOutboxProvider);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: 'File d\'attente Outbox',
              icon: Icons.send_rounded,
              subtitle: 'Modifications locales en attente d\'envoi.',
              actionLabel: 'Vider',
              onAction: () => _confirmClearOutbox(context, ref),
            ),
            const Divider(height: 16),
            outboxAsync.when(
              data: (entries) {
                if (entries.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'Toutes les données locales sont synchronisées.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  );
                }
                return Column(
                  children: [
                    for (final e in entries.take(5))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: _operationIcon(e.operation, cs),
                        title: Text('${e.tableNameColumn} (${e.operation})'),
                        subtitle: Text(
                          'ID: ${e.recordId ?? "nouveau"} • '
                          '${DateFormatter.relative(e.createdAt)}',
                        ),
                        trailing: e.lastError != null
                            ? const Icon(
                                Icons.error_outline,
                                color: Colors.red,
                                size: 18,
                              )
                            : null,
                      ),
                    if (entries.length > 5)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '+ ${entries.length - 5} autres modifications...',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: cs.primary,
                          ),
                        ),
                      ),
                  ],
                );
              },
              loading: () => const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              error: (e, _) => Text('Erreur: $e'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _operationIcon(String op, ColorScheme cs) {
    switch (op.toUpperCase()) {
      case 'INSERT':
        return Icon(Icons.add_circle_outline, color: cs.primary, size: 20);
      case 'UPDATE':
        return Icon(Icons.edit_outlined, color: Colors.blue, size: 20);
      case 'DELETE':
        return Icon(Icons.delete_outline, color: Colors.red, size: 20);
      default:
        return const Icon(Icons.help_outline, size: 20);
    }
  }

  Future<void> _confirmClearOutbox(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Vider l\'outbox ?'),
        content: const Text(
          'Cela supprimera toutes les modifications locales non encore envoyées au serveur. Cette action est irréversible.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Vider', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(outboxProvider).clearAll();
      ref.invalidate(pendingOutboxProvider);
    }
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
// Carte : Sauvegarde & Restauration
// ---------------------------------------------------------------------------

class _BackupRestoreCard extends ConsumerWidget {
  const _BackupRestoreCard();

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
            const SectionHeader(
              title: 'Sauvegarde & Restauration',
              icon: Icons.storage_rounded,
              subtitle: 'Gestion de la base de données locale (JSON).',
            ),
            const Divider(height: 16),
            Text(
              'Exportez vos données scolaires (élèves, notes, appels) pour les sauvegarder ou les transférer.',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _handleExport(context, ref),
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('Exporter'),
                    style: FilledButton.styleFrom(
                      backgroundColor: cs.secondary,
                      foregroundColor: cs.onSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _handleImport(context, ref),
                    icon: const Icon(Icons.upload, size: 18),
                    label: const Text('Importer'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleExport(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(backupServiceProvider).exportBackup();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sauvegarde exportée avec succès.')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Échec de l\'export : $e')),
      );
    }
  }

  Future<void> _handleImport(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Importer une sauvegarde ?'),
        content: const Text(
          'Attention : les données existantes seront écrasées ou fusionnées avec celles du fichier JSON.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Importer'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final success = await ref.read(backupServiceProvider).importBackup();
      if (!context.mounted) return;
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Données restaurées avec succès.')),
        );
        // On pourrait vouloir invalider certains providers ici
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Échec de l\'import : $e')),
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Carte : Réinitialisation
// ---------------------------------------------------------------------------

class _ResetDataCard extends ConsumerWidget {
  const _ResetDataCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.refresh_rounded, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Données locales', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Réinitialise la base de données locale. Utile en cas de corruption ou pour repartir de zéro.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _confirmReset(context, ref),
                icon: const Icon(Icons.cleaning_services_rounded),
                label: const Text('Réinitialiser la base locale'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmReset(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tout réinitialiser ?'),
        content: const Text(
          'Cette action va effacer TOUTES les données stockées localement (élèves, notes, appels, outbox). Les informations de connexion seront conservées.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Réinitialiser', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(databaseProvider).clearAllData();
      ref.invalidate(pendingOutboxProvider);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Base locale réinitialisée avec succès.')),
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Zone d'action : oublier le serveur actif
// ---------------------------------------------------------------------------

class _DangerZoneCard extends ConsumerWidget {
  const _DangerZoneCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: theme.colorScheme.errorContainer.withOpacity(0.3),
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
              'Oublier le serveur actif supprime son profil, sa session et '
              'ses données LOCALES sur cet appareil (les autres serveurs '
              'enregistrés sont conservés).',
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
                onPressed: () => _confirmForgetActive(context, ref),
                icon: const Icon(Icons.link_off),
                label: const Text('Oublier ce serveur'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmForgetActive(BuildContext context, WidgetRef ref) async {
    final conn = ref.read(connectionProvider);
    final pid = conn.profileId;
    if (pid == null) {
      // Aucun profil actif : retour à l'appairage.
      context.go('/pairing');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Oublier ce serveur ?'),
        content: const Text(
          'Ce serveur sera retiré de l\'appareil (session et données locales '
          'supprimées). Les autres serveurs enregistrés restent disponibles.',
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
            child: const Text('Oublier'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await ref.read(multiServerControllerProvider).forget(pid);
    if (!context.mounted) return;
    final stillPaired = ref.read(connectionProvider).isPaired;
    context.go(stillPaired ? '/connections' : '/pairing');
  }
}
