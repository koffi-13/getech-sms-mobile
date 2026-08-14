/// Contrôleur du module Finance : paiements, soldes élèves, KPI "paiements du
/// jour".
///
/// Source de données V1 : API REST (online). Hors-ligne, l'enregistrement d'un
/// paiement est mis en file d'attente via [outboxProvider] pour être poussé
/// ultérieurement par le [SyncEngine].
///
/// Endpoints :
/// - `GET /finance/payments` (PAYMENT_READ) — liste paginée filtrée.
/// - `POST /finance/payments` (PAYMENT_VALIDATE) — enregistrement.
/// - `DELETE /finance/payments/{id}` — annulation (best-effort).
/// - `GET /finance/balances` (PAYMENT_READ) — soldes élèves.
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

import '../../core/config/constants.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../../core/sync/outbox.dart';
import '../../core/utils/formatters.dart';
import '../../features/connections/connection_state.dart';
import '../../shared/models/classroom_dto.dart';
import '../../shared/models/finance_dto.dart';

final Logger _log = Logger(
  printer: PrettyPrinter(methodNames: false, noBoxingByDefault: true),
  level: Level.off,
});

// ---------------------------------------------------------------------------
// BalanceFilter
// ---------------------------------------------------------------------------

/// Filtres de la liste des soldes : classe + recherche texte.
///
/// L'égalité structurelle permet à Riverpod de cacher correctement les
/// résultats de [balancesProvider] (family).
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
// Helpers de parsing (défensifs : List brute ou {items:[...]} / {data:[...]})
// ---------------------------------------------------------------------------

