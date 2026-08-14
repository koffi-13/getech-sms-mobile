/// Page "Paiements" : liste filtrée des paiements avec pagination,
/// pull-to-refresh, en-tête de synthèse (total + nombre), et FAB
/// d'enregistrement (RBAC PAYMENT_VALIDATE).
///
/// Filtres :
/// - `student_id` (sélecteur d'élève — serveur).
/// - `method` (PaymentMethod — client-side).
/// - `status` (PaymentStatus — client-side).
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
import '../../shared/models/finance_dto.dart';
import '../../shared/models/student_dto.dart';
import '../../shared/widgets/widgets.dart';
import '../connections/connection_state.dart';
import '../students/student_controller.dart';
import 'finance_controller.dart';

class PaymentsListPage extends ConsumerStatefulWidget {
  const PaymentsListPage({super.key});

  @override
  ConsumerState<PaymentsListPage> createState() => _PaymentsListPageState();
}

class _PaymentsListPageState extends ConsumerState<PaymentsListPage> {
  PaymentFilter _filter = const PaymentFilter(page: 1, perPage: 25);

  /// Élève sélectionné (résolu via [studentDetailProvider] si `_filter.studentId`
  /// est non null — par ex. au retour depuis une autre page).
  StudentDto? _selectedStudent;

  /// Éléments accumulés via "Charger plus" (pages 2..N).
  final List<PaymentDto> _extraItems = [];

  /// Page suivante à charger.
  int _nextPage = 2;

  bool _loadingMore = false;

  // --- Mutations de filtre (réinitialisent la pagination) ---

  void _updateFilter(PaymentFilter next) {
    _resetPagination();
    setState(() => _filter = next);
  }

  void _resetPagination() {
    _extraItems.clear();
    _nextPage = 2;
  }

  // --- Refresh ---

  Future<void> _refresh() async {
    _resetPagination();
    ref.invalidate(paymentsListProvider);
    setState(() => _filter = _filter.copyWith());
  }

  // --- Pagination ---

