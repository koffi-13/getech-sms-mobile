/// Page « Emploi du temps » : sélecteur de classe + bascule de semaine A/B
/// et grille hebdomadaire horizontale (6 colonnes Lundi..Samedi).
///
/// Affiche une bannière hors-ligne lorsque le serveur est injoignable et un
/// [EmptyState] lorsque l'emploi du temps est vide.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/constants.dart';
import '../../features/connections/connection_state.dart';
import '../../shared/models/attendance_dto.dart';
import '../../shared/widgets/widgets.dart';
import 'schedule_controller.dart';

class SchedulePage extends ConsumerStatefulWidget {
  const SchedulePage({super.key});

  @override
  ConsumerState<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends ConsumerState<SchedulePage> {
  int? _classroomId;
  WeekType _weekType = WeekType.a;

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(connectionProvider);
    final classrooms = ref.watch(classroomsForScheduleProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Emploi du temps'),
        actions: [
          if (!conn.canReachServer)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: StatusBadge.offline(),
            ),
        ],
      ),
      body: Column(
        children: [
          if (!conn.canReachServer) _offlineBanner(context),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: classrooms.when(
                    data: (list) {
                      if (list.isEmpty) {
                        return const Text('Aucune classe disponible.');
                      }
                      // Auto-sélection de la première classe.
                      if (_classroomId == null ||
                          !list.any((c) => c.id == _classroomId)) {
                        _classroomId = list.first.id;
                      }
                      return DropdownButtonFormField<int>(
                        value: _classroomId,
                        decoration: const InputDecoration(
                          labelText: 'Classe',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: list
                            .map((c) => DropdownMenuItem(
                                  value: c.id,
                                  child: Text(c.name),
                                ))
                            .toList(),
                        onChanged: (v) => setState(() => _classroomId = v),
                      );
                    },
                    loading: () => const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: LinearProgressIndicator(),
                    ),
                    error: (e, _) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'Erreur : $e',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                _weekToggle(context),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: _classroomId == null
                ? const EmptyState(
                    title: 'Sélectionnez une classe',
                    message: 'Choisissez une classe pour afficher son emploi du temps.',
                    icon: Icons.school_outlined,
                  )
                : (!conn.canReachServer
                    ? const EmptyState(
                        title: 'Hors-ligne',
                        message:
                            'Connectez-vous au serveur pour charger l\'emploi du temps.',
                        icon: Icons.cloud_off,
                      )
                    : ref
                        .watch(weeklyScheduleProvider(ScheduleQuery(
                          classroomId: _classroomId!,
                          weekType: _weekType,
                        )))
                        .when(
                          data: (list) => list.isEmpty
                              ? EmptyState(
                                  title: 'Aucun cours programmé',
                                  message:
                                      'L\'emploi du temps de cette classe est vide pour la semaine ${_weekType == WeekType.a ? 'A' : 'B'}.',
                                  icon: Icons.event_busy,
                                )
                              : _ScheduleGrid(schedule: list),
                          loading: () => const AppLoading(
                              label: 'Chargement de l\'emploi du temps…'),
                          error: (e, _) => AppErrorWidget(
                            message: e.toString(),
                            onRetry: () => ref.invalidate(
                                weeklyScheduleProvider(ScheduleQuery(
                                  classroomId: _classroomId!,
                                  weekType: _weekType,
                                ))),
                          ),
                        )),
          ),
        ],
      ),
    );
  }

  Widget _weekToggle(BuildContext context) {
    return SegmentedButton<WeekType>(
      segments: const [
        ButtonSegment(value: WeekType.a, label: Text('A')),
        ButtonSegment(value: WeekType.b, label: Text('B')),
      ],
      selected: {_weekType},
      onSelectionChanged: (s) => setState(() => _weekType = s.first),
    );
  }

  Widget _offlineBanner(BuildContext context) {
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

/// Grille hebdomadaire horizontale : 6 colonnes (Lundi..Samedi), chaque
/// colonne liste verticalement les cours du jour triés par heure de début.
class _ScheduleGrid extends StatelessWidget {
  const _ScheduleGrid({required this.schedule});
  final List<WeeklyScheduleDto> schedule;

  @override
  Widget build(BuildContext context) {
    final byDay = <SchoolDay, List<WeeklyScheduleDto>>{};
    for (final s in schedule) {
      final day = s.day;
      if (day == null) continue;
      byDay.putIfAbsent(day, () => []).add(s);
    }
    for (final day in byDay.keys) {
      byDay[day]!.sort((a, b) => a.startTime.compareTo(b.startTime));
    }

    return Scrollbar(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: SchoolDay.values.map((d) {
            final list = byDay[d] ?? const <WeeklyScheduleDto>[];
            return Container(
              width: 184,
              margin: const EdgeInsets.only(right: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    color: Theme.of(context).colorScheme.primaryContainer,
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
                              color: Theme.of(context)
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
                    ...list.map((s) => _SessionCard(session: s)),
                ],
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.session});
  final WeeklyScheduleDto session;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showDetails(context),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.schedule,
                      size: 14, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '${session.startTime} – ${session.endTime}',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                  if (session.room != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .secondaryContainer
                            .withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        session.room!,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                session.subjectName ?? '—',
                style: Theme.of(context).textTheme.titleSmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (session.teacherName != null) ...[
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(Icons.person_outline,
                        size: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        session.teacherName!,
                        style: Theme.of(context).textTheme.bodySmall,
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

  void _showDetails(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(session.subjectName ?? 'Cours',
                  style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 12),
              _DetailRow(
                icon: Icons.schedule,
                label: 'Horaire',
                value: '${session.startTime} – ${session.endTime}',
              ),
              _DetailRow(
                icon: Icons.calendar_today,
                label: 'Jour',
                value: session.day?.label ?? '—',
              ),
              if (session.teacherName != null)
                _DetailRow(
                  icon: Icons.person_outline,
                  label: 'Enseignant',
                  value: session.teacherName!,
                ),
              if (session.room != null)
                _DetailRow(
                  icon: Icons.place_outlined,
                  label: 'Salle',
                  value: session.room!,
                ),
              _DetailRow(
                icon: Icons.repeat,
                label: 'Semaine',
                value: session.weekType == WeekType.b ? 'B' : 'A',
              ),
            ],
          ),
        ),
      ),
    );
  }
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
