/// Moteur de synchronisation offline-first (pull / push, server-wins).
library;

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart' as log_pkg;
import 'package:uuid/uuid.dart';

import '../../features/connections/connection_state.dart';
import '../../features/students/student_controller.dart';
import '../../shared/models/grade_dto.dart';
import '../../shared/models/student_dto.dart';
import '../../shared/models/sync_dto.dart';
import '../database/database.dart';
import '../network/api_endpoints.dart';
import '../network/api_exceptions.dart';
import '../network/dio_client.dart';
import 'outbox.dart';

/// Logger du module sync.
final log_pkg.Logger _log = log_pkg.Logger(
  printer: log_pkg.PrettyPrinter(noBoxingByDefault: true),
  level: log_pkg.Level.debug,
);

// ---------------------------------------------------------------------------
// Helpers de lecture JSON (le serveur utilise du snake_case).
// ---------------------------------------------------------------------------

int _rId(Map<String, dynamic> r) => (r['id'] as num?)?.toInt() ?? 0;

String _rStr(Map<String, dynamic> r, String k, {String d = ''}) =>
    (r[k] as String?) ?? d;

String? _rStrN(Map<String, dynamic> r, String k) => r[k] as String?;

int _rInt(Map<String, dynamic> r, String k, {int d = 0}) =>
    (r[k] as num?)?.toInt() ?? d;

int? _rIntN(Map<String, dynamic> r, String k) => (r[k] as num?)?.toInt();

double _rDbl(Map<String, dynamic> r, String k, {double d = 0.0}) =>
    (r[k] as num?)?.toDouble() ?? d;

double? _rDblN(Map<String, dynamic> r, String k) =>
    (r[k] as num?)?.toDouble();

bool _rBool(Map<String, dynamic> r, String k, {bool d = false}) =>
    (r[k] as bool?) ?? d;

DateTime? _rDt(Map<String, dynamic> r, String k) {
  final v = r[k];
  if (v == null) return null;
  if (v is String) return DateTime.tryParse(v);
  if (v is num) {
    return DateTime.fromMillisecondsSinceEpoch(v.toInt(), isUtc: true);
  }
  return null;
}

// ---------------------------------------------------------------------------
// SyncState & Progress
// ---------------------------------------------------------------------------

enum SyncStatus { idle, pulling, pushing, processing, success, error }

class SyncProgress {
  final SyncStatus status;
  final double progress; // 0.0 to 1.0
  final String message;
  final SyncResult? lastResult;

  const SyncProgress({
    this.status = SyncStatus.idle,
    this.progress = 0.0,
    this.message = '',
    this.lastResult,
  });

  SyncProgress copyWith({
    SyncStatus? status,
    double? progress,
    String? message,
    SyncResult? lastResult,
  }) {
    return SyncProgress(
      status: status ?? this.status,
      progress: progress ?? this.progress,
      message: message ?? this.message,
      lastResult: lastResult ?? this.lastResult,
    );
  }
}

class SyncProgressNotifier extends StateNotifier<SyncProgress> {
  SyncProgressNotifier() : super(const SyncProgress());

  void update(SyncStatus status, double progress, String message) {
    state = state.copyWith(status: status, progress: progress, message: message);
  }

  void complete(SyncResult result) {
    state = state.copyWith(
      status: result.isSuccess ? SyncStatus.success : SyncStatus.error,
      progress: 1.0,
      message: result.isSuccess ? 'Synchronisation réussie' : 'Erreur de synchronisation',
      lastResult: result,
    );
  }

  void reset() {
    state = const SyncProgress();
  }
}

final syncProgressProvider = StateNotifierProvider<SyncProgressNotifier, SyncProgress>((ref) {
  return SyncProgressNotifier();
});

// ---------------------------------------------------------------------------
// SyncResult
// ---------------------------------------------------------------------------

/// Résultat d'une opération de synchronisation.
class SyncResult {
  final int pulled;
  final int pushed;
  final DateTime timestamp;
  final List<String> errors;

  const SyncResult({
    this.pulled = 0,
    this.pushed = 0,
    required this.timestamp,
    this.errors = const [],
  });

  bool get isSuccess => errors.isEmpty;

  @override
  String toString() =>
      'SyncResult(pulled: $pulled, pushed: $pushed, errors: $errors)';
}

// ---------------------------------------------------------------------------
// SyncEngine
// ---------------------------------------------------------------------------

class SyncEngine {
  SyncEngine(this._ref) {
    _db = _ref.watch(databaseProvider);
  }

  final Ref _ref;

  /// Base locale — initialisée depuis le provider (WATCH) pour suivre la
  /// bascule de serveur : le moteur est recréé avec la base du profil actif.
  late final AppDatabase _db;

  Future<SyncResult> syncNow() async {
    final notifier = _ref.read(syncProgressProvider.notifier);
    final errors = <String>[];
    var pulled = 0;
    var pushed = 0;

    if (!_ref.read(connectionProvider).canReachServer) {
      final res = SyncResult(
        timestamp: DateTime.now(),
        errors: ['Serveur injoignable'],
      );
      notifier.complete(res);
      return res;
    }

    notifier.update(SyncStatus.pulling, 0.1, 'Récupération des données...');
    final pull1 = await pull();
    pulled += pull1.pulled;
    errors.addAll(pull1.errors);

    if (!pull1.isSuccess) {
      final res = SyncResult(
        pulled: pulled,
        pushed: pushed,
        timestamp: DateTime.now(),
        errors: errors,
      );
      notifier.complete(res);
      return res;
    }

    notifier.update(SyncStatus.pushing, 0.4, 'Envoi des modifications locales...');
    final pushResult = await push();
    pushed += pushResult.pushed;
    errors.addAll(pushResult.errors);

    notifier.update(SyncStatus.pulling, 0.7, 'Finalisation de la synchro...');
    final pull2 = await pull();
    pulled += pull2.pulled;
    errors.addAll(pull2.errors);

    final finalResult = SyncResult(
      pulled: pulled,
      pushed: pushed,
      timestamp: DateTime.now(),
      errors: errors,
    );
    notifier.complete(finalResult);
    return finalResult;
  }

