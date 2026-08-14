/// Page « Historique des absences » : si `studentId` est fourni, affiche
/// l'historique des absences de cet élève (date, matière, justifié, motif) ;
/// sinon, propose un sélecteur d'élève (recherche par nom/matricule).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/utils/formatters.dart';
import '../../features/connections/connection_state.dart';
import '../../shared/models/student_dto.dart';
import '../../shared/widgets/widgets.dart';
import 'attendance_controller.dart';

class AttendanceHistoryPage extends ConsumerWidget {
  const AttendanceHistoryPage({super.key, this.studentId});

  final int? studentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider);
    if (!conn.canReachServer) {
      return Scaffold(
        appBar: AppBar(title: const Text('Historique d\'absences')),
        body: const EmptyState(
          title: 'Hors-ligne',
          message: 'L\'historique nécessite une connexion au serveur.',
          icon: Icons.cloud_off,
        ),
      );
    }
    if (studentId == null) {
      return const _StudentPicker();
    }
    return _AbsenceHistoryView(studentId: studentId!);
  }
}

// ---------------------------------------------------------------------------
// Sélecteur d'élève (quand studentId est null).
// ---------------------------------------------------------------------------

class _StudentPicker extends ConsumerStatefulWidget {
  const _StudentPicker();

  @override
  ConsumerState<_StudentPicker> createState() => _StudentPickerState();
}

class _StudentPickerState extends ConsumerState<_StudentPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final students = ref.watch(allStudentsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Historique d\'absences')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: AppSearchBar(
              hint: 'Rechercher un élève (nom ou matricule)…',
              onChanged: (q) => setState(() => _query = q.trim().toLowerCase()),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: students.when(
              data: (list) {
                if (list.isEmpty) {
                  return const EmptyState(
                    title: 'Aucun élève',
                    message: 'Aucun élève inscrit sur le serveur.',
                    icon: Icons.group_off,
                  );
                }
                final filtered = _query.isEmpty
                    ? list
                    : list
                        .where((s) =>
                            s.fullName.toLowerCase().contains(_query) ||
                            s.matricule.toLowerCase().contains(_query))
                        .toList();
                if (filtered.isEmpty) {
                  return EmptyState(
                    title: 'Aucun résultat',
                    message: 'Aucun élève ne correspond à « $_query ».',
                    icon: Icons.search_off,
                  );
                }
                return ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (_, i) {
                    final s = filtered[i];
                    return Card(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 4),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .primaryContainer,
                          child: Text(s.displayInitials),
                        ),
                        title: Text(s.fullName),
                        subtitle: Text(s.matricule),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.push(
                            '/attendance/history?student_id=${s.id}'),
                      ),
                    );
                  },
                );
              },
              loading: () =>
                  const AppLoading(label: 'Chargement des élèves…'),
              error: (e, _) => AppErrorWidget(
                message: e.toString(),
                onRetry: () => ref.invalidate(allStudentsProvider),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Vue historique d'un élève.
// ---------------------------------------------------------------------------

class _AbsenceHistoryView extends ConsumerWidget {
  const _AbsenceHistoryView({required this.studentId});
  final int studentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(absenceHistoryEntriesProvider(studentId));
    return Scaffold(
      appBar: AppBar(title: const Text('Historique d\'absences')),
      body: async.when(
        data: (entries) {
          if (entries.isEmpty) {
            return const EmptyState(
              title: 'Aucune absence',
              message: 'Cet élève n\'a aucune absence enregistrée.',
              icon: Icons.check_circle_outline,
            );
          }
          // Stats rapides.
          final justified = entries.where((e) => e.isJustified).length;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: _StatTile(
                          label: 'Total absences',
                          value: '${entries.length}',
                          color: Colors.red.shade400,
                          icon: Icons.event_busy,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _StatTile(
                          label: 'Justifiées',
                          value: '$justified',
                          color: Colors.green,
                          icon: Icons.verified,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SectionHeader(
                title: 'Détail',
                icon: Icons.list,
                subtitle: '${entries.length} absence(s) au total.',
              ),
              const SizedBox(height: 8),
              ...entries.map((e) => _AbsenceCard(entry: e)),
            ],
          );
        },
        loading: () => const AppLoading(label: 'Chargement de l\'historique…'),
        error: (e, _) => AppErrorWidget(
          message: e.toString(),
          onRetry: () =>
              ref.invalidate(absenceHistoryEntriesProvider(studentId)),
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });
  final String label;
  final String value;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 18, color: color),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: color,
                    )),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ],
    );
  }
}

class _AbsenceCard extends StatelessWidget {
  const _AbsenceCard({required this.entry});
  final AbsenceHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: (entry.isJustified ? Colors.green : Colors.red.shade400)
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                entry.isJustified ? Icons.verified : Icons.event_busy,
                size: 20,
                color:
                    entry.isJustified ? Colors.green : Colors.red.shade400,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.courseName ?? 'Cours #${entry.courseSessionId}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(Icons.calendar_today_outlined,
                          size: 14,
                          color: Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Text(
                        DateFormatter.date(entry.date),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  if (entry.reason != null && entry.reason!.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Motif : ${entry.reason}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontStyle: FontStyle.italic,
                          ),
                    ),
                  ],
                ],
              ),
            ),
            StatusBadge(
              label: entry.isJustified ? 'Justifiée' : 'Non justifiée',
              color: entry.isJustified ? Colors.green : Colors.red.shade400,
              icon: entry.isJustified ? Icons.check : Icons.close,
            ),
          ],
        ),
      ),
    );
  }
}
