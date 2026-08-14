/// Page « Classement » : sélection classe + période (+ mode optionnel
/// PERIOD/SUBJECT et matière si SUBJECT) → tableau des [RankingRowDto]
/// (rang, élève, matricule, moyenne, progression vs période précédente,
/// moyenne annuelle). Les 3 premiers sont mis en couleur.
///
/// Tap sur une ligne → push `/grades/bulletin/$studentId?classroom_id=&period_id=`.
library;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_state.dart';
import '../../core/config/constants.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/permissions.dart';
import '../../features/connections/connection_state.dart';
import '../../shared/models/classroom_dto.dart';
import '../../shared/models/grade_dto.dart';
import '../../shared/widgets/widgets.dart';
import 'grade_controller.dart';

class RankingPage extends ConsumerWidget {
  const RankingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    if (!hasPermission(auth.permissions, RbacPermissions.gradeRead)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Classement')),
        body: const EmptyState(
          title: 'Permission insuffisante',
          message: 'Vous n\'avez pas accès au classement (GRADE_READ).',
          icon: Icons.lock_outline,
        ),
      );
    }
    return const _RankingBody();
  }
}

class _RankingBody extends ConsumerStatefulWidget {
  const _RankingBody();

  @override
  ConsumerState<_RankingBody> createState() => _RankingBodyState();
}

class _RankingBodyState extends ConsumerState<_RankingBody> {
  int? _classroomId;
  int? _periodId;
  RankingMode _mode = RankingMode.period;
  int? _subjectId;

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(connectionProvider);
    final classrooms = ref.watch(classroomsForGradesProvider);
    final periods = ref.watch(periodsProvider);
    final subjects = _classroomId == null
        ? null
        : ref.watch(classSubjectsProvider(_classroomId!));

    // Auto-sélection de la première classe/période si non choisie.
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

    final query = (_classroomId != null && _periodId != null)
        ? RankingQuery(
            classroomId: _classroomId!,
            periodId: _periodId!,
            rankingMode: _mode,
            subjectId: _mode == RankingMode.subject ? _subjectId : null,
          )
        : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Classement')),
      body: !conn.canReachServer
          ? const EmptyState(
              title: 'Hors-ligne',
              message: 'Le classement nécessite une connexion au serveur.',
              icon: Icons.cloud_off,
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _FiltersCard(
                  classrooms: classrooms,
                  periods: periods,
                  subjects: subjects,
                  classroomId: _classroomId,
                  periodId: _periodId,
                  mode: _mode,
                  subjectId: _subjectId,
                  onClassroomChanged: (id) => setState(() {
                    _classroomId = id;
                    _subjectId = null;
                  }),
                  onPeriodChanged: (id) => setState(() => _periodId = id),
                  onModeChanged: (m) => setState(() => _mode = m),
                  onSubjectChanged: (id) => setState(() => _subjectId = id),
                ),
                const SizedBox(height: 16),
                if (query == null)
                  const EmptyState(
                    title: 'Sélectionnez une classe et une période',
                    icon: Icons.filter_list,
                  )
                else if (_mode == RankingMode.subject && _subjectId == null)
                  const EmptyState(
                    title: 'Sélectionnez une matière',
                    message:
                        'Le mode SUBJECT nécessite une matière spécifique.',
                    icon: Icons.book_outlined,
                  )
                else
                  ref.watch(rankingProvider(query)).when(
                        data: (rows) {
                          if (rows.isEmpty) {
                            return const EmptyState(
                              title: 'Aucun élève classé',
                              message:
                                  'Aucune note n\'a été saisie pour cette classe/période.',
                              icon: Icons.leaderboard_outlined,
                            );
                          }
                          return Column(
                            children: rows
                                .map((r) => _RankingRow(
                                      row: r,
                                      classroomId: _classroomId!,
                                      periodId: _periodId!,
                                    ))
                                .toList(),
                          );
                        },
                        loading: () => const AppLoading(
                            label: 'Calcul du classement…'),
                        error: (e, _) => AppErrorWidget(
                          message: e.toString(),
                          onRetry: () => ref.invalidate(rankingProvider(query)),
                        ),
                      ),
              ],
            ),
    );
  }
}

/// Carte des filtres : classe + période + mode + matière (si SUBJECT).
class _FiltersCard extends StatelessWidget {
  const _FiltersCard({
    required this.classrooms,
    required this.periods,
    required this.subjects,
    required this.classroomId,
    required this.periodId,
    required this.mode,
    required this.subjectId,
    required this.onClassroomChanged,
    required this.onPeriodChanged,
    required this.onModeChanged,
    required this.onSubjectChanged,
  });

