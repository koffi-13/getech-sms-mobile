/// DTOs Finances : paiements et soldes élèves.
///
/// Devise : XOF (Franc CFA). Endpoints :
/// - `GET /finance/payments` (PAYMENT_READ)
/// - `POST /finance/payments` (PAYMENT_VALIDATE)
/// - `GET /finance/balances` (PAYMENT_READ)
library;

import '../../core/config/constants.dart';
import '../../core/utils/formatters.dart';

/// Un paiement enregistré.
class PaymentDto {
  final int id;
  final int? studentId;
  final String? studentName;
  final String? matricule;
  final String? classroomName;
  final PaymentType type;
  final double amount;
  final PaymentMethod method;
  final PaymentStatus status;
  final DateTime? date;
  final String? reference;
  final String? receiptNumber;
  final int? collectedById;
  final String? collectedByName;
  final String? notes;

  const PaymentDto({
    required this.id,
    this.studentId,
    this.studentName,
    this.matricule,
    this.classroomName,
    this.type = PaymentType.scolarite,
    required this.amount,
    this.method = PaymentMethod.espece,
    this.status = PaymentStatus.valide,
    this.date,
    this.reference,
    this.receiptNumber,
    this.collectedById,
    this.collectedByName,
    this.notes,
  });

  factory PaymentDto.fromJson(Map<String, dynamic> j) => PaymentDto(
        id: (j['id'] as num).toInt(),
        studentId: (j['student_id'] as num?)?.toInt(),
        studentName: j['student_name'] as String?,
        matricule: j['matricule'] as String?,
        classroomName: j['classroom_name'] as String?,
        type: PaymentType.fromCode(j['type'] as String?) ?? PaymentType.scolarite,
        amount: (j['amount'] as num?)?.toDouble() ?? 0,
        method: PaymentMethod.fromCode(j['method'] as String?) ??
            PaymentMethod.espece,
        status: PaymentStatus.fromCode(j['status'] as String?) ??
            PaymentStatus.valide,
        date: DateFormatter.parse(j['date'] as String?),
        reference: j['reference'] as String?,
        receiptNumber: j['receipt_number'] as String?,
        collectedById: (j['collected_by_id'] as num?)?.toInt(),
        collectedByName: j['collected_by_name'] as String?,
        notes: j['notes'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'student_id': studentId,
        'student_name': studentName,
        'matricule': matricule,
        'classroom_name': classroomName,
        'type': type.code,
        'amount': amount,
        'method': method.code,
        'status': status.code,
        'date': DateFormatter.toIso(date),
        'reference': reference,
        'receipt_number': receiptNumber,
        'collected_by_id': collectedById,
        'collected_by_name': collectedByName,
        'notes': notes,
      };
}

/// Requête d'enregistrement d'un paiement : `POST /finance/payments`.
class PaymentRequest {
  final int studentId;
  final PaymentType type;
  final double amount;
  final PaymentMethod method;
  final DateTime date;
  final String? reference;
  final String? notes;

  const PaymentRequest({
    required this.studentId,
    this.type = PaymentType.scolarite,
    required this.amount,
    this.method = PaymentMethod.espece,
    required this.date,
    this.reference,
    this.notes,
  });

  Map<String, dynamic> toJson() => {
        'student_id': studentId,
        'type': type.code,
        'amount': amount,
        'method': method.code,
        'date': DateFormatter.toIso(date),
        'reference': reference,
        'notes': notes,
      };
}

/// Solde d'un élève (ce qu'il doit / a payé).
class StudentBalanceDto {
  final int studentId;
  final String studentName;
  final String? matricule;
  final String? classroomName;
  final double totalDue;
  final double totalPaid;
  final double balance;
  final DateTime? lastPaymentDate;

  const StudentBalanceDto({
    required this.studentId,
    required this.studentName,
    this.matricule,
    this.classroomName,
    this.totalDue = 0,
    this.totalPaid = 0,
    this.balance = 0,
    this.lastPaymentDate,
  });

  /// Solde restant à payer (positif = l'élève doit).
  double get outstanding => totalDue - totalPaid;

  /// Indique si l'élève a soldé sa scolarité.
  bool get isSettled => outstanding <= 0;

  /// Taux de paiement (0..1).
  double get paymentRate =>
      totalDue == 0 ? 1 : (totalPaid / totalDue).clamp(0, 1);

  factory StudentBalanceDto.fromJson(Map<String, dynamic> j) => StudentBalanceDto(
        studentId: (j['student_id'] as num).toInt(),
        studentName: j['student_name'] as String? ?? '',
        matricule: j['matricule'] as String?,
        classroomName: j['classroom_name'] as String?,
        totalDue: (j['total_due'] as num?)?.toDouble() ?? 0,
        totalPaid: (j['total_paid'] as num?)?.toDouble() ?? 0,
        balance: (j['balance'] as num?)?.toDouble() ?? 0,
        lastPaymentDate: DateFormatter.parse(j['last_payment_date'] as String?),
      );
}

/// Filtres de recherche des paiements.
class PaymentFilter {
  final int? studentId;
  final int? classroomId;
  final PaymentType? type;
  final PaymentStatus? status;
  final DateTime? fromDate;
  final DateTime? toDate;
  final String? search;
  final int page;
  final int perPage;

  const PaymentFilter({
    this.studentId,
    this.classroomId,
    this.type,
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
    if (classroomId != null) q['classroom_id'] = classroomId;
    if (type != null) q['type'] = type!.code;
    if (status != null) q['status'] = status!.code;
    if (fromDate != null) q['from_date'] = DateFormatter.toIso(fromDate);
    if (toDate != null) q['to_date'] = DateFormatter.toIso(toDate);
    if (search != null && search!.isNotEmpty) q['search'] = search;
    return q;
  }

  PaymentFilter copyWith({
    int? studentId,
    int? classroomId,
    PaymentType? type,
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
        type: type ?? this.type,
        status: status ?? this.status,
        fromDate: fromDate ?? this.fromDate,
        toDate: toDate ?? this.toDate,
        search: search ?? this.search,
        page: page ?? this.page,
        perPage: perPage ?? this.perPage,
      );
}

/// Réponse paginée de paiements.
class PaginatedPayments {
  final List<PaymentDto> items;
  final int total;
  final int page;
  final int perPage;
  final int totalPages;

  const PaginatedPayments({
    this.items = const [],
    this.total = 0,
    this.page = 1,
    this.perPage = 50,
    this.totalPages = 1,
  });

  factory PaginatedPayments.fromJson(Map<String, dynamic> j) {
    final list = j['items'] as List? ?? j['data'] as List? ?? const [];
    return PaginatedPayments(
      items: list
          .map((e) => PaymentDto.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: (j['total'] as num?)?.toInt() ?? list.length,
      page: (j['page'] as num?)?.toInt() ?? 1,
      perPage: (j['per_page'] as num?)?.toInt() ?? 50,
      totalPages: (j['total_pages'] as num?)?.toInt() ?? 1,
    );
  }
}
