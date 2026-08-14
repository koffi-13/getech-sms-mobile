/// Page "Élèves" : liste filtrée (recherche + classe + sexe + statut) avec
/// pull-to-refresh, support offline-first et FAB d'ajout (RBAC).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_state.dart';
import '../../core/config/constants.dart';
import '../../core/utils/permissions.dart';
import '../../shared/models/classroom_dto.dart';
import '../../shared/models/student_dto.dart';
import '../../shared/widgets/widgets.dart';
import '../classrooms/classroom_controller.dart';
import 'student_controller.dart';

class StudentsListPage extends ConsumerStatefulWidget {
  const StudentsListPage({super.key});

  @override
  ConsumerState<StudentsListPage> createState() => _StudentsListPageState();
}

class _StudentsListPageState extends ConsumerState<StudentsListPage> {
  StudentFilter _filter = const StudentFilter.empty();

  // Recherche debouncée (léger délai pour limiter les requêtes).
  String _searchText = '';
  DateTime? _lastSearchAt;

  void _onSearchChanged(String value) {
    setState(() => _searchText = value);
    final now = DateTime.now();
    _lastSearchAt = now;
    Future.delayed(const Duration(milliseconds: 350), () {
      if (_lastSearchAt == now) {
        setState(() => _filter = _filter.copyWith(search: value.trim()));
      }
    });
  }

  Future<void> _refresh() async {
    ref.invalidate(classroomsListProvider);
    ref.invalidate(studentsListProvider);
    // Re-déclenche la requête en réécrivant le filtre (force le watch).
    setState(() => _filter = _filter.copyWith());
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final perms = auth.permissions;
    final canCreate = hasPermission(perms, RbacPermissions.studentCreate);

    final classroomsAsync = ref.watch(classroomsListProvider);
    final studentsAsync = ref.watch(studentsListProvider(_filter));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Élèves'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Rafraîchir',
            onPressed: _refresh,
          ),
        ],
      ),
      floatingActionButton: canCreate
          ? FloatingActionButton.extended(
              onPressed: () => context.push('/students/new'),
              icon: const Icon(Icons.person_add),
              label: const Text('Ajouter'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          slivers: [
            // Bannière hors-ligne.
            SliverToBoxAdapter(child: _OfflineBanner()),
            // Barre de recherche.
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: AppSearchBar(
                  hint: 'Rechercher un élève (matricule, nom…)',
                  onChanged: _onSearchChanged,
                ),
              ),
            ),
            // Chips de filtres.
            SliverToBoxAdapter(
              child: _FilterChips(
                filter: _filter,
                classroomsAsync: classroomsAsync,
                onChanged: (next) => setState(() => _filter = next),
              ),
            ),
            // Liste des élèves.
            studentsAsync.when(
              data: (students) {
                if (students.isEmpty) {
                  return const SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyState(
                      icon: Icons.people_outline,
                      title: 'Aucun élève',
                      message:
                          'Aucun élève ne correspond à votre recherche ou à votre base locale.',
                    ),
                  );
                }
                return SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  sliver: SliverList.separated(
                    itemCount: students.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 4),
                    itemBuilder: (context, i) {
                      final s = students[i];
                      return _StudentTile(student: s);
                    },
                  ),
                );
              },
              loading: () => const SliverFillRemaining(
                hasScrollBody: false,
                child: AppLoading(label: 'Chargement des élèves…'),
              ),
              error: (e, _) => SliverFillRemaining(
                hasScrollBody: false,
                child: AppErrorWidget(
                  message: e.toString(),
                  onRetry: _refresh,
                ),
              ),
            ),
            // Espace pour le FAB.
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
                size: 18, color: Theme.of(context).colorScheme.onSecondaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Mode hors-ligne — données locales (sync différée).',
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
// Filtres (chips)
// ---------------------------------------------------------------------------

class _FilterChips extends StatelessWidget {
  const _FilterChips({
    required this.filter,
    required this.classroomsAsync,
    required this.onChanged,
  });

