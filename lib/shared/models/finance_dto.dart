/// DTOs Finances — alignés sur les schémas Pydantic et les modèles SQLAlchemy
/// du desktop.
library;

import '../../core/config/constants.dart';
import '../../core/utils/formatters.dart';

/// Paiement (PaymentResponse côté serveur).
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

/// Requête d'enregistrement d'un paiement.
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

/// Réponse paginée de paiements.
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

/// Subscription de frais d'un élève.
class FeeSubscriptionDto {
  final int id;
  final int studentId;
  final double agreedAmount;
  final double balanceDue;
  final String currency;
  final SubscriptionStatus status;
  final String? studentName;
  final String? matricule;
  final String? classroomName;
  final String? feeCategoryName;
  final int? schoolYearId;
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
    this.feeCategoryName,
    this.schoolYearId,
    this.isActive = true,
  });

  bool get isSettled => balanceDue <= 0 || status == SubscriptionStatus.payed;
  double get paymentRate => agreedAmount == 0
      ? 1
      : ((agreedAmount - balanceDue) / agreedAmount).clamp(0, 1);
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
        feeCategoryName: j['fee_category_name'] as String?,
        schoolYearId: (j['school_year_id'] as num?)?.toInt(),
        isActive: (j['is_active'] as bool?) ?? true,
      );
}

/// Réponse paginée de soldes.
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

/// Filtres de recherche des paiements.
class PaymentFilter {
  final int? studentId;
  final int? classroomId;
  final PaymentMethod? method;
  final PaymentStatus? status;
  final String? search;
  final int page;
  final int perPage;

  const PaymentFilter({
    this.studentId,
    this.classroomId,
    this.method,
    this.status,
    this.search,
    this.page = 1,
    this.perPage = 50,
  });

  Map<String, dynamic> toQuery() {
    final q = <String, dynamic>{'page': page, 'per_page': perPage};
    if (studentId != null) q['student_id'] = studentId;
    if (method != null) q['method'] = method!.code;
    return q;
  }

  PaymentFilter copyWith({
    int? studentId,
    int? classroomId,
    PaymentMethod? method,
    PaymentStatus? status,
    String? search,
    int? page,
    int? perPage,
    bool clearStudent = false,
    bool clearMethod = false,
    bool clearStatus = false,
  }) =>
      PaymentFilter(
        studentId: clearStudent ? null : (studentId ?? this.studentId),
        classroomId: classroomId ?? this.classroomId,
        method: clearMethod ? null : (method ?? this.method),
        status: clearStatus ? null : (status ?? this.status),
        search: search ?? this.search,
        page: page ?? this.page,
        perPage: perPage ?? this.perPage,
      );
}
