/// Page Tableau de bord : KPIs (effectifs, classes, enseignants, utilisateurs,
/// paiements, solde dû), paiements récents et élèves récemment inscrits.
///
/// Aligné sur `DashboardStats` du desktop (schemas.py) :
/// {total_students, total_classrooms, total_teachers, total_payments (count),
/// total_balance_due, total_users, recent_payments[], recent_students[]}.
///
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

/// Contenu complet du tableau de bord (KPIs + sections récentes).
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
        _RecentPaymentsCard(payments: stats.recentPayments),
        const SizedBox(height: 16),
        _RecentStudentsCard(students: stats.recentStudents),
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

/// Grille 2 colonnes de KPI cards (6 tuiles).
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
          label: 'Utilisateurs',
          value: '${stats.totalUsers}',
          icon: Icons.manage_accounts,
          color: Colors.deepPurple,
        ),
        KpiCard(
          label: 'Paiements',
          value: '${stats.totalPayments}',
          icon: Icons.payments,
          color: Colors.green,
        ),
        KpiCard(
          label: 'Solde dû',
          value: MoneyFormatter.compact(stats.totalBalanceDue),
          icon: Icons.account_balance_wallet,
          color: Colors.red.shade700,
        ),
      ],
    );
  }
}

/// Carte "Paiements récents" : liste des derniers paiements enregistrés.
class _RecentPaymentsCard extends StatelessWidget {
  const _RecentPaymentsCard({required this.payments});
  final List<DashboardRecentPaymentDto> payments;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: 'Paiements récents',
              icon: Icons.receipt_long_outlined,
              subtitle: '${payments.length} paiement(s) récent(s)',
            ),
            const SizedBox(height: 4),
            if (payments.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: EmptyState(
                  title: 'Aucun paiement récent',
                  message: 'Les derniers paiements apparaîtront ici.',
                  icon: Icons.receipt_long_outlined,
                ),
              )
            else
              ...payments.map((p) => _PaymentTile(p: p)),
          ],
        ),
      ),
    );
  }
}

class _PaymentTile extends StatelessWidget {
  const _PaymentTile({required this.p});
  final DashboardRecentPaymentDto p;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = PaymentStatus.fromCode(p.status);
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(vertical: 4),
      leading: CircleAvatar(
        backgroundColor: Colors.green.withValues(alpha: 0.14),
        child: const Icon(Icons.payments, color: Colors.green, size: 20),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              MoneyFormatter.format(p.amount, withSymbol: false),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: Colors.green.shade700,
              ),
            ),
          ),
          if (status != null)
            _PaymentStatusBadge(status: status),
        ],
      ),
      subtitle: Wrap(
        spacing: 8,
        runSpacing: 2,
        children: [
          if (p.method != null && p.method!.isNotEmpty)
            Text(
              PaymentMethod.fromCode(p.method)?.label ?? p.method!,
              style: theme.textTheme.bodySmall,
            ),
          if (p.receiptNumber != null && p.receiptNumber!.isNotEmpty)
            Text(
              'Reçu : ${p.receiptNumber}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          Text(
            p.paymentDate == null
                ? '—'
                : DateFormatter.relative(p.paymentDate),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      onTap: p.studentId == null
          ? null
          : () => context.push('/students/${p.studentId}'),
    );
  }
}

class _PaymentStatusBadge extends StatelessWidget {
  const _PaymentStatusBadge({required this.status});
  final PaymentStatus status;

  @override
  Widget build(BuildContext context) {
    final (color, _) = _statusStyle(status);
    return StatusBadge(label: status.label, color: color, filled: false);
  }

  (Color, IconData) _statusStyle(PaymentStatus s) {
    switch (s) {
      case PaymentStatus.valide:
        return (Colors.green, Icons.check_circle);
      case PaymentStatus.enAttente:
        return (Colors.orange, Icons.hourglass_top);
      case PaymentStatus.echec:
        return (Colors.red, Icons.error);
      case PaymentStatus.rembourse:
        return (Colors.blueGrey, Icons.undo);
      case PaymentStatus.annule:
        return (Colors.grey, Icons.cancel);
    }
  }
}

/// Carte "Élèves récemment inscrits" : liste des derniers élèves enregistrés.
class _RecentStudentsCard extends StatelessWidget {
  const _RecentStudentsCard({required this.students});
  final List<DashboardRecentStudentDto> students;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: 'Élèves récemment inscrits',
              icon: Icons.person_add_outlined,
              subtitle: '${students.length} nouvel(s) élève(s)',
            ),
            const SizedBox(height: 4),
            if (students.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: EmptyState(
                  title: 'Aucune inscription récente',
                  message: 'Les dernières inscriptions apparaîtront ici.',
                  icon: Icons.person_add_outlined,
                ),
              )
            else
              ...students.map((s) => ListTile(
                    dense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 4),
                    leading: CircleAvatar(
                      backgroundColor:
                          theme.colorScheme.primaryContainer,
                      child: Text(
                        s.fullName.isNotEmpty
                            ? s.fullName[0].toUpperCase()
                            : '?',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                    title: Text(
                      s.fullName.isEmpty ? '(sans nom)' : s.fullName,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w500),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      s.matricule.isEmpty ? 'Mat. —' : 'Mat. ${s.matricule}',
                      style: theme.textTheme.bodySmall,
                    ),
                    onTap: () => context.push('/students/${s.id}'),
                  )),
          ],
        ),
      ),
    );
  }
}
