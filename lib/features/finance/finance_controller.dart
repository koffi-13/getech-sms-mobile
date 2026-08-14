/// Contrôleur du module Finance : paiements, soldes élèves, subscriptions.
///
/// Source de données V1 : API REST (online). Hors-ligne, l'enregistrement d'un
/// paiement est mis en file d'attente via [outboxProvider] pour être poussé
/// ultérieurement par le [SyncEngine].
///
/// Flux de paiement réel (aligné sur le desktop `finance` router) :
/// 1. `GET /finance/balances` retourne les `StudentFeeSubscription` actives
///    avec `balance_due > 0`, triées par `balance_due` décroissant.
/// 2. `POST /finance/payments` avec `{student_id, subscription_id, amount,
///    method, reference}`. Le serveur valide `amount <= balance_due`, crée une
///    `PaymentTransaction` + `PaymentAllocation`, met à jour la subscription
///    (balance_due + status) et attribue un `receipt_number`.
/// 3. `GET /finance/payments?student_id=&page=&per_page=` renvoie les
///    paiements paginés.
///
/// Endpoints :
/// - `GET /finance/payments` (PAYMENT_READ) — liste paginée filtrée.
/// - `POST /finance/payments` (PAYMENT_VALIDATE) — enregistrement.
/// - `DELETE /finance/payments/{id}` — annulation (best-effort).
/// - `GET /finance/balances` (PAYMENT_READ) — subscriptions avec solde dû.
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

import '../../core/config/constants.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../../core/sync/outbox.dart';
import '../../features/connections/connection_state.dart';
import '../../shared/models/classroom_dto.dart';
import '../../shared/models/finance_dto.dart';

final Logger _log = Logger(
  printer: PrettyPrinter(methodNames: false, noBoxingByDefault: true),
  level: Level.off,
);

// ---------------------------------------------------------------------------
// BalanceFilter
// ---------------------------------------------------------------------------

/// Filtres de la liste des soldes : classe + recherche texte.
///
/// ⚠️ Le serveur `/finance/balances` ne supporte que `page`/`per_page`. Les
/// filtres `classroomId` et `search` sont appliqués **côté client** sur les
/// `FeeSubscriptionDto` retournées (qui portent déjà `classroomName`,
/// `studentName`, `matricule`).
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

