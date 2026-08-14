/// Page « Bulletin » d'un élève : en-tête (élève, classe, période, année),
/// moyenne générale (gros), rang/effectif, tableau des matières (matière,
/// coef, moyenne, moyenne classe, enseignant), détail des évaluations par
/// matière (dépliable) et appréciation générale.
///
/// Le contrat serveur `GET /grades/bulletin/{student_id}` exige `classroom_id`
/// et `period_id` comme query params. Si l'appelant (ex : RankingPage) les
/// passe via les query params de la route, on les utilise directement ; sinon,
/// on affiche des sélecteurs classe + période.
library;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/utils/formatters.dart';
import '../../shared/models/classroom_dto.dart';
import '../../shared/models/grade_dto.dart';
import '../../shared/widgets/widgets.dart';
import 'grade_controller.dart';

class BulletinPage extends ConsumerWidget {
  const BulletinPage({super.key, required this.studentId});

  final int studentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Lecture des query params optionnels (`classroom_id`, `period_id`).
    final qp = GoRouterState.of(context).uri.queryParameters;
    final initialClassroom = int.tryParse(qp['classroom_id'] ?? '');
    final initialPeriod = int.tryParse(qp['period_id'] ?? '');

    return _BulletinScope(
      studentId: studentId,
      initialClassroomId: initialClassroom,
      initialPeriodId: initialPeriod,
    );
  }
}

/// Widget privé qui gère l'état local (classroomId/periodId) et décide
/// d'afficher les sélecteurs ou le bulletin directement.
class _BulletinScope extends ConsumerStatefulWidget {
  const _BulletinScope({
    required this.studentId,
    required this.initialClassroomId,
    required this.initialPeriodId,
  });

  final int studentId;
  final int? initialClassroomId;
  final int? initialPeriodId;

  @override
  ConsumerState<_BulletinScope> createState() => _BulletinScopeState();
}

class _BulletinScopeState extends ConsumerState<_BulletinScope> {
  int? _classroomId;
  int? _periodId;
  bool _initialized = false;

  @override
  Widget build(BuildContext context) {
    // Initialise paresseusement à partir des query params.
    if (!_initialized) {
      _classroomId = widget.initialClassroomId;
      _periodId = widget.initialPeriodId;
      _initialized = true;
    }

    final classrooms = ref.watch(classroomsForGradesProvider);
    final periods = ref.watch(periodsProvider);

    // Auto-sélection de la première classe/période si non fournie.
    classrooms.whenData((list) {
      if (_classroomId == null && list.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _classroomId = list.first.id);
        });
      }
    });
    periods.whenData((list) {
      if (_periodId == null && list.isNotEmpty) {
        final active =
            list.firstWhereOrNull((p) => p.isActive) ?? list.first;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _periodId = active.id);
        });
      }
    });

    final needsSelectors =
        widget.initialClassroomId == null || widget.initialPeriodId == null;
    final query = (_classroomId != null && _periodId != null)
        ? BulletinQuery(
            studentId: widget.studentId,
            classroomId: _classroomId!,
            periodId: _periodId!,
          )
        : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bulletin'),
        actions: [
          IconButton(
            tooltip: 'Partager / Imprimer',
            icon: const Icon(Icons.print_outlined),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Export PDF à venir')),
              );
            },
          ),
        ],
      ),
      body: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          if (needsSelectors) ...[
            _BulletinSelectors(
              classrooms: classrooms,
              periods: periods,
              classroomId: _classroomId,
              periodId: _periodId,
              onClassroomChanged: (id) =>
                  setState(() => _classroomId = id),
              onPeriodChanged: (id) => setState(() => _periodId = id),
            ),
            const SizedBox(height: 16),
          ],
          if (query == null)
            const EmptyState(
              title: 'Sélectionnez une classe et une période',
              message: 'Ces informations sont requises pour afficher le bulletin.',
              icon: Icons.filter_list,
            )
          else
            ref.watch(bulletinProvider(query)).when(
                  data: (b) => _BulletinView(bulletin: b),
                  loading: () =>
                      const AppLoading(label: 'Chargement du bulletin…'),
                  error: (e, _) => AppErrorWidget(
                    message: e.toString(),
                    onRetry: () => ref.invalidate(bulletinProvider(query)),
                  ),
                ),
        ],
      ),
    );
  }
}

/// Sélecteurs classe + période (affichés si les valeurs n'ont pas été passées
/// en query params par la page appelante).
class _BulletinSelectors extends StatelessWidget {
  const _BulletinSelectors({
    required this.classrooms,
    required this.periods,
    required this.classroomId,
    required this.periodId,
    required this.onClassroomChanged,
    required this.onPeriodChanged,
  });

