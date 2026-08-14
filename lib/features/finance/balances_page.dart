/// Page "Soldes élèves" : liste des subscriptions avec solde dû, triée par
/// `balance_due` décroissant (déjà fait côté serveur).
///
/// Chaque `FeeSubscriptionDto` représente une `StudentFeeSubscription` avec
/// `agreed_amount`, `balance_due`, `total_paid` (= agreed - balance),
/// `payment_rate`, `status` (SubscriptionStatus).
///
/// KPIs de synthèse : Total dû, Total encaissé, Solde restant.
///
/// Tap sur une subscription → ouvre la page d'enregistrement d'un paiement
/// pour l'élève concerné (`/finance/payments/new?student_id=<id>`).
///
/// RBAC : PAYMENT_READ requis pour visualiser la page.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_state.dart';
import '../../core/config/constants.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/permissions.dart';
import '../../shared/models/classroom_dto.dart';
import '../../shared/models/finance_dto.dart';
import '../../shared/widgets/widgets.dart';
import '../connections/connection_state.dart';
import 'finance_controller.dart';

class BalancesPage extends ConsumerStatefulWidget {
  const BalancesPage({super.key});

  @override
  ConsumerState<BalancesPage> createState() => _BalancesPageState();
}

class _BalancesPageState extends ConsumerState<BalancesPage> {
  BalanceFilter _filter = const BalanceFilter.empty();
  String _searchText = '';
  DateTime? _lastSearchAt;

  void _onSearchChanged(String value) {
    setState(() => _searchText = value);
    final now = DateTime.now();
    _lastSearchAt = now;
    Future.delayed(const Duration(milliseconds: 350), () {
      if (_lastSearchAt == now) {
        setState(() => _filter = _filter.copyWith(search: value.trim()));
      }
    });
  }

