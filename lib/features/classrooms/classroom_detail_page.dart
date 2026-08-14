/// Page "Détail classe" : header (capacité/occupation) au-dessus d'onglets
/// (Élèves · Emploi du temps · Matières).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/constants.dart';
import '../../shared/models/classroom_dto.dart';
import '../../shared/models/student_dto.dart';
import '../../shared/widgets/widgets.dart';
import '../students/student_controller.dart';
import 'classroom_controller.dart';

class ClassroomDetailPage extends ConsumerWidget {
  const ClassroomDetailPage({super.key, required this.id});

  final int id;

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(classroomDetailProvider(id));
    ref.invalidate(classSubjectsForClassroomProvider(id));
    ref.invalidate(studentsListProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(classroomDetailProvider(id));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Classe'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Rafraîchir',
            onPressed: () => _refresh(ref),
          ),
        ],
      ),
      body: async.when(
        data: (classroom) => DefaultTabController(
          length: 3,
          child: Column(
            children: [
              _Header(classroom: classroom),
              const TabBar(
                tabs: [
                  Tab(text: 'Élèves'),
                  Tab(text: 'Emploi du temps'),
                  Tab(text: 'Matières'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _StudentsTab(classroomId: id),
                    _ScheduleTab(classroomId: id),
                    _SubjectsTab(classroomId: id),
                  ],
                ),
              ),
            ],
          ),
        ),
        loading: () => const AppLoading(label: 'Chargement de la classe…'),
        error: (e, _) => AppErrorWidget(
          message: e.toString(),
          onRetry: () => _refresh(ref),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// En-tête classe (header)
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({required this.classroom});
  final ClassroomDto classroom;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final occupancy = classroom.occupancyRate;
    final occupancyColor = occupancy >= 1
        ? Colors.red
        : (occupancy >= 0.8 ? Colors.orange : theme.colorScheme.primary);

    final subtitleParts = <String>[];
    if (classroom.levelName != null) subtitleParts.add(classroom.levelName!);
    if (classroom.cycleName != null) subtitleParts.add(classroom.cycleName!);
    if (classroom.seriesName != null) subtitleParts.add(classroom.seriesName!);

    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.school, color: theme.colorScheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(classroom.name, style: theme.textTheme.titleLarge),
                      if (subtitleParts.isNotEmpty)
                        Text(
                          subtitleParts.join(' · '),
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      if (classroom.teacherName != null)
                        Text(
                          'Titulaire : ${classroom.teacherName}',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _StatTile(
                    label: 'Effectif',
                    value: '${classroom.studentCount}',
                    icon: Icons.people_outline,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _StatTile(
                    label: 'Capacité',
                    value: '${classroom.capacity}',
                    icon: Icons.event_seat_outlined,
                    color: theme.colorScheme.tertiary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: occupancy,
                      minHeight: 8,
                      backgroundColor: theme.colorScheme.surfaceContainerHighest,
                      color: occupancyColor,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${(occupancy * 100).round()}% occupé',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: occupancyColor, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                Text(label,
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Onglet Élèves
// ---------------------------------------------------------------------------

class _StudentsTab extends ConsumerWidget {
  const _StudentsTab({required this.classroomId});
  final int classroomId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final studentsAsync = ref.watch(
      studentsListProvider(StudentFilter(classroomId: classroomId)),
    );

    return studentsAsync.when(
      data: (students) {
        if (students.isEmpty) {
          return const Center(
            child: EmptyState(
              icon: Icons.person_off_outlined,
              title: 'Aucun élève',
              message: 'Cette classe ne contient encore aucun élève.',
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          itemCount: students.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) => _StudentRow(student: students[i]),
        );
      },
      loading: () => const AppLoading(label: 'Chargement des élèves…'),
      error: (e, _) => AppErrorWidget(
        message: e.toString(),
        onRetry: () => ref.invalidate(
          studentsListProvider(StudentFilter(classroomId: classroomId)),
        ),
      ),
    );
  }
}

class _StudentRow extends StatelessWidget {
  const _StudentRow({required this.student});
  final StudentDto student;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = student.sexe == Sexe.feminin
        ? Colors.pink.shade300
        : (student.sexe == Sexe.masculin ? Colors.blue.shade300 : Colors.teal);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: color,
        child: Text(
          student.displayInitials,
          style: const TextStyle(color: Colors.white),
        ),
      ),
      title: Text(student.fullName, style: theme.textTheme.titleSmall),
      subtitle: Text(student.matricule, style: theme.textTheme.bodySmall),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push('/students/${student.id}'),
    );
  }
}

// ---------------------------------------------------------------------------
// Onglet Emploi du temps
// ---------------------------------------------------------------------------

class _ScheduleTab extends StatelessWidget {
  const _ScheduleTab({required this.classroomId});
  final int classroomId;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.calendar_view_week,
                size: 64, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              'Emploi du temps',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Consultez l\'emploi du temps hebdomadaire de cette classe.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () =>
                  context.push('/schedule?classroom_id=$classroomId'),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Ouvrir l\'emploi du temps'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Onglet Matières
// ---------------------------------------------------------------------------

class _SubjectsTab extends ConsumerWidget {
  const _SubjectsTab({required this.classroomId});
  final int classroomId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(classSubjectsForClassroomProvider(classroomId));

    return async.when(
      data: (subjects) {
        if (subjects.isEmpty) {
          return const Center(
            child: EmptyState(
              icon: Icons.menu_book_outlined,
              title: 'Aucune matière',
              message: 'Aucune matière n\'est affectée à cette classe.',
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: subjects.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) => _SubjectRow(subject: subjects[i]),
        );
      },
      loading: () => const AppLoading(label: 'Chargement des matières…'),
      error: (e, _) => AppErrorWidget(
        message: e.toString(),
        onRetry: () =>
            ref.invalidate(classSubjectsForClassroomProvider(classroomId)),
      ),
    );
  }
}

class _SubjectRow extends StatelessWidget {
  const _SubjectRow({required this.subject});
  final ClassSubjectDto subject;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.primaryContainer,
        child: Icon(Icons.menu_book_outlined, color: theme.colorScheme.primary),
      ),
      title: Text(subject.subjectName, style: theme.textTheme.titleSmall),
      subtitle: subject.teacherName != null
          ? Text('Enseignant : ${subject.teacherName}',
              style: theme.textTheme.bodySmall)
          : null,
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          'Coef. ${subject.coefficient}',
          style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onTertiaryContainer,
              fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
