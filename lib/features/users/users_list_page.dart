/// Page "Utilisateurs" : liste filtrée (recherche) avec pull-to-refresh,
/// support hors-ligne et FAB d'ajout (RBAC USER_MANAGE).
///
/// RBAC : USER_READ requis pour consulter la liste. Sans cette permission, un
/// écran « Permission insuffisante » est affiché.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_state.dart';
import '../../core/config/constants.dart';
import '../../core/utils/permissions.dart';
import '../../shared/models/auth_dto.dart';
import '../../shared/widgets/widgets.dart';
import '../connections/connection_state.dart';
import 'user_controller.dart';

class UsersListPage extends ConsumerStatefulWidget {
  const UsersListPage({super.key});

  @override
  ConsumerState<UsersListPage> createState() => _UsersListPageState();
}

class _UsersListPageState extends ConsumerState<UsersListPage> {
  /// Texte affiché dans la barre de recherche (mis à jour immédiatement).
  String _searchText = '';
  /// Requête réellement transmise au provider (mise à jour après debounce).
  String _searchQuery = '';
  DateTime? _lastSearchAt;

  void _onSearchChanged(String value) {
    setState(() => _searchText = value);
    final now = DateTime.now();
    _lastSearchAt = now;
    Future.delayed(const Duration(milliseconds: 350), () {
      // Ne déclenche la requête que si l'utilisateur a cessé de taper depuis
      // 350 ms (debounce).
      if (_lastSearchAt == now) {
        setState(() => _searchQuery = value.trim());
      }
    });
  }

  Future<void> _refresh() async {
    ref.invalidate(usersListProvider);
    setState(() {}); // Re-déclenche le watch sur la famille.
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final perms = auth.permissions;

    // Garde RBAC : USER_READ requis.
    if (!hasPermission(perms, RbacPermissions.userRead)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Utilisateurs')),
        body: const EmptyState(
          icon: Icons.lock_outline,
          title: 'Permission insuffisante',
          message:
              'Vous n\'avez pas la permission USER_READ requise pour consulter la liste des utilisateurs.',
        ),
      );
    }

    final canManage = hasPermission(perms, RbacPermissions.userManage);
    final usersAsync = ref.watch(usersListProvider(_searchQuery));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Utilisateurs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Rafraîchir',
            onPressed: _refresh,
          ),
        ],
      ),
      floatingActionButton: canManage
          ? FloatingActionButton.extended(
              onPressed: () => context.push('/users/new'),
              icon: const Icon(Icons.person_add),
              label: const Text('Ajouter'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          slivers: [
            const SliverToBoxAdapter(child: _OfflineBanner()),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: AppSearchBar(
                  hint: 'Rechercher un utilisateur (nom, identifiant, email…)',
                  onChanged: _onSearchChanged,
                ),
              ),
            ),
            usersAsync.when(
              data: (users) {
                if (users.isEmpty) {
                  return const SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyState(
                      icon: Icons.people_outline,
                      title: 'Aucun utilisateur',
                      message:
                          'Aucun utilisateur ne correspond à votre recherche ou est enregistré sur le serveur.',
                    ),
                  );
                }
                return SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  sliver: SliverList.separated(
                    itemCount: users.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 4),
                    itemBuilder: (context, i) =>
                        _UserTile(user: users[i], canManage: canManage),
                  ),
                );
              },
              loading: () => const SliverFillRemaining(
                hasScrollBody: false,
                child: AppLoading(label: 'Chargement des utilisateurs…'),
              ),
              error: (e, _) => SliverFillRemaining(
                hasScrollBody: false,
                child: AppErrorWidget(
                  message: e.toString(),
                  onRetry: _refresh,
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 88)),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bannière hors-ligne
// ---------------------------------------------------------------------------

