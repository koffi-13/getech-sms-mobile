/// DTOs Finances — alignés sur les schémas Pydantic et les modèles SQLAlchemy
/// du desktop.
///
/// ⚠️ Le flux de paiement réel nécessite un `subscription_id` :
/// 1. L'élève a une `StudentFeeSubscription` (agreed_amount, balance_due, status).
/// 2. Le paiement est alloué à cette subscription via `PaymentAllocation`.
/// 3. Le serveur génère un `receipt_number`.
///
/// Énumérations serveur (payment_transaction.py) :
/// - PaymentType: PAYMENT, REFUND
/// - PaymentStatus: PENDING, COMPLETED, FAILED, REFUNDED, CANCELLED
/// - PaymentMethod: CASH, MOBILE_MONEY, BANK_TRANSFER, CARD, CHEQUE, OTHER
/// - SubscriptionStatus: ACTIVE, PARTIAL, PAID, CANCELLED
library;

import '../../core/config/constants.dart';
import '../../core/utils/formatters.dart';

/// Paiement (PaymentResponse côté serveur).
///
/// Champs serveur : {id, establishment_id, student_id, amount, currency,
/// method, status, receipt_number, payment_date}.
class PaymentDto {
  final int id;
  final int? establishmentId;
  final int? studentId;
  final double amount;
  final String currency;
  final PaymentMethod method;
  final PaymentStatus status;
  final String? receiptNumber;
  final DateTime? paymentDate;
  // Champs de compatibilité (non dans la réponse de base, enrichis côté mobile)
  final String? studentName;
  final String? matricule;
  final String? classroomName;
  final String? reference;
  final int? subscriptionId;

  const PaymentDto({
    required this.id,
    this.establishmentId,
    this.studentId,
    required this.amount,
    this.currency = defaultCurrency,
    this.method = PaymentMethod.espece,
    this.status = PaymentStatus.enAttente,
    this.receiptNumber,
    this.paymentDate,
    this.studentName,
    this.matricule,
    this.classroomName,
    this.reference,
    this.subscriptionId,
  });