  Future<void> _refresh() async {
    ref.invalidate(balancesProvider);
    ref.invalidate(classroomsForFinanceProvider);
    setState(() => _filter = _filter.copyWith());
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final canRead = hasPermission(auth.permissions, RbacPermissions.paymentRead);

    if (!canRead) {
      return Scaffold(
        appBar: AppBar(title: const Text('Soldes élèves')),
        body: const EmptyState(
          icon: Icons.lock_outline,
          title: 'Permission insuffisante',
          message:
              'Vous n\'avez pas la permission PAYMENT_READ pour consulter les soldes.',
        ),
      );
    }

    final classroomsAsync = ref.watch(classroomsForFinanceProvider);
    final balancesAsync = ref.watch(balancesProvider(_filter));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Soldes élèves'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Rafraîchir',
            onPressed: _refresh,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          slivers: _buildSlivers(balancesAsync, classroomsAsync),
        ),
      ),
    );
  }

  List<Widget> _buildSlivers(
    AsyncValue<List<FeeSubscriptionDto>> balancesAsync,
    AsyncValue<List<ClassroomDto>> classroomsAsync,
  ) {
    final slivers = <Widget>[
      const SliverToBoxAdapter(child: _OfflineBanner()),
      // Barre de recherche.
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: AppSearchBar(
            hint: 'Rechercher un élève…',
            onChanged: _onSearchChanged,
          ),
        ),
      ),
      // Filtre classe.
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: _ClassroomFilter(
            filter: _filter,
            classroomsAsync: classroomsAsync,
            onChanged: (next) => setState(() => _filter = next),
          ),
        ),
      ),
    ];

    if (balancesAsync.isLoading) {
      slivers.add(const SliverFillRemaining(
        hasScrollBody: false,
        child: AppLoading(label: 'Chargement des soldes…'),
      ));
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 24)));
      return slivers;
    }
    if (balancesAsync.hasError) {
      slivers.add(SliverFillRemaining(
        hasScrollBody: false,
        child: AppErrorWidget(
          message: balancesAsync.error.toString(),
          onRetry: _refresh,
        ),
      ));
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 24)));
      return slivers;
    }

    final balances = balancesAsync.value ?? const <FeeSubscriptionDto>[];
    if (balances.isEmpty) {
      slivers.add(const SliverFillRemaining(
        hasScrollBody: false,
        child: EmptyState(
          icon: Icons.account_balance_wallet_outlined,
          title: 'Aucun solde dû',
          message: 'Aucune subscription avec solde restant à payer.',
        ),
      ));
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 24)));
      return slivers;
    }

    // Tri : solde dû décroissant (le serveur le fait déjà, mais on le
    // re-tri côté client pour garantir l'ordre après filtrage).
    final sorted = List<FeeSubscriptionDto>.from(balances)
      ..sort((a, b) => b.balanceDue.compareTo(a.balanceDue));

    // KPIs.
    double totalDue = 0, totalPaid = 0, totalOutstanding = 0;
    for (final b in sorted) {
      totalDue += b.agreedAmount;
      totalPaid += b.totalPaid;
      totalOutstanding += b.balanceDue;
    }

    slivers.add(SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: KpiCard(
                    label: 'Total dû',
                    value: MoneyFormatter.compact(totalDue),
                    icon: Icons.request_quote_outlined,
                    color: Colors.red.shade400,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: KpiCard(
                    label: 'Encaissé',
                    value: MoneyFormatter.compact(totalPaid),
                    icon: Icons.check_circle_outline,
                    color: Colors.green,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            KpiCard(
              label: 'Solde restant',
              value: MoneyFormatter.format(totalOutstanding),
              icon: Icons.account_balance_outlined,
              color: totalOutstanding > 0 ? Colors.orange : Colors.green,
            ),
            const SizedBox(height: 8),
            SectionHeader(
              title: 'Subscriptions',
              subtitle:
                  '${sorted.length} subscription${sorted.length > 1 ? 's' : ''}',
              icon: Icons.assignment_outlined,
            ),
          ],
        ),
      ),
    ));

    slivers.add(SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      sliver: SliverList.separated(
        itemCount: sorted.length,
        separatorBuilder: (_, __) => const SizedBox(height: 4),
        itemBuilder: (context, i) =>
            _BalanceTile(subscription: sorted[i]),
      ),
    ));
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 24)));
    return slivers;
  }
}

// ---------------------------------------------------------------------------
// Bannière hors-ligne
// ---------------------------------------------------------------------------

class _OfflineBanner extends ConsumerWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider);
    if (conn.canReachServer) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.cloud_off,
                size: 18, color: theme.colorScheme.onSecondaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Mode hors-ligne — données potentiellement obsolètes.',
                style: TextStyle(
                  color: theme.colorScheme.onSecondaryContainer,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Filtre classe
// ---------------------------------------------------------------------------

class _ClassroomFilter extends StatelessWidget {
  const _ClassroomFilter({
    required this.filter,
    required this.classroomsAsync,
    required this.onChanged,
  });

  final BalanceFilter filter;
  final AsyncValue<List<ClassroomDto>> classroomsAsync;
  final ValueChanged<BalanceFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = filter.classroomId != null;
    return ActionChip(
      avatar: const Icon(Icons.school, size: 16),
      label: Text(_label()),
      selected: selected,
      backgroundColor: selected
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.surfaceContainerHighest,
      onPressed: () => _openPicker(context),
    );
  }

  String _label() {
    if (filter.classroomId == null) return 'Toutes classes';
    return classroomsAsync.maybeWhen(
      data: (list) {
        for (final c in list) {
          if (c.id == filter.classroomId) return c.name;
        }
        return 'Classe #${filter.classroomId}';
      },
      orElse: () => 'Classe #${filter.classroomId}',
    );
  }

  Future<void> _openPicker(BuildContext context) async {
    final classrooms = classroomsAsync.maybeWhen(
      data: (list) => list,
      orElse: () => const <ClassroomDto>[],
    );
    if (classrooms.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Aucune classe disponible.')),
      );
      return;
    }
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: const Text('Toutes les classes'),
              leading: const Icon(Icons.clear_all),
              onTap: () => Navigator.pop(ctx, -1),
            ),
            const Divider(height: 1),
            ...classrooms.map((c) => ListTile(
                  title: Text(c.name),
                  subtitle: c.code.isEmpty ? null : Text(c.code),
                  trailing: filter.classroomId == c.id
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.pop(ctx, c.id),
                )),
          ],
        ),
      ),
    );
    if (selected == null) return;
    if (selected == -1) {
      onChanged(filter.copyWith(clearClassroom: true));
    } else {
      onChanged(filter.copyWith(classroomId: selected));
    }
  }
}