class _OfflineBanner extends ConsumerWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider);
    if (conn.canReachServer) return const SizedBox.shrink();
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.cloud_off,
                size: 18,
                color: Theme.of(context).colorScheme.onSecondaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Mode hors-ligne — les écritures seront synchronisées ultérieurement.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
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
// Tuile utilisateur
// ---------------------------------------------------------------------------

class _UserTile extends ConsumerWidget {
  const _UserTile({required this.user, required this.canManage});

  final UserDto user;
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final displayName = user.fullName.isEmpty ? user.username : user.fullName;
    final initials = _initials(user);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: () => _onTap(context),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: user.isActive
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.surfaceContainerHighest,
                child: Text(
                  initials,
                  style: TextStyle(
                    color: user.isActive
                        ? theme.colorScheme.onPrimaryContainer
                        : theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            displayName,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (user.isSuperuser) ...[
                          const SizedBox(width: 6),
                          StatusBadge(
                            label: 'Admin',
                            color: theme.colorScheme.tertiary,
                            icon: Icons.shield,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '@${user.username}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (user.email != null && user.email!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        user.email!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        user.isActive
                            ? const StatusBadge(
                                label: 'Actif',
                                color: Colors.green,
                                icon: Icons.check_circle,
                              )
                            : const StatusBadge(
                                label: 'Inactif',
                                color: Colors.grey,
                                icon: Icons.pause_circle,
                              ),
                        if (user.sexe != null)
                          StatusBadge(
                            label: user.sexe!.label,
                            color: theme.colorScheme.primary,
                            filled: false,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  void _onTap(BuildContext context) {
    if (canManage) {
      context.push('/users/${user.id}/edit');
    } else {
      // USER_READ seul → dialogue de consultation.
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (_) => _UserDetailSheet(user: user),
      );
    }
  }

  static String _initials(UserDto u) {
    final f = (u.firstName?.isNotEmpty ?? false) ? u.firstName![0] : '';
    final l = (u.lastName?.isNotEmpty ?? false) ? u.lastName![0] : '';
    final initials = '$f$l'.toUpperCase();
    if (initials.isEmpty) {
      return u.username.isNotEmpty ? u.username[0].toUpperCase() : '?';
    }
    return initials;
  }
}

// ---------------------------------------------------------------------------
// Dialogue de détail (lecture seule — RBAC USER_READ sans USER_MANAGE)
// ---------------------------------------------------------------------------

class _UserDetailSheet extends ConsumerWidget {
  const _UserDetailSheet({required this.user});

  final UserDto user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: CircleAvatar(
                radius: 36,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Text(
                  _UserTile._initials(user),
                  style: TextStyle(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                user.fullName.isEmpty ? user.username : user.fullName,
                style: theme.textTheme.titleLarge,
              ),
            ),
            Center(
              child: Text(
                '@${user.username}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 6,
              runSpacing: 4,
              children: [
                user.isActive
                    ? const StatusBadge(
                        label: 'Actif',
                        color: Colors.green,
                        icon: Icons.check_circle,
                      )
                    : const StatusBadge(
                        label: 'Inactif',
                        color: Colors.grey,
                        icon: Icons.pause_circle,
                      ),
                if (user.isSuperuser)
                  StatusBadge(
                    label: 'Administrateur',
                    color: theme.colorScheme.tertiary,
                    icon: Icons.shield,
                  ),
                if (user.sexe != null)
                  StatusBadge(
                    label: user.sexe!.label,
                    color: theme.colorScheme.primary,
                    filled: false,
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _DetailRow(
              icon: Icons.alternate_email,
              label: 'Identifiant',
              value: user.username,
            ),
            if (user.email != null && user.email!.isNotEmpty)
              _DetailRow(
                icon: Icons.mail_outline,
                label: 'Email',
                value: user.email!,
              ),
            if (user.phone != null && user.phone!.isNotEmpty)
              _DetailRow(
                icon: Icons.phone_outlined,
                label: 'Téléphone',
                value: user.phone!,
              ),
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            '$label :',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
