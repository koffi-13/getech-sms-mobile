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

import '../../core/auth/auth_state.dart';
import '../../core/auth/teacher_scope.dart';
import '../../core/config/constants.dart';
import '../../core/notifications/notification_service.dart';
import '../../core/sync/sync_engine.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/permissions.dart';
import '../connections/connection_state.dart';
import '../../shared/models/sync_dto.dart';
import '../../shared/widgets/widgets.dart';
import 'dashboard_controller.dart';

/// Page racine après connexion : vue d'ensemble.
///
/// - **Enseignant** : statistiques de SES classes uniquement (effectifs,
///   matières, cours du jour) — aucune donnée financière ni globale.
/// - **Autres profils** : KPIs de l'établissement ; les tuiles financières
///   (Paiements, Solde dû) ne sont affichées qu'avec la permission
///   PAYMENT_READ, et la tuile Utilisateurs avec USER_READ.
class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider);
    final auth = ref.watch(authProvider);
    final scopeAsync = ref.watch(teacherScopeProvider);
    final statsAsync = ref.watch(dashboardStatsProvider);
    final isOffline = !conn.canReachServer;

    // L'accueil d'un enseignant est totalement différent : statistiques de
    // ses classes uniquement, sans appel à /dashboard/stats (qui n'est pas
    // scopé par rôle et exposerait des données financières).
    //
    // [Fix-TEACHER-DASHBOARD] Durcissement de la détection : tant que le
    // scope n'a pas tranché (chargement/erreur) ET qu'aucun rôle TEACHER
    // n'est déclaré, on affiche un état d'attente — JAMAIS la vue générique
    // (qui contient paiements récents + élèves récemment inscrits).
    final declared = auth.hasDeclaredTeacherRole;
    final scopeIsTeacher = scopeAsync.maybeWhen(
        data: (s) => s.isTeacher, orElse: () => false);
    final isTeacher = !auth.isAdminOrHeadmaster && (declared || scopeIsTeacher);
    final scopePending =
        !auth.isAdminOrHeadmaster && !declared && !scopeAsync.hasValue;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tableau de bord'),
        actions: [
          _SyncButton(),
        ],
      ),
      body: scopePending
          ? (scopeAsync.hasError
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    AppErrorWidget(
                      message:
                          'Impossible de déterminer votre profil enseignant.',
                      onRetry: () =>
                          ref.invalidate(teacherScopeProvider),
                    ),
                  ],
                )
              : const AppLoading(
                  label: 'Détection de votre profil…'))
          : isTeacher
              ? _TeacherDashboard(isOffline: isOffline)
              : RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(dashboardStatsProvider);
                // Attendre la prochaine valeur pour garder le spinner affiché.
                await ref.read(dashboardStatsProvider.future);
              },
              child: statsAsync.when(
                data: (stats) => _DashboardContent(
                  stats: stats,
                  isOffline: isOffline,
                  perms: auth.permissions,
                ),
                loading: () =>
                    const AppLoading(label: 'Chargement des statistiques…'),
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
      // [Notifications] Suit la validation/rejet des modifications de
      // notes + informe du résultat de la synchro (utile, non répétitif).
      if (result.isSuccess) {
        await ref
            .read(notificationServiceProvider)
            .maybeCheckGradeModifications();
      }
      await ref.read(notificationServiceProvider).notifySyncResult(result);
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
///
/// [Fix-TEACHER-DASHBOARD] Les sections « Paiements récents » et « Élèves
/// récemment inscrits » sont désormais filtrées par permission (elles ne
/// sont plus rendues inconditionnellement) : PAYMENT_READ pour les
/// paiements, STUDENT_READ pour les inscriptions.
class _DashboardContent extends StatelessWidget {
  const _DashboardContent({
    required this.stats,
    required this.isOffline,
    required this.perms,
  });

  final DashboardStatsDto stats;
  final bool isOffline;
  final List<String> perms;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canSeePayments = hasPermission(perms, RbacPermissions.paymentRead);
    final canSeeStudents = hasPermission(perms, RbacPermissions.studentRead);
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
        if (canSeePayments) ...[
          const SizedBox(height: 16),
          _RecentPaymentsCard(payments: stats.recentPayments),
        ],
        if (canSeeStudents) ...[
          const SizedBox(height: 16),
          _RecentStudentsCard(students: stats.recentStudents),
        ],
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

// ---------------------------------------------------------------------------
// Accueil ENSEIGNANT
// ---------------------------------------------------------------------------

/// Tableau de bord enseignant : statistiques de ses classes uniquement —
/// effectifs, matières, cours du jour et prochains créneaux. Aucune donnée
/// financière, aucun compteur global des autres utilisateurs.
class _TeacherDashboard extends ConsumerWidget {
  const _TeacherDashboard({required this.isOffline});
  final bool isOffline;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(teacherDashboardProvider);
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(teacherDashboardProvider);
        await ref.read(teacherDashboardProvider.future);
      },
      child: async.when(
        data: (data) => _TeacherDashboardContent(
            data: data, isOffline: isOffline),
        loading: () => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 120),
            AppLoading(label: 'Chargement de vos classes…'),
          ],
        ),
        error: (e, _) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            AppErrorWidget(
              message: e.toString(),
              onRetry: () => ref.invalidate(teacherDashboardProvider),
            ),
          ],
        ),
      ),
    );
  }
}

