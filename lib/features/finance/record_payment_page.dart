/// Page d'enregistrement d'un nouveau paiement.
library;

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/constants.dart';
import '../../core/utils/formatters.dart';
import '../../shared/models/finance_dto.dart';
import '../../shared/models/student_dto.dart';
import '../../shared/widgets/widgets.dart';
import '../students/student_controller.dart';
import 'finance_controller.dart';

class RecordPaymentPage extends ConsumerStatefulWidget {
  final int? studentId;
  const RecordPaymentPage({super.key, this.studentId});

  @override
  ConsumerState<RecordPaymentPage> createState() => _RecordPaymentPageState();
}

class _RecordPaymentPageState extends ConsumerState<RecordPaymentPage> {
  int? _studentId;
  FeeSubscriptionDto? _selectedSubscription;
  final _amountCtrl = TextEditingController();
  final _referenceCtrl = TextEditingController();
  PaymentMethod _method = PaymentMethod.espece;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _studentId = widget.studentId;
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _referenceCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final studentAsync = _studentId != null
        ? ref.watch(studentDetailProvider(_studentId!))
        : const AsyncValue<StudentDto>.loading();

    return Scaffold(
      appBar: AppBar(title: const Text('Encaisser un paiement')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StudentPicker(
              selectedStudent: studentAsync.valueOrNull,
              onPick: (s) => setState(() {
                _studentId = s.id;
                _selectedSubscription = null;
              }),
            ),
            const SizedBox(height: 24),
            if (_studentId != null) ...[
              _SubscriptionPicker(
                studentId: _studentId!,
                selected: _selectedSubscription,
                onSelect: (sub) => setState(() => _selectedSubscription = sub),
              ),
              const SizedBox(height: 24),
            ],
            if (_selectedSubscription != null)
              _PaymentForm(
                subscription: _selectedSubscription!,
                amountCtrl: _amountCtrl,
                referenceCtrl: _referenceCtrl,
                method: _method,
                onMethodChanged: (m) => setState(() => _method = m!),
                saving: _saving,
                onSubmit: _onSubmit,
              ),
          ],
        ),
      ),
    );
  }

  void _onSubmit() async {
    if (_selectedSubscription == null) return;
    final amount = double.tryParse(_amountCtrl.text.replaceAll(',', '.'));
    if (amount == null || amount <= 0) return;

    setState(() => _saving = true);
    try {
      final req = PaymentRequest(
        studentId: _studentId!,
        subscriptionId: _selectedSubscription!.id,
        amount: amount,
        method: _method,
        reference: _referenceCtrl.text.trim(),
      );
      await ref.read(financeRepositoryProvider).recordPayment(req);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Paiement enregistré avec succès')),
        );
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur : $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _StudentPicker extends StatelessWidget {
  final StudentDto? selectedStudent;
  final ValueChanged<StudentDto> onPick;

  const _StudentPicker({this.selectedStudent, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.person_outline),
        title: Text(selectedStudent?.fullName ?? 'Choisir un élève'),
        subtitle: Text(selectedStudent?.matricule ?? 'Cliquer pour rechercher'),
        trailing: const Icon(Icons.search),
        onTap: () async {
          final s = await showDialog<StudentDto>(
            context: context,
            builder: (ctx) => const _StudentPickerDialog(),
          );
          if (s != null) onPick(s);
        },
      ),
    );
  }
}

class _SubscriptionPicker extends ConsumerWidget {
  final int studentId;
  final FeeSubscriptionDto? selected;
  final ValueChanged<FeeSubscriptionDto> onSelect;

  const _SubscriptionPicker({
    required this.studentId,
    this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(studentSubscriptionsProvider(studentId));

    return async.when(
      data: (list) {
        if (list.isEmpty) return const Text('Aucun solde dû pour cet élève');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Choisir la subscription', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...list.map((sub) => RadioListTile<FeeSubscriptionDto>(
                  title: Text(sub.feeCategoryName ?? 'Frais'),
                  subtitle: Text('Reste : ${MoneyFormatter.format(sub.balanceDue)}'),
                  value: sub,
                  groupValue: selected,
                  onChanged: (v) => onSelect(v!),
                )),
          ],
        );
      },
      loading: () => const AppLoading(),
      error: (e, st) => Text(e.toString()),
    );
  }
}

class _PaymentForm extends StatelessWidget {
  final FeeSubscriptionDto subscription;
  final TextEditingController amountCtrl;
  final TextEditingController referenceCtrl;
  final PaymentMethod method;
  final ValueChanged<PaymentMethod?> onMethodChanged;
  final bool saving;
  final VoidCallback onSubmit;

  const _PaymentForm({
    required this.subscription,
    required this.amountCtrl,
    required this.referenceCtrl,
    required this.method,
    required this.onMethodChanged,
    required this.saving,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextFormField(
          controller: amountCtrl,
          decoration: const InputDecoration(labelText: 'Montant (FCFA)'),
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<PaymentMethod>(
          value: method,
          items: PaymentMethod.values
              .map((m) => DropdownMenuItem(value: m, child: Text(m.label)))
              .toList(),
          onChanged: onMethodChanged,
          decoration: const InputDecoration(labelText: 'Méthode'),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: referenceCtrl,
          decoration: const InputDecoration(labelText: 'Référence / ID Transaction'),
        ),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: saving ? null : onSubmit,
          child: Text(saving ? 'Enregistrement...' : 'Valider le paiement'),
        ),
      ],
    );
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
      title: const Text('Rechercher un élève'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              decoration: const InputDecoration(hintText: 'Nom ou matricule'),
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