  final StudentFilter filter;
  final AsyncValue<List<ClassroomDto>> classroomsAsync;
  final ValueChanged<StudentFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          // Classe — dropdown popup.
          _ClassroomFilterChip(
            filter: filter,
            classroomsAsync: classroomsAsync,
            onChanged: onChanged,
          ),
          // Sexe.
          _ChoiceChip(
            label: 'Masculin',
            selected: filter.sexe == Sexe.masculin,
            onSelected: (sel) => onChanged(
              filter.copyWith(
                sexe: sel ? Sexe.masculin : null,
                clearSexe: !sel,
              ),
            ),
          ),
          _ChoiceChip(
            label: 'Féminin',
            selected: filter.sexe == Sexe.feminin,
            onSelected: (sel) => onChanged(
              filter.copyWith(
                sexe: sel ? Sexe.feminin : null,
                clearSexe: !sel,
              ),
            ),
          ),
          // Statut.
          _ChoiceChip(
            label: 'Nouveau',
            selected: filter.status == StudentStatus.nouveau,
            onSelected: (sel) => onChanged(
              filter.copyWith(
                status: sel ? StudentStatus.nouveau : null,
                clearStatus: !sel,
              ),
            ),
          ),
          _ChoiceChip(
            label: 'Redoublant',
            selected: filter.status == StudentStatus.redoublant,
            onSelected: (sel) => onChanged(
              filter.copyWith(
                status: sel ? StudentStatus.redoublant : null,
                clearStatus: !sel,
              ),
            ),
          ),
          if (filter != const StudentFilter.empty())
            ActionChip(
              label: const Text('Réinitialiser'),
              avatar: const Icon(Icons.clear, size: 18),
              onPressed: () => onChanged(const StudentFilter.empty()),
            ),
        ],
      ),
    );
  }
}

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });
  final String label;
  final bool selected;
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: onSelected,
    );
  }
}

class _ClassroomFilterChip extends StatelessWidget {
  const _ClassroomFilterChip({
    required this.filter,
    required this.classroomsAsync,
    required this.onChanged,
  });

  final StudentFilter filter;
  final AsyncValue<List<ClassroomDto>> classroomsAsync;
  final ValueChanged<StudentFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = filter.classroomId != null;
    return ActionChip(
      avatar: const Icon(Icons.school, size: 18),
      label: Text(_label(classroomsAsync)),
      selected: selected,
      backgroundColor: selected
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.surfaceContainerHighest,
      onPressed: () => _openClassroomPicker(context),
    );
  }

  String _label(AsyncValue<List<ClassroomDto>> async) {
    if (filter.classroomId == null) return 'Toutes classes';
    return async.maybeWhen(
      data: (list) {
        for (final c in list) {
          if (c.id == filter.classroomId) return c.name;
        }
        return 'Classe #${filter.classroomId}';
      },
      orElse: () => 'Classe #${filter.classroomId}',
    );
  }

  Future<void> _openClassroomPicker(BuildContext context) async {
    final classrooms = classroomsAsync.maybeWhen(
      data: (list) => list,
      orElse: () => const <ClassroomDto>[],
    );
    if (classrooms.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Aucune classe disponible pour le filtrage.'),
        ),
      );
      return;
    }
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                title: const Text('Toutes les classes'),
                leading: const Icon(Icons.clear_all),
                onTap: () => Navigator.pop(ctx, -1),
              ),
              const Divider(height: 1),
              ...classrooms.map((c) => ListTile(
                    title: Text(c.name),
                    subtitle: c.code == null ? null : Text(c.code),
                    trailing: filter.classroomId == c.id
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () => Navigator.pop(ctx, c.id),
                  )),
            ],
          ),
        );
      },
    );
    if (selected == null) return;
    if (selected == -1) {
      onChanged(filter.copyWith(clearClassroom: true));
    } else {
      onChanged(filter.copyWith(classroomId: selected));
    }
  }
}

// ---------------------------------------------------------------------------
// Tuile élève
// ---------------------------------------------------------------------------

class _StudentTile extends StatelessWidget {
  const _StudentTile({required this.student});
  final StudentDto student;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = student.sexe == Sexe.feminin
        ? Colors.pink.shade300
        : (student.sexe == Sexe.masculin ? Colors.blue.shade300 : Colors.teal);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        leading: CircleAvatar(
          backgroundColor: color,
          child: student.photoPath != null && student.photoPath!.isNotEmpty
              ? ClipOval(
                  child: Image.network(
                    student.photoPath!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Text(
                      student.displayInitials,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                )
              : Text(
                  student.displayInitials,
                  style: const TextStyle(color: Colors.white),
                ),
        ),
        title: Text(
          student.fullName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Row(
              children: [
                Icon(Icons.badge_outlined,
                    size: 14, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    student.matricule,
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (student.classroomName != null) ...[
              const SizedBox(height: 2),
              Row(
                children: [
                  Icon(Icons.school_outlined,
                      size: 14, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      student.classroomName!,
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/students/${student.id}'),
      ),
    );
  }
}
