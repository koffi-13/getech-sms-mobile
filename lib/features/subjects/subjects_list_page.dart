/// Page "Matières" : liste filtrée (recherche) avec pull-to-refresh, support
/// hors-ligne, FAB d'ajout (RBAC SUBJECT_MANAGE) et accès aux affectations
/// par classe.
///
/// RBAC : SUBJECT_MANAGE ou GRADE_READ pour consulter la liste. Les actions
/// de gestion (ajout, édition, affectations) requièrent SUBJECT_MANAGE.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_state.dart';
import '../../core/config/constants.dart';
import '../../core/utils/permissions.dart';
import '../../shared/models/classroom_dto.dart';
import '../../shared/widgets/widgets.dart';
import '../connections/connection_state.dart';
import 'subject_controller.dart';

class SubjectsListPage extends ConsumerStatefulWidget {
  const SubjectsListPage({super.key});

  @override
  ConsumerState<SubjectsListPage> createState() => _SubjectsListPageState();
}

class _SubjectsListPageState extends ConsumerState<SubjectsListPage> {
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
      if (_lastSearchAt == now) {
        setState(() => _searchQuery = value.trim());
      }
    });
  }

  Future<void> _refresh() async {
    ref.invalidate(subjectsListProvider);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final perms = auth.permissions;
    final canManage = hasPermission(perms, RbacPermissions.subjectManage);
    final canRead = canManage ||
        hasPermission(perms, RbacPermissions.gradeRead) ||
        hasPermission(perms, RbacPermissions.studentRead);

    // Garde RBAC : SUBJECT_MANAGE ou GRADE_READ requis.
    if (!canRead) {
      return Scaffold(
        appBar: AppBar(title: const Text('Matières')),
        body: const EmptyState(
          icon: Icons.lock_outline,
          title: 'Permission insuffisante',
          message:
              'Vous n\'avez pas la permission SUBJECT_MANAGE ou GRADE_READ requise pour consulter la liste des matières.',
        ),
      );
    }

    final subjectsAsync = ref.watch(subjectsListProvider(_searchQuery));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Matières'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Rafraîchir',
            onPressed: _refresh,
          ),
          if (canManage)
            IconButton(
              icon: const Icon(Icons.assignment_ind_outlined),
              tooltip: 'Affectations par classe',
              onPressed: () => context.push('/subjects/class-subjects'),
            ),
        ],
      ),
      floatingActionButton: canManage
          ? FloatingActionButton.extended(
              onPressed: () => context.push('/subjects/new'),
              icon: const Icon(Icons.add),
              label: const Text('Ajouter une matière'),
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
                  hint: 'Rechercher une matière (nom, code…)',
                  onChanged: _onSearchChanged,
                ),
              ),
            ),
            if (canManage)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Card(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    elevation: 0,
                    child: ListTile(
                      leading: Icon(Icons.assignment_ind_outlined,
                          color: Theme.of(context).colorScheme.onPrimaryContainer),
                      title: Text(
                        'Affectations par classe',
                        style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        'Gérer les matières enseignées dans chaque classe',
                        style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onPrimaryContainer
                              .withValues(alpha: 0.85),
                        ),
                      ),
                      trailing: Icon(Icons.chevron_right,
                          color:
                              Theme.of(context).colorScheme.onPrimaryContainer),
                      onTap: () => context.push('/subjects/class-subjects'),
                    ),
                  ),
                ),
              ),
            subjectsAsync.when(
              data: (subjects) {
                if (subjects.isEmpty) {
                  return const SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyState(
                      icon: Icons.menu_book_outlined,
                      title: 'Aucune matière',
                      message:
                          'Aucune matière ne correspond à votre recherche ou n\'est enregistrée sur le serveur.',
                    ),
                  );
                }
                return SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  sliver: SliverList.separated(
                    itemCount: subjects.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 4),
                    itemBuilder: (context, i) => _SubjectTile(
                      subject: subjects[i],
                      canManage: canManage,
                    ),
                  ),
                );
              },
              loading: () => const SliverFillRemaining(
                hasScrollBody: false,
                child: AppLoading(label: 'Chargement des matières…'),
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
// Tuile matière
// ---------------------------------------------------------------------------

class _SubjectTile extends StatelessWidget {
  const _SubjectTile({required this.subject, required this.canManage});

  final SubjectDto subject;
  final bool canManage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: canManage
            ? () => context.push('/subjects/${subject.id}/edit')
            : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.menu_book_outlined,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      subject.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subject.code.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Code : ${subject.code}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (canManage)
                Icon(Icons.chevron_right,
                    color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