  factory PaymentDto.fromJson(Map<String, dynamic> j) => PaymentDto(
        id: (j['id'] as num).toInt(),
        establishmentId: (j['establishment_id'] as num?)?.toInt(),
        studentId: (j['student_id'] as num?)?.toInt(),
        amount: (j['amount'] as num?)?.toDouble() ?? 0,
        currency: (j['currency'] as String?) ?? defaultCurrency,
        method: PaymentMethod.fromCode(j['method'] as String?) ??
            PaymentMethod.espece,
        status: PaymentStatus.fromCode(j['status'] as String?) ??
            PaymentStatus.enAttente,
        receiptNumber: j['receipt_number'] as String?,
        paymentDate: DateFormatter.parse(j['payment_date'] as String?),
        studentName: j['student_name'] as String?,
        matricule: j['matricule'] as String?,
        classroomName: j['classroom_name'] as String?,
        reference: j['reference'] as String? ??
            j['transaction_reference'] as String?,
        subscriptionId: (j['subscription_id'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'establishment_id': establishmentId,
        'student_id': studentId,
        'amount': amount,
        'currency': currency,
        'method': method.code,
        'status': status.code,
        'receipt_number': receiptNumber,
        'payment_date': DateFormatter.toIso(paymentDate),
        'student_name': studentName,
        'matricule': matricule,
        'classroom_name': classroomName,
        'reference': reference,
        'subscription_id': subscriptionId,
      };
}

/// Requête d'enregistrement d'un paiement (PaymentCreateRequest côté serveur).
///
/// ⚠️ `subscription_id` est OBLIGATOIRE côté serveur.
class PaymentRequest {
  final int studentId;
  final int subscriptionId;
  final double amount;
  final PaymentMethod method;
  final String? reference;

  const PaymentRequest({
    required this.studentId,
    required this.subscriptionId,
    required this.amount,
    this.method = PaymentMethod.espece,
    this.reference,
  });

  Map<String, dynamic> toJson() => {
        'student_id': studentId,
        'subscription_id': subscriptionId,
        'amount': amount,
        'method': method.code,
        'reference': reference,
      };
}

/// Réponse paginée de paiements (PaymentListResponse).
class PaymentListResponse {
  final List<PaymentDto> items;
  final int total;

  const PaymentListResponse({this.items = const [], this.total = 0});

  factory PaymentListResponse.fromJson(Map<String, dynamic> j) =>
      PaymentListResponse(
        items: (j['items'] as List?)
                ?.map((e) => PaymentDto.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        total: (j['total'] as num?)?.toInt() ?? 0,
      );
}

/// Subscription de frais d'un élève (StudentFeeSubscription côté serveur).
///
/// L'endpoint `GET /finance/balances` retourne ces subscriptions avec
/// `balance_due > 0`, triées par `balance_due` décroissant.
class FeeSubscriptionDto {
  final int id;
  final int studentId;
  final double agreedAmount;
  final double balanceDue;
  final String currency;
  final SubscriptionStatus status;
  // Champs enrichis (non dans la réponse balances de base)
  final String? studentName;
  final String? matricule;
  final String? classroomName;
  final int? schoolYearId;
  final int? feeStructureId;
  final double? discountAmount;
  final double? discountPct;
  final bool isActive;

  const FeeSubscriptionDto({
    required this.id,
    required this.studentId,
    this.agreedAmount = 0,
    this.balanceDue = 0,
    this.currency = defaultCurrency,
    this.status = SubscriptionStatus.active,
    this.studentName,
    this.matricule,
    this.classroomName,
    this.schoolYearId,
    this.feeStructureId,
    this.discountAmount,
    this.discountPct,
    this.isActive = true,
  });

  /// Indique si la subscription est soldée.
  bool get isSettled => balanceDue <= 0 || status == SubscriptionStatus.payed;

  /// Taux de paiement (0..1).
  double get paymentRate => agreedAmount == 0
      ? 1
      : ((agreedAmount - balanceDue) / agreedAmount).clamp(0, 1);

  /// Montant déjà payé.
  double get totalPaid => agreedAmount - balanceDue;

  factory FeeSubscriptionDto.fromJson(Map<String, dynamic> j) =>
      FeeSubscriptionDto(
        id: (j['id'] as num).toInt(),
        studentId: (j['student_id'] as num).toInt(),
        agreedAmount: (j['agreed_amount'] as num?)?.toDouble() ?? 0,
        balanceDue: (j['balance_due'] as num?)?.toDouble() ?? 0,
        currency: (j['currency'] as String?) ?? defaultCurrency,
        status: SubscriptionStatus.fromCode(j['status'] as String?) ??
            SubscriptionStatus.active,
        studentName: j['student_name'] as String?,
        matricule: j['matricule'] as String?,
        classroomName: j['classroom_name'] as String?,
        schoolYearId: (j['school_year_id'] as num?)?.toInt(),
        feeStructureId: (j['fee_structure_id'] as num?)?.toInt(),
        discountAmount: (j['discount_amount'] as num?)?.toDouble(),
        discountPct: (j['discount_pct'] as num?)?.toDouble(),
        isActive: (j['is_active'] as bool?) ?? true,
      );
}

/// Réponse paginée de soldes (balances endpoint).
class BalanceListResponse {
  final List<FeeSubscriptionDto> items;
  final int total;

  const BalanceListResponse({this.items = const [], this.total = 0});

  factory BalanceListResponse.fromJson(Map<String, dynamic> j) =>
      BalanceListResponse(
        items: (j['items'] as List?)
                ?.map((e) =>
                    FeeSubscriptionDto.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        total: (j['total'] as num?)?.toInt() ?? 0,
      );
}

/// DTO de compatibilité pour la page "Soldes" (aggrégation par élève).
class StudentBalanceDto {
  final int studentId;
  final String studentName;
  final String? matricule;
  final String? classroomName;
  final double totalDue;
  final double totalPaid;
  final double balance;
  final DateTime? lastPaymentDate;
  final List<FeeSubscriptionDto> subscriptions;

  const StudentBalanceDto({
    required this.studentId,
    required this.studentName,
    this.matricule,
    this.classroomName,
    this.totalDue = 0,
    this.totalPaid = 0,
    this.balance = 0,
    this.lastPaymentDate,
    this.subscriptions = const [],
  });

  double get outstanding => totalDue - totalPaid;
  bool get isSettled => outstanding <= 0;
  double get paymentRate =>
      totalDue == 0 ? 1 : (totalPaid / totalDue).clamp(0, 1);

  /// Construit un StudentBalanceDto à partir d'une liste de subscriptions
  /// d'un même élève.
  factory StudentBalanceDto.fromSubscriptions(
    List<FeeSubscriptionDto> subs, {
    String? studentName,
    String? matricule,
    String? classroomName,
  }) {
    final due = subs.fold(0.0, (s, e) => s + e.agreedAmount);
    final paid = subs.fold(0.0, (s, e) => s + e.totalPaid);
    return StudentBalanceDto(
      studentId: subs.first.studentId,
      studentName: studentName ?? subs.first.studentName ?? '',
      matricule: matricule ?? subs.first.matricule,
      classroomName: classroomName ?? subs.first.classroomName,
      totalDue: due,
      totalPaid: paid,
      balance: due - paid,
      subscriptions: subs,
    );
  }
}

/// Filtres de recherche des paiements.
class PaymentFilter {
  final int? studentId;
  final int? classroomId;
  final PaymentMethod? method;
  final PaymentStatus? status;
  final DateTime? fromDate;
  final DateTime? toDate;
  final String? search;
  final int page;
  final int perPage;

  const PaymentFilter({
    this.studentId,
    this.classroomId,
    this.method,
    this.status,
    this.fromDate,
    this.toDate,
    this.search,
    this.page = 1,
    this.perPage = 50,
  });

  Map<String, dynamic> toQuery() {
    final q = <String, dynamic>{
      'page': page,
      'per_page': perPage,
    };
    if (studentId != null) q['student_id'] = studentId;
    if (method != null) q['method'] = method!.code;
    // Note: le serveur ne supporte que student_id, page, per_page pour /payments.
    // classroomId/fromDate/toDate/search nécessitent un enrichissement serveur.
    return q;
  }

  PaymentFilter copyWith({
    int? studentId,
    int? classroomId,
    PaymentMethod? method,
    PaymentStatus? status,
    DateTime? fromDate,
    DateTime? toDate,
    String? search,
    int? page,
    int? perPage,
  }) =>
      PaymentFilter(
        studentId: studentId ?? this.studentId,
        classroomId: classroomId ?? this.classroomId,
        method: method ?? this.method,
        status: status ?? this.status,
        fromDate: fromDate ?? this.fromDate,
        toDate: toDate ?? this.toDate,
        search: search ?? this.search,
        page: page ?? this.page,
        perPage: perPage ?? this.perPage,
      );
}