// ---------------------------------------------------------------------------
// Tuile subscription (solde élève)
// ---------------------------------------------------------------------------

/// Couleur associée à un [SubscriptionStatus].
Color _subscriptionStatusColor(SubscriptionStatus s) {
  switch (s) {
    case SubscriptionStatus.active:
      return Colors.blue;
    case SubscriptionStatus.partiel:
      return Colors.orange;
    case SubscriptionStatus.payed:
      return Colors.green;
    case SubscriptionStatus.annule:
      return Colors.grey;
  }
}

class _BalanceTile extends StatelessWidget {
  const _BalanceTile({required this.subscription});
  final FeeSubscriptionDto subscription;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sub = subscription;
    final settled = sub.isSettled;
    final initials = _initials(sub.studentName);
    final statusColor = _subscriptionStatusColor(sub.status);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: () => context.push(
          '/finance/payments/new?student_id=${sub.studentId}',
        ),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Ligne 1 : avatar + nom + matricule + classe + statut.
              Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Text(
                      initials,
                      style: TextStyle(
                        color: theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          sub.studentName ?? 'Élève inconnu',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                        Text(
                          [
                            if (sub.matricule != null &&
                                sub.matricule!.isNotEmpty)
                              sub.matricule!,
                            if (sub.classroomName != null)
                              sub.classroomName!,
                          ].join(' • '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  StatusBadge(
                    label: sub.status.label,
                    color: statusColor,
                    icon: settled ? Icons.check_circle : Icons.schedule,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Ligne 2 : dû / payé / reste.
              Row(
                children: [
                  Expanded(
                    child: _AmountColumn(
                      label: 'Convenu',
                      value: MoneyFormatter.format(sub.agreedAmount,
                          withSymbol: false),
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Expanded(
                    child: _AmountColumn(
                      label: 'Payé',
                      value: MoneyFormatter.format(sub.totalPaid,
                          withSymbol: false),
                      color: Colors.green.shade700,
                    ),
                  ),
                  Expanded(
                    child: _AmountColumn(
                      label: 'Reste',
                      value: MoneyFormatter.format(sub.balanceDue,
                          withSymbol: false),
                      color: sub.balanceDue > 0
                          ? Colors.orange.shade700
                          : Colors.green.shade700,
                      bold: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Progression.
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: sub.paymentRate,
                  minHeight: 6,
                  backgroundColor:
                      theme.colorScheme.surfaceContainerHighest,
                  color: settled ? Colors.green : Colors.orange,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Taux : ${(sub.paymentRate * 100).toStringAsFixed(0)} %',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AmountColumn extends StatelessWidget {
  const _AmountColumn({
    required this.label,
    required this.value,
    required this.color,
    this.bold = false,
  });

  final String label;
  final String value;
  final Color color;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          value,
          style: theme.textTheme.bodySmall?.copyWith(
            color: color,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

// --- Helpers ---

String _initials(String? name) {
  if (name == null || name.isEmpty) return '?';
  final parts = name.trim().split(RegExp(r'\s+'));
  if (parts.length >= 2) {
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }
  return name[0].toUpperCase();
}