PaymentListResponse _parsePaymentList(dynamic data) {
  if (data is Map) {
    return PaymentListResponse.fromJson(Map<String, dynamic>.from(data));
  }
  if (data is List) {
    final items = data
        .whereType<Map>()
        .map((e) => PaymentDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return PaymentListResponse(items: items, total: items.length);
  }
  return const PaymentListResponse();
}

List<FeeSubscriptionDto> _parseBalances(dynamic data) {
  if (data is List) {
    return data
        .whereType<Map>()
        .map((e) => FeeSubscriptionDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  if (data is Map) {
    final items = data['items'] ?? data['balances'] ?? data['data'];
    if (items is List) {
      return items
          .whereType<Map>()
          .map((e) => FeeSubscriptionDto.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    // Réponse paginée complète : on parse via BalanceListResponse.
    try {
      return BalanceListResponse.fromJson(Map<String, dynamic>.from(data))
          .items;
    } catch (_) {
      return const [];
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
  /// Le serveur valide `amount <= balance_due` de la subscription, génère une
  /// `PaymentTransaction` + `PaymentAllocation`, met à jour la subscription
  /// (balance_due + status) et attribue un `receipt_number`.
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
          'élève=${req.studentId}, subscription=${req.subscriptionId}, '
          'montant=${req.amount}');
      // Placeholder : ID négatif (basé sur timestamp) pour distinguer des
      // entrées serveur. Statut PENDING jusqu'à synchro.
      return PaymentDto(
        id: -DateTime.now().millisecondsSinceEpoch,
        studentId: req.studentId,
        subscriptionId: req.subscriptionId,
        amount: req.amount,
        method: req.method,
        status: PaymentStatus.enAttente,
        reference: req.reference,
        paymentDate: DateTime.now(),
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
/// Le serveur ne supporte que les filtres `student_id`, `page`, `per_page`
/// (cf. `PaymentFilter.toQuery()`). Les filtres `method` et `status` sont
/// appliqués côté client sur les items retournés.
///
/// Renvoie une [PaymentListResponse] vide en cas de 403 (RBAC insuffisant) ou
/// serveur non appairé.
final paymentsListProvider = FutureProvider.autoDispose
    .family<PaymentListResponse, PaymentFilter>((ref, filter) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) {
    return const PaymentListResponse();
  }
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.getJson<dynamic>(
      buildUrl(conn.serverUrl!, ApiEndpoints.financePayments),
      query: filter.toQuery(),
    );
    final page = _parsePaymentList(resp.data);

    // Filtres client-side : method + status (le serveur ne les supporte pas).
    var items = page.items;
    if (filter.method != null) {
      items = items.where((p) => p.method == filter.method).toList();
    }
    if (filter.status != null) {
      items = items.where((p) => p.status == filter.status).toList();
    }
    // Filtre client-side : search (sur studentName / matricule / reference).
    if (filter.search != null && filter.search!.isNotEmpty) {
      final q = filter.search!.toLowerCase();
      items = items.where((p) {
        return (p.studentName?.toLowerCase().contains(q) ?? false) ||
            (p.matricule?.toLowerCase().contains(q) ?? false) ||
            (p.reference?.toLowerCase().contains(q) ?? false) ||
            (p.receiptNumber?.toLowerCase().contains(q) ?? false);
      }).toList();
    }
    return PaymentListResponse(items: items, total: page.total);
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403) return const PaymentListResponse();
    rethrow;
  }
});

/// Soldes des élèves : `GET /finance/balances?page=&per_page=`.
///
/// Le serveur retourne les `StudentFeeSubscription` actives avec
/// `balance_due > 0`, triées par `balance_due` décroissant. Les filtres
/// `classroomId` et `search` sont appliqués **côté client** (le serveur ne les
/// supporte pas).
///
/// Renvoie une liste vide en cas de 403 ou serveur non appairé.
final balancesProvider = FutureProvider.autoDispose
    .family<List<FeeSubscriptionDto>, BalanceFilter>((ref, filter) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return const [];
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.getJson<dynamic>(
      buildUrl(conn.serverUrl!, ApiEndpoints.financeBalances),
      query: {
        'page': 1,
        'per_page': 500, // Charge toutes les subscriptions actives d'un coup.
      },
    );
    var subs = _parseBalances(resp.data);

    // Filtre client-side par classroomId : on résout le nom de la classe via
    // /classrooms (les subscriptions portent `classroomName`, pas `classroomId`).
    if (filter.classroomId != null) {
      String? classroomName;
      try {
        final cResp = await dio.getJson<dynamic>(
          buildUrl(conn.serverUrl!, ApiEndpoints.classrooms),
        );
        final classrooms = _parseClassrooms(cResp.data);
        for (final c in classrooms) {
          if (c.id == filter.classroomId) {
            classroomName = c.name;
            break;
          }
        }
      } catch (_) {
        // Best-effort : si on ne peut pas résoudre, on garde tout.
      }
      if (classroomName != null) {
        subs = subs
            .where((s) => s.classroomName == classroomName)
            .toList();
      }
    }

    // Filtre client-side par recherche texte.
    if (filter.search.isNotEmpty) {
      final q = filter.search.toLowerCase();
      subs = subs.where((s) {
        return (s.studentName?.toLowerCase().contains(q) ?? false) ||
            (s.matricule?.toLowerCase().contains(q) ?? false) ||
            (s.classroomName?.toLowerCase().contains(q) ?? false);
      }).toList();
    }

    return subs;
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403) return const [];
    rethrow;
  }
});

/// Subscriptions actives (avec `balance_due > 0`) d'un élève donné.
///
/// Utilisé par la page `RecordPaymentPage` pour proposer à l'utilisateur la
/// liste des subscriptions sur lesquelles encaisser un paiement.
///
/// Stratégie : `GET /finance/balances?student_id=X` (le serveur peut ou non
/// filtrer par `student_id`), puis filtrage client-side par `studentId` et
/// `balance_due > 0`.
///
/// Renvoie `[]` en cas de 403 ou serveur non appairé.
final studentSubscriptionsProvider = FutureProvider.autoDispose
    .family<List<FeeSubscriptionDto>, int>((ref, studentId) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return const [];
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.getJson<dynamic>(
      buildUrl(conn.serverUrl!, ApiEndpoints.financeBalances),
      query: {
        'student_id': studentId,
        'page': 1,
        'per_page': 100,
      },
    );
    final subs = _parseBalances(resp.data);
    return subs
        .where((s) => s.studentId == studentId && s.balanceDue > 0)
        .toList();
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403) return const [];
    rethrow;
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