  Future<SyncResult> pull() async {
    final conn = _ref.read(connectionProvider);
    // [Fix-OFFLINE] `checking` ne bloque pas le pull (démarrage à froid).
    if ((!conn.canReachServer && !conn.isChecking) || conn.serverUrl == null) {
      return SyncResult(
        timestamp: DateTime.now(),
        errors: ['Serveur injoignable'],
      );
    }

    final dio = _ref.read(dioProvider);
    final since = conn.lastSyncAt ?? DateTime(2000, 1, 1);
    final url = buildUrl(conn.serverUrl!, ApiEndpoints.syncPull);

    try {
      _log.i('Pull depuis $url (since=${since.toIso8601String()})');
      final resp = await dio.getJson<Map<String, dynamic>>(
        url,
        query: {'since': since.toUtc().toIso8601String()},
      );
      final data = resp.data;
      if (data == null) {
        return SyncResult(
          timestamp: DateTime.now(),
          errors: ['Réponse vide du serveur'],
        );
      }

      final pullResp = SyncPullResponse.fromJson(data);
      _log.i('Pull reçu : ${pullResp.totalChanges} changements, '
          '${pullResp.deleted.length} suppressions');

      final notifier = _ref.read(syncProgressProvider.notifier);
      int processed = 0;
      final total = pullResp.changes.length + (pullResp.deleted.isNotEmpty ? 1 : 0);

      for (final entry in pullResp.changes.entries) {
        processed++;
        notifier.update(SyncStatus.processing, 0.1 + (0.3 * (processed/total)), 'Traitement de ${entry.key}...');
        await _applyTableChanges(entry.key, entry.value, pullResp.serverTime);
      }

      if (pullResp.deleted.isNotEmpty) {
        notifier.update(SyncStatus.processing, 0.4, 'Traitement des suppressions...');
        await _applyDeletes(pullResp.deleted, pullResp.serverTime);
      }

      await _ref
          .read(connectionProvider.notifier)
          .recordSync(count: pullResp.totalChanges);

      await _updateSyncMetadata(pullResp.serverTime, pullResp.totalChanges);

      return SyncResult(
        pulled: pullResp.totalChanges,
        timestamp: pullResp.serverTime,
      );
    } on ApiException catch (e) {
      _log.w('Pull échoué (API) : ${e.message}');
      return SyncResult(timestamp: DateTime.now(), errors: [e.message]);
    } catch (e) {
      _log.e('Pull échoué (inattendu) : $e');
      return SyncResult(timestamp: DateTime.now(), errors: [e.toString()]);
    }
  }