class _TeacherDashboardContent extends StatelessWidget {
  const _TeacherDashboardContent({
    required this.data,
    required this.isOffline,
  });

  final TeacherDashboardData data;
  final bool isOffline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final todayCourses = data.todayCourses;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (isOffline)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _OfflineBanner(),
          ),

        // --- KPIs du périmètre enseignant ---
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1.25,
          children: [
            KpiCard(
              label: 'Mes classes',
              value: '${data.classCount}',
              icon: Icons.school,
              color: theme.colorScheme.primary,
              onTap: () => context.push('/schedule'),
            ),
            KpiCard(
              label: 'Mes élèves',
              value: '${data.studentCount}',
              icon: Icons.people,
              color: Colors.teal,
              onTap: () => context.push('/students'),
            ),
            KpiCard(
              label: 'Mes matières',
              value: '${data.subjectCount}',
              icon: Icons.book_outlined,
              color: Colors.indigo,
            ),
            KpiCard(
              label: 'Cours aujourd\'hui',
              value: '${todayCourses.length}',
              icon: Icons.schedule,
              color: Colors.deepOrange,
              onTap: () => context.push('/schedule'),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // --- Cours du jour ---
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionHeader(
                  title: 'Mes cours aujourd\'hui',
                  icon: Icons.today_outlined,
                  subtitle: todayCourses.isEmpty
                      ? 'Aucun cours programmé aujourd\'hui'
                      : '${todayCourses.length} cours',
                ),
                const SizedBox(height: 4),
                if (todayCourses.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: EmptyState(
                      title: 'Journée libre',
                      message:
                          'Aucun cours planifié pour aujourd\'hui.',
                      icon: Icons.event_available,
                    ),
                  )
                else
                  ...todayCourses.map((c) => ListTile(
                        dense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 4),
                        leading: CircleAvatar(
                          backgroundColor:
                              theme.colorScheme.primaryContainer,
                          child: const Icon(Icons.schedule, size: 20),
                        ),
                        title: Text(
                          c.subjectName ?? 'Cours',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          [
                            '${c.startTime} – ${c.endTime}',
                            if (c.classroomName != null) c.classroomName!,
                            if (c.room != null && c.room!.isNotEmpty)
                              'Salle ${c.room}',
                          ].join(' • '),
                        ),
                      )),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // --- Mes classes ---
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionHeader(
                  title: 'Mes classes',
                  icon: Icons.school_outlined,
                  subtitle:
                      '${data.classCount} classe(s) — enseignement et titulariat',
                ),
                const SizedBox(height: 4),
                if (data.classrooms.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: EmptyState(
                      title: 'Aucune classe liée',
                      message:
                          'Vous n\'êtes ni titulaire ni enseignant dans une classe.',
                      icon: Icons.school_outlined,
                    ),
                  )
                else
                  ...data.classrooms.map((c) {
                    final isHead = data.scope.headClassrooms
                        .any((h) => h.id == c.id);
                    return ListTile(
                      dense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 4),
                      leading: CircleAvatar(
                        backgroundColor: isHead
                            ? Colors.amber.withValues(alpha: 0.2)
                            : theme.colorScheme.primaryContainer,
                        child: Icon(
                          isHead ? Icons.star : Icons.school,
                          size: 18,
                          color: isHead
                              ? Colors.amber.shade800
                              : null,
                        ),
                      ),
                      title: Text(c.name,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        [
                          '${c.studentCount} élève${c.studentCount > 1 ? 's' : ''}',
                          if (c.capacity > 0)
                            'capacité ${c.capacity}',
                          if (isHead) 'Titulaire',
                        ].join(' • '),
                      ),
                      onTap: () => context.push('/classrooms/${c.id}'),
                    );
                  }),
              ],
            ),
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

/// Grille 2 colonnes de KPI cards — tuiles filtrées par permission :
/// Paiements/Solde dû uniquement avec PAYMENT_READ, Utilisateurs avec
/// USER_READ (l'accueil n'est plus identique pour tous les profils).
class _KpiGrid extends ConsumerWidget {
  const _KpiGrid({required this.stats});
  final DashboardStatsDto stats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final canSeePayments =
        hasPermission(auth.permissions, RbacPermissions.paymentRead);
    final canSeeUsers =
        hasPermission(auth.permissions, RbacPermissions.userRead);

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
        if (canSeeUsers)
          KpiCard(
            label: 'Utilisateurs',
            value: '${stats.totalUsers}',
            icon: Icons.manage_accounts,
            color: Colors.deepPurple,
          ),
        if (canSeePayments) ...[
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
