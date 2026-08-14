/// Page "Paiements" : liste filtrée des paiements (recherche + type + statut +
/// classe + plage de dates) avec pagination, pull-to-refresh, en-tête de synthèse
/// (total + nombre), et FAB d'enregistrement (RBAC PAYMENT_VALIDATE).
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

class PaymentsListPage extends ConsumerStatefulWidget {
  const PaymentsListPage({super.key});

  @override
  ConsumerState<PaymentsListPage> createState() => _PaymentsListPageState();
}

class _PaymentsListPageState extends ConsumerState<PaymentsListPage> {
  /// Filtre de base (page toujours 1 — la pagination se gère via [_extraItems]).
  PaymentFilter _filter = const PaymentFilter(page: 1, perPage: 25);

  String _searchText = '';
  DateTime? _lastSearchAt;

  /// Éléments accumulés via "Charger plus" (pages 2..N).
  final List<PaymentDto> _extraItems = [];

  /// Page suivante à charger.
  int _nextPage = 2;

  bool _loadingMore = false;

  // --- Recherche debouncée ---

  void _onSearchChanged(String value) {
    setState(() => _searchText = value);
    final now = DateTime.now();
    _lastSearchAt = now;
    Future.delayed(const Duration(milliseconds: 350), () {
      if (_lastSearchAt == now) {
        _resetPagination();
        setState(() => _filter = _filter.copyWith(search: value.trim()));
      }
    });
  }

  void _resetPagination() {
    _extraItems.clear();
    _nextPage = 2;
  }

  // --- Mutations de filtre (réinitialisent la pagination) ---

  void _updateFilter(PaymentFilter next) {
    _resetPagination();
    setState(() => _filter = next);
  }

  // --- Refresh ---

  Future<void> _refresh() async {
    _resetPagination();
    ref.invalidate(paymentsListProvider);
    ref.invalidate(classroomsForFinanceProvider);
    setState(() => _filter = _filter.copyWith());
  }

  // --- Pagination ---

  Future<void> _loadMore(int currentPage, int totalPages) async {
    if (_loadingMore || currentPage >= totalPages) return;
    setState(() => _loadingMore = true);
    try {
      final page = await ref.read(
        paymentsListProvider(_filter.copyWith(page: _nextPage)).future,
      );
      if (mounted) {
        setState(() {
          _extraItems.addAll(page.items);
          _nextPage++;
          _loadingMore = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  // --- Date pickers ---

  Future<void> _pickDate({required bool isFrom}) async {
    final now = DateTime.now();
    final initial = isFrom
        ? (_filter.fromDate ?? now)
        : (_filter.toDate ?? now);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 3),
      lastDate: now,
    );
    if (picked == null) return;
    _updateFilter(
      isFrom
          ? _filter.copyWith(
              fromDate: picked,
              // Si la date "au" est avant la nouvelle date "du", on la pousse.
              toDate: (_filter.toDate != null &&
                      _filter.toDate!.isBefore(picked))
                  ? picked
                  : _filter.toDate,
            )
          : _filter.copyWith(toDate: picked),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final perms = auth.permissions;
    final canRead = hasPermission(perms, RbacPermissions.paymentRead);
    final canValidate = hasPermission(perms, RbacPermissions.paymentValidate);

    if (!canRead) {
      return Scaffold(
        appBar: AppBar(title: const Text('Paiements')),
        body: const EmptyState(
          icon: Icons.lock_outline,
          title: 'Permission insuffisante',
          message:
              'Vous n\'avez pas la permission PAYMENT_READ pour consulter les paiements.',
        ),
      );
    }

    final classroomsAsync = ref.watch(classroomsForFinanceProvider);
    final paymentsAsync = ref.watch(paymentsListProvider(_filter));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Paiements'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Rafraîchir',
            onPressed: _refresh,
          ),
        ],
      ),
      floatingActionButton: canValidate
          ? FloatingActionButton.extended(
              onPressed: () => context.push('/finance/payments/new'),
              icon: const Icon(Icons.add),
              label: const Text('Enregistrer'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          slivers: _buildSlivers(context, paymentsAsync, classroomsAsync),
        ),
      ),
    );
  }

