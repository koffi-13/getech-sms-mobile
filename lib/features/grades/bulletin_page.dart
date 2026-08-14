/// Page « Bulletin » d'un élève : en-tête (élève, classe, période, année),
/// moyenne générale (gros), rang/effectif, tableau des matières (matière,
/// coef, moyenne, rang, appréciation) et appréciation générale.
///
/// Bouton « Partager / Imprimer » → snackbar « Export PDF à venir ».
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/formatters.dart';
import '../../shared/models/grade_dto.dart';
import '../../shared/widgets/widgets.dart';
import 'grade_controller.dart';

class BulletinPage extends ConsumerWidget {
  const BulletinPage({super.key, required this.studentId});

  final int studentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncBulletin = ref.watch(bulletinProvider(studentId));

    return Scaffold(
      appBar: AppBar(title: const Text('Bulletin')),
      body: asyncBulletin.when(
        data: (b) => _BulletinView(bulletin: b),
        loading: () => const AppLoading(label: 'Chargement du bulletin…'),
        error: (e, _) => AppErrorWidget(
          message: e.toString(),
          onRetry: () => ref.invalidate(bulletinProvider(studentId)),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () =>
            ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Export PDF à venir')),
        ),
        icon: const Icon(Icons.print_outlined),
        label: const Text('Partager / Imprimer'),
      ),
    );
  }
}

class _BulletinView extends StatelessWidget {
  const _BulletinView({required this.bulletin});
  final BulletinDto bulletin;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        // --- En-tête ---
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 24,
                      backgroundColor:
                          Theme.of(context).colorScheme.primaryContainer,
                      child: Text(
                        bulletin.studentName.isNotEmpty
                            ? bulletin.studentName[0].toUpperCase()
                            : '?',
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onPrimaryContainer,
                            ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            bulletin.studentName,
                            style: Theme.of(context).textTheme.titleLarge,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (bulletin.matricule != null)
                            Text('Mat. ${bulletin.matricule}',
                                style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                    ),
                  ],
                ),
                const Divider(height: 24),
                _HeaderRow(label: 'Classe', value: bulletin.classroomName),
                _HeaderRow(label: 'Période', value: bulletin.periodName),
                if (bulletin.schoolYearName != null)
                  _HeaderRow(
                      label: 'Année scolaire', value: bulletin.schoolYearName!),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // --- Moyenne générale + rang ---
        Row(
          children: [
            Expanded(
              child: _KpiTile(
                label: 'Moyenne générale',
                value: GradeFormatter.format(bulletin.generalAverage),
                icon: Icons.school,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _KpiTile(
                label: 'Rang',
                value: (bulletin.rank != null && bulletin.totalStudents != null)
                    ? '${bulletin.rank} / ${bulletin.totalStudents}'
                    : (bulletin.rank != null ? '${bulletin.rank}' : '—'),
                icon: Icons.leaderboard,
                color: Colors.amber.shade700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // --- Tableau des matières ---
        SectionHeader(
          title: 'Matières',
          icon: Icons.book_outlined,
          subtitle:
              '${bulletin.subjects.length} matière(s) — coefficient total ${_totalCoef(bulletin.subjects).toStringAsFixed(1)}',
        ),
        const SizedBox(height: 8),
        if (bulletin.subjects.isEmpty)
          const EmptyState(
            title: 'Aucune matière',
            message: 'Aucune note n\'a été saisie pour cette période.',
            icon: Icons.book_outlined,
          )
        else
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  const _SubjectHeaderRow(),
                  const Divider(height: 1),
                  ...bulletin.subjects.map((s) => _SubjectRow(subject: s)),
                ],
              ),
            ),
          ),

        // --- Appreciation générale ---
        if (bulletin.appreciation != null) ...[
          const SizedBox(height: 16),
          Card(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.chat_bubble_outline,
                          size: 18,
                          color:
                              Theme.of(context).colorScheme.onSecondaryContainer),
                      const SizedBox(width: 8),
                      Text('Appréciation générale',
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSecondaryContainer)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    bulletin.appreciation!,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSecondaryContainer,
                        ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  double _totalCoef(List<BulletinSubjectDto> subjects) {
    double s = 0;
    for (final sub in subjects) {
      s += sub.coefficient;
    }
    return s;
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const Spacer(),
          Text(value,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _KpiTile extends StatelessWidget {
  const _KpiTile({
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 18, color: color),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              value,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _SubjectHeaderRow extends StatelessWidget {
  const _SubjectHeaderRow();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(flex: 4, child: Text('Matière', style: style)),
          Expanded(flex: 2, child: Text('Coef.', style: style, textAlign: TextAlign.center)),
          Expanded(flex: 2, child: Text('Moy.', style: style, textAlign: TextAlign.center)),
          Expanded(flex: 2, child: Text('Rang', style: style, textAlign: TextAlign.center)),
        ],
      ),
    );
  }
}

class _SubjectRow extends StatelessWidget {
  const _SubjectRow({required this.subject});
  final BulletinSubjectDto subject;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(subject.subjectName,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600)),
                    if (subject.teacherName != null)
                      Text(subject.teacherName!,
                          style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  subject.coefficient.toStringAsFixed(1),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  GradeFormatter.format(subject.average),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.primary),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  subject.rank != null ? '${subject.rank}' : '—',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          if (subject.appreciation != null) ...[
            const SizedBox(height: 4),
            Text(
              subject.appreciation!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontStyle: FontStyle.italic,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
          const Divider(height: 16),
        ],
      ),
    );
  }
}
