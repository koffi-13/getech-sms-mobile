/// Moteur de synchronisation offline-first (pull / push, server-wins).
///
/// Flux de synchronisation :
/// 1. **Pull** — `GET /sync/pull?since=<watermark>` : récupère les changements
///    serveur depuis la dernière synchro et les upsert localement.
/// 2. **Push** — `POST /sync/push` : dépile l'[Outbox] et envoie les écritures
///    locales au serveur.
/// 3. **Re-pull final** — récupère les changements issus du push (IDs générés
///    côté serveur, conflits résolus).
///
/// Stratégie de conflit : **server-wins** (V1). Le serveur est l'autorité ;
/// toute modification locale en conflit est écrasée par la version serveur
/// lors du prochain pull.
///
/// Watermark global : le `last_sync` du SecureStorage (via
/// [ConnectionNotifier.recordSync]) est utilisé comme paramètre `since` du
/// pull. Les métadonnées par table (`sync_metadata`) sont également mises à
/// jour avec le `serverTime` pour un usage futur (watermark par table).
library;

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

import '../../features/connections/connection_state.dart';
import '../../shared/models/sync_dto.dart';
import '../database/database.dart';
import '../network/api_endpoints.dart';
import '../network/api_exceptions.dart';
import '../network/dio_client.dart';
import 'outbox.dart';