  List<Widget> _buildSlivers(
    BuildContext context,
    AsyncValue<PaginatedPayments> paymentsAsync,
    AsyncValue<List<ClassroomDto>> classroomsAsync,
  ) {
    final slivers = <Widget>[
      // Bannière hors-ligne.
      const SliverToBoxAdapter(child: _OfflineBanner()),
      // Barre de recherche.
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: AppSearchBar(
            hint: 'Rechercher (élève, matricule, référence…)',
            onChanged: _onSearchChanged,
          ),
        ),
      ),
      // Barre de filtres.
      SliverToBoxAdapter(
        child: _FilterBar(
          filter: _filter,
          classroomsAsync: classroomsAsync,
          onChanged: _updateFilter,
          onPickFrom: () => _pickDate(isFrom: true),
          onPickTo: () => _pickDate(isFrom: false),
        ),
      ),
    ];

    // Contenu principal selon l'état asynchrone.
    if (paymentsAsync.isLoading) {
      slivers.add(const SliverFillRemaining(
        hasScrollBody: false,
        child: AppLoading(label: 'Chargement des paiements…'),
      ));
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 88)));
      return slivers;
    }
    if (paymentsAsync.hasError) {
      slivers.add(SliverFillRemaining(
        hasScrollBody: false,
        child: AppErrorWidget(
          message: paymentsAsync.error.toString(),
          onRetry: _refresh,
        ),
      ));
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 88)));
      return slivers;
    }

    final page = paymentsAsync.value ?? const PaginatedPayments();
    if (page.items.isEmpty && _extraItems.isEmpty) {
      slivers.add(const SliverFillRemaining(
        hasScrollBody: false,
        child: EmptyState(
          icon: Icons.receipt_long_outlined,
          title: 'Aucun paiement',
          message: 'Aucun paiement ne correspond à votre recherche.',
        ),
      ));
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 88)));
      return slivers;
    }

    final allItems = [...page.items, ..._extraItems];
    // En-tête de synthèse.
    slivers.add(SliverToBoxAdapter(
      child: _SummaryHeader(
        items: allItems,
        totalMatching: page.total,
        displayedCount: allItems.length,
      ),
    ));
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 4)));
    // Liste des paiements.
    slivers.add(SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      sliver: SliverList.separated(
        itemCount: allItems.length,
        separatorBuilder: (_, __) => const SizedBox(height: 4),
        itemBuilder: (context, i) => _PaymentTile(payment: allItems[i]),
      ),
    ));
    // Bouton "Charger plus".
    if (page.page < page.totalPages) {
      slivers.add(SliverToBoxAdapter(
        child: _LoadMoreButton(
          loading: _loadingMore,
          currentPage: page.page,
          totalPages: page.totalPages,
          onLoad: () => _loadMore(page.page, page.totalPages),
        ),
      ));
    }
    // Espace pour le FAB.
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 88)));
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
// Helper : fusion de filtre avec effacement possible des champs nullables.
//
// [PaymentFilter.copyWith] ne supporte pas l'effacement des champs nullables
// (passer `null` conserve la valeur existante). Cette fonction permet de
// reconstruire un filtre en forcant certains champs à `null`.
// ---------------------------------------------------------------------------

PaymentFilter _mergeFilter(
  PaymentFilter base, {
  int? classroomId,
  bool clearClassroom = false,
  PaymentType? type,
  bool clearType = false,
  PaymentStatus? status,
  bool clearStatus = false,
  DateTime? fromDate,
  bool clearFromDate = false,
  DateTime? toDate,
  bool clearToDate = false,
  String? search,
  bool clearSearch = false,
  int? page,
  int? perPage,
}) =>
    PaymentFilter(
      studentId: base.studentId,
      classroomId:
          clearClassroom ? null : (classroomId ?? base.classroomId),
      type: clearType ? null : (type ?? base.type),
      status: clearStatus ? null : (status ?? base.status),
      fromDate: clearFromDate ? null : (fromDate ?? base.fromDate),
      toDate: clearToDate ? null : (toDate ?? base.toDate),
      search: clearSearch ? null : (search ?? base.search),
      page: page ?? base.page,
      perPage: perPage ?? base.perPage,
    );

