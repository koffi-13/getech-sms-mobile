/// Contrôleur du module Finance : paiements, soldes élèves, subscriptions.
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart' as log_pkg;

import '../../core/config/constants.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../../core/sync/outbox.dart';
import '../../features/connections/connection_state.dart';
import '../classrooms/classroom_controller.dart';
import '../../shared/models/classroom_dto.dart';
import '../../shared/models/finance_dto.dart';

final log_pkg.Logger _log = log_pkg.Logger(
  printer: log_pkg.PrettyPrinter(noBoxingByDefault: true),
  level: log_pkg.Level.off,
);

// ---------------------------------------------------------------------------
// BalanceFilter
// ---------------------------------------------------------------------------

class BalanceFilter {
  final int? classroomId;
  final String search;

  const BalanceFilter({this.classroomId, this.search = ''});

  static const empty = BalanceFilter();

  BalanceFilter copyWith({
    int? classroomId,
    String? search,
    bool clearClassroom = false,
  }) =>
      BalanceFilter(
        classroomId:
            clearClassroom ? null : (classroomId ?? this.classroomId),
        search: search ?? this.search,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BalanceFilter &&
          other.classroomId == classroomId &&
          other.search == search;

  @override
  int get hashCode => Object.hash(classroomId, search);
}

// ---------------------------------------------------------------------------
// FinanceRepository
// ---------------------------------------------------------------------------

final financeRepositoryProvider = Provider<FinanceRepository>((ref) {
  return FinanceRepository(ref);
});

class FinanceRepository {
  FinanceRepository(this._ref);
  final Ref _ref;

  Future<PaymentDto> recordPayment(PaymentRequest req) async {
    final conn = _ref.read(connectionProvider);
    if (conn.serverUrl == null) throw const ApiException('Serveur non configuré');

    if (!conn.canReachServer) {
      await _ref.read(outboxProvider).enqueue(
            table: 'payments',
            operation: 'INSERT',
            payload: req.toJson(),
          );
      return PaymentDto(
        id: -DateTime.now().millisecondsSinceEpoch,
        studentId: req.studentId,
        subscriptionId: req.subscriptionId,
        amount: req.amount,
        method: req.method,
        status: PaymentStatus.enAttente,
        paymentDate: DateTime.now(),
      );
    }

    final dio = _ref.read(dioProvider);
    final resp = await dio.postJson(
      '${conn.baseUrl}${ApiEndpoints.financePayments}',
      data: req.toJson(),
    );
    return PaymentDto.fromJson(Map<String, dynamic>.from(resp.data));
  }
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

final paymentsListProvider = FutureProvider.autoDispose
    .family<PaymentListResponse, PaymentFilter>((ref, filter) async {
  final conn = ref.watch(connectionProvider);
  if (conn.serverUrl == null) return const PaymentListResponse();

  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.getJson(
      '${conn.baseUrl}${ApiEndpoints.financePayments}',
      query: filter.toQuery(),
    );
    return PaymentListResponse.fromJson(Map<String, dynamic>.from(resp.data));
  } catch (_) {
    return const PaymentListResponse();
  }
});

final balancesProvider = FutureProvider.autoDispose
    .family<List<FeeSubscriptionDto>, BalanceFilter>((ref, filter) async {
  final conn = ref.watch(connectionProvider);
  if (conn.serverUrl == null) return const [];

  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.getJson(
      '${conn.baseUrl}${ApiEndpoints.financeBalances}',
    );
    final list = resp.data as List;
    var subs = list.map((j) => FeeSubscriptionDto.fromJson(j)).toList();

    if (filter.search.isNotEmpty) {
      final q = filter.search.toLowerCase();
      subs = subs.where((s) =>
        (s.studentName?.toLowerCase().contains(q) ?? false) ||
        (s.matricule?.toLowerCase().contains(q) ?? false)
      ).toList();
    }
    return subs;
  } catch (_) {
    return const [];
  }
});

final studentSubscriptionsProvider = FutureProvider.autoDispose
    .family<List<FeeSubscriptionDto>, int>((ref, studentId) async {
  final conn = ref.watch(connectionProvider);
  if (conn.serverUrl == null) return const [];

  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.getJson(
      '${conn.baseUrl}${ApiEndpoints.financeBalances}',
      query: {'student_id': studentId},
    );
    final list = resp.data as List;
    return list
        .map((j) => FeeSubscriptionDto.fromJson(j))
        .where((s) => s.studentId == studentId && s.balanceDue > 0)
        .toList();
  } catch (_) {
    return const [];
  }
});

final classroomsForFinanceProvider =
    Provider.autoDispose<AsyncValue<List<ClassroomDto>>>((ref) {
  return ref.watch(classroomsProvider);
});
