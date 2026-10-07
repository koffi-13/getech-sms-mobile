/// Grille hebdomadaire de l'emploi du temps — widget réutilisable partagé par
/// la page Emploi du temps et l'onglet EDT du détail d'une classe.
///
/// Deux modes d'affichage (miroir du desktop `ScheduleGrid`) :
/// - [ScheduleDisplayMode.classroom] : L1 = matière, L2 = enseignant, L3 = salle ;
/// - [ScheduleDisplayMode.teacher] : L1 = classe, L2 = matière, L3 = salle.
///
/// Chaque cours affiche un badge « A »/« B » si les semaines alternées sont
/// actives. Les colonnes sont les jours Lundi→Samedi, les cartes triées par
/// heure de début (les créneaux horaires de l'établissement n'étant pas
/// exposés par l'API de base, la grille est déduite des entrées elles-mêmes).
library;

import 'package:flutter/material.dart';

import '../../core/config/constants.dart';
import '../../shared/models/attendance_dto.dart';

/// Mode d'affichage de la grille.
enum ScheduleDisplayMode { classroom, teacher }

class ScheduleGridView extends StatelessWidget {
  const ScheduleGridView({
    super.key,
    required this.schedule,
    this.mode = ScheduleDisplayMode.classroom,
    this.showWeekBadge = true,
    this.onEntryTap,
    this.compact = false,
  });

  /// Entrées déjà filtrées sur la semaine voulue par l'appelant.
  final List<WeeklyScheduleDto> schedule;

  /// Mode d'affichage (classe ou enseignant).
  final ScheduleDisplayMode mode;

  /// Affiche le badge A/B sur chaque carte.
  final bool showWeekBadge;

  /// Tap sur une carte de cours (détail / édition).
  final void Function(WeeklyScheduleDto entry)? onEntryTap;

  /// Mode compact (onglet EDT du détail de classe).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final byDay = <SchoolDay, List<WeeklyScheduleDto>>{};
    for (final s in schedule) {
      final day = s.day;
      if (day == null) continue;
      byDay.putIfAbsent(day, () => []).add(s);
    }
    for (final day in byDay.keys) {
      byDay[day]!.sort((a, b) {
        final c = a.startTime.compareTo(b.startTime);
        if (c != 0) return c;
        return (a.subjectName ?? '').compareTo(b.subjectName ?? '');
      });
    }

    final todayIndex = DateTime.now().weekday; // 1..7 (ISO)

    return Scrollbar(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: SchoolDay.values.map((d) {
            final list = byDay[d] ?? const <WeeklyScheduleDto>[];
            final isToday = d.dayIndex == todayIndex;
            return Container(
              width: compact ? 168 : 184,
              margin: const EdgeInsets.only(right: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    color: isToday
                        ? Theme.of(context).colorScheme.tertiaryContainer
                        : Theme.of(context).colorScheme.primaryContainer,
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      child: Text(
                        d.label,
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(
                              color: isToday
                                  ? Theme.of(context)
                                      .colorScheme
                                      .onTertiaryContainer
                                  : Theme.of(context)
                                      .colorScheme
                                      .onPrimaryContainer,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (list.isEmpty)
                    Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          'Libre',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    )
                  else
                    ...list.map((s) => ScheduleEntryCard(
                          entry: s,
                          mode: mode,
                          showWeekBadge: showWeekBadge,
                          compact: compact,
                          onTap: onEntryTap == null ? null : () => onEntryTap!(s),
                        )),
                ],
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

/// Carte d'un cours planifié.
class ScheduleEntryCard extends StatelessWidget {
  const ScheduleEntryCard({
    super.key,
    required this.entry,
    this.mode = ScheduleDisplayMode.classroom,
    this.showWeekBadge = true,
    this.compact = false,
    this.onTap,
  });

  final WeeklyScheduleDto entry;
  final ScheduleDisplayMode mode;
  final bool showWeekBadge;
  final bool compact;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = mode == ScheduleDisplayMode.teacher
        ? (entry.classroomName ?? '—')
        : (entry.subjectName ?? '—');
    final subtitle = mode == ScheduleDisplayMode.teacher
        ? entry.subjectName
        : entry.teacherName;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(compact ? 10 : 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.schedule,
                      size: 14, color: theme.colorScheme.primary),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '${entry.startTime} – ${entry.endTime}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (showWeekBadge && !entry.isAllWeeks)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: entry.weekType == WeekType.b
                            ? Colors.indigo.withValues(alpha: 0.14)
                            : Colors.teal.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        entry.weekType == WeekType.b ? 'B' : 'A',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: entry.weekType == WeekType.b
                              ? Colors.indigo.shade700
                              : Colors.teal.shade700,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  if (entry.room != null && entry.room!.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.secondaryContainer
                            .withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        entry.room!,
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Text(
                title,
                style: theme.textTheme.titleSmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (subtitle != null && subtitle.isNotEmpty) ...[
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(
                        mode == ScheduleDisplayMode.teacher
                            ? Icons.book_outlined
                            : Icons.person_outline,
                        size: 12,
                        color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        subtitle,
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
        ),
      ),
    );
  }
}

/// Bottom sheet de détail d'un cours (lecture seule — élèves et autres
/// profils non éditeurs).
Future<void> showScheduleEntryDetails(
  BuildContext context,
  WeeklyScheduleDto entry, {
  ScheduleDisplayMode mode = ScheduleDisplayMode.classroom,
}) {
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              mode == ScheduleDisplayMode.teacher
                  ? (entry.classroomName ?? 'Cours')
                  : (entry.subjectName ?? 'Cours'),
              style: Theme.of(ctx).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            _DetailRow(
                icon: Icons.schedule,
                label: 'Horaire',
                value: '${entry.startTime} – ${entry.endTime}'),
            _DetailRow(
                icon: Icons.calendar_today,
                label: 'Jour',
                value: entry.day?.label ?? '—'),
            if (mode == ScheduleDisplayMode.teacher)
              _DetailRow(
                  icon: Icons.book_outlined,
                  label: 'Matière',
                  value: entry.subjectName ?? '—')
            else
              _DetailRow(
                  icon: Icons.person_outline,
                  label: 'Enseignant',
                  value: entry.teacherName ?? '—'),
            if (entry.classroomName != null &&
                mode == ScheduleDisplayMode.teacher)
              _DetailRow(
                  icon: Icons.school_outlined,
                  label: 'Classe',
                  value: entry.classroomName!),
            if (entry.room != null && entry.room!.isNotEmpty)
              _DetailRow(
                  icon: Icons.place_outlined, label: 'Salle', value: entry.room!),
            _DetailRow(
              icon: Icons.repeat,
              label: 'Semaine',
              value: entry.isAllWeeks
                  ? 'Toutes les semaines'
                  : (entry.weekType == WeekType.b ? 'B' : 'A'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Text(label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bandeau « hors-ligne » du module EDT.
class ScheduleOfflineBanner extends StatelessWidget {
  const ScheduleOfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.cloud_off,
                size: 18, color: Theme.of(context).colorScheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Mode hors-ligne : emploi du temps indisponible.',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