// ---------------------------------------------------------------------------
// Barre de filtres
// ---------------------------------------------------------------------------

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.filter,
    required this.classroomsAsync,
    required this.onChanged,
    required this.onPickFrom,
    required this.onPickTo,
  });

  final PaymentFilter filter;
  final AsyncValue<List<ClassroomDto>> classroomsAsync;
  final ValueChanged<PaymentFilter> onChanged;
  final VoidCallback onPickFrom;
  final VoidCallback onPickTo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          // Type de paiement.
          _PopupFilterChip<PaymentType?>(
            label: filter.type?.label ?? 'Type',
            icon: Icons.category_outlined,
            selected: filter.type != null,
            value: filter.type,
            items: const [
              DropdownMenuItem(value: null, child: Text('Tous types')),
              ...PaymentType.values.map(
                (t) => DropdownMenuItem(value: t, child: Text(t.label)),
              ),
            ],
            onChanged: (v) => onChanged(
              _mergeFilter(filter, type: v, clearType: v == null),
            ),
          ),
          // Statut.
          _PopupFilterChip<PaymentStatus?>(
            label: filter.status?.label ?? 'Statut',
            icon: Icons.flag_outlined,
            selected: filter.status != null,
            value: filter.status,
            items: const [
              DropdownMenuItem(value: null, child: Text('Tous statuts')),
              ...PaymentStatus.values.map(
                (s) => DropdownMenuItem(value: s, child: Text(s.label)),
              ),
            ],
            onChanged: (v) => onChanged(
              _mergeFilter(filter, status: v, clearStatus: v == null),
            ),
          ),
          // Classe.
          _ClassroomFilterChip(
            filter: filter,
            classroomsAsync: classroomsAsync,
            onChanged: onChanged,
          ),
          // Date "Du".
          ActionChip(
            avatar: const Icon(Icons.calendar_today, size: 16),
            label: Text(filter.fromDate != null
                ? 'Du ${DateFormatter.date(filter.fromDate)}'
                : 'Date début'),
            onPressed: onPickFrom,
            backgroundColor: filter.fromDate != null
                ? theme.colorScheme.primaryContainer
                : null,
          ),
          // Date "Au".
          ActionChip(
            avatar: const Icon(Icons.event, size: 16),
            label: Text(filter.toDate != null
                ? 'Au ${DateFormatter.date(filter.toDate)}'
                : 'Date fin'),
            onPressed: onPickTo,
            backgroundColor: filter.toDate != null
                ? theme.colorScheme.primaryContainer
                : null,
          ),
          // Réinitialiser.
          if (filter.type != null ||
              filter.status != null ||
              filter.classroomId != null ||
              filter.fromDate != null ||
              filter.toDate != null ||
              (filter.search?.isNotEmpty ?? false))
            ActionChip(
              label: const Text('Réinitialiser'),
              avatar: const Icon(Icons.clear, size: 18),
              onPressed: () => onChanged(const PaymentFilter(page: 1, perPage: 25)),
            ),
        ],
      ),
    );
  }
}

