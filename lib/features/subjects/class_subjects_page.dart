/// Page des matières d'une classe.
///
/// [Fix-DEV-TEXT] Remplace l'ancien placeholder « Liste des matières non
/// implémentée » par la vraie liste servie par [classSubjectsProvider]
/// (API `GET /grades/class-subjects?classroom_id=` avec repli cache Drift).
library;

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/formatters.dart';
import '../../shared/models/classroom_dto.dart';
import '../../shared/widgets/widgets.dart';
import '../classrooms/classroom_controller.dart';
import '../grades/grade_controller.dart' show classSubjectsProvider;

class ClassSubjectsPage extends ConsumerStatefulWidget {
  final int classroomId;
  const ClassSubjectsPage({super.key, required this.classroomId});

  @override
  ConsumerState<ClassSubjectsPage> createState() => _ClassSubjectsPageState();
}

class _ClassSubjectsPageState extends ConsumerState<ClassSubjectsPage> {
  @override
  Widget build(BuildContext context) {
    final classroomAsync = ref.watch(classroomDetailProvider(widget.classroomId));
    final subjectsAsync = ref.watch(classSubjectsProvider(widget.classroomId));
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: classroomAsync.when(
          data: (c) => Text('Matières : ${c.name}'),
          loading: () => const Text('Matières'),
          error: (_, __) => const Text('Matières'),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(classroomDetailProvider(widget.classroomId));
          ref.invalidate(classSubjectsProvider(widget.classroomId));
          await ref.read(classSubjectsProvider(widget.classroomId).future);
        },
        child: subjectsAsync.when(
          data: (subjects) {
            if (subjects.isEmpty) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  EmptyState(
                    title: 'Aucune matière',
                    message: 'Aucune matière n\'est affectée à cette classe '
                        'pour le moment.',
                    icon: Icons.book_outlined,
                  ),
                ],
              );
            }
            return ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              itemCount: subjects.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final s = subjects[i];
                return _SubjectTile(subject: s, theme: theme);
              },
            );
          },
          loading: () => const AppLoading(label: 'Chargement des matières…'),
          error: (e, _) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              AppErrorWidget(
                message: e.toString(),
                onRetry: () =>
                    ref.invalidate(classSubjectsProvider(widget.classroomId)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SubjectTile extends StatelessWidget {
  const _SubjectTile({required this.subject, required this.theme});

  final ClassSubjectDto subject;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final teacher = subject.assignedTeacherName;
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(
            subject.isFacultative
                ? Icons.auto_stories_outlined
                : Icons.menu_book_outlined,
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
        title: Text(
          subject.subjectName.isNotEmpty
              ? subject.subjectName
              : subject.subjectCode,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (teacher != null && teacher.isNotEmpty)
              Text(
                'Enseignant : $teacher',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            Text(
              'Coefficient : ${subject.coefficient.toStringAsFixed(subject.coefficient == subject.coefficient.truncate() ? 0 : 1)}',
            ),
          ],
        ),
        trailing: subject.isFacultative
            ? Chip(
                label: const Text('Facultative'),
                visualDensity: VisualDensity.compact,
                backgroundColor: theme.colorScheme.tertiaryContainer,
                labelStyle: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onTertiaryContainer,
                ),
              )
            : null,
      ),
    );
  }
}
