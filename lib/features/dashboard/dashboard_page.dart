/// Page Tableau de bord : KPIs, répartition par sexe, taux d'occupation des
/// classes, alertes d'absentéisme et paiements en retard.
///
/// Données fournies par [dashboardStatsProvider] (GET /dashboard/stats).
/// Le bouton "Synchroniser" de l'AppBar déclenche [SyncEngine.syncNow] puis
/// rafraîchit les statistiques. Si le serveur est injoignable, un bandeau
/// « Mode hors-ligne » est affiché en lieu et place du contenu.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/constants.dart';
import '../../core/sync/sync_engine.dart';
import '../../core/utils/formatters.dart';
import '../connections/connection_state.dart';
import '../../shared/models/sync_dto.dart';
import '../../shared/widgets/widgets.dart';
import 'dashboard_controller.dart';

/// Page racine après connexion : vue d'ensemble de l'établissement.
class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider);
    final statsAsync = ref.watch(dashboardStatsProvider);
    final isOffline = !conn.canReachServer;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tableau de bord'),
        actions: [
          _SyncButton(),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(dashboardStatsProvider);
          // Attendre la prochaine valeur pour garder le spinner affiché.
          await ref.read(dashboardStatsProvider.future);
        },
        child: statsAsync.when(
          data: (stats) => _DashboardContent(
            stats: stats,
            isOffline: isOffline,
          ),
          loading: () => const AppLoading(label: 'Chargement des statistiques…'),
          error: (err, _) {
            // Distingue le mode hors-ligne des autres erreurs.
            final offline = isOffline || err is OfflineDashboardException;
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                if (offline)
                  AppErrorWidget(
                    message:
                        'Mode hors-ligne — données non disponibles. Vérifiez votre connexion au serveur.',
                    onRetry: () => ref.invalidate(dashboardStatsProvider),
                  )
                else
                  AppErrorWidget(
                    message: err.toString(),
                    onRetry: () => ref.invalidate(dashboardStatsProvider),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Bouton "Synchroniser" de l'AppBar : déclenche [SyncEngine.syncNow] puis
/// rafraîchit les KPIs.
class _SyncButton extends ConsumerStatefulWidget {
  const _SyncButton();

  @override
  ConsumerState<_SyncButton> createState() => _SyncButtonState();
}

class _SyncButtonState extends ConsumerState<_SyncButton> {
  bool _syncing = false;

  Future<void> _runSync() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    SyncResult? result;
    try {
      result = await ref.read(syncEngineProvider).syncNow();
    } catch (_) {
      result = null;
    } finally {
      // Toujours rafraîchir les KPIs après une synchro (même en échec partiel).
      ref.invalidate(dashboardStatsProvider);
      if (mounted) setState(() => _syncing = false);
    }
    if (messenger != null && result != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result.isSuccess
                ? 'Synchro terminée : ${result.pulled} reçus, ${result.pushed} envoyés.'
                : 'Synchro terminée avec ${result.errors.length} erreur(s).',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Synchroniser',
      onPressed: _syncing ? null : _runSync,
      icon: _syncing
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            )
          : const Icon(Icons.sync),
    );
  }
}

/// Contenu complet du tableau de bord (KPIs + sections).
class _DashboardContent extends StatelessWidget {
  const _DashboardContent({
    required this.stats,
    required this.isOffline,
  });

  final DashboardStatsDto stats;
  final bool isOffline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (isOffline)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _OfflineBanner(),
          ),
        _KpiGrid(stats: stats),
        const SizedBox(height: 16),
        _SexDistributionCard(
          studentsBySex: stats.studentsBySex,
          total: stats.totalStudents,
        ),
        const SizedBox(height: 16),
        _ClassOccupancyCard(items: stats.classOccupancy),
        const SizedBox(height: 16),
        _AbsenteeAlertsCard(items: stats.absenteeAlerts),
        const SizedBox(height: 16),
        _OverduePaymentsCard(items: stats.overduePayments),
        const SizedBox(height: 8),
        Text(
          'Devise : $defaultCurrency',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Bandeau "Mode hors-ligne" affiché en haut du tableau de bord.
class _OfflineBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off, color: Colors.orange, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Mode hors-ligne — les données affichées peuvent être obsolètes.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.orange.shade800,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Grille 2 colonnes de KPI cards.
class _KpiGrid extends StatelessWidget {
  const _KpiGrid({required this.stats});
  final DashboardStatsDto stats;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 1.25,
      children: [
        KpiCard(
          label: 'Effectif élèves',
          value: '${stats.totalStudents}',
          icon: Icons.people,
          color: Theme.of(context).colorScheme.primary,
          onTap: () => context.push('/students'),
        ),
        KpiCard(
          label: 'Classes',
          value: '${stats.totalClassrooms}',
          icon: Icons.school,
          color: Colors.teal,
          onTap: () => context.push('/classrooms'),
        ),
        KpiCard(
          label: 'Enseignants',
          value: '${stats.totalTeachers}',
          icon: Icons.badge,
          color: Colors.indigo,
        ),
        KpiCard(
          label: 'Paiements du jour',
          value: MoneyFormatter.compact(stats.paymentsToday),
          icon: Icons.payments,
          color: Colors.green,
        ),
        KpiCard(
          label: 'Solde dû',
          value: MoneyFormatter.compact(stats.outstandingBalance),
          icon: Icons.account_balance_wallet,
          color: Colors.red.shade700,
        ),
      ],
    );
  }
}

