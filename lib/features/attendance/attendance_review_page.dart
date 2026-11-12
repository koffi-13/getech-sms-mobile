/// [Fix-ATTENDANCE-REVIEW] V22 — Page « Consultation des présences »
/// (admins / direction, LECTURE SEULE, 100 % hors-ligne).
///
/// Retour utilisateur 2026-11-07 : « les admins ne saisissent pas de
/// présence mais affichent les présences des autres (enseignants, élèves
/// et autres utilisateurs) ». La saisie reste strictement en ligne
/// ([Fix-PRESENCE-ONLINE], règle métier) ; cette page CONSULTE :
///
/// - Onglet « Sessions » : les sessions de cours des 30 derniers jours
///   (classe, matière, enseignant, date/heure, état, absents X / justifiés Y)
///   avec détail dépliable de la liste d'absences ;
/// - Onglet « Élèves » : récapitulatif par élève (total absences,
///   justifiées / non justifiées) sur la même fenêtre.
///
/// Source : cache Drift (course_sessions + student_absences + students…,
/// rempli par la synchro automatique) — aucune requête réseau, donc
/// aucun écran « le serveur ne répond pas ». Les données se rafraîchissent
/// à chaque synchro (syncGenerationProvider).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_state.dart';
import '../../features/connections/connection_state.dart';
import '../../shared/widgets/widgets.dart';
import 'attendance_review_controller.dart';

class AttendanceReviewPage extends ConsumerWidget {
  const AttendanceReviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    // Consultation réservée aux admins / direction (miroir du desktop :
    // la saisie exige ATTENDANCE_MARK, la consultation ATTENDANCE_READ).
    if (!auth.isAdminOrHeadmaster && !auth.isSuperuser) {
      return Scaffold(
        appBar: AppBar(title: const Text('Présences')),
        body: const EmptyState(
          title: 'Permission insuffisante',
          message:
              'La consultation des présences est réservée à l\'administration.',
          icon: Icons.lock_outline,
        ),
      );
    }
    return const _AttendanceReviewBody();
  }
}

