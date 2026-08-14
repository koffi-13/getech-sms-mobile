/// Page "Enregistrer un paiement" : flux basé sur les subscriptions.
///
/// Flux réel (aligné sur le desktop `finance` router) :
/// 1. L'utilisateur sélectionne un élève (recherche par nom/matricule).
/// 2. On charge ses subscriptions actives via `studentSubscriptionsProvider`
///    (celles avec `balance_due > 0`).
/// 3. L'utilisateur sélectionne UNE subscription sur laquelle encaisser.
/// 4. Saisie du montant (> 0 et <= balance_due), méthode, référence.
/// 5. `POST /finance/payments` avec `{student_id, subscription_id, amount,
///    method, reference}` → le serveur crée la transaction, l'allocation,
///    met à jour la subscription et attribue un `receipt_number`.
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

  // État du formulaire.
  StudentDto? _selectedStudent;
  FeeSubscriptionDto? _selectedSubscription;
  PaymentMethod _method = PaymentMethod.espece;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _amountCtrl = TextEditingController();
    _referenceCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _referenceCtrl.dispose();
    super.dispose();
  }

  Future<void> _openStudentPicker() async {
    final selected = await showDialog<StudentDto>(
      context: context,
      builder: (_) => const _StudentPickerDialog(),
    );
    if (selected != null) {
      setState(() {
        _selectedStudent = selected;
        _selectedSubscription = null;
        _amountCtrl.clear();
        _referenceCtrl.clear();
      });
    }
  }

  void _clearStudent() {
    setState(() {
      _selectedStudent = null;
      _selectedSubscription = null;
      _amountCtrl.clear();
      _referenceCtrl.clear();
    });
  }

  double? get _parsedAmount {
    final raw = _amountCtrl.text.trim().replaceAll(RegExp(r'[^\d.,]'), '');
    final normalized = raw.replaceAll(',', '.');
    return double.tryParse(normalized);
  }

  /// Reste à payer après saisie du montant (balance_due - amount).
  /// Retourne `null` si le montant saisi est invalide.
  double? get _remainingDue {
    final sub = _selectedSubscription;
    final amt = _parsedAmount;
    if (sub == null || amt == null) return null;
    return sub.balanceDue - amt;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final student = _selectedStudent;
    final sub = _selectedSubscription;
    if (student == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Veuillez sélectionner un élève.')),
      );
      return;
    }
    if (sub == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Veuillez sélectionner une subscription.')),
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
    if (amount > sub.balanceDue) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Le montant dépasse le solde dû (${MoneyFormatter.format(sub.balanceDue, withSymbol: false)} FCFA).'),
        ),
      );
      return;
    }

    setState(() => _saving = true);
    final req = PaymentRequest(
      studentId: student.id,
      subscriptionId: sub.id,
      amount: amount,
      method: _method,
      reference: _referenceCtrl.text.trim().isEmpty
          ? null
          : _referenceCtrl.text.trim(),
    );

    try {
      final payment =
          await ref.read(financeRepositoryProvider).recordPayment(req);
      if (!mounted) return;

      // Invalide les listes pour rafraîchir.
      ref.invalidate(paymentsListProvider);
      ref.invalidate(balancesProvider);
      ref.invalidate(studentSubscriptionsProvider);

      final msg = payment.status == PaymentStatus.enAttente
          ? 'Paiement mis en file d\'attente (hors-ligne). Il sera synchronisé ultérieurement.'
          : 'Paiement enregistré'
              '${payment.receiptNumber != null && payment.receiptNumber!.isNotEmpty ? ' — Reçu n°${payment.receiptNumber}' : ''}'
              '.';
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
                    // Étape 1 : Élève.
                    _StudentField(
                      student: _selectedStudent,
                      onTap: _openStudentPicker,
                      onClear: _selectedStudent != null ? _clearStudent : null,
                    ),
                    const SizedBox(height: 16),
                    // Étape 2 + 3 : subscriptions + saisie (uniquement si élève sélectionné).
                    if (_selectedStudent != null) ...[
                      _SubscriptionsSection(
                        studentId: _selectedStudent!.id,
                        selected: _selectedSubscription,
                        onSelect: (sub) {
                          setState(() {
                            _selectedSubscription = sub;
                            _amountCtrl.clear();
                          });
                        },
                      ),
                      const SizedBox(height: 16),
                      if (_selectedSubscription != null)
                        _PaymentForm(
                          subscription: _selectedSubscription!,
                          amountCtrl: _amountCtrl,
                          referenceCtrl: _referenceCtrl,
                          method: _method,
                          onMethodChanged: (m) {
                            if (m != null) setState(() => _method = m);
                          },
                          parsedAmount: _parsedAmount,
                          remainingDue: _remainingDue,
                          saving: _saving,
                          onSubmit: _submit,
                          onAmountChanged: (_) => setState(() {}),
                        ),
                    ],
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
  const _StudentField({
    required this.student,
    required this.onTap,
    this.onClear,
  });
  final StudentDto? student;
  final VoidCallback onTap;
  final VoidCallback? onClear;

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
          suffixIcon: hasStudent
              ? IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: onClear,
                  tooltip: 'Changer d\'élève',
                )
              : const Icon(Icons.search),
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
// Section "Subscriptions" : liste des subscriptions actives de l'élève
// ---------------------------------------------------------------------------

