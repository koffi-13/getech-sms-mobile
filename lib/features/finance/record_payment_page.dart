/// Page "Enregistrer un paiement" : formulaire de saisie d'un paiement avec
/// sélection d'élève, type, montant, méthode, date, référence et notes.
///
/// RBAC : PAYMENT_VALIDATE requis pour afficher le formulaire.
///
/// Hors-ligne : le paiement est enfilé dans l'outbox (sync différée) et un
/// placeholder est retourné pour le feedback UI.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

class RecordPaymentPage extends ConsumerStatefulWidget {
  const RecordPaymentPage({super.key, this.studentId});

  /// ID de l'élève présélectionné (depuis la page Soldes, par exemple).
  final int? studentId;

  @override
  ConsumerState<RecordPaymentPage> createState() => _RecordPaymentPageState();
}

class _RecordPaymentPageState extends ConsumerState<RecordPaymentPage> {
  final _formKey = GlobalKey<FormState>();

  // Contrôleurs de texte.
  late final TextEditingController _amountCtrl;
  late final TextEditingController _referenceCtrl;
  late final TextEditingController _notesCtrl;

  // État du formulaire.
  StudentDto? _selectedStudent;
  PaymentType _type = PaymentType.scolarite;
  PaymentMethod _method = PaymentMethod.espece;
  DateTime _date = DateTime.now();

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _amountCtrl = TextEditingController();
    _referenceCtrl = TextEditingController();
    _notesCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _referenceCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(_date.year - 2),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _openStudentPicker() async {
    final selected = await showDialog<StudentDto>(
      context: context,
      builder: (_) => const _StudentPickerDialog(),
    );
    if (selected != null) {
      setState(() => _selectedStudent = selected);
    }
  }