  final AsyncValue<List<ClassroomDto>> classrooms;
  final AsyncValue<List<PeriodDto>> periods;
  final int? classroomId;
  final int? periodId;
  final ValueChanged<int?> onClassroomChanged;
  final ValueChanged<int?> onPeriodChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(child: _buildClassroomField()),
            const SizedBox(width: 12),
            Expanded(child: _buildPeriodField()),
          ],
        ),
      ),
    );
  }

  Widget _buildClassroomField() {
    return classrooms.when(
      data: (list) {
        if (list.isEmpty) {
          return const _DisabledField(label: 'Classe', hint: 'Aucune classe');
        }
        final selected =
            list.firstWhereOrNull((c) => c.id == classroomId) ?? list.first;
        return DropdownButtonFormField<ClassroomDto>(
          value: selected,
          decoration: const InputDecoration(
            labelText: 'Classe',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: list
              .map((c) => DropdownMenuItem(
                    value: c,
                    child: Text(c.name, overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
          onChanged: (c) => onClassroomChanged(c?.id),
        );
      },
      loading: () => const LinearProgressIndicator(minHeight: 56),
      error: (e, _) => _DisabledField(label: 'Classe', hint: 'Erreur : $e'),
    );
  }

  Widget _buildPeriodField() {
    return periods.when(
      data: (list) {
        if (list.isEmpty) {
          return const _DisabledField(label: 'Période', hint: 'Aucune période');
        }
        final selected =
            list.firstWhereOrNull((p) => p.id == periodId) ?? list.first;
        return DropdownButtonFormField<PeriodDto>(
          value: selected,
          decoration: const InputDecoration(
            labelText: 'Période',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: list
              .map((p) => DropdownMenuItem(
                    value: p,
                    child: Text(p.name, overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
          onChanged: (p) => onPeriodChanged(p?.id),
        );
      },
      loading: () => const LinearProgressIndicator(minHeight: 56),
      error: (e, _) => _DisabledField(label: 'Période', hint: 'Erreur : $e'),
    );
  }
}

class _BulletinView extends StatelessWidget {
  const _BulletinView({required this.bulletin});
  final BulletinDto bulletin;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
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
                          if (bulletin.matricule != null &&
                              bulletin.matricule!.isNotEmpty)
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
                value: GradeFormatter.format(bulletin.overallAverage),
                icon: Icons.school,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _KpiTile(
                label: 'Rang',
                value: (bulletin.rank != null &&
                        bulletin.totalStudents != null)
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
              '${bulletin.subjects.length} matière(s) — coefficient total ${_totalCoef(bulletin.subjects)}',
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
        if (bulletin.appreciation != null &&
            bulletin.appreciation!.isNotEmpty) ...[
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
        const SizedBox(height: 24),
      ],
    );
  }

  int _totalCoef(List<BulletinSubjectDto> subjects) {
    int s = 0;
    for (final sub in subjects) {
      if (!sub.isFacultative) s += sub.coefficient;
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
          Expanded(flex: 3, child: Text('Moy. classe', style: style, textAlign: TextAlign.center)),
        ],
      ),
    );
  }
}

class _SubjectRow extends StatefulWidget {
  const _SubjectRow({required this.subject});
  final BulletinSubjectDto subject;

  @override
  State<_SubjectRow> createState() => _SubjectRowState();
}

class _SubjectRowState extends State<_SubjectRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.subject;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: s.assessments.isEmpty
              ? null
              : () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  flex: 4,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(s.subjectName,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600)),
                          ),
                          if (s.isFacultative)
                            Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.tertiaryContainer,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'Fac.',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color:
                                      theme.colorScheme.onTertiaryContainer,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (s.subjectCode != null && s.subjectCode!.isNotEmpty)
                        Text(s.subjectCode!,
                            style: theme.textTheme.bodySmall),
                      if (s.teacher != null && s.teacher!.isNotEmpty)
                        Text('Ens. ${s.teacher}',
                            style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    '${s.coefficient}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    GradeFormatter.format(s.average),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.primary),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    s.moyenneClasse == null
                        ? '—'
                        : s.moyenneClasse!.toStringAsFixed(2),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (s.assessments.isNotEmpty)
                  Icon(
                    _expanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    color: theme.colorScheme.onSurfaceVariant,
                    size: 20,
                  ),
              ],
            ),
          ),
        ),
        if (_expanded && s.assessments.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Column(
                children: [
                  ...s.assessments.map((a) => _AssessmentLine(a: a)),
                ],
              ),
            ),
          ),
        ],
        const Divider(height: 16),
      ],
    );
  }
}

class _AssessmentLine extends StatelessWidget {
  const _AssessmentLine({required this.a});
  final BulletinAssessmentDto a;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = DateFormatter.parse(a.date);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a.name.isEmpty ? '(sans nom)' : a.name,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(fontWeight: FontWeight.w500)),
                if (a.type.isNotEmpty)
                  Text(a.type,
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              a.isAbsent
                  ? 'Absent'
                  : (a.value == null
                      ? '—'
                      : '${a.value!.toStringAsFixed(2)} / ${a.maxScore.toStringAsFixed(0)}'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: a.isAbsent ? Colors.red.shade400 : null,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              date == null ? '—' : DateFormatter.date(date),
              textAlign: TextAlign.end,
              style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _DisabledField extends StatelessWidget {
  const _DisabledField({required this.label, required this.hint});
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return TextField(
      enabled: false,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }
}
