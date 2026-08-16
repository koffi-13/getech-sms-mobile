/// Page « Bulletin » d'un élève : en-tête (avatar coloré par sexe, élève,
/// classe, période, année, statut), 3 KPI (moyenne générale colorée par
/// mention, rang avec ex-æquo, mention), carte honneurs/distinctions si
/// présente, carte conduite/absences/retards, tableau des matières (matière
/// + code + coef + fac + enseignant + domaine, moyenne colorée + badge
/// mention, note de composition, moyenne de classe, badge « Note importée »
/// si from_previous_grade, détail dépliable des évaluations), appréciation
/// générale, action « Partager / Imprimer » (snackbar — endpoint PDF à venir).
///
/// Si `overall_average` est nul : message « Aucune note pour cette période ».
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
import 'grade_utils.dart';

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
                const SnackBar(
                  content: Text(
                      'Export PDF — fonctionnalité à venir (endpoint serveur requis).'),
                ),
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
    // Cas « aucune note » : moyenne générale nulle.
    if (bulletin.overallAverage == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BulletinHeader(bulletin: bulletin),
          const SizedBox(height: 16),
          const EmptyState(
            title: 'Aucune note pour cette période',
            message:
                'Aucune note n\'a encore été saisie pour cet élève sur la période sélectionnée.',
            icon: Icons.assignment_late_outlined,
          ),
        ],
      );
    }

    final totalCoef = _totalCoef(bulletin.subjects);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // --- En-tête ---
        _BulletinHeader(bulletin: bulletin),
        const SizedBox(height: 16),

        // --- 3 KPI : Moyenne / Rang / Mention ---
        Row(
          children: [
            Expanded(
              flex: 2,
              child: _KpiTile(
                label: 'Moyenne générale',
                value: GradeFormatter.format(bulletin.overallAverage),
                icon: Icons.school,
                color: MentionHelper.color(bulletin.overallAverage),
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
            const SizedBox(width: 12),
            Expanded(
              child: _KpiTile(
                label: 'Mention',
                value: bulletin.mention ??
                    MentionHelper.mention(bulletin.overallAverage),
                icon: Icons.emoji_events_outlined,
                color: MentionHelper.color(bulletin.overallAverage),
                compact: true,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // --- Honneurs / distinctions ---
        if (bulletin.honors != null && bulletin.honors!.hasAny) ...[
          _HonorsCard(honors: bulletin.honors!),
          const SizedBox(height: 16),
        ],

        // --- Conduite / absences / retards ---
        if (bulletin.conduct != null ||
            bulletin.absencesCount != null ||
            bulletin.delaysCount != null) ...[
          _ConductCard(
            conduct: bulletin.conduct,
            absences: bulletin.absencesCount,
            delays: bulletin.delaysCount,
          ),
          const SizedBox(height: 16),
        ],

        // --- Tableau des matières ---
        SectionHeader(
          title: 'Matières',
          icon: Icons.book_outlined,
          subtitle:
              '${bulletin.subjects.length} matière(s) — coefficient total $totalCoef',
        ),
        const SizedBox(height: 8),
        if (bulletin.subjects.isEmpty)
          const EmptyState(
            title: 'Aucune matière',
            message: 'Aucune matière n\'est rattachée à ce bulletin.',
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

        // --- Action partager / imprimer ---
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                    'Export PDF — fonctionnalité à venir (endpoint serveur requis).'),
              ),
            );
          },
          icon: const Icon(Icons.share_outlined),
          label: const Text('Partager / Imprimer'),
        ),
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

/// En-tête du bulletin : avatar coloré par sexe, nom + matricule + sexe +
/// statut, classe, période, année scolaire.
class _BulletinHeader extends StatelessWidget {
  const _BulletinHeader({required this.bulletin});
  final BulletinDto bulletin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isMale = (bulletin.sexe ?? '').toUpperCase() == 'M';
    final avatarColor = bulletin.sexe == null
        ? theme.colorScheme.primaryContainer
        : (isMale
            ? const Color(0xFF3B82F6).withValues(alpha: 0.18)
            : const Color(0xFFEC4899).withValues(alpha: 0.18));
    final avatarFg = bulletin.sexe == null
        ? theme.colorScheme.onPrimaryContainer
        : (isMale ? const Color(0xFF3B82F6) : const Color(0xFFEC4899));
    final initials = bulletin.studentName.isEmpty
        ? '?'
        : bulletin.studentName
            .split(' ')
            .where((s) => s.isNotEmpty)
            .take(2)
            .map((s) => s[0])
            .join('')
            .toUpperCase();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: avatarColor,
                  child: Text(
                    initials,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: avatarFg,
                      fontWeight: FontWeight.w800,
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
                        style: theme.textTheme.titleLarge,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          if (bulletin.matricule != null &&
                              bulletin.matricule!.isNotEmpty)
                            _HeaderChip(
                              icon: Icons.badge_outlined,
                              label: bulletin.matricule!,
                            ),
                          if (bulletin.sexe != null &&
                              bulletin.sexe!.isNotEmpty)
                            _SexeChip(sexe: bulletin.sexe!),
                          if (bulletin.statusLabel != null &&
                              bulletin.statusLabel!.isNotEmpty)
                            _HeaderChip(
                              icon: Icons.flag_outlined,
                              label: bulletin.statusLabel!,
                              color: theme.colorScheme.tertiary,
                            ),
                        ],
                      ),
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
    );
  }
}