PaginatedPayments _parsePaginatedPayments(dynamic data) {
  if (data is Map) {
    return PaginatedPayments.fromJson(Map<String, dynamic>.from(data));
  }
  if (data is List) {
    final items = data
        .whereType<Map>()
        .map((e) => PaymentDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return PaginatedPayments(items: items, total: items.length);
  }
  return const PaginatedPayments();
}

List<StudentBalanceDto> _parseBalances(dynamic data) {
  if (data is List) {
    return data
        .whereType<Map>()
        .map((e) => StudentBalanceDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  if (data is Map) {
    final items = data['items'] ?? data['balances'] ?? data['data'];
    if (items is List) {
      return items
          .whereType<Map>()
          .map((e) => StudentBalanceDto.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
  }
  return const [];
}

List<ClassroomDto> _parseClassrooms(dynamic data) {
  if (data is List) {
    return data
        .whereType<Map>()
        .map((e) => ClassroomDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  if (data is Map && data['items'] is List) {
    return (data['items'] as List)
        .whereType<Map>()
        .map((e) => ClassroomDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  return const [];
}

// ---------------------------------------------------------------------------
// FinanceRepository — mutations (create / cancel)
// ---------------------------------------------------------------------------

/// Repository Finance : enregistrement et annulation de paiements.
///
/// - En ligne (`canReachServer`) : `POST /finance/payments` et
///   `DELETE /finance/payments/{id}` via [dioProvider].
/// - Hors-ligne : l'opération est enfilée dans l'[outbox] et un placeholder
///   est retourné (statut `PENDING`, ID temporaire négatif) pour le feedback
///   UI immédiat. Le [SyncEngine] poussera l'écriture ultérieurement.
class FinanceRepository {
  FinanceRepository(this._ref);
  final Ref _ref;

  Dio get _dio => _ref.read(dioProvider);
  String? get _serverUrl => _ref.read(connectionProvider).serverUrl;
  bool get _canReachServer => _ref.read(connectionProvider).canReachServer;

  /// Enregistre un paiement : `POST /finance/payments`.
  ///
  /// Hors-ligne : enfile dans l'outbox (table `payments`, opération `INSERT`)
  /// et retourne un [PaymentDto] placeholder avec `status = PENDING`.
  Future<PaymentDto> recordPayment(PaymentRequest req) async {
    final url = _serverUrl;
    if (url == null) {
      throw const ApiException('Serveur non configuré');
    }

    if (!_canReachServer) {
      await _ref.read(outboxProvider).enqueue(
            table: 'payments',
            operation: 'INSERT',
            payload: req.toJson(),
          );
      _log.i('Paiement enfilé dans l\'outbox (offline) : '
          'élève=${req.studentId}, montant=${req.amount}');
      // Placeholder : ID négatif (basé sur timestamp) pour distinguer des
      // entrées serveur. Statut PENDING jusqu'à synchro.
      return PaymentDto(
        id: -DateTime.now().millisecondsSinceEpoch,
        studentId: req.studentId,
        type: req.type,
        amount: req.amount,
        method: req.method,
        status: PaymentStatus.enAttente,
        date: req.date,
        reference: req.reference,
        notes: req.notes,
      );
    }

    final resp = await _dio.postJson<dynamic>(
      buildUrl(url, ApiEndpoints.financePayments),
      data: req.toJson(),
    );
    final data = resp.data is Map
        ? resp.data as Map<String, dynamic>
        : <String, dynamic>{};
    return PaymentDto.fromJson(data);
  }

  /// Annule un paiement (best-effort) : `DELETE /finance/payments/{id}`.
  ///
  /// Hors-ligne : enfile l'opération dans l'outbox.
  Future<void> cancelPayment(int id) async {
    final url = _serverUrl;
    if (url == null) throw const ApiException('Serveur non configuré');

    if (!_canReachServer) {
      await _ref.read(outboxProvider).enqueue(
            table: 'payments',
            operation: 'DELETE',
            recordId: id,
            payload: {'id': id},
          );
      return;
    }
    await _dio.deleteJson<dynamic>(buildUrl(url, ApiEndpoints.payment(id)));
  }
}

/// Provider du repository Finance.
final financeRepositoryProvider = Provider<FinanceRepository>((ref) {
  return FinanceRepository(ref);
});

// ---------------------------------------------------------------------------
// Providers de lecture
// ---------------------------------------------------------------------------

/// Liste paginée des paiements : `GET /finance/payments`.
///
/// Renvoie une [PaginatedPayments] vide en cas de 403 (RBAC insuffisant) ou
/// serveur non appairé.
final paymentsListProvider = FutureProvider.autoDispose
    .family<PaginatedPayments, PaymentFilter>((ref, filter) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) {
    return const PaginatedPayments();
  }
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.getJson<dynamic>(
      buildUrl(conn.serverUrl!, ApiEndpoints.financePayments),
      query: filter.toQuery(),
    );
    return _parsePaginatedPayments(resp.data);
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403) return const PaginatedPayments();
    rethrow;
  }
});

/// Soldes des élèves : `GET /finance/balances?classroom_id=&search=`.
///
/// Renvoie une liste vide en cas de 403 ou serveur non appairé.
final balancesProvider = FutureProvider.autoDispose
    .family<List<StudentBalanceDto>, BalanceFilter>((ref, filter) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return const [];
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.getJson<dynamic>(
      buildUrl(conn.serverUrl!, ApiEndpoints.financeBalances),
      query: {
        if (filter.classroomId != null) 'classroom_id': filter.classroomId,
        if (filter.search.isNotEmpty) 'search': filter.search,
      },
    );
    return _parseBalances(resp.data);
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403) return const [];
    rethrow;
  }
});

/// Total des paiements validés du jour (KPI tableau de bord "paiements du jour").
///
/// `GET /finance/payments?from_date=<today>&status=VALIDATED` puis somme des
/// montants. Renvoie 0 en cas d'erreur réseau ou 403 (silencieux).
final paymentsTodayProvider =
    FutureProvider.autoDispose<double>((ref) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return 0;
  final dio = ref.watch(dioProvider);
  try {
    final today = DateTime.now();
    final fromIso = DateFormatter.toIso(
      DateTime(today.year, today.month, today.day),
    );
    final resp = await dio.getJson<dynamic>(
      buildUrl(conn.serverUrl!, ApiEndpoints.financePayments),
      query: {
        'from_date': fromIso,
        'status': PaymentStatus.valide.code,
        'per_page': 200,
      },
    );
    final page = _parsePaginatedPayments(resp.data);
    double sum = 0;
    for (final p in page.items) {
      sum += p.amount;
    }
    return sum;
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403) return 0;
    _log.w('paymentsTodayProvider : ${api.message}');
    return 0;
  } catch (e) {
    _log.w('paymentsTodayProvider : $e');
    return 0;
  }
});

/// Liste des classes pour le filtre (réutilise `GET /classrooms`).
///
/// Renvoie `[]` en cas de 403 ou serveur non appairé.
final classroomsForFinanceProvider =
    FutureProvider.autoDispose<List<ClassroomDto>>((ref) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return const [];
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.get<dynamic>(
      buildUrl(conn.serverUrl!, ApiEndpoints.classrooms),
    );
    return _parseClassrooms(resp.data);
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403) return const [];
    rethrow;
  }
});