/// Chip-filtre générique avec menu déroulant (Dropdown).
class _PopupFilterChip<T> extends StatelessWidget {
  const _PopupFilterChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ActionChip(
      avatar: Icon(icon, size: 16),
      label: Text(label),
      selected: selected,
      backgroundColor: selected
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.surfaceContainerHighest,
      onPressed: () {
        // Ouvre un menu déroulant via showModalBottomSheet (mobile-friendly).
        // On appelle onChanged directement dans onTap pour gérer le cas
        // "Tous" (valeur null) — un .then() ne distinguerait pas la sélection
        // null d'un dismiss sans sélection.
        showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          builder: (ctx) {
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final item in items)
                    ListTile(
                      title: item.child,
                      selected: item.value == value,
                      trailing:
                          item.value == value ? const Icon(Icons.check) : null,
                      onTap: () {
                        Navigator.pop(ctx);
                        onChanged(item.value as T);
                      },
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _ClassroomFilterChip extends StatelessWidget {
  const _ClassroomFilterChip({
    required this.filter,
    required this.classroomsAsync,
    required this.onChanged,
  });

  final PaymentFilter filter;
  final AsyncValue<List<ClassroomDto>> classroomsAsync;
  final ValueChanged<PaymentFilter> onChanged;

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
                  subtitle: c.code == null ? null : Text(c.code!),
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
      onChanged(_mergeFilter(filter, clearClassroom: true));
    } else {
      onChanged(_mergeFilter(filter, classroomId: selected));
    }
  }
}

// ---------------------------------------------------------------------------
// En-tête de synthèse (total + nombre affichés)
// ---------------------------------------------------------------------------

class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader({
    required this.items,
    required this.totalMatching,
    required this.displayedCount,
  });

  final List<PaymentDto> items;
  final int totalMatching;
  final int displayedCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    double sum = 0;
    for (final p in items) {
      if (p.status != PaymentStatus.annule) sum += p.amount;
    }
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.payments_outlined,
                color: theme.colorScheme.primary,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    MoneyFormatter.format(sum),
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  Text(
                    '$displayedCount paiement${displayedCount > 1 ? 's' : ''}'
                    '${totalMatching > displayedCount ? ' sur $totalMatching' : ''}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bouton "Charger plus"
// ---------------------------------------------------------------------------

class _LoadMoreButton extends StatelessWidget {
  const _LoadMoreButton({
    required this.loading,
    required this.currentPage,
    required this.totalPages,
    required this.onLoad,
  });

  final bool loading;
  final int currentPage;
  final int totalPages;
  final VoidCallback onLoad;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Center(
        child: loading
            ? const Padding(
                padding: EdgeInsets.all(8),
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : OutlinedButton.icon(
                onPressed: onLoad,
                icon: const Icon(Icons.expand_more),
                label: Text(
                    'Charger plus (page ${currentPage + 1} / $totalPages)'),
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tuile paiement
// ---------------------------------------------------------------------------

/// Couleur associée à un [PaymentStatus].
Color _statusColor(PaymentStatus s) {
  switch (s) {
    case PaymentStatus.valide:
      return Colors.green;
    case PaymentStatus.enAttente:
      return Colors.orange;
    case PaymentStatus.annule:
      return Colors.red;
  }
}

class _PaymentTile extends StatelessWidget {
  const _PaymentTile({required this.payment});
  final PaymentDto payment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initials = _initials(payment.studentName);
    final statusColor = _statusColor(payment.status);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Text(
            initials,
            style: TextStyle(
              color: theme.colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                payment.studentName ?? 'Élève inconnu',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              MoneyFormatter.format(payment.amount),
              style: theme.textTheme.titleSmall?.copyWith(
                color: Colors.green.shade700,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Wrap(
              spacing: 8,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (payment.matricule != null)
                  _MetaChip(
                    icon: Icons.badge_outlined,
                    text: payment.matricule!,
                  ),
                _MetaChip(
                  icon: Icons.category_outlined,
                  text: payment.type.label,
                ),
                _MetaChip(
                  icon: Icons.account_balance_wallet_outlined,
                  text: payment.method.label,
                ),
                if (payment.date != null)
                  _MetaChip(
                    icon: Icons.calendar_today_outlined,
                    text: DateFormatter.date(payment.date),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                StatusBadge(
                  label: payment.status.label,
                  color: statusColor,
                  icon: payment.status == PaymentStatus.valide
                      ? Icons.check_circle
                      : (payment.status == PaymentStatus.enAttente
                          ? Icons.pending
                          : Icons.cancel),
                ),
                if (payment.receiptNumber != null &&
                    payment.receiptNumber!.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Reçu : ${payment.receiptNumber}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
        onTap: () => _showDetail(context),
      ),
    );
  }

  void _showDetail(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _PaymentDetailSheet(payment: payment),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 3),
        Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _PaymentDetailSheet extends StatelessWidget {
  const _PaymentDetailSheet({required this.payment});
  final PaymentDto payment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor = _statusColor(payment.status);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: 'Détail du paiement',
              icon: Icons.receipt_long,
            ),
            const SizedBox(height: 8),
            _DetailRow(
              label: 'Élève',
              value: payment.studentName ?? '—',
              icon: Icons.person_outline,
            ),
            if (payment.matricule != null)
              _DetailRow(
                label: 'Matricule',
                value: payment.matricule!,
                icon: Icons.badge_outlined,
              ),
            if (payment.classroomName != null)
              _DetailRow(
                label: 'Classe',
                value: payment.classroomName!,
                icon: Icons.school_outlined,
              ),
            _DetailRow(
              label: 'Type',
              value: payment.type.label,
              icon: Icons.category_outlined,
            ),
            _DetailRow(
              label: 'Montant',
              value: MoneyFormatter.format(payment.amount),
              icon: Icons.payments_outlined,
              valueColor: Colors.green.shade700,
            ),
            _DetailRow(
              label: 'Méthode',
              value: payment.method.label,
              icon: Icons.account_balance_wallet_outlined,
            ),
            _DetailRow(
              label: 'Date',
              value: DateFormatter.date(payment.date),
              icon: Icons.calendar_today_outlined,
            ),
            if (payment.reference != null &&
                payment.reference!.isNotEmpty)
              _DetailRow(
                label: 'Référence',
                value: payment.reference!,
                icon: Icons.tag,
              ),
            if (payment.receiptNumber != null &&
                payment.receiptNumber!.isNotEmpty)
              _DetailRow(
                label: 'N° de reçu',
                value: payment.receiptNumber!,
                icon: Icons.receipt,
              ),
            if (payment.collectedByName != null)
              _DetailRow(
                label: 'Encaissé par',
                value: payment.collectedByName!,
                icon: Icons.person,
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Statut : '),
                StatusBadge(
                  label: payment.status.label,
                  color: statusColor,
                ),
              ],
            ),
            if (payment.notes != null && payment.notes!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Notes', style: theme.textTheme.labelMedium),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(payment.notes!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    required this.icon,
    this.valueColor,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: valueColor,
              ),
            ),
          ),
        ],
      ),
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