/// Carte "Répartition par sexe" : barre horizontale proportionnelle M/F.
class _SexDistributionCard extends StatelessWidget {
  const _SexDistributionCard({
    required this.studentsBySex,
    required this.total,
  });

  final Map<String, int> studentsBySex;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Accepte à la fois les codes courts ('M'/'F') et les libellés longs
    // retournés par certaines variantes de l'API.
    final masculin = studentsBySex['M'] ?? studentsBySex['Masculin'] ?? 0;
    final feminin = studentsBySex['F'] ?? studentsBySex['Féminin'] ?? 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              title: 'Répartition par sexe',
              icon: Icons.pie_chart_outline,
            ),
            const SizedBox(height: 8),
            if (masculin == 0 && feminin == 0)
              Text(
                'Aucune donnée disponible.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  height: 22,
                  child: Row(
                    children: [
                      if (masculin > 0)
                        Expanded(
                          flex: masculin,
                          child: Container(
                            color: Colors.blue,
                            alignment: Alignment.center,
                            child: Text(
                              '$masculin',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      if (feminin > 0)
                        Expanded(
                          flex: feminin,
                          child: Container(
                            color: Colors.pink,
                            alignment: Alignment.center,
                            child: Text(
                              '$feminin',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 10),
            Row(
              children: [
                _LegendDot(color: Colors.blue, label: 'Garçons ($masculin)'),
                const SizedBox(width: 16),
                _LegendDot(color: Colors.pink, label: 'Filles ($feminin)'),
                const Spacer(),
                Text(
                  'Total : $total',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

/// Carte "Taux d'occupation des classes" : liste avec barre de progression.
class _ClassOccupancyCard extends StatelessWidget {
  const _ClassOccupancyCard({required this.items});
  final List<ClassOccupancyDto> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              title: 'Taux d\'occupation des classes',
              icon: Icons.meeting_room_outlined,
            ),
            const SizedBox(height: 4),
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: EmptyState(
                  title: 'Aucune classe',
                  message: 'Aucun taux d\'occupation à afficher.',
                  icon: Icons.school_outlined,
                ),
              )
            else
              ...items.map((c) {
                final rate = c.capacity == 0
                    ? 0.0
                    : (c.studentCount / c.capacity).clamp(0.0, 1.0);
                final pct = (rate * 100).round();
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              c.classroomName,
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w500),
                            ),
                          ),
                          Text(
                            '${c.studentCount} / ${c.capacity}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '$pct %',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                        value: rate,
                        minHeight: 8,
                        backgroundColor:
                            theme.colorScheme.surfaceContainerHighest,
                        color: _colorForRate(rate),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Color _colorForRate(double r) {
    if (r >= 0.9) return Colors.red.shade700;
    if (r >= 0.7) return Colors.orange;
    return Colors.green;
  }
}

/// Carte "Alertes — Absentéisme" : liste des élèves à risque.
class _AbsenteeAlertsCard extends StatelessWidget {
  const _AbsenteeAlertsCard({required this.items});
  final List<AbsenteeAlertDto> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              title: 'Alertes — Absentéisme',
              icon: Icons.warning_amber_rounded,
            ),
            const SizedBox(height: 4),
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: EmptyState(
                  title: 'Aucune alerte',
                  message: 'Aucun élève en situation d\'absentéisme.',
                  icon: Icons.check_circle_outline,
                ),
              )
            else
              ...items.map((a) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor:
                          Colors.orange.withValues(alpha: 0.16),
                      child: const Icon(Icons.person_off_outlined,
                          color: Colors.orange, size: 20),
                    ),
                    title: Text(
                      a.studentName,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w500),
                    ),
                    subtitle: Text(
                      [
                        if (a.classroomName != null) a.classroomName!,
                        if (a.matricule != null) 'Mat. ${a.matricule}',
                      ].join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '${a.absenceCount} absence${a.absenceCount > 1 ? 's' : ''}',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: Colors.orange.shade800,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          a.lastAbsence == null
                              ? '—'
                              : DateFormatter.relative(a.lastAbsence),
                          style: theme.textTheme.labelSmall,
                        ),
                      ],
                    ),
                    onTap: () => context.push('/students/${a.studentId}'),
                  )),
          ],
        ),
      ),
    );
  }
}

/// Carte "Paiements en retard" : liste des élèves en retard de paiement.
class _OverduePaymentsCard extends StatelessWidget {
  const _OverduePaymentsCard({required this.items});
  final List<OverduePaymentDto> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              title: 'Paiements en retard',
              icon: Icons.payment_outlined,
            ),
            const SizedBox(height: 4),
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: EmptyState(
                  title: 'Aucun retard',
                  message: 'Tous les paiements sont à jour.',
                  icon: Icons.check_circle_outline,
                ),
              )
            else
              ...items.map((p) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: Colors.red.withValues(alpha: 0.14),
                      child: const Icon(Icons.error_outline,
                          color: Colors.red, size: 20),
                    ),
                    title: Text(
                      p.studentName,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w500),
                    ),
                    subtitle: Text(
                      [
                        if (p.classroomName != null) p.classroomName!,
                        'Échéance : ${DateFormatter.date(p.dueDate)}',
                      ].join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                    trailing: Text(
                      MoneyFormatter.format(p.amountDue, withSymbol: false),
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: Colors.red.shade700,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    onTap: () => context.push('/students/${p.studentId}'),
                  )),
          ],
        ),
      ),
    );
  }
}
