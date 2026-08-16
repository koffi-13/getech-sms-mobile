/// Page « Classement » : sélection classe + période (+ mode optionnel
/// PERIOD/SUBJECT et matière si SUBJECT) → tableau des [RankingRowDto]
/// (rang avec médailles pour le top 3, élève + sexe + matricule, moyenne
/// colorée, badge de mention via [MentionHelper], moyenne de classe,
/// progression vs période précédente, moyenne annuelle, détail des
/// périodes précédentes dépliable).
///
/// En-tête de synthèse : moyenne de classe, effectif, taux de réussite
/// (% d'élèves avec moyenne ≥ 10).
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
import 'grade_utils.dart';

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
                            children: [
                              _RankingSummary(rows: rows),
                              const SizedBox(height: 16),
                              ...rows
                                  .asMap()
                                  .entries
                                  .map((entry) => _RankingRow(
                                        row: entry.value,
                                        rank: entry.key + 1,
                                        classroomId: _classroomId!,
                                        periodId: _periodId!,
                                      ))
                                  .toList(),
                            ],
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

/// En-tête de synthèse : moyenne de classe, effectif, taux de réussite.
class _RankingSummary extends StatelessWidget {
  const _RankingSummary({required this.rows});
  final List<RankingRowDto> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final averages =
        rows.map((r) => r.average).whereType<double>().toList();
    final classAvg = averages.isEmpty
        ? null
        : averages.reduce((a, b) => a + b) / averages.length;
    final passing = averages.where((a) => a >= 10).length;
    final passRate =
        averages.isEmpty ? 0.0 : (passing / averages.length) * 100;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: _SummaryStat(
                icon: Icons.groups,
                label: 'Effectif',
                value: '${rows.length}',
                color: theme.colorScheme.primary,
              ),
            ),
            Container(
                width: 1,
                height: 40,
                color: theme.dividerColor.withValues(alpha: 0.5)),
            Expanded(
              child: _SummaryStat(
                icon: Icons.insights,
                label: 'Moy. classe',
                value:
                    classAvg == null ? '—' : classAvg.toStringAsFixed(2),
                color: MentionHelper.color(classAvg),
              ),
            ),
            Container(
                width: 1,
                height: 40,
                color: theme.dividerColor.withValues(alpha: 0.5)),
            Expanded(
              child: _SummaryStat(
                icon: Icons.check_circle_outline,
                label: 'Réussite',
                value: '${passRate.toStringAsFixed(0)} %',
                color: passRate >= 50
                    ? const Color(0xFF10B981)
                    : const Color(0xFFEF4444),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryStat extends StatelessWidget {
  const _SummaryStat({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(height: 6),
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
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
                  label: Text('Moyenne globale'),
                  icon: Icon(Icons.calendar_view_week, size: 16),
                ),
                ButtonSegment(
                  value: RankingMode.subject,
                  label: Text('Par matière'),
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

/// Ligne de classement : rang (médaille top 3), élève + matricule + sexe,
/// moyenne (colorée par mention) + badge mention, moyenne de classe,
/// progression vs dernière période précédente, moyenne annuelle, détail
/// dépliable des périodes précédentes.
class _RankingRow extends StatefulWidget {
  const _RankingRow({
    required this.row,
    required this.rank,
    required this.classroomId,
    required this.periodId,
  });

  final RankingRowDto row;
  final int rank;
  final int classroomId;
  final int periodId;

  @override
  State<_RankingRow> createState() => _RankingRowState();
}

class _RankingRowState extends State<_RankingRow> {
  bool _expanded = false;

  Color? _rankColor(BuildContext context) {
    switch (widget.rank) {
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

  String? get _medal {
    switch (widget.rank) {
      case 1:
        return '🥇';
      case 2:
        return '🥈';
      case 3:
        return '🥉';
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = widget.row;
    final rankColor = _rankColor(context);
    final prog = row.progression;
    final progUp = prog > 0;
    final progDown = prog < 0;
    final hasPrevious = row.previousPeriodAverages.isNotEmpty;
    final mentionColor = MentionHelper.color(row.average);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push(
          '/grades/bulletin/${row.studentId}'
          '?classroom_id=${widget.classroomId}&period_id=${widget.periodId}',
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  // Rang (médaille top 3)
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: rankColor?.withValues(alpha: 0.18) ??
                          theme.colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.4),
                      shape: BoxShape.circle,
                      border: rankColor != null
                          ? Border.all(color: rankColor, width: 1.5)
                          : null,
                    ),
                    alignment: Alignment.center,
                    child: _medal != null
                        ? Text(_medal!, style: const TextStyle(fontSize: 20))
                        : Text(
                            '${widget.rank}',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: rankColor,
                            ),
                          ),
                  ),
                  const SizedBox(width: 12),
                  // Élève + matricule + sexe
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                row.studentName,
                                style: theme.textTheme.titleSmall,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (row.sexe != null &&
                                row.sexe!.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              _SexeBadge(sexe: row.sexe!),
                            ],
                          ],
                        ),
                        if (row.matricule != null &&
                            row.matricule!.isNotEmpty)
                          Text(row.matricule!,
                              style: theme.textTheme.bodySmall),
                        if (row.classAvg != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            'Moy. classe : ${row.classAvg!.toStringAsFixed(2)}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
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
                                    : theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            prog.abs().toStringAsFixed(2),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: progUp
                                  ? Colors.green
                                  : progDown
                                      ? Colors.red.shade400
                                      : theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  // Moyenne + mention
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        row.average == null
                            ? '—'
                            : '${row.average!.toStringAsFixed(2)} / 20',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: mentionColor,
                        ),
                      ),
                      const SizedBox(height: 2),
                      _MentionBadge(average: row.average),
                    ],
                  ),
                ],
              ),
              // Ligne secondaire : moyenne annuelle + bouton expand
              if (row.annualAverage != null || hasPrevious) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (row.annualAverage != null)
                      Text(
                        'Annuelle : ${row.annualAverage!.toStringAsFixed(2)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    const Spacer(),
                    if (hasPrevious)
                      InkWell(
                        onTap: () =>
                            setState(() => _expanded = !_expanded),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${row.previousPeriodAverages.length} période(s) précédente(s)',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.primary,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                              Icon(
                                _expanded
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                                size: 16,
                                color: theme.colorScheme.primary,
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
                if (_expanded && hasPrevious) ...[
                  const SizedBox(height: 4),
                  _PreviousPeriodsList(entries: row.previousPeriodAverages),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Badge coloré du sexe (M bleu, F rose).
class _SexeBadge extends StatelessWidget {
  const _SexeBadge({required this.sexe});
  final String sexe;

  @override
  Widget build(BuildContext context) {
    final isMale = sexe.toUpperCase() == 'M';
    final color =
        isMale ? const Color(0xFF3B82F6) : const Color(0xFFEC4899);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        sexe.toUpperCase(),
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Badge de mention basé sur [MentionHelper] (couleurs cohérentes partout).
class _MentionBadge extends StatelessWidget {
  const _MentionBadge({required this.average});
  final double? average;

  @override
  Widget build(BuildContext context) {
    final color = MentionHelper.color(average);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: MentionHelper.backgroundColor(average),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        MentionHelper.mention(average),
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Liste dépliable des moyennes des périodes précédentes.
class _PreviousPeriodsList extends StatelessWidget {
  const _PreviousPeriodsList({required this.entries});
  final Map<int, double> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sorted = entries.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: sorted
            .map((e) => Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 4, vertical: 2),
                  child: Row(
                    children: [
                      Icon(Icons.history,
                          size: 12, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Text('Période #${e.key}',
                          style: theme.textTheme.bodySmall),
                      const Spacer(),
                      Text(
                        e.value.toStringAsFixed(2),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: MentionHelper.color(e.value),
                        ),
                      ),
                    ],
                  ),
                ))
            .toList(),
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
