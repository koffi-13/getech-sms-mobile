/// Page « Classement » : sélection classe + période → tableau des
/// [RankingRowDto] (rang, élève, moyenne, progression vs période précédente,
/// appréciation). Les 3 premiers sont mis en couleur.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_state.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/permissions.dart';
import '../../core/config/constants.dart';
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

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(connectionProvider);
    final classrooms = ref.watch(classroomsForGradesProvider);
    final periods = ref.watch(periodsProvider);

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
                Row(
                  children: [
                    Expanded(
                      child: classrooms.when(
                        data: (list) {
                          if (list.isEmpty) {
                            return const _DisabledField(
                                label: 'Classe', hint: 'Aucune classe');
                          }
                          if (_classroomId == null ||
                              !list.any((c) => c.id == _classroomId)) {
                            _classroomId = list.first.id;
                          }
                          return DropdownButtonFormField<ClassroomDto>(
                            value: list.firstWhere((c) => c.id == _classroomId),
                            decoration: const InputDecoration(
                              labelText: 'Classe',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            items: list
                                .map((c) => DropdownMenuItem(
                                      value: c,
                                      child: Text(c.name),
                                    ))
                                .toList(),
                            onChanged: (c) =>
                                setState(() => _classroomId = c?.id),
                          );
                        },
                        loading: () =>
                            const LinearProgressIndicator(minHeight: 56),
                        error: (e, _) => _DisabledField(
                            label: 'Classe', hint: 'Erreur : $e'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: periods.when(
                        data: (list) {
                          if (list.isEmpty) {
                            return const _DisabledField(
                                label: 'Période', hint: 'Aucune période');
                          }
                          // Auto-sélection de la période active, sinon la 1re.
                          if (_periodId == null ||
                              !list.any((p) => p.id == _periodId)) {
                            _periodId = list
                                .firstWhere((p) => p.isActive,
                                    orElse: () => list.first)
                                .id;
                          }
                          return DropdownButtonFormField<PeriodDto>(
                            value: list.firstWhere((p) => p.id == _periodId),
                            decoration: const InputDecoration(
                              labelText: 'Période',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            items: list
                                .map((p) => DropdownMenuItem(
                                      value: p,
                                      child: Text(p.name),
                                    ))
                                .toList(),
                            onChanged: (p) =>
                                setState(() => _periodId = p?.id),
                          );
                        },
                        loading: () =>
                            const LinearProgressIndicator(minHeight: 56),
                        error: (e, _) => _DisabledField(
                            label: 'Période', hint: 'Erreur : $e'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                if (_classroomId != null && _periodId != null)
                  ref
                      .watch(rankingProvider(RankingQuery(
                        classroomId: _classroomId!,
                        periodId: _periodId!,
                      )))
                      .when(
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
                                .map((r) => _RankingRow(row: r))
                                .toList(),
                          );
                        },
                        loading: () => const AppLoading(
                            label: 'Calcul du classement…'),
                        error: (e, _) => AppErrorWidget(
                          message: e.toString(),
                          onRetry: () => ref.invalidate(rankingProvider(
                              RankingQuery(
                                  classroomId: _classroomId!,
                                  periodId: _periodId!))),
                        ),
                      )
                else
                  const EmptyState(
                    title: 'Sélectionnez une classe et une période',
                    icon: Icons.filter_list,
                  ),
              ],
            ),
    );
  }
}

class _RankingRow extends StatelessWidget {
  const _RankingRow({required this.row});
  final RankingRowDto row;

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

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push('/grades/bulletin/${row.studentId}'),
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
                    if (row.matricule != null)
                      Text(row.matricule!,
                          style: Theme.of(context).textTheme.bodySmall),
                    if (row.appreciation != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        row.appreciation!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              fontStyle: FontStyle.italic,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Progression vs période précédente
              if (row.previousAverage != null)
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