  Future<void> _loadMore(int total) async {
    if (_loadingMore) return;
    final loaded = _filter.perPage + _extraItems.length;
    if (loaded >= total) return;
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

  // --- Sélecteur d'élève ---

  Future<void> _openStudentPicker() async {
    final selected = await showDialog<StudentDto>(
      context: context,
      builder: (_) => const _StudentPickerDialog(),
    );
    if (selected != null) {
      setState(() => _selectedStudent = selected);
      _updateFilter(_filter.copyWith(studentId: selected.id));
    }
  }

  void _clearStudent() {
    setState(() => _selectedStudent = null);
    _updateFilter(const PaymentFilter(page: 1, perPage: 25));
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

    // Résolution de l'élève présélectionné (si _filter.studentId est set sans
    // _selectedStudent — par ex. via un deep-link).
    if (_filter.studentId != null && _selectedStudent == null) {
      final preselectAsync =
          ref.watch(studentDetailProvider(_filter.studentId!));
      preselectAsync.whenData((s) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _selectedStudent == null) {
            setState(() => _selectedStudent = s);
          }
        });
      });
    }

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
          slivers: _buildSlivers(context, paymentsAsync),
        ),
      ),
    );
  }

  List<Widget> _buildSlivers(
    BuildContext context,
    AsyncValue<PaymentListResponse> paymentsAsync,
  ) {
    final slivers = <Widget>[
      // Bannière hors-ligne.
      const SliverToBoxAdapter(child: _OfflineBanner()),
      // Barre de filtres.
      SliverToBoxAdapter(
        child: _FilterBar(
          filter: _filter,
          selectedStudent: _selectedStudent,
          onPickStudent: _openStudentPicker,
          onClearStudent: _clearStudent,
          onChanged: _updateFilter,
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

    final page = paymentsAsync.value ?? const PaymentListResponse();
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
    if (allItems.length < page.total) {
      slivers.add(SliverToBoxAdapter(
        child: _LoadMoreButton(
          loading: _loadingMore,
          displayedCount: allItems.length,
          total: page.total,
          onLoad: () => _loadMore(page.total),
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
// ---------------------------------------------------------------------------

PaymentFilter _mergeFilter(
  PaymentFilter base, {
  int? studentId,
  bool clearStudent = false,
  PaymentMethod? method,
  bool clearMethod = false,
  PaymentStatus? status,
  bool clearStatus = false,
  String? search,
  bool clearSearch = false,
  int? page,
  int? perPage,
}) =>
    PaymentFilter(
      studentId: clearStudent ? null : (studentId ?? base.studentId),
      method: clearMethod ? null : (method ?? base.method),
      status: clearStatus ? null : (status ?? base.status),
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
    required this.selectedStudent,
    required this.onPickStudent,
    required this.onClearStudent,
    required this.onChanged,
  });

  final PaymentFilter filter;
  final StudentDto? selectedStudent;
  final VoidCallback onPickStudent;
  final VoidCallback onClearStudent;
  final ValueChanged<PaymentFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          // Élève.
          ActionChip(
            avatar: const Icon(Icons.person_search, size: 16),
            label: Text(selectedStudent?.fullName ?? 'Tous les élèves'),
            selected: filter.studentId != null,
            backgroundColor: filter.studentId != null
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.surfaceContainerHighest,
            onPressed: onPickStudent,
            onDeleted: filter.studentId != null ? onClearStudent : null,
            deleteIconColor: theme.colorScheme.onPrimaryContainer,
          ),
          // Méthode.
          _PopupFilterChip<PaymentMethod?>(
            label: filter.method?.label ?? 'Méthode',
            icon: Icons.account_balance_wallet_outlined,
            selected: filter.method != null,
            value: filter.method,
            items: const [
              DropdownMenuItem(value: null, child: Text('Toutes méthodes')),
              ...PaymentMethod.values.map(
                (m) => DropdownMenuItem(value: m, child: Text(m.label)),
              ),
            ],
            onChanged: (v) => onChanged(
              _mergeFilter(filter, method: v, clearMethod: v == null),
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
          // Réinitialiser.
          if (filter.studentId != null ||
              filter.method != null ||
              filter.status != null ||
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
      if (p.status == PaymentStatus.valide) sum += p.amount;
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
    required this.displayedCount,
    required this.total,
    required this.onLoad,
  });

  final bool loading;
  final int displayedCount;
  final int total;
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
                    'Charger plus ($displayedCount / $total)'),
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
    case PaymentStatus.echec:
      return Colors.red;
    case PaymentStatus.rembourse:
      return Colors.purple;
    case PaymentStatus.annule:
      return Colors.grey;
  }
}

/// Icône associée à un [PaymentStatus].
IconData _statusIcon(PaymentStatus s) {
  switch (s) {
    case PaymentStatus.valide:
      return Icons.check_circle;
    case PaymentStatus.enAttente:
      return Icons.pending;
    case PaymentStatus.echec:
      return Icons.error_outline;
    case PaymentStatus.rembourse:
      return Icons.undo;
    case PaymentStatus.annule:
      return Icons.cancel;
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
                  icon: Icons.account_balance_wallet_outlined,
                  text: payment.method.label,
                ),
                if (payment.paymentDate != null)
                  _MetaChip(
                    icon: Icons.calendar_today_outlined,
                    text: DateFormatter.dateTime(payment.paymentDate),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                StatusBadge(
                  label: payment.status.label,
                  color: statusColor,
                  icon: _statusIcon(payment.status),
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
            if (payment.subscriptionId != null)
              _DetailRow(
                label: 'Subscription',
                value: '#${payment.subscriptionId}',
                icon: Icons.assignment_outlined,
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
              value: DateFormatter.dateTime(payment.paymentDate),
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
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Statut : '),
                StatusBadge(
                  label: payment.status.label,
                  color: statusColor,
                  icon: _statusIcon(payment.status),
                ),
              ],
            ),
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

// ---------------------------------------------------------------------------
// Dialogue de sélection d'élève (recherche + liste)
// ---------------------------------------------------------------------------

class _StudentPickerDialog extends ConsumerStatefulWidget {
  const _StudentPickerDialog();

  @override
  ConsumerState<_StudentPickerDialog> createState() =>
      _StudentPickerDialogState();
}

class _StudentPickerDialogState extends ConsumerState<_StudentPickerDialog> {
  String _search = '';
  DateTime? _lastSearchAt;

  void _onSearchChanged(String value) {
    final now = DateTime.now();
    _lastSearchAt = now;
    Future.delayed(const Duration(milliseconds: 300), () {
      if (_lastSearchAt == now && mounted) {
        setState(() => _search = value.trim());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final filter = StudentFilter(search: _search.trim(), perPage: 50);
    final async = ref.watch(studentsListProvider(filter));

    return Dialog(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Sélectionner un élève',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            AppSearchBar(
              hint: 'Nom ou matricule…',
              onChanged: _onSearchChanged,
              autofocus: true,
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 320,
              child: async.when(
                data: (students) {
                  if (students.isEmpty) {
                    return const EmptyState(
                      icon: Icons.person_search,
                      title: 'Aucun élève trouvé',
                    );
                  }
                  return ListView.separated(
                    itemCount: students.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final s = students[i];
                      return ListTile(
                        leading: CircleAvatar(
                          child: Text(s.displayInitials),
                        ),
                        title: Text(s.fullName),
                        subtitle: Text(
                          [
                            if (s.matricule.isNotEmpty) s.matricule,
                            s.classroomName,
                          ].whereType<String>().join(' • '),
                        ),
                        onTap: () => Navigator.of(context).pop(s),
                      );
                    },
                  );
                },
                loading: () => const AppLoading(),
                error: (e, _) => AppErrorWidget(message: e.toString()),
              ),
            ),
          ],
        ),
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
