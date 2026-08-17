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
import '../connections/connection_state.dart';
import 'student_controller.dart';
import 'student_export_dialog.dart';

class StudentsListPage extends ConsumerStatefulWidget {
  const StudentsListPage({super.key});

  @override
  ConsumerState<StudentsListPage> createState() => _StudentsListPageState();
}

class _StudentsListPageState extends ConsumerState<StudentsListPage> {
  StudentFilter _filter = StudentFilter.empty;

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
    ref.invalidate(studentControllerProvider);
    ref.invalidate(classroomsProvider);
    // On force un rafraîchissement manuel
    setState(() => _filter = _filter.copyWith());
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final canRead = hasPermission(auth.permissions, RbacPermissions.studentRead);
    final canCreate = hasPermission(auth.permissions, RbacPermissions.studentCreate);

    if (!canRead) {
      return Scaffold(
        appBar: AppBar(title: const Text('Élèves')),
        body: const EmptyState(
          icon: Icons.lock_outline,
          title: 'Permission insuffisante',
          message: 'Vous n\'avez pas la permission STUDENT_READ.',
        ),
      );
    }

    final classroomsAsync = ref.watch(classroomsProvider);
    final studentsAsync = ref.watch(studentControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Élèves'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Rafraîchir',
            onPressed: _refresh,
          ),
          IconButton(
            icon: const Icon(Icons.file_upload_outlined),
            tooltip: 'Export / Import',
            onPressed: () => _openImportExport(context),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          slivers: _buildSlivers(studentsAsync, classroomsAsync),
        ),
      ),
      floatingActionButton: canCreate
          ? FloatingActionButton.extended(
              onPressed: () => context.push('/students/new'),
              icon: const Icon(Icons.add),
              label: const Text('Nouvel élève'),
            )
          : null,
    );
  }

  List<Widget> _buildSlivers(
    AsyncValue<List<StudentDto>> studentsAsync,
    AsyncValue<List<ClassroomDto>> classroomsAsync,
  ) {
    final slivers = <Widget>[
      const SliverToBoxAdapter(child: _OfflineBanner()),
      // Barre de recherche.
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: AppSearchBar(
            hint: 'Nom ou matricule…',
            onChanged: _onSearchChanged,
          ),
        ),
      ),
      // Filtres horizontaux.
      SliverToBoxAdapter(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              _FilterChip(
                label: _classroomLabel(classroomsAsync),
                icon: Icons.school_outlined,
                selected: _filter.classroomId != null,
                onTap: () => _openClassroomPicker(context, classroomsAsync),
              ),
              const SizedBox(width: 8),
              _FilterChip(
                label: _filter.sexe?.label ?? 'Sexe',
                icon: Icons.people_outline,
                selected: _filter.sexe != null,
                onTap: () => _openSexePicker(context),
              ),
              const SizedBox(width: 8),
              _FilterChip(
                label: _filter.status?.label ?? 'Statut',
                icon: Icons.new_releases_outlined,
                selected: _filter.status != null,
                onTap: () => _openStatusPicker(context),
              ),
              if (_filter != StudentFilter.empty) ...[
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: () => setState(() => _filter = StudentFilter.empty),
                  icon: const Icon(Icons.clear, size: 16),
                  label: const Text('Reset'),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 8)),
    ];

    if (studentsAsync.isLoading) {
      slivers.add(const SliverFillRemaining(
        hasScrollBody: false,
        child: AppLoading(label: 'Chargement des élèves…'),
      ));
      return slivers;
    }

    if (studentsAsync.hasError) {
      slivers.add(SliverFillRemaining(
        hasScrollBody: false,
        child: AppErrorWidget(
          message: studentsAsync.error.toString(),
          onRetry: _refresh,
        ),
      ));
      return slivers;
    }

    final students = studentsAsync.value ?? [];
    if (students.isEmpty) {
      slivers.add(const SliverFillRemaining(
        hasScrollBody: false,
        child: EmptyState(
          icon: Icons.person_search,
          title: 'Aucun élève trouvé',
          message: 'Essayez d\'ajuster vos filtres ou effectuez une synchro.',
        ),
      ));
      return slivers;
    }

    slivers.add(SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      sliver: SliverList.separated(
        itemCount: students.length,
        separatorBuilder: (_, __) => const SizedBox(height: 4),
        itemBuilder: (context, i) => _StudentTile(student: students[i]),
      ),
    ));

    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 80)));
    return slivers;
  }

  String _classroomLabel(AsyncValue<List<ClassroomDto>> async) {
    if (_filter.classroomId == null) return 'Classe';
    return async.maybeWhen(
      data: (list) => list.firstWhere((c) => c.id == _filter.classroomId).name,
      orElse: () => 'Classe #${_filter.classroomId}',
    );
  }

  void _openClassroomPicker(BuildContext context, AsyncValue<List<ClassroomDto>> async) {
    final list = async.value ?? [];
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: const Text('Toutes les classes'),
              onTap: () {
                setState(() => _filter = _filter.copyWith(clearClassroom: true));
                Navigator.pop(ctx);
              },
            ),
            ...list.map((c) => ListTile(
                  title: Text(c.name),
                  trailing: _filter.classroomId == c.id ? const Icon(Icons.check) : null,
                  onTap: () {
                    setState(() => _filter = _filter.copyWith(classroomId: c.id));
                    Navigator.pop(ctx);
                  },
                )),
          ],
        ),
      ),
    );
  }

  void _openSexePicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Tous les sexes'),
              onTap: () {
                setState(() => _filter = _filter.copyWith(sexe: null));
                Navigator.pop(ctx);
              },
            ),
            ...Sexe.values.map((v) => ListTile(
                  title: Text(v.label),
                  onTap: () {
                    setState(() => _filter = _filter.copyWith(sexe: v));
                    Navigator.pop(ctx);
                  },
                )),
          ],
        ),
      ),
    );
  }

  void _openStatusPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Tous les statuts'),
              onTap: () {
                setState(() => _filter = _filter.copyWith(status: null));
                Navigator.pop(ctx);
              },
            ),
            ...StudentStatus.values.map((v) => ListTile(
                  title: Text(v.label),
                  onTap: () {
                    setState(() => _filter = _filter.copyWith(status: v));
                    Navigator.pop(ctx);
                  },
                )),
          ],
        ),
      ),
    );
  }

  void _openImportExport(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => const StudentExportDialog(),
    );
  }
}

// ---------------------------------------------------------------------------
// Composants internes
// ---------------------------------------------------------------------------

class _OfflineBanner extends ConsumerWidget {
  const _OfflineBanner();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider);
    if (conn.canReachServer) return const SizedBox.shrink();
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.cloud_off, size: 16),
            SizedBox(width: 8),
            Text('Mode hors-ligne — accès SQLite uniquement',
                style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FilterChip(
      avatar: Icon(icon, size: 16),
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
      selectedColor: theme.colorScheme.primaryContainer,
      labelStyle: TextStyle(
        color: selected ? theme.colorScheme.onPrimaryContainer : null,
      ),
    );
  }
}

class _StudentTile extends StatelessWidget {
  final StudentDto student;
  const _StudentTile({required this.student});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          child: Text(student.displayInitials),
        ),
        title: Text(student.fullName),
        subtitle: Text(
          [
            if (student.matricule.isNotEmpty) student.matricule,
            student.classroomName,
          ].join(' • '),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/students/${student.id}'),
      ),
    );
  }
}
