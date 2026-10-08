/// Page "Établissements" : liste multi-tenant (tous les établissements visibles
/// par l'utilisateur), avec mise en avant de l'établissement courant.
///
/// RBAC : tout utilisateur authentifié peut consulter (l'établissement
/// courant est déjà dans le JWT/profile ; la liste complète peut être
/// restreinte côté serveur selon les permissions).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_state.dart';
import '../../features/connections/connection_state.dart';
import '../../shared/models/auth_dto.dart';
import '../../shared/widgets/widgets.dart';
import 'establishment_controller.dart';

class EstablishmentsPage extends ConsumerWidget {
  const EstablishmentsPage({super.key});

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(establishmentsListProvider);
    ref.invalidate(currentEstablishmentProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider);
    final online = conn.canReachServer;
    final async = ref.watch(establishmentsListProvider);
    final auth = ref.watch(authProvider);
    final currentId = auth.establishmentId;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Établissements'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Rafraîchir',
            onPressed: () => _refresh(ref),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _refresh(ref),
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _OfflineBanner(online: online)),
            async.when(
              data: (list) {
                if (list.isEmpty) {
                  return SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyState(
                      icon: Icons.domain_outlined,
                      title: 'Aucun établissement',
                      message: online
                          ? 'Aucun établissement accessible à votre compte.'
                          : 'Connectez-vous au serveur pour consulter les établissements.',
                    ),
                  );
                }
                // Si un seul établissement et qu'il est courant → carte unique.
                if (list.length == 1) {
                  final est = list.first;
                  return SliverFillRemaining(
                    hasScrollBody: false,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: _SingleEstablishmentCard(
                        establishment: est,
                        isCurrent: est.id == currentId,
                        onTap: () => context.push('/establishments/${est.id}'),
                      ),
                    ),
                  );
                }
                return SliverPadding(
                  padding: const EdgeInsets.all(12),
                  sliver: SliverList.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final est = list[i];
                      return _EstablishmentTile(
                        establishment: est,
                        isCurrent: est.id == currentId,
                        onTap: () => context.push('/establishments/${est.id}'),
                      );
                    },
                  ),
                );
              },
              loading: () => const SliverFillRemaining(
                hasScrollBody: false,
                child: AppLoading(label: 'Chargement des établissements…'),
              ),
              error: (e, _) => SliverFillRemaining(
                hasScrollBody: false,
                child: AppErrorWidget(
                  message: e.toString(),
                  onRetry: () => _refresh(ref),
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bannière hors-ligne
// ---------------------------------------------------------------------------

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.online});
  final bool online;

  @override
  Widget build(BuildContext context) {
    if (online) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.cloud_off,
                size: 18, color: theme.colorScheme.onSecondaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Mode hors-ligne — établissements indisponibles.',
                style: TextStyle(
                  color: theme.colorScheme.onSecondaryContainer,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tuile établissement (liste)
// ---------------------------------------------------------------------------

class _EstablishmentTile extends StatelessWidget {
  const _EstablishmentTile({
    required this.establishment,
    required this.isCurrent,
    required this.onTap,
  });

  final EstablishmentDto establishment;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isCurrent
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isCurrent
            ? BorderSide(color: theme.colorScheme.primary, width: 1.5)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _LogoAvatar(
                logoPath: establishment.logoPath,
                name: establishment.name,
                radius: 24,
                color: color,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      establishment.name,
                      style: theme.textTheme.titleMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      runSpacing: 2,
                      children: [
                        _InfoChip(
                          icon: Icons.tag,
                          text: establishment.code,
                        ),
                        if (establishment.city != null &&
                            establishment.city!.isNotEmpty)
                          _InfoChip(
                            icon: Icons.location_city_outlined,
                            text: establishment.city!,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (isCurrent)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Courant',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                )
              else
                const Icon(Icons.chevron_right, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}

class _SingleEstablishmentCard extends StatelessWidget {
  const _SingleEstablishmentCard({
    required this.establishment,
    required this.isCurrent,
    required this.onTap,
  });

  final EstablishmentDto establishment;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: isCurrent
            ? BorderSide(color: theme.colorScheme.primary, width: 1.5)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _LogoAvatar(
                logoPath: establishment.logoPath,
                name: establishment.name,
                radius: 36,
                color: theme.colorScheme.primaryContainer,
              ),
              const SizedBox(height: 12),
              Text(
                establishment.name,
                style: theme.textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                'Code : ${establishment.code}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (isCurrent) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle,
                          color: theme.colorScheme.primary, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        'Établissement courant',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onTap,
                icon: const Icon(Icons.visibility_outlined),
                label: const Text('Voir les détails'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sous-widgets
// ---------------------------------------------------------------------------

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Avatar logo ou initiales (fallback) — partagé entre liste et détail.
class _LogoAvatar extends StatelessWidget {
  const _LogoAvatar({
    required this.logoPath,
    required this.name,
    required this.radius,
    required this.color,
  });

  final String? logoPath;
  final String name;
  final double radius;
  final Color color;

  String get _initials {
    if (name.isEmpty) return '?';
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasLogo = logoPath != null && logoPath!.isNotEmpty;
    final isUrl = hasLogo &&
        (logoPath!.startsWith('http://') || logoPath!.startsWith('https://'));
    return CircleAvatar(
      radius: radius,
      backgroundColor: color,
      child: hasLogo && isUrl
          ? ClipOval(
              child: Image.network(
                logoPath!,
                fit: BoxFit.cover,
                width: radius * 2,
                height: radius * 2,
                errorBuilder: (_, __, ___) => Text(
                  _initials,
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                    fontSize: radius * 0.8,
                  ),
                ),
              ),
            )
          : Text(
              _initials,
              style: TextStyle(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
                fontSize: radius * 0.8,
              ),
            ),
    );
  }
}