/// Logger du module sync.
final Logger _log = Logger(
  printer: PrettyPrinter(methodNames: false, noBoxingByDefault: true),
  level: Level.debug,
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
// SyncResult
// ---------------------------------------------------------------------------

/// Résultat d'une opération de synchronisation.
class SyncResult {
  /// Nombre d'enregistrements reçus du serveur (pull).
  final int pulled;

  /// Nombre d'enregistrements envoyés au serveur (push).
  final int pushed;

  /// Horodatage du résultat.
  final DateTime timestamp;

  /// Liste des messages d'erreur rencontrés (vide si succès).
  final List<String> errors;

  const SyncResult({
    this.pulled = 0,
    this.pushed = 0,
    required this.timestamp,
    this.errors = const [],
  });

  /// `true` si aucune erreur n'a été rencontrée.
  bool get isSuccess => errors.isEmpty;

  @override
  String toString() =>
      'SyncResult(pulled: $pulled, pushed: $pushed, errors: $errors)';
}

// ---------------------------------------------------------------------------
// SyncEngine
// ---------------------------------------------------------------------------

/// Moteur de synchronisation offline-first.
///
/// Coordonne le pull (serveur → local) et le push (local → serveur) via
/// [Dio], en s'appuyant sur [AppDatabase] pour le stockage local et
/// [Outbox] pour la file d'attente des écritures.
class SyncEngine {
  SyncEngine(this._ref) : _db = _ref.read(databaseProvider);

  final Ref _ref;
  final AppDatabase _db;

  /// Synchronisation complète : pull → push → re-pull final.
  ///
  /// Si le serveur est injoignable, retourne immédiatement un résultat
  /// d'erreur sans tenter d'appel réseau.
  Future<SyncResult> syncNow() async {
    final errors = <String>[];
    var pulled = 0;
    var pushed = 0;

    // Vérification préalable de la connexion.
    if (!_ref.read(connectionProvider).canReachServer) {
      return SyncResult(
        timestamp: DateTime.now(),
        errors: ['Serveur injoignable'],
      );
    }

    // 1. Pull initial.
    final pull1 = await pull();
    pulled += pull1.pulled;
    errors.addAll(pull1.errors);
    if (!pull1.isSuccess) {
      // Si le pull initial échoue (réseau), on ne tente pas le push.
      return SyncResult(
        pulled: pulled,
        pushed: pushed,
        timestamp: DateTime.now(),
        errors: errors,
      );
    }

    // 2. Push des écritures locales.
    final pushResult = await push();
    pushed += pushResult.pushed;
    errors.addAll(pushResult.errors);

    // 3. Re-pull final pour récupérer les IDs serveur et les conflits résolus.
    final pull2 = await pull();
    pulled += pull2.pulled;
    errors.addAll(pull2.errors);

    return SyncResult(
      pulled: pulled,
      pushed: pushed,
      timestamp: DateTime.now(),
      errors: errors,
    );
  }

  /// Pull incrémental : `GET /sync/pull?since=<watermark>`.
  ///
  /// Récupère les changements serveur depuis la dernière synchro, les upsert
  /// localement, applique les suppressions (soft-delete), puis met à jour le
  /// watermark global via [ConnectionNotifier.recordSync].
  Future<SyncResult> pull() async {
    final conn = _ref.read(connectionProvider);
    if (!conn.canReachServer || conn.serverUrl == null) {
      return SyncResult(
        timestamp: DateTime.now(),
        errors: ['Serveur injoignable'],
      );
    }

    final dio = _ref.read(dioProvider);
    final since = conn.lastSync ?? DateTime(2000, 1, 1);
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

      // Application des changements par table.
      for (final entry in pullResp.changes.entries) {
        await _applyTableChanges(entry.key, entry.value, pullResp.serverTime);
      }

      // Application des suppressions (soft-delete).
      await _applyDeletes(pullResp.deleted, pullResp.serverTime);

      // Mise à jour du watermark global.
      await _ref
          .read(connectionProvider.notifier)
          .recordSync(count: pullResp.totalChanges);

      // Mise à jour des métadonnées par table.
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

  /// Push des écritures locales : dépile l'[Outbox] → `POST /sync/push`.
  ///
  /// Regroupe les entrées pending par table, construit une [SyncPushRequest],
  /// l'envoie au serveur, puis marque les entrées comme traitées.
  /// En cas de conflit (server-wins), l'entrée est marquée traitée avec une
  /// note ; la version serveur sera récupérée au prochain pull.
  Future<SyncResult> push() async {
    final conn = _ref.read(connectionProvider);
    if (!conn.canReachServer || conn.serverUrl == null) {
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

    // Regroupement par table → liste de payloads.
    final changes = <String, List<Map<String, dynamic>>>{};
    for (final entry in pending) {
      changes.putIfAbsent(entry.tableName, () => []).add(entry.payloadMap);
    }

    final dio = _ref.read(dioProvider);
    final url = buildUrl(conn.serverUrl!, ApiEndpoints.syncPush);

    try {
      _log.i('Push vers $url : ${pending.length} entrées '
          '(${changes.keys.length} tables)');
      final resp = await dio.postJson<Map<String, dynamic>>(
        url,
        data: SyncPushRequest(changes: changes).toJson(),
      );
      final data = resp.data;
      if (data == null) {
        return SyncResult(
          timestamp: DateTime.now(),
          errors: ['Réponse vide du serveur'],
        );
      }

      final pushResp = SyncPushResponse.fromJson(data);
      final appliedCount =
          pushResp.applied.values.fold(0, (sum, n) => sum + n);
      _log.i('Push terminé : $appliedCount appliqués, '
          '${pushResp.conflicts.length} conflits');

      // Marquage des entrées comme traitées.
      for (final entry in pending) {
        final conflictKey = entry.recordId != null
            ? '${entry.tableName}:${entry.recordId}'
            : null;
        final isConflict = conflictKey != null &&
            pushResp.conflicts.contains(conflictKey);

        if (isConflict) {
          // Server-wins : l'entrée est marquée traitée avec une note.
          // La version serveur sera récupérée au prochain pull.
          await outbox.markProcessed(
            entry.id,
            error: 'Conflit (server-wins) — ignoré par le serveur',
          );
        } else {
          await outbox.markProcessed(entry.id);
          // Marque l'enregistrement local comme synchronisé.
          if (entry.recordId != null) {
            final isDelete =
                entry.operation.toUpperCase() == 'DELETE';
            await _updateRowSyncState(
              entry.tableName,
              entry.recordId!,
              pushResp.serverTime,
              deleted: isDelete,
            );
          }
        }
      }

      // Nettoyage des entrées traitées.
      await outbox.clearProcessed();

      final errors = pushResp.conflicts.isEmpty
          ? const <String>[]
          : [
              '${pushResp.conflicts.length} conflit(s) résolu(s) '
              '(server-wins) — re-pull requis',
            ];

      return SyncResult(
        pushed: appliedCount,
        timestamp: pushResp.serverTime,
        errors: errors,
      );
    } on ApiException catch (e) {
      _log.w('Push échoué (API) : ${e.message}');
      return SyncResult(timestamp: DateTime.now(), errors: [e.message]);
    } catch (e) {
      _log.e('Push échoué (inattendu) : $e');
      return SyncResult(timestamp: DateTime.now(), errors: [e.toString()]);
    }
  }

  // -------------------------------------------------------------------------
  // Application des changements (upsert par table).
  // -------------------------------------------------------------------------

  /// Applique un lot de changements pour une table donnée (upsert en batch).
  ///
  /// Utilise un `switch` explicite sur le nom de la table pour appeler le
  /// companion Drift typé correspondant. Les tables non gérées loguent un
  /// avertissement et sont ignorées.
  Future<void> _applyTableChanges(
    String table,
    List<Map<String, dynamic>> rows,
    DateTime syncedAt,
  ) async {
    if (rows.isEmpty) return;

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

            case 'grades':
              b.insert(
                _db.grades,
                GradesCompanion.insert(
                  id: Value(_rId(row)),
                  assessmentId: _rInt(row, 'assessment_id'),
                  studentId: _rInt(row, 'student_id'),
                  value: Value(_rDblN(row, 'value')),
                  isAbsent: Value(_rBool(row, 'is_absent')),
                  comments: Value(_rStrN(row, 'comments')),
                  syncedAt: Value(syncedAt),
                  isDirty: const Value(false),
                  isDeleted: const Value(false),
                ),
                mode: InsertMode.insertOrReplace,
              );
              break;

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

  // -------------------------------------------------------------------------
  // Application des suppressions (soft-delete).
  // -------------------------------------------------------------------------

  /// Applique les suppressions serveur (soft-delete local).
  ///
  /// Chaque entrée de [deleted] est au format `tableName:recordId`.
  /// L'enregistrement local correspondant voit son `is_deleted` mis à `true`.
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

  // -------------------------------------------------------------------------
  // Mise à jour des flags de synchro (synced_at, is_dirty, is_deleted).
  // -------------------------------------------------------------------------

  /// Met à jour les flags de synchro d'un enregistrement local après un push
  /// réussi ou une suppression serveur.
  ///
  /// [deleted] : si `true`, marque l'enregistrement comme supprimé
  /// (soft-delete). Si `false`, marque comme synchronisé et non dirty.
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

  // -------------------------------------------------------------------------
  // Métadonnées de synchro.
  // ---------------------------------------------------------------------------

  /// Met à jour `sync_metadata.last_synced_at` pour toutes les tables
  /// répliquées avec le `serverTime` du dernier pull.
  Future<void> _updateSyncMetadata(DateTime serverTime, int totalChanges) async {
    try {
      await _db.batch((b) {
        for (final table in replicatedTables) {
          b.insert(
            _db.syncMetadata,
            SyncMetadataCompanion.insert(
              tableName: table,
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

/// Provider Riverpod du moteur de synchronisation (singleton).
final syncEngineProvider = Provider<SyncEngine>((ref) => SyncEngine(ref));