  Future<SyncResult> push() async {
    final conn = _ref.read(connectionProvider);
    // [Fix-OFFLINE] L'état `checking` (démarrage à froid) ne bloque pas :
    // la requête échouera d'elle-même si le serveur est injoignable.
    if ((!conn.canReachServer && !conn.isChecking) || conn.serverUrl == null) {
      return SyncResult(
        timestamp: DateTime.now(),
        errors: ['Serveur injoignable'],
      );
    }

    final outbox = _ref.read(outboxProvider);
    final pending = await outbox.pending();
    if (pending.isEmpty) {
      _log.i('Push : outbox vide, rien à envoyer');
      return SyncResult(timestamp: DateTime.now());
    }

    var pushed = 0;
    final errors = <String>[];

    // ---------------------------------------------------------------------
    // 1. [Grade-Validation] Soumissions de notes hors-ligne → endpoint
    // dédié (POST /grades/assessments/{id}/grades) avec sémantique de
    // file de validation. Jamais via /sync/push (le push direct des
    // notes serait écrasé / bypasserait la validation).
    // ---------------------------------------------------------------------
    final submissions = pending
        .where((e) => e.tableNameColumn == 'grade_submission')
        .toList(growable: false);

    // [Fix-STUDENT-DUP] Les mutations d'élèves (POST/PATCH hors-ligne)
    // passent par les endpoints REST dédiés — `/sync/push` rejette la
    // table `students` (lecture seule côté serveur), ce qui laissait les
    // modifications hors-ligne partir en erreur « read-only » sans jamais
    // atteindre le serveur.
    final studentMutations = pending
        .where((e) =>
            e.tableNameColumn == 'students' &&
            e.operation.toUpperCase() != 'DELETE')
        .toList(growable: false);
    final studentDeletes = pending
        .where((e) =>
            e.tableNameColumn == 'students' &&
            e.operation.toUpperCase() == 'DELETE')
        .toList(growable: false);
    final rest = pending
        .where((e) =>
            e.tableNameColumn != 'grade_submission' &&
            e.tableNameColumn != 'students')
        .toList(growable: false);

    for (final entry in submissions) {
      try {
        pushed += await _pushGradeSubmission(entry, outbox);
      } catch (e) {
        _log.w('Soumission notes #${entry.id} échouée : $e');
        errors.add('Notes hors-ligne : $e');
        // Garde-fou anti-retry infini : après 5 tentatives on abandonne
        // l'entrée (erreur conservée dans lastError).
        if (entry.attempts >= 4) {
          await outbox.markProcessed(
            entry.id,
            error: 'Abandon après ${entry.attempts + 1} tentatives : $e',
          );
        }
      }
    }

    // [Fix-STUDENT-DUP] Rejeu REST des mutations d'élèves.
    for (final entry in studentMutations) {
      try {
        pushed += await _pushStudentMutation(entry, outbox);
      } catch (e) {
        _log.w('Mutation élève #${entry.id} échouée : $e');
        errors.add('Élève hors-ligne : $e');
        // Garde-fou anti-retry infini (miroir des soumissions de notes).
        if (entry.attempts >= 4) {
          await outbox.markProcessed(
            entry.id,
            error: 'Abandon après ${entry.attempts + 1} tentatives : $e',
          );
        }
      }
    }

    // Les suppressions d'élèves n'ont pas d'endpoint serveur : marquées
    // traitées avec une note explicite (le soft-delete local reste).
    for (final entry in studentDeletes) {
      await outbox.markProcessed(
        entry.id,
        error: 'Suppression d\'élève non synchropluggable — le serveur '
            'n\'expose pas DELETE /students.',
      );
    }

    if (rest.isEmpty) {
      return pushed == 0 && errors.isEmpty
          ? SyncResult(timestamp: DateTime.now())
          : SyncResult(pushed: pushed, timestamp: DateTime.now(), errors: errors);
    }

    // ---------------------------------------------------------------------
    // 2. Lignes classiques — [Fix-SYNC-PUSH] contrat RÉEL du serveur :
    // POST /sync/push {lines: [{line_id, op, table, data}]}. L'ancien
    // format {changes: {table: [rows]}} provoquait un 422 permanent.
    // ---------------------------------------------------------------------
    final dio = _ref.read(dioProvider);
    final url = buildUrl(conn.serverUrl!, ApiEndpoints.syncPush);
    final lines = [
      for (final e in rest)
        {
          'line_id': 'ob-${e.id}',
          'table': e.tableNameColumn,
          'op': e.operation.toLowerCase() == 'delete' ? 'delete' : 'upsert',
          'data': e.payloadMap,
        }
    ];

    try {
      _log.i('Push vers $url : ${lines.length} lignes (+${submissions.length} soumissions notes)');

      // [Fix-SYNC-IDEMPOTENCE] Enrichir chaque ligne du payload avec
      // idempotency_key et device_uuid pour permettre au serveur de détecter
      // les doublons en cas de retry réseau (coupure, timeout). Le device_uuid
      // est récupéré depuis le secure storage (généré au pairing).
      // Rétrocompatible : champs absents -> le serveur applique le LWW
      // classique (server-wins).
      String? deviceUuid;
      try {
        deviceUuid = await _ref.read(secureStorageProvider).getDeviceId();
      } catch (e) {
        _log.w('device_uuid indisponible — push sans idempotence : $e');
      }

      final SyncPushRequest pushRequest;
      if (deviceUuid != null && deviceUuid.isNotEmpty) {
        pushRequest = SyncPushRequest.withIdempotency(
          lines: lines,
          deviceUuid: deviceUuid,
          generateIdempotencyKey: _generateIdempotencyKey,
        );
      } else {
        // Fallback : push sans idempotence (rétrocompatible avec l'ancien
        // comportement — le serveur applique LWW classique).
        pushRequest = SyncPushRequest(lines: lines);
      }

      final resp = await dio.postJson<Map<String, dynamic>>(
        url,
        data: pushRequest.toJson(),
      );
      final data = resp.data;
      if (data == null) {
        return SyncResult(
          timestamp: DateTime.now(),
          pushed: pushed,
          errors: [...errors, 'Réponse vide du serveur'],
        );
      }

      final pushResp = SyncPushResponse.fromJson(data);
      _log.i('Push terminé : ${pushResp.accepted} appliqués '
          '(${pushResp.results.length} lignes)');

      for (final entry in rest) {
        final lineId = 'ob-${entry.id}';
        final r = pushResp.resultFor(lineId);
        if (r == null) {
          await outbox.markProcessed(
            entry.id,
            error: 'Sans réponse du serveur pour cette ligne',
          );
          continue;
        }
        switch (r.status) {
          case 'applied':
            pushed++;
            await outbox.markProcessed(entry.id);
            if (entry.recordId != null) {
              await _updateRowSyncState(
                entry.tableNameColumn,
                entry.recordId!,
                pushResp.serverTime,
                deleted: entry.operation.toUpperCase() == 'DELETE',
              );
            }
            break;
          case 'queued_for_validation':
            // [Grade-Validation] Cas théorique (les notes passent par
            // l'endpoint dédié) — traité comme un succès partiel.
            pushed++;
            await outbox.markProcessed(entry.id, error: r.detail);
            break;
          default:
            // conflict_server_wins | invalid | unknown_table | error :
            // marqué traité (pas de retry infini), erreur conservée.
            await outbox.markProcessed(
              entry.id,
              error: '${r.status} : ${r.detail ?? ''}',
            );
        }
      }

      await outbox.clearProcessed();

      final conflicts = pushResp.results
          .where((r) => r.status == 'conflict_server_wins')
          .length;
      if (conflicts > 0) {
        errors.add(
          '$conflicts conflit(s) résolu(s) (server-wins) — re-pull requis',
        );
      }

      return SyncResult(
        pushed: pushed,
        timestamp: pushResp.serverTime,
        errors: errors,
      );
    } on ApiException catch (e) {
      _log.w('Push échoué (API) : ${e.message}');
      return SyncResult(
        timestamp: DateTime.now(),
        pushed: pushed,
        errors: [...errors, e.message],
      );
    } catch (e) {
      _log.e('Push échoué (inattendu) : $e');
      return SyncResult(
        timestamp: DateTime.now(),
        pushed: pushed,
        errors: [...errors, e.toString()],
      );
    }
  }