class _HeaderChip extends StatelessWidget {
  const _HeaderChip({
    required this.icon,
    required this.label,
    this.color,
  });
  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = color ?? theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _SexeChip extends StatelessWidget {
  const _SexeChip({required this.sexe});
  final String sexe;

  @override
  Widget build(BuildContext context) {
    final isMale = sexe.toUpperCase() == 'M';
    final color =
        isMale ? const Color(0xFF3B82F6) : const Color(0xFFEC4899);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
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
    this.compact = false,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(height: 12),
            Text(
              value,
              style: (compact
                      ? theme.textTheme.titleMedium
                      : theme.textTheme.headlineSmall)
                  ?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: theme.textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// Carte des honneurs/distinctions : primaryLabel avec icône appropriée.
class _HonorsCard extends StatelessWidget {
  const _HonorsCard({required this.honors});
  final BulletinHonorsDto honors;

  IconData get _icon {
    if (honors.honorRoll) return Icons.emoji_events;
    if (honors.congratulations) return Icons.celebration;
    if (honors.encouragement) return Icons.thumb_up_alt_outlined;
    if (honors.warningBlame) return Icons.warning_amber_outlined;
    return Icons.star_outline;
  }

  Color get _color {
    if (honors.honorRoll) return const Color(0xFF10B981);
    if (honors.congratulations) return const Color(0xFF3B82F6);
    if (honors.encouragement) return const Color(0xFFF59E0B);
    if (honors.warningBlame) return const Color(0xFFEF4444);
    return Colors.grey;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = honors.primaryLabel ?? 'Distinction';
    final color = _color;
    return Card(
      color: color.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.18),
                shape: BoxShape.circle,
              ),
              child: Icon(_icon, size: 22, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (honors.absencesCount > 0 ||
                      honors.delaysCount > 0) ...[
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (honors.absencesCount > 0)
                          '${honors.absencesCount} absence(s)',
                        if (honors.delaysCount > 0)
                          '${honors.delaysCount} retard(s)',
                      ].join(' • '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Carte conduite / absences / retards.
class _ConductCard extends StatelessWidget {
  const _ConductCard({
    required this.conduct,
    required this.absences,
    required this.delays,
  });

  final String? conduct;
  final int? absences;
  final int? delays;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasStats = absences != null || delays != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.rule_outlined,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Conduite & assiduité',
                    style: theme.textTheme.titleSmall),
              ],
            ),
            if (hasStats) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  if (absences != null) ...[
                    Expanded(
                      child: _AttendanceStat(
                        icon: Icons.event_busy,
                        label: 'Absences',
                        value: '$absences',
                        color: absences! > 0
                            ? const Color(0xFFEF4444)
                            : const Color(0xFF10B981),
                      ),
                    ),
                    if (delays != null) const SizedBox(width: 12),
                  ],
                  if (delays != null)
                    Expanded(
                      child: _AttendanceStat(
                        icon: Icons.schedule,
                        label: 'Retards',
                        value: '$delays',
                        color: delays! > 0
                            ? const Color(0xFFF59E0B)
                            : const Color(0xFF10B981),
                      ),
                    ),
                ],
              ),
            ],
            if (conduct != null && conduct!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  conduct!,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AttendanceStat extends StatelessWidget {
  const _AttendanceStat({
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
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 16, color: color),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(value,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: color,
                  )),
              Text(label, style: theme.textTheme.labelSmall),
            ],
          ),
        ),
      ],
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
          Expanded(flex: 3, child: Text('Moy. / Mention', style: style, textAlign: TextAlign.center)),
          Expanded(flex: 3, child: Text('Moy. classe', style: style, textAlign: TextAlign.center)),
        ],
      ),
    );
  }
}

/// Ligne matière : nom + code + badges (coef, fac., importée, domaine),
/// enseignant, moyenne colorée + badge mention, note de composition,
/// moyenne de classe, détail dépliable des évaluations.
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
    final mentionColor = MentionHelper.color(s.average);
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
                            _MiniBadge(
                              label: 'Fac.',
                              color: theme.colorScheme.tertiary,
                            ),
                          if (s.isFromPreviousGrade)
                            Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: _MiniBadge(
                                label: 'Note importée',
                                color: Colors.purple,
                              ),
                            ),
                        ],
                      ),
                      Wrap(
                        spacing: 6,
                        runSpacing: 2,
                        children: [
                          if (s.subjectCode != null &&
                              s.subjectCode!.isNotEmpty)
                            Text(s.subjectCode!,
                                style: theme.textTheme.bodySmall),
                          if (s.domain != null && s.domain!.isNotEmpty)
                            _InfoChip(s.domain!),
                          if (s.teacher != null && s.teacher!.isNotEmpty)
                            _InfoChip('Ens. ${s.teacher}'),
                        ],
                      ),
                      if (s.noteComposition != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          'Composition : ${s.noteComposition!.toStringAsFixed(2)} / 20',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color:
                            theme.colorScheme.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${s.coefficient}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Column(
                    children: [
                      Text(
                        GradeFormatter.format(s.average),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w700, color: mentionColor),
                      ),
                      const SizedBox(height: 2),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: MentionHelper.backgroundColor(s.average),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          MentionHelper.mention(s.average),
                          style: TextStyle(
                            color: mentionColor,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    s.classAverage == null
                        ? '—'
                        : s.classAverage!.toStringAsFixed(2),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (s.assessments.isNotEmpty)
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
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

class _MiniBadge extends StatelessWidget {
  const _MiniBadge({
    required this.label,
    required this.color,
  });
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
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