class _AttendanceReviewBody extends ConsumerWidget {
  const _AttendanceReviewBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Consultation des présences'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Sessions'),
              Tab(text: 'Élèves'),
            ],
          ),
        ),
        body: Column(
          children: [
            if (!conn.canReachServer)
              const _OfflineNotice(),
            const Expanded(
              child: TabBarView(
                children: [
                  _SessionsTab(),
                  _StudentsTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bandeau informatif : les données viennent du cache local (dernière
/// synchro) et se mettront à jour à la reconnexion.
class _OfflineNotice extends StatelessWidget {
  const _OfflineNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 18,
            color: theme.colorScheme.onTertiaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Mode hors-ligne — présences issues de la dernière '
              'synchronisation. Elles s\'actualiseront à la reconnexion.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Onglet « Sessions »
// ---------------------------------------------------------------------------

class _SessionsTab extends ConsumerWidget {
  const _SessionsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionsAsync = ref.watch(attendanceSessionsProvider);
    return RefreshIndicator(
      onRefresh: () async => ref.refresh(attendanceSessionsProvider.future),
      child: sessionsAsync.when(
        data: (sessions) {
          if (sessions.isEmpty) {
            return ListView(
              children: const [
                SizedBox(height: 120),
                EmptyState(
                  title: 'Aucune session enregistrée',
                  message:
                      'Aucune session de cours des $kAttendanceReviewWindowDays '
                      'derniers jours dans le cache. Les sessions apparaissent '
                      'après la prochaine synchronisation.',
                  icon: Icons.event_busy,
                ),
              ],
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: sessions.length,
            itemBuilder: (context, i) =>
                _SessionCard(session: sessions[i]),
          );
        },
        loading: () => const AppLoading(label: 'Chargement des sessions…'),
        error: (e, _) => ListView(
          children: [
            const SizedBox(height: 120),
            AppErrorWidget(
              message: e.toString(),
              onRetry: () => ref.invalidate(attendanceSessionsProvider),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionCard extends ConsumerWidget {
  const _SessionCard({required this.session});

  final AttendanceSessionView session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dateLabel =
        '${session.date.day.toString().padLeft(2, '0')}/${session.date.month.toString().padLeft(2, '0')}/${session.date.year}';
    final hours = (session.startTime != null && session.startTime!.isNotEmpty)
        ? '${session.startTime}${session.endTime != null && session.endTime!.isNotEmpty ? ' – ${session.endTime}' : ''}'
        : null;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Theme(
        // ExpansionTile sans couleur de fond parasite.
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                [
                  session.classroomName ?? 'Classe ?',
                  if (session.subjectName != null) session.subjectName!,
                ].join(' — '),
                style: theme.textTheme.titleSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                [
                  dateLabel,
                  if (hours != null) hours,
                ].join(' · '),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (session.teacherName != null)
                  _Chip(
                    icon: Icons.person_outline,
                    label: session.teacherName!,
                  ),
                _Chip(
                  icon: session.isCompleted
                      ? Icons.check_circle_outline
                      : Icons.schedule,
                  label: session.isCompleted ? 'Terminée' : 'En cours',
                ),
                _Chip(
                  icon: Icons.person_off_outlined,
                  label:
                      '${session.absentCount} absent(s) · ${session.justifiedCount} justifiée(s)',
                  color: session.absentCount > 0
                      ? Colors.red.shade700
                      : Colors.green.shade700,
                ),
              ],
            ),
          ),
          children: [
            _SessionAbsenceDetail(sessionId: session.id),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
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
    final c = color ?? theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: c),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(color: c),
          ),
        ],
      ),
    );
  }
}

class _SessionAbsenceDetail extends ConsumerWidget {
  const _SessionAbsenceDetail({required this.sessionId});

  final int sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(sessionAbsenceDetailsProvider(sessionId));
    return async.when(
      data: (absences) {
        if (absences.isEmpty) {
          return const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text('Aucun absent enregistré pour cette session.'),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Absences (${absences.length})',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 6),
              ...absences.map((a) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Icon(
                          a.isJustified
                              ? Icons.verified_outlined
                              : Icons.cancel_outlined,
                          size: 16,
                          color: a.isJustified
                              ? Colors.green.shade700
                              : Colors.red.shade400,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            a.matricule == null || a.matricule!.isEmpty
                                ? a.studentName
                                : '${a.studentName} (${a.matricule})',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                        Text(
                          a.isJustified ? 'Justifiée' : 'Non justifiée',
                          style:
                              Theme.of(context).textTheme.labelSmall?.copyWith(
                                    color: a.isJustified
                                        ? Colors.green.shade700
                                        : Colors.red.shade400,
                                  ),
                        ),
                      ],
                    ),
                  )),
            ],
          ),
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.all(12),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(12),
        child: Text('Erreur : $e'),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Onglet « Élèves » (récapitulatif)
// ---------------------------------------------------------------------------

class _StudentsTab extends ConsumerWidget {
  const _StudentsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summariesAsync = ref.watch(attendanceStudentSummariesProvider);
    return RefreshIndicator(
      onRefresh: () async =>
          ref.refresh(attendanceStudentSummariesProvider.future),
      child: summariesAsync.when(
        data: (summaries) {
          if (summaries.isEmpty) {
            return ListView(
              children: const [
                SizedBox(height: 120),
                EmptyState(
                  title: 'Aucune absence enregistrée',
                  message:
                      'Aucune absence des $kAttendanceReviewWindowDays derniers '
                      'jours dans le cache.',
                  icon: Icons.person_off_outlined,
                ),
              ],
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: summaries.length,
            itemBuilder: (context, i) => _StudentSummaryCard(
              summary: summaries[i],
            ),
          );
        },
        loading: () => const AppLoading(label: 'Chargement du récapitulatif…'),
        error: (e, _) => ListView(
          children: [
            const SizedBox(height: 120),
            AppErrorWidget(
              message: e.toString(),
              onRetry: () => ref.invalidate(attendanceStudentSummariesProvider),
            ),
          ],
        ),
      ),
    );
  }
}

class _StudentSummaryCard extends StatelessWidget {
  const _StudentSummaryCard({required this.summary});

  final AttendanceStudentSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unjustified = summary.unjustifiedAbsences;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    summary.studentName,
                    style: theme.textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    summary.classroomName,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _AbsenceStat(
              label: 'Absences',
              value: summary.totalAbsences,
              color: Colors.red.shade700,
            ),
            const SizedBox(width: 12),
            _AbsenceStat(
              label: 'Justifiées',
              value: summary.justifiedAbsences,
              color: Colors.green.shade700,
            ),
            const SizedBox(width: 12),
            _AbsenceStat(
              label: 'Non just.',
              value: unjustified,
              color: unjustified > 0
                  ? Colors.deepOrange.shade700
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _AbsenceStat extends StatelessWidget {
  const _AbsenceStat({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$value',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