  /// Pousse UNE soumission de notes hors-ligne via l'endpoint dédié et
  /// applique les marques locales (queued / résolues).
  Future<int> _pushGradeSubmission(
    OutboxEntry entry,
    Outbox outbox,
  ) async {
    final conn = _ref.read(connectionProvider);
    final dio = _ref.read(dioProvider);
    final payload = entry.payloadMap;
    final assessmentId = (payload['assessment_id'] as num?)?.toInt() ?? 0;
    final rows = ((payload['grades'] as List?) ?? const [])
        .whereType<Map>()
        .map(Map<String, dynamic>.from)
        .toList();
    if (assessmentId == 0 || rows.isEmpty) {
      await outbox.markProcessed(entry.id, error: 'Soumission vide — ignorée');
      return 0;
    }

    final url = buildUrl(conn.serverUrl!, ApiEndpoints.assessmentGrades(assessmentId));
    final resp = await dio.post(url, data: {'grades': rows});
    final data = resp.data is Map
        ? Map<String, dynamic>.from(resp.data as Map)
        : const <String, dynamic>{};
    final body = SaveGradesResponse.fromJson(data);

    // Marques locales par ligne (valeur proposée conservée pour
    // l'affichage « X -> Y · en attente de validation »).
    await _applySubmissionMarks(assessmentId, rows, body);
    await outbox.markProcessed(entry.id);
    _log.i('Soumission notes #$assessmentId : ${body.savedCount} saved, '
        '${body.queuedCount} queued, ${body.skippedCount} unchanged');
    return body.savedCount + body.queuedCount + body.skippedCount;
  }

  /// [Fix-STUDENT-DUP] Pousse UNE mutation d'élève hors-ligne via l'endpoint
  /// REST dédié (`POST /students` ou `PATCH /students/{id}`) et réconcilie
  /// la ligne locale temporaire (id négatif) avec la réponse serveur.
  Future<int> _pushStudentMutation(
    OutboxEntry entry,
    Outbox outbox,
  ) async {
    final conn = _ref.read(connectionProvider);
    final dio = _ref.read(dioProvider);
    final payload = entry.payloadMap;
    final op = entry.operation.toUpperCase();
    final recordId = entry.recordId;

    // PATCH sur une ligne locale temporaire (id négatif — élève créé
    // hors-ligne puis modifié) : le serveur ne connaît pas cet id → on
    // rejoue une CRÉATION avec le payload le plus récent.
    final isCreate = op == 'POST' || (recordId != null && recordId < 0);

    if (isCreate) {
      final url = buildUrl(conn.serverUrl!, ApiEndpoints.students);
      final resp = await dio.post(url, data: payload);
      if (resp.data is Map) {
        final serverDto = StudentDto.fromJson(
            Map<String, dynamic>.from(resp.data as Map));
        // Réconcilie l'id local (négatif) avec l'id serveur — sinon la
        // ligne locale ET la ligne serveure coexistaient (doublon).
        if (recordId != null && recordId < 0) {
          try {
            await _ref
                .read(studentRepositoryProvider)
                .reconcileCreatedStudent(recordId, serverDto);
          } catch (e) {
            _log.w('Réconciliation élève #$recordId différée au pull : $e');
          }
        }
        await outbox.markProcessed(entry.id);
        _log.i('Création élève hors-ligne poussée : '
            '${serverDto.matricule} (id ${serverDto.id})');
        return 1;
      }
      throw const ApiException('Réponse serveur inattendue après création');
    }

    // PATCH d'un élève existant (id serveur positif).
    if (recordId == null || recordId <= 0) {
      await outbox.markProcessed(
          entry.id, error: 'Modification sans identifiant serveur — ignorée');
      return 0;
    }
    final url = buildUrl(conn.serverUrl!, ApiEndpoints.student(recordId));
    await dio.patch(url, data: payload);
    // La ligne locale redevient propre (les valeurs reviendront au pull).
    await (_db.update(_db.students)..where((t) => t.id.equals(recordId))).write(
      const StudentsCompanion(isDirty: Value(false)),
    );
    await outbox.markProcessed(entry.id);
    _log.i('Modification élève #$recordId poussée');
    return 1;
  }

  /// Applique les marques issues d'une soumission sur les lignes Drift
  /// locales (les lignes existent déjà — répliquées par le pull).
  Future<void> _applySubmissionMarks(
    int assessmentId,
    List<Map<String, dynamic>> requestRows,
    SaveGradesResponse body,
  ) async {
    final byStudent = <int, Map<String, dynamic>>{};
    for (final r in requestRows) {
      final sid = (r['student_id'] as num?)?.toInt();
      if (sid != null) byStudent[sid] = r;
    }

    for (final line in body.results) {
      final gradeId = line.gradeId;
      if (gradeId == null) continue; // note nouvelle : le pull la matérialisera
      final request = byStudent[line.studentId];
      final queued = line.action == 'queued';
      await (_db.update(_db.grades)..where((t) => t.id.equals(gradeId))).write(
        GradesCompanion(
          syncStatus: queued ? const Value('queued') : const Value(null),
          proposedValue: queued
              ? Value((request?['value'] as num?)?.toDouble())
              : const Value(null),
          proposedIsAbsent: queued
              ? Value((request?['is_absent'] as bool?) ?? false)
              : const Value(null),
          proposedComments: queued
              ? Value(request?['comment'] as String?)
              : const Value(null),
          isDirty: const Value(false),
        ),
      );
    }
  }