class _SubscriptionsSection extends ConsumerWidget {
  const _SubscriptionsSection({
    required this.studentId,
    required this.selected,
    required this.onSelect,
  });

  final int studentId;
  final FeeSubscriptionDto? selected;
  final ValueChanged<FeeSubscriptionDto> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(studentSubscriptionsProvider(studentId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: 'Subscriptions à encaisser',
          subtitle: 'Sélectionnez la subscription à solder',
          icon: Icons.assignment_outlined,
        ),
        const SizedBox(height: 4),
        async.when(
          data: (subs) {
            if (subs.isEmpty) {
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Icon(Icons.check_circle,
                          color: Colors.green.shade400, size: 40),
                      const SizedBox(height: 8),
                      Text(
                        'Cet élève n\'a pas de solde dû',
                        style: Theme.of(context).textTheme.titleMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Aucune subscription active avec un solde restant à payer.',
                        style: Theme.of(context).textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              );
            }
            return Column(
              children: subs
                  .map((s) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: _SubscriptionTile(
                          subscription: s,
                          selected: selected?.id == s.id,
                          onTap: () => onSelect(s),
                        ),
                      ))
                  .toList(),
            );
          },
          loading: () => const Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          ),
          error: (e, _) => AppErrorWidget(message: e.toString()),
        ),
      ],
    );
  }
}

class _SubscriptionTile extends StatelessWidget {
  const _SubscriptionTile({
    required this.subscription,
    required this.selected,
    required this.onTap,
  });

  final FeeSubscriptionDto subscription;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sub = subscription;
    final settled = sub.isSettled;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: selected
            ? BorderSide(color: theme.colorScheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.assignment_outlined,
                      size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      sub.classroomName ?? 'Subscription #${sub.id}',
                      style: theme.textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  StatusBadge(
                    label: sub.status.label,
                    color: _subscriptionStatusColor(sub.status),
                  ),
                  if (selected) ...[
                    const SizedBox(width: 8),
                    Icon(Icons.check_circle,
                        color: theme.colorScheme.primary, size: 20),
                  ],
                ],
              ),
              const SizedBox(height: 8),
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
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: sub.paymentRate,
                  minHeight: 6,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
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

// ---------------------------------------------------------------------------
// Formulaire de saisie du paiement (montant + méthode + référence + submit)
// ---------------------------------------------------------------------------

class _PaymentForm extends StatelessWidget {
  const _PaymentForm({
    required this.subscription,
    required this.amountCtrl,
    required this.referenceCtrl,
    required this.method,
    required this.onMethodChanged,
    required this.parsedAmount,
    required this.remainingDue,
    required this.saving,
    required this.onSubmit,
    required this.onAmountChanged,
  });