  double? get _parsedAmount {
    final raw = _amountCtrl.text.trim().replaceAll(RegExp(r'[^\d.,]'), '');
    final normalized = raw.replaceAll(',', '.');
    return double.tryParse(normalized);
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedStudent == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Veuillez sélectionner un élève.')),
      );
      return;
    }
    final amount = _parsedAmount;
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Le montant doit être supérieur à 0.')),
      );
      return;
    }

    setState(() => _saving = true);
    final req = PaymentRequest(
      studentId: _selectedStudent!.id,
      type: _type,
      amount: amount,
      method: _method,
      date: _date,
      reference: _referenceCtrl.text.trim().isEmpty
          ? null
          : _referenceCtrl.text.trim(),
      notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
    );

    try {
      final payment =
          await ref.read(financeRepositoryProvider).recordPayment(req);
      if (!mounted) return;

      // Invalide les listes pour rafraîchir.
      ref.invalidate(paymentsListProvider);
      ref.invalidate(balancesProvider);
      ref.invalidate(paymentsTodayProvider);

      final msg = payment.status == PaymentStatus.enAttente
          ? 'Paiement mis en file d\'attente (hors-ligne). Il sera synchronisé ultérieurement.'
          : 'Paiement enregistré${payment.receiptNumber != null && payment.receiptNumber!.isNotEmpty ? ' — Reçu n°${payment.receiptNumber}' : ''}.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: payment.status == PaymentStatus.enAttente
              ? Colors.orange.shade700
              : Colors.green.shade700,
        ),
      );
      context.pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur : $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final canValidate =
        hasPermission(auth.permissions, RbacPermissions.paymentValidate);
    final conn = ref.watch(connectionProvider);
    final isOffline = !conn.canReachServer;

    // Préselection d'élève : on watch studentDetailProvider jusqu'à ce que
    // l'élève soit chargé et assigné à _selectedStudent.
    if (widget.studentId != null && _selectedStudent == null) {
      final preselectAsync =
          ref.watch(studentDetailProvider(widget.studentId!));
      preselectAsync.whenData((s) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _selectedStudent == null) {
            setState(() => _selectedStudent = s);
          }
        });
      });
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Nouveau paiement')),
      body: !canValidate
          ? const EmptyState(
              icon: Icons.lock_outline,
              title: 'Permission insuffisante',
              message:
                  'Vous n\'avez pas la permission PAYMENT_VALIDATE pour enregistrer un paiement.',
            )
          : Form(
              key: _formKey,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (isOffline) ...[
                      const _OfflineWarning(),
                      const SizedBox(height: 12),
                    ],
                    // Élève.
                    _StudentField(
                      student: _selectedStudent,
                      onTap: _openStudentPicker,
                    ),
                    const SizedBox(height: 16),
                    // Type.
                    DropdownButtonFormField<PaymentType>(
                      value: _type,
                      decoration: const InputDecoration(
                        labelText: 'Type de paiement',
                        prefixIcon: Icon(Icons.category_outlined),
                      ),
                      items: PaymentType.values
                          .map((t) => DropdownMenuItem(
                                value: t,
                                child: Text(t.label),
                              ))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) setState(() => _type = v);
                      },
                    ),
                    const SizedBox(height: 16),
                    // Montant.
                    TextFormField(
                      controller: _amountCtrl,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                            RegExp(r'[\d.,]')),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Montant',
                        hintText: '0',
                        suffixText: 'FCFA',
                        prefixIcon: Icon(Icons.payments_outlined),
                      ),
                      validator: (v) {
                        final amt = _parsedAmount;
                        if (amt == null || amt <= 0) {
                          return 'Entrez un montant valide (> 0).';
                        }
                        return null;
                      },
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 16),
                    // Méthode.
                    DropdownButtonFormField<PaymentMethod>(
                      value: _method,
                      decoration: const InputDecoration(
                        labelText: 'Méthode de paiement',
                        prefixIcon:
                            Icon(Icons.account_balance_wallet_outlined),
                      ),
                      items: PaymentMethod.values
                          .map((m) => DropdownMenuItem(
                                value: m,
                                child: Text(m.label),
                              ))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) setState(() => _method = v);
                      },
                    ),
                    const SizedBox(height: 16),
                    // Date.
                    InkWell(
                      onTap: _pickDate,
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Date',
                          prefixIcon: Icon(Icons.calendar_today_outlined),
                        ),
                        child: Text(DateFormatter.date(_date)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Référence.
                    TextFormField(
                      controller: _referenceCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Référence (optionnel)',
                        hintText: 'Ex. ID transaction Mobile Money',
                        prefixIcon: Icon(Icons.tag),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 16),
                    // Notes.
                    TextFormField(
                      controller: _notesCtrl,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Notes (optionnel)',
                        prefixIcon: Icon(Icons.notes),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 24),
                    // Récapitulatif.
                    _RecapCard(
                      student: _selectedStudent,
                      type: _type,
                      amount: _parsedAmount ?? 0,
                      method: _method,
                      date: _date,
                    ),
                    const SizedBox(height: 16),
                    // Bouton.
                    FilledButton.icon(
                      onPressed: _saving ? null : _submit,
                      icon: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.check),
                      label: Text(_saving ? 'Enregistrement…' : 'Enregistrer'),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Avertissement hors-ligne
// ---------------------------------------------------------------------------

class _OfflineWarning extends StatelessWidget {
  const _OfflineWarning();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off, color: Colors.orange.shade700, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Mode hors-ligne — le paiement sera synchronisé ultérieurement.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.orange.shade900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Champ "Élève" (sélectionneur)
// ---------------------------------------------------------------------------

class _StudentField extends StatelessWidget {
  const _StudentField({required this.student, required this.onTap});
  final StudentDto? student;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasStudent = student != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: 'Élève *',
          prefixIcon: const Icon(Icons.person_outline),
          suffixIcon: const Icon(Icons.search),
          border: const OutlineInputBorder(),
        ),
        child: hasStudent
            ? Row(
                children: [
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Text(
                      student!.displayInitials,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          student!.fullName,
                          style: theme.textTheme.bodyMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (student!.matricule.isNotEmpty ||
                            student!.classroomName != null)
                          Text(
                            [
                              if (student!.matricule.isNotEmpty)
                                student!.matricule,
                              student!.classroomName,
                            ].whereType<String>().join(' • '),
                            style: theme.textTheme.bodySmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                ],
              )
            : Text(
                'Sélectionner un élève…',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Carte récapitulative
// ---------------------------------------------------------------------------

class _RecapCard extends StatelessWidget {
  const _RecapCard({
    required this.student,
    required this.type,
    required this.amount,
    required this.method,
    required this.date,
  });

  final StudentDto? student;
  final PaymentType type;
  final double amount;
  final PaymentMethod method;
  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.receipt_long,
                    color: theme.colorScheme.onPrimaryContainer, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Récapitulatif',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _RecapRow(
              label: 'Élève',
              value: student?.fullName ?? '—',
              onColor: theme.colorScheme.onPrimaryContainer,
            ),
            _RecapRow(
              label: 'Type',
              value: type.label,
              onColor: theme.colorScheme.onPrimaryContainer,
            ),
            _RecapRow(
              label: 'Montant',
              value: MoneyFormatter.format(amount),
              onColor: theme.colorScheme.onPrimaryContainer,
              valueStyle: TextStyle(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w700,
                fontSize: 18,
              ),
            ),
            _RecapRow(
              label: 'Méthode',
              value: method.label,
              onColor: theme.colorScheme.onPrimaryContainer,
            ),
            _RecapRow(
              label: 'Date',
              value: DateFormatter.date(date),
              onColor: theme.colorScheme.onPrimaryContainer,
            ),
          ],
        ),
      ),
    );
  }
}

class _RecapRow extends StatelessWidget {
  const _RecapRow({
    required this.label,
    required this.value,
    required this.onColor,
    this.valueStyle,
  });

  final String label;
  final String value;
  final Color onColor;
  final TextStyle? valueStyle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(color: onColor.withValues(alpha: 0.8)),
          ),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: valueStyle ?? TextStyle(color: onColor),
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
    // Debounce : on ne met à jour _search (qui alimente le provider) que 300ms
    // après la dernière frappe. L'AppSearchBar gère l'affichage du texte saisi
    // immédiatement (contrôleur interne), donc l'utilisateur ne subit pas de
    // latence visuelle.
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