  /// [Grade-Validation] Application du pull des notes avec préservation
  /// des marques locales :
  ///   - une ligne locale `queued` n'est PAS écrasée si la valeur serveur
  ///     n'a pas encore repris la valeur proposée (l'admin n'a pas tranché) ;
  ///   - quand la valeur serveur rejoint la valeur proposée, la marque est
  ///     résolue (syncStatus -> null) ;
  ///   - les colonnes proposées (proposedValue…) survivent à l'upsert.
  Future<void> _applyGradesPull(
    List<Map<String, dynamic>> rows,
    DateTime syncedAt,
  ) async {
    final ids = rows.map(_rId).where((id) => id > 0).toList();
    final byId = <int, Grade>{};
    if (ids.isNotEmpty) {
      final existing =
          await (_db.select(_db.grades)..where((t) => t.id.isIn(ids))).get();
      for (final g in existing) {
        byId[g.id] = g;
      }
    }

    await _db.batch((b) {
      for (final row in rows) {
        final id = _rId(row);
        if (id <= 0) continue;
        final local = byId[id];

        // Protection : proposition pas encore poussée -> le pull attend.
        if (local != null && local.syncStatus == 'pending') continue;

        final serverValue = _rDblN(row, 'value');
        String? nextStatus = local?.syncStatus;
        double? nextProposed = local?.proposedValue;
        bool? nextProposedAbsent = local?.proposedIsAbsent;
        String? nextProposedComments = local?.proposedComments;

        // Résolution implicite : l'admin a appliqué la valeur proposée.
        if (local != null &&
            local.syncStatus == 'queued' &&
            serverValue != null &&
            local.proposedValue != null &&
            (serverValue - local.proposedValue!).abs() < 0.001) {
          nextStatus = null;
          nextProposed = null;
          nextProposedAbsent = null;
          nextProposedComments = null;
        }

        b.insert(
          _db.grades,
          GradesCompanion.insert(
            id: Value(id),
            assessmentId: _rInt(row, 'assessment_id'),
            studentId: _rInt(row, 'student_id'),
            value: Value(serverValue),
            isAbsent: Value(_rBool(row, 'is_absent')),
            comments: Value(_rStrN(row, 'comments')),
            syncedAt: Value(syncedAt),
            isDirty: const Value(false),
            isDeleted: const Value(false),
            // [Grade-Validation] marques préservées / résolues.
            syncStatus: Value(nextStatus),
            proposedValue: Value(nextProposed),
            proposedIsAbsent: Value(nextProposedAbsent),
            proposedComments: Value(nextProposedComments),
            // [Fix-SYNC-IDEMPOTENCE] champs de sync lus depuis le serveur
            // (nullables — absents => null, rétrocompatible).
            idempotencyKey: Value(_rStrN(row, 'idempotency_key')),
            deviceUuid: Value(_rStrN(row, 'device_uuid')),
            syncVersion: Value(_rInt(row, 'sync_version')),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  Future<void> _applyTableChanges(
    String table,
    List<Map<String, dynamic>> rows,
    DateTime syncedAt,
  ) async {
    if (rows.isEmpty) return;

    // [Grade-Validation] Les notes suivent un chemin dédié : préservation
    // des marques (queued/rejected + valeur proposée) et protection des
    // propositions en attente contre l'écrasement par le pull.
    if (table == 'grades') {
      await _applyGradesPull(rows, syncedAt);
      return;
    }

    try {
      await _db.batch((b) {
        for (final row in rows) {
          switch (table) {
            case 'establishments':
              b.insert(
                _db.establishments,
                EstablishmentsCompanion.insert(
                  id: Value(_rId(row)),
                  code: _rStr(row, 'code'),
                  name: _rStr(row, 'name'),
                  address: Value(_rStrN(row, 'address')),
                  city: Value(_rStrN(row, 'city')),
                  phone: Value(_rStrN(row, 'phone')),
                  email: Value(_rStrN(row, 'email')),
                  logoPath: Value(_rStrN(row, 'logo_path')),
                  currency: Value(_rStr(row, 'currency', d: 'XOF')),
                  country: Value(_rStrN(row, 'country')),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            case 'school_years':
              b.insert(
                _db.schoolYears,
                SchoolYearsCompanion.insert(
                  id: Value(_rId(row)),
                  name: _rStr(row, 'name'),
                  startDate: Value(_rDt(row, 'start_date')),
                  endDate: Value(_rDt(row, 'end_date')),
                  isActive: Value(_rBool(row, 'is_active')),
                  alternatingWeekStartDate:
                      Value(_rDt(row, 'alternating_week_start_date')),
                  establishmentId: Value(_rIntN(row, 'establishment_id')),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            case 'periods':
              b.insert(
                _db.periods,
                PeriodsCompanion.insert(
                  id: Value(_rId(row)),
                  name: _rStr(row, 'name'),
                  schoolYearId: Value(_rIntN(row, 'school_year_id')),
                  startDate: Value(_rDt(row, 'start_date')),
                  endDate: Value(_rDt(row, 'end_date')),
                  weight: Value(_rDbl(row, 'weight', d: 1.0)),
                  isActive: Value(_rBool(row, 'is_active')),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            case 'levels':
              b.insert(
                _db.levels,
                LevelsCompanion.insert(
                  id: Value(_rId(row)),
                  name: _rStr(row, 'name'),
                  code: Value(_rStrN(row, 'code')),
                  order: Value(_rInt(row, 'order', d: 0)),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            case 'series':
              b.insert(
                _db.series,
                SeriesCompanion.insert(
                  id: Value(_rId(row)),
                  name: _rStr(row, 'name'),
                  code: Value(_rStrN(row, 'code')),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            case 'streams':
              b.insert(
                _db.streams,
                StreamsCompanion.insert(
                  id: Value(_rId(row)),
                  name: _rStr(row, 'name'),
                  code: Value(_rStrN(row, 'code')),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            case 'classrooms':
              b.insert(
                _db.classrooms,
                ClassroomsCompanion.insert(
                  id: Value(_rId(row)),
                  name: _rStr(row, 'name'),
                  code: Value(_rStrN(row, 'code')),
                  levelId: Value(_rIntN(row, 'level_id')),
                  streamId: Value(_rIntN(row, 'stream_id')),
                  seriesId: Value(_rIntN(row, 'series_id')),
                  teacherId: Value(_rIntN(row, 'teacher_id')),
                  capacity: Value(_rInt(row, 'capacity', d: 0)),
                  schoolYearId: Value(_rIntN(row, 'school_year_id')),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            case 'subjects':
              b.insert(
                _db.subjects,
                SubjectsCompanion.insert(
                  id: Value(_rId(row)),
                  name: _rStr(row, 'name'),
                  code: Value(_rStrN(row, 'code')),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            case 'class_subjects':
              b.insert(
                _db.classSubjects,
                ClassSubjectsCompanion.insert(
                  id: Value(_rId(row)),
                  classroomId: _rInt(row, 'classroom_id'),
                  subjectId: _rInt(row, 'subject_id'),
                  coefficient: Value(_rDbl(row, 'coefficient', d: 1.0)),
                  teacherId: Value(_rIntN(row, 'teacher_id')),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            case 'assessments':
              b.insert(
                _db.assessments,
                AssessmentsCompanion.insert(
                  id: Value(_rId(row)),
                  classSubjectId: _rInt(row, 'class_subject_id'),
                  periodId: Value(_rIntN(row, 'period_id')),
                  title: _rStr(row, 'title'),
                  type: Value(_rStr(row, 'type', d: 'DEVOIR')),
                  date: Value(_rDt(row, 'date')),
                  maxScore: Value(_rDbl(row, 'max_score', d: 20.0)),
                  coefficient: Value(_rDbl(row, 'coefficient', d: 1.0)),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            // [Grade-Validation] `grades` est routé en tête de méthode vers
            // _applyGradesPull (préservation des marques) — pas de cas ici.
            case 'students':
              b.insert(
                _db.students,
                StudentsCompanion.insert(
                  id: Value(_rId(row)),
                  matricule: _rStr(row, 'matricule'),
                  nom: _rStr(row, 'nom'),
                  prenoms: Value(_rStrN(row, 'prenoms')),
                  dob: Value(_rDt(row, 'dob')),
                  sexe: Value(_rStrN(row, 'sexe')),
                  birthPlace: Value(_rStrN(row, 'birth_place')),
                  birthPrefecture: Value(_rStrN(row, 'birth_prefecture')),
                  birthRegion: Value(_rStrN(row, 'birth_region')),
                  birthCountry: Value(_rStrN(row, 'birth_country')),
                  photoPath: Value(_rStrN(row, 'photo_path')),
                  groupe: Value(_rStrN(row, 'groupe')),
                  establishmentId: Value(_rIntN(row, 'establishment_id')),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            case 'student_contacts':
              b.insert(
                _db.studentContacts,
                StudentContactsCompanion.insert(
                  id: Value(_rId(row)),
                  studentId: _rInt(row, 'student_id'),
                  phone: Value(_rStrN(row, 'phone')),
                  email: Value(_rStrN(row, 'email')),
                  address: Value(_rStrN(row, 'address')),
                  city: Value(_rStrN(row, 'city')),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            case 'student_medicals':
              b.insert(
                _db.studentMedicals,
                StudentMedicalsCompanion.insert(
                  id: Value(_rId(row)),
                  studentId: _rInt(row, 'student_id'),
                  bloodType: Value(_rStrN(row, 'blood_type')),
                  allergies: Value(_rStrN(row, 'allergies')),
                  doctor: Value(_rStrN(row, 'doctor')),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            case 'student_scholastics':
              b.insert(
                _db.studentScholastics,
                StudentScholasticsCompanion.insert(
                  id: Value(_rId(row)),
                  studentId: _rInt(row, 'student_id'),
                  previousSchool: Value(_rStrN(row, 'previous_school')),
                  transport: Value(_rStrN(row, 'transport')),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            case 'student_parents':
              b.insert(
                _db.studentParents,
                StudentParentsCompanion.insert(
                  id: Value(_rId(row)),
                  studentId: _rInt(row, 'student_id'),
                  role: _rStr(row, 'role'),
                  nom: Value(_rStrN(row, 'nom')),
                  prenoms: Value(_rStrN(row, 'prenoms')),
                  phone: Value(_rStrN(row, 'phone')),
                  profession: Value(_rStrN(row, 'profession')),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            case 'guardians':
              b.insert(
                _db.guardians,
                GuardiansCompanion.insert(
                  id: Value(_rId(row)),
                  nom: Value(_rStrN(row, 'nom')),
                  prenoms: Value(_rStrN(row, 'prenoms')),
                  phone: Value(_rStrN(row, 'phone')),
                  email: Value(_rStrN(row, 'email')),
                  relation: Value(_rStrN(row, 'relation')),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            case 'student_guardians':
              b.insert(
                _db.studentGuardians,
                StudentGuardiansCompanion.insert(
                  id: Value(_rId(row)),
                  studentId: _rInt(row, 'student_id'),
                  guardianId: _rInt(row, 'guardian_id'),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            case 'student_class_assignments':
              b.insert(
                _db.studentClassAssignments,
                StudentClassAssignmentsCompanion.insert(
                  id: Value(_rId(row)),
                  studentId: _rInt(row, 'student_id'),
                  classroomId: _rInt(row, 'classroom_id'),
                  schoolYearId: Value(_rIntN(row, 'school_year_id')),
                  status: Value(_rStrN(row, 'status')),
                  inscriptionType: Value(_rStrN(row, 'inscription_type')),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            case 'student_statuses':
              b.insert(
                _db.studentStatuses,
                StudentStatusesCompanion.insert(
                  id: Value(_rId(row)),
                  code: _rStr(row, 'code'),
                  label: _rStr(row, 'label'),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            case 'inscription_types':
              b.insert(
                _db.inscriptionTypes,
                InscriptionTypesCompanion.insert(
                  id: Value(_rId(row)),
                  code: _rStr(row, 'code'),
                  label: _rStr(row, 'label'),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            case 'time_slots':
              b.insert(
                _db.timeSlots,
                TimeSlotsCompanion.insert(
                  id: Value(_rId(row)),
                  dayOfWeek: _rInt(row, 'day_of_week'),
                  startTime: _rStr(row, 'start_time'),
                  endTime: _rStr(row, 'end_time'),
                  breakAfter: Value(_rIntN(row, 'break_after')),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            case 'weekly_schedules':
              b.insert(
                _db.weeklySchedules,
                WeeklySchedulesCompanion.insert(
                  id: Value(_rId(row)),
                  classroomId: Value(_rIntN(row, 'classroom_id')),
                  subjectId: Value(_rIntN(row, 'subject_id')),
                  teacherId: Value(_rIntN(row, 'teacher_id')),
                  timeSlotId: _rInt(row, 'time_slot_id'),
                  dayOfWeek: _rInt(row, 'day_of_week'),
                  startTime: Value(_rStrN(row, 'start_time')),
                  endTime: Value(_rStrN(row, 'end_time')),
                  room: Value(_rStrN(row, 'room')),
                  weekType: Value(_rStr(row, 'week_type', d: 'A')),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            case 'course_sessions':
              b.insert(
                _db.courseSessions,
                CourseSessionsCompanion.insert(
                  id: Value(_rId(row)),
                  weeklyScheduleId: Value(_rIntN(row, 'weekly_schedule_id')),
                  classroomId: Value(_rIntN(row, 'classroom_id')),
                  subjectId: Value(_rIntN(row, 'subject_id')),
                  teacherId: Value(_rIntN(row, 'teacher_id')),
                  date: _rDt(row, 'date') ?? DateTime.now(),
                  startTime: Value(_rStrN(row, 'start_time')),
                  endTime: Value(_rStrN(row, 'end_time')),
                  state: Value(_rStr(row, 'state', d: 'PENDING')),
                  lessonRecordId: Value(_rIntN(row, 'lesson_record_id')),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            case 'student_absences':
              b.insert(
                _db.studentAbsences,
                StudentAbsencesCompanion.insert(
                  id: Value(_rId(row)),
                  courseSessionId: _rInt(row, 'course_session_id'),
                  studentId: _rInt(row, 'student_id'),
                  isJustified: Value(_rBool(row, 'is_justified')),
                  reason: Value(_rStrN(row, 'reason')),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                  // [Fix-SYNC-IDEMPOTENCE] Lecture des champs de sync.
                  idempotencyKey: Value(_rStrN(row, 'idempotency_key')),
                  deviceUuid: Value(_rStrN(row, 'device_uuid')),
                  syncVersion: Value(_rInt(row, 'sync_version')),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            case 'lesson_records':
              b.insert(
                _db.lessonRecords,
                LessonRecordsCompanion.insert(
                  id: Value(_rId(row)),
                  courseSessionId: _rInt(row, 'course_session_id'),
                  content: _rStr(row, 'content'),
                  homework: Value(_rStrN(row, 'homework')),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            case 'users':
              b.insert(
                _db.users,
                UsersCompanion.insert(
                  id: Value(_rId(row)),
                  username: _rStr(row, 'username'),
                  firstName: Value(_rStrN(row, 'first_name')),
                  lastName: Value(_rStrN(row, 'last_name')),
                  email: Value(_rStrN(row, 'email')),
                  phone: Value(_rStrN(row, 'phone')),
                  photoPath: Value(_rStrN(row, 'photo_path')),
                  sexe: Value(_rStrN(row, 'sexe')),
                  isActive: Value(_rBool(row, 'is_active', d: true)),
                  isSuperuser: Value(_rBool(row, 'is_superuser')),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

            default:
              _log.w('Table non gérée par le sync engine : $table '
                  '(${rows.length} lignes ignorées)');
          }
        }
      });
    } catch (e) {
      _log.e('Erreur batch upsert table "$table" : $e');
      rethrow;
    }
  }

  Future<void> _applyDeletes(List<String> deleted, DateTime syncedAt) async {
    if (deleted.isEmpty) return;

    for (final entry in deleted) {
      final parts = entry.split(':');
      if (parts.length != 2) {
        _log.w('Format de suppression non reconnu : "$entry"');
        continue;
      }
      final table = parts[0].trim();
      final id = int.tryParse(parts[1].trim());
      if (id == null) {
        _log.w('ID de suppression invalide : "$entry"');
        continue;
      }
      await _updateRowSyncState(table, id, syncedAt, deleted: true);
    }
  }

  Future<void> _updateRowSyncState(
    String table,
    int recordId,
    DateTime syncedAt, {
    required bool deleted,
  }) async {
    switch (table) {
      case 'establishments':
        await (_db.update(_db.establishments)
              ..where((t) => t.id.equals(recordId)))
            .write(EstablishmentsCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      case 'school_years':
        await (_db.update(_db.schoolYears)..where((t) => t.id.equals(recordId)))
            .write(SchoolYearsCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      case 'periods':
        await (_db.update(_db.periods)..where((t) => t.id.equals(recordId)))
            .write(PeriodsCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      case 'levels':
        await (_db.update(_db.levels)..where((t) => t.id.equals(recordId)))
            .write(LevelsCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      case 'series':
        await (_db.update(_db.series)..where((t) => t.id.equals(recordId)))
            .write(SeriesCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      case 'streams':
        await (_db.update(_db.streams)..where((t) => t.id.equals(recordId)))
            .write(StreamsCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      case 'classrooms':
        await (_db.update(_db.classrooms)..where((t) => t.id.equals(recordId)))
            .write(ClassroomsCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      case 'subjects':
        await (_db.update(_db.subjects)..where((t) => t.id.equals(recordId)))
            .write(SubjectsCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      case 'class_subjects':
        await (_db.update(_db.classSubjects)
              ..where((t) => t.id.equals(recordId)))
            .write(ClassSubjectsCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      case 'assessments':
        await (_db.update(_db.assessments)..where((t) => t.id.equals(recordId)))
            .write(AssessmentsCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      case 'grades':
        await (_db.update(_db.grades)..where((t) => t.id.equals(recordId)))
            .write(GradesCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
          // [Grade-Validation] écriture directe appliquée -> marque résolue.
          syncStatus: const Value(null),
          proposedValue: const Value(null),
          proposedIsAbsent: const Value(null),
          proposedComments: const Value(null),
        ));
        break;
      case 'students':
        await (_db.update(_db.students)..where((t) => t.id.equals(recordId)))
            .write(StudentsCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      case 'student_contacts':
        await (_db.update(_db.studentContacts)
              ..where((t) => t.id.equals(recordId)))
            .write(StudentContactsCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      case 'student_medicals':
        await (_db.update(_db.studentMedicals)
              ..where((t) => t.id.equals(recordId)))
            .write(StudentMedicalsCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      case 'student_scholastics':
        await (_db.update(_db.studentScholastics)
              ..where((t) => t.id.equals(recordId)))
            .write(StudentScholasticsCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      case 'student_parents':
        await (_db.update(_db.studentParents)
              ..where((t) => t.id.equals(recordId)))
            .write(StudentParentsCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      case 'guardians':
        await (_db.update(_db.guardians)..where((t) => t.id.equals(recordId)))
            .write(GuardiansCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      case 'student_guardians':
        await (_db.update(_db.studentGuardians)
              ..where((t) => t.id.equals(recordId)))
            .write(StudentGuardiansCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      case 'student_class_assignments':
        await (_db.update(_db.studentClassAssignments)
              ..where((t) => t.id.equals(recordId)))
            .write(StudentClassAssignmentsCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      case 'student_statuses':
        await (_db.update(_db.studentStatuses)
              ..where((t) => t.id.equals(recordId)))
            .write(StudentStatusesCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      case 'inscription_types':
        await (_db.update(_db.inscriptionTypes)
              ..where((t) => t.id.equals(recordId)))
            .write(InscriptionTypesCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      case 'time_slots':
        await (_db.update(_db.timeSlots)..where((t) => t.id.equals(recordId)))
            .write(TimeSlotsCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      case 'weekly_schedules':
        await (_db.update(_db.weeklySchedules)
              ..where((t) => t.id.equals(recordId)))
            .write(WeeklySchedulesCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      case 'course_sessions':
        await (_db.update(_db.courseSessions)
              ..where((t) => t.id.equals(recordId)))
            .write(CourseSessionsCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      case 'student_absences':
        await (_db.update(_db.studentAbsences)
              ..where((t) => t.id.equals(recordId)))
            .write(StudentAbsencesCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      case 'lesson_records':
        await (_db.update(_db.lessonRecords)
              ..where((t) => t.id.equals(recordId)))
            .write(LessonRecordsCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      case 'users':
        await (_db.update(_db.users)..where((t) => t.id.equals(recordId)))
            .write(UsersCompanion(
          syncedAt: Value(syncedAt),
          isDirty: const Value(false),
          isDeleted: Value(deleted),
        ));
        break;
      default:
        _log.w('_updateRowSyncState : table non gérée "$table" (id=$recordId)');
    }
  }

  Future<void> _updateSyncMetadata(DateTime serverTime, int totalChanges) async {
    try {
      await _db.batch((b) {
        for (final table in replicatedTables) {
          b.insert(
            _db.syncMetadata,
            SyncMetadataCompanion.insert(
              tableNameColumn: table,
              lastSyncedAt: Value(serverTime),
              lastCount: Value(totalChanges),
              updatedAt: Value(serverTime),
            ),
            mode: InsertMode.insertOrReplace,
          );
        }
      });
    } catch (e) {
      _log.w('Échec mise à jour sync_metadata : $e');
    }
  }
}

/// [Fix-SYNC-IDEMPOTENCE] Génère une clé d'idempotence UUID v4 standard.
///
/// Utilisée par [SyncEngine.push] pour enrichir chaque ligne du payload
/// avec une `idempotency_key` unique, permettant au serveur de détecter
/// les doublons en cas de retry réseau (coupure, timeout).
///
/// Probabilité de collision : 1 sur 5,3 × 10^36 — négligeable.
String _generateIdempotencyKey() {
  return const Uuid().v4();
}

final syncEngineProvider = Provider<SyncEngine>((ref) {
  // WATCH databaseProvider : invalide le moteur lors d'une bascule.
  ref.watch(databaseProvider);
  return SyncEngine(ref);
});
