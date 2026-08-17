/// Page Historique des paiements : liste filtrée par élève, méthode, statut, date.
library;

import 'package:flutter/material.dart' hide ConnectionState;
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
  final int? studentId;
  const PaymentsListPage({super.key, this.studentId});

  @override
  ConsumerState<PaymentsListPage> createState() => _PaymentsListPageState();
}

class _PaymentsListPageState extends ConsumerState<PaymentsListPage> {
  late PaymentFilter _filter;

  @override
  void initState() {
    super.initState();
    _filter = PaymentFilter(studentId: widget.studentId);
  }

  Future<void> _refresh() async {
    ref.invalidate(paymentsListProvider(_filter));
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final canRead = hasPermission(auth.permissions, RbacPermissions.paymentRead);

    if (!canRead) {
      return Scaffold(
        appBar: AppBar(title: const Text('Historique paiements')),
        body: const EmptyState(
          icon: Icons.lock_outline,
          title: 'Permission insuffisante',
          message: 'Vous n\'avez pas la permission PAYMENT_READ.',
        ),
      );
    }

    final paymentsAsync = ref.watch(paymentsListProvider(_filter));
    final studentAsync = _filter.studentId != null
        ? ref.watch(studentDetailProvider(_filter.studentId!))
        : const AsyncValue<StudentDto>.loading();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Historique paiements'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: Column(
        children: [
          _FilterBar(
            filter: _filter,
            selectedStudent: _filter.studentId != null ? studentAsync.valueOrNull : null,
            onPickStudent: () => _pickStudent(context),
            onClearStudent: () => setState(() => _filter = _filter.copyWith(clearStudent: true)),
            onChanged: (next) => setState(() => _filter = next),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: paymentsAsync.when(
                data: (page) {
                  final list = page.items;
                  if (list.isEmpty) {
                    return const EmptyState(
                      icon: Icons.history,
                      title: 'Aucun paiement',
                      message: 'Aucune transaction ne correspond aux filtres.',
                    );
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (ctx, i) => _PaymentTile(payment: list[i]),
                  );
                },
                loading: () => const AppLoading(),
                error: (e, st) => AppErrorWidget(message: e.toString(), onRetry: _refresh),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _pickStudent(BuildContext context) async {
    final s = await showDialog<StudentDto>(
      context: context,
      builder: (ctx) => const _StudentPickerDialog(),
    );
    if (s != null) {
      setState(() => _filter = _filter.copyWith(studentId: s.id));
    }
  }
}

class _FilterBar extends StatelessWidget {
  final PaymentFilter filter;
  final StudentDto? selectedStudent;
  final VoidCallback onPickStudent;
  final VoidCallback onClearStudent;
  final ValueChanged<PaymentFilter> onChanged;

  const _FilterBar({
    required this.filter,
    required this.selectedStudent,
    required this.onPickStudent,
    required this.onClearStudent,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Wrap(
        spacing: 8,
        children: [
          FilterChip(
            label: Text(selectedStudent?.fullName ?? 'Élève'),
            selected: filter.studentId != null,
            onSelected: (_) => onPickStudent(),
          ),
          FilterChip(
            label: Text(filter.method?.label ?? 'Méthode'),
            selected: filter.method != null,
            onSelected: (_) => _showMethodPicker(context),
          ),
        ],
      ),
    );
  }

  void _showMethodPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Toutes les méthodes'),
              onTap: () {
                onChanged(filter.copyWith(clearMethod: true));
                Navigator.pop(ctx);
              },
            ),
            ...PaymentMethod.values.map((m) => ListTile(
                  title: Text(m.label),
                  onTap: () {
                    onChanged(filter.copyWith(method: m));
                    Navigator.pop(ctx);
                  },
                )),
          ],
        ),
      ),
    );
  }
}

class _PaymentTile extends StatelessWidget {
  final PaymentDto payment;
  const _PaymentTile({required this.payment});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        title: Text(MoneyFormatter.format(payment.amount)),
        subtitle: Text('${payment.method.label} • ${payment.reference ?? "Pas de réf."}'),
        trailing: StatusBadge(label: payment.status.label, color: _statusColor(payment.status)),
      ),
    );
  }

  Color _statusColor(PaymentStatus s) {
    switch (s) {
      case PaymentStatus.valide: return Colors.green;
      case PaymentStatus.enAttente: return Colors.orange;
      default: return Colors.grey;
    }
  }
}

class _StudentPickerDialog extends ConsumerStatefulWidget {
  const _StudentPickerDialog();
  @override
  ConsumerState<_StudentPickerDialog> createState() => _StudentPickerDialogState();
}

class _StudentPickerDialogState extends ConsumerState<_StudentPickerDialog> {
  String _search = '';
  @override
  Widget build(BuildContext context) {
    final filter = StudentFilter(search: _search);
    final async = ref.watch(studentsListProvider(filter));

    return AlertDialog(
      title: const Text('Choisir un élève'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              decoration: const InputDecoration(hintText: 'Rechercher…'),
              onChanged: (v) => setState(() => _search = v),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: async.when(
                data: (list) => ListView.builder(
                  shrinkWrap: true,
                  itemCount: list.length,
                  itemBuilder: (ctx, i) => ListTile(
                    title: Text(list[i].fullName),
                    onTap: () => Navigator.pop(context, list[i]),
                  ),
                ),
                loading: () => const AppLoading(),
                error: (e, st) => Text(e.toString()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