  final AsyncValue<List<ClassroomDto>> classrooms;
  final AsyncValue<List<PeriodDto>> periods;
  final AsyncValue<List<ClassSubjectDto>>? subjects;
  final int? classroomId;
  final int? periodId;
  final RankingMode mode;
  final int? subjectId;
  final ValueChanged<int?> onClassroomChanged;
  final ValueChanged<int?> onPeriodChanged;
  final ValueChanged<RankingMode> onModeChanged;
  final ValueChanged<int?> onSubjectChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: _buildClassroomField(),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildPeriodField(),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SegmentedButton<RankingMode>(
              segments: const [
                ButtonSegment(
                  value: RankingMode.period,
                  label: Text('Période'),
                  icon: Icon(Icons.calendar_view_week, size: 16),
                ),
                ButtonSegment(
                  value: RankingMode.subject,
                  label: Text('Matière'),
                  icon: Icon(Icons.book, size: 16),
                ),
              ],
              selected: {mode},
              onSelectionChanged: (s) => onModeChanged(s.first),
            ),
            if (mode == RankingMode.subject) ...[
              const SizedBox(height: 12),
              _buildSubjectField(),
            ],
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

  Widget _buildSubjectField() {
    final async = subjects;
    if (async == null || classroomId == null) {
      return const _DisabledField(
          label: 'Matière', hint: 'Sélectionnez une classe d\'abord.');
    }
    return async.when(
      data: (list) {
        if (list.isEmpty) {
          return const _DisabledField(
              label: 'Matière', hint: 'Aucune matière');
        }
        final selected =
            list.firstWhereOrNull((s) => s.id == subjectId) ?? list.first;
        // Auto-sélection de la première matière.
        if (selected.id != subjectId) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            onSubjectChanged(selected.id);
          });
        }
        return DropdownButtonFormField<ClassSubjectDto>(
          value: selected,
          decoration: const InputDecoration(
            labelText: 'Matière',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: list
              .map((s) => DropdownMenuItem(
                    value: s,
                    child: Text('${s.subjectName} (coef. ${s.coefficient})',
                        overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
          onChanged: (s) => onSubjectChanged(s?.id),
        );
      },
      loading: () =>
          const Padding(padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator()),
      error: (e, _) => _DisabledField(label: 'Matière', hint: 'Erreur : $e'),
    );
  }
}

class _RankingRow extends StatelessWidget {
  const _RankingRow({
    required this.row,
    required this.classroomId,
    required this.periodId,
  });

  final RankingRowDto row;
  final int classroomId;
  final int periodId;

  Color? _rankColor(BuildContext context) {
    switch (row.rank) {
      case 1:
        return Colors.amber.shade700; // Or
      case 2:
        return Colors.blueGrey.shade400; // Argent
      case 3:
        return Colors.brown.shade400; // Bronze
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final rankColor = _rankColor(context);
    final prog = row.progression;
    final progUp = prog > 0;
    final progDown = prog < 0;
    final hasPrevious = row.previousPeriodAverages.isNotEmpty;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push(
          '/grades/bulletin/${row.studentId}'
          '?classroom_id=$classroomId&period_id=$periodId',
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              // Rang
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: rankColor?.withValues(alpha: 0.18) ??
                      Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withValues(alpha: 0.4),
                  shape: BoxShape.circle,
                  border: rankColor != null
                      ? Border.all(color: rankColor, width: 1.5)
                      : null,
                ),
                alignment: Alignment.center,
                child: Text(
                  '${row.rank}',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: rankColor,
                      ),
                ),
              ),
              const SizedBox(width: 12),
              // Élève
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(row.studentName,
                        style: Theme.of(context).textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    if (row.matricule != null &&
                        row.matricule!.isNotEmpty)
                      Text(row.matricule!,
                          style: Theme.of(context).textTheme.bodySmall),
                    if (row.annualAverage != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Annuelle : ${row.annualAverage!.toStringAsFixed(2)}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Progression vs période précédente
              if (hasPrevious)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        progUp
                            ? Icons.arrow_upward
                            : progDown
                                ? Icons.arrow_downward
                                : Icons.remove,
                        size: 14,
                        color: progUp
                            ? Colors.green
                            : progDown
                                ? Colors.red.shade400
                                : Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        prog.abs().toStringAsFixed(2),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: progUp
                                  ? Colors.green
                                  : progDown
                                      ? Colors.red.shade400
                                      : Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ],
                  ),
                ),
              // Moyenne
              Text(
                GradeFormatter.format(row.average),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.primary,
                    ),
              ),
            ],
          ),
        ),
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