  final FeeSubscriptionDto subscription;
  final TextEditingController amountCtrl;
  final TextEditingController referenceCtrl;
  final PaymentMethod method;
  final ValueChanged<PaymentMethod?> onMethodChanged;
  final double? parsedAmount;
  final double? remainingDue;
  final bool saving;
  final VoidCallback onSubmit;
  final ValueChanged<String> onAmountChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sub = subscription;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
          // Carte récapitulative de la subscription sélectionnée.
          Card(
            color: theme.colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.receipt_long,
                          color: theme.colorScheme.onPrimaryContainer,
                          size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Subscription sélectionnée',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      StatusBadge(
                        label: sub.status.label,
                        color: _subscriptionStatusColor(sub.status)
                            .withValues(alpha: 0.9),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _RecapRow(
                    label: 'Convenu',
                    value: MoneyFormatter.format(sub.agreedAmount),
                    onColor: theme.colorScheme.onPrimaryContainer,
                  ),
                  _RecapRow(
                    label: 'Déjà payé',
                    value: MoneyFormatter.format(sub.totalPaid),
                    onColor: theme.colorScheme.onPrimaryContainer,
                  ),
                  _RecapRow(
                    label: 'Solde dû',
                    value: MoneyFormatter.format(sub.balanceDue),
                    onColor: theme.colorScheme.onPrimaryContainer,
                    valueStyle: TextStyle(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: sub.paymentRate,
                      minHeight: 6,
                      backgroundColor:
                          theme.colorScheme.onPrimaryContainer.withValues(
                        alpha: 0.2,
                      ),
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Montant.
          TextFormField(
            controller: amountCtrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')),
            ],
            decoration: const InputDecoration(
              labelText: 'Montant',
              hintText: '0',
              suffixText: 'FCFA',
              prefixIcon: Icon(Icons.payments_outlined),
            ),
            validator: (v) {
              final amt = parsedAmount;
              if (amt == null || amt <= 0) {
                return 'Entrez un montant valide (> 0).';
              }
              if (amt > sub.balanceDue) {
                return 'Le montant ne peut pas dépasser le solde dû '
                    '(${MoneyFormatter.format(sub.balanceDue, withSymbol: false)} FCFA).';
              }
              return null;
            },
            onChanged: onAmountChanged,
          ),
          const SizedBox(height: 8),
          // Reste à payer (live).
          if (parsedAmount != null && parsedAmount! > 0)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                () {
                  final rem = remainingDue ?? sub.balanceDue - parsedAmount!;
                  if (rem < 0) {
                    return '⚠️ Dépasse le solde dû de '
                        '${MoneyFormatter.format(-rem, withSymbol: false)} FCFA.';
                  }
                  return 'Reste à payer après ce paiement : '
                      '${MoneyFormatter.format(rem, withSymbol: false)} FCFA.';
                }(),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: (remainingDue ?? 0) < 0
                      ? Colors.red.shade700
                      : Colors.green.shade700,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          const SizedBox(height: 16),
          // Méthode.
          DropdownButtonFormField<PaymentMethod>(
            value: method,
            decoration: const InputDecoration(
              labelText: 'Méthode de paiement',
              prefixIcon: Icon(Icons.account_balance_wallet_outlined),
            ),
            items: PaymentMethod.values
                .map((m) => DropdownMenuItem(
                      value: m,
                      child: Text(m.label),
                    ))
                .toList(),
            onChanged: onMethodChanged,
          ),
          const SizedBox(height: 16),
          // Référence.
          TextFormField(
            controller: referenceCtrl,
            decoration: const InputDecoration(
              labelText: 'Référence (optionnel)',
              hintText: 'Ex. ID transaction Mobile Money',
              prefixIcon: Icon(Icons.tag),
            ),
          ),
          const SizedBox(height: 24),
          // Bouton.
          FilledButton.icon(
            onPressed: saving ? null : onSubmit,
            icon: saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.check),
            label: Text(saving ? 'Enregistrement…' : 'Enregistrer'),
          ),
        ],
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
