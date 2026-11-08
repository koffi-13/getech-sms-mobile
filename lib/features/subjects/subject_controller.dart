/// Contrôleur du module Matières : liste (recherche), matières par classe,
/// et repository (création / mise à jour / affectation / suppression)
/// offline-first.
///
/// - En ligne (`connection.canReachServer`) : appels REST `/subjects/*` et
///   `/class-subjects/*` via [dioProvider] + [buildUrl].
/// - Hors-ligne ([Fix-SUBJECTS-OFFLINE] V23) : lecture depuis le cache
///   Drift (`subjects` / `class_subjects`, rempli par la synchro) — la
///   page Matières restait une erreur réseau avant ce repli alors que la
///   table est répliquée depuis la V1.
/// - Écritures : mises en file d'attente via [outboxProvider] pour être
///   poussées ultérieurement par le [SyncEngine].
///
/// RBAC : SUBJECT_MANAGE pour toutes les écritures (création / édition /
/// affectation / suppression). La lecture est ouverte à GRADE_READ (les
/// enseignants consultent les matières pour la saisie des notes).
library;

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' as d;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart' as log_pkg;

import '../../core/database/database.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../../core/sync/outbox.dart';
import '../../core/sync/sync_engine.dart' show syncGenerationProvider;
import '../../features/connections/connection_state.dart';
import '../../shared/models/classroom_dto.dart';

final log_pkg.Logger _log = log_pkg.Logger(
  printer: log_pkg.PrettyPrinter(noBoxingByDefault: true),
  level: log_pkg.Level.off,
);

// ===========================================================================
// Providers de lecture (family FutureProvider.autoDispose).
// ===========================================================================

/// Liste des matières filtrée par recherche : `GET /subjects?search=`.
///
/// [Fix-SUBJECTS-OFFLINE] V23 — hors-ligne ou réseau coupé : cache Drift
/// (`subjects`, rempli par la synchro). En ligne, la réponse met le cache
/// à jour (best-effort) pour les consultations suivantes.
final subjectsListProvider =
    FutureProvider.autoDispose.family<List<SubjectDto>, String>(
        (ref, search) async {
  // [Fix-AUTO-SYNC] rafraîchissement après chaque synchro utile.
  ref.watch(syncGenerationProvider);
  final conn = ref.watch(
    connectionProvider.select(
      (c) => (
        isPaired: c.isPaired,
        serverUrl: c.serverUrl,
        canReachServer: c.canReachServer,
        isChecking: c.isChecking,
      ),
    ),
  );
  if (!conn.isPaired || conn.serverUrl == null) {
    return _subjectsFromLocal(ref, search);
  }
  if (!conn.canReachServer && !conn.isChecking) {
    return _subjectsFromLocal(ref, search);
  }

  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.getJson<dynamic>(
      buildUrl(conn.serverUrl!, ApiEndpoints.subjects),
      query: {
        if (search.trim().isNotEmpty) 'search': search.trim(),
        'per_page': 200,
      },
    );
    final subjects = _parseSubjectList(resp.data);
    await _cacheSubjectsFromDtos(ref, subjects);
    return subjects;
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403) return const [];
    _log.w('subjectsListProvider : ${api.message}');
    // [Fix-SUBJECTS-OFFLINE] réseau KO en cours de requête → cache Drift.
    if (api is NetworkException) return _subjectsFromLocal(ref, search);
    rethrow;
  } catch (e) {
    _log.w('subjectsListProvider : $e');
    rethrow;
  }
});

/// [Fix-SUBJECTS-OFFLINE] V23 — matières servies par le cache Drift
/// (recherche insensible à la casse sur nom + code).
Future<List<SubjectDto>> _subjectsFromLocal(Ref ref, String search) async {
  try {
    final db = ref.read(databaseProvider);
    final rows = await (db.select(db.subjects)
          ..where((t) => t.isDeleted.equals(false))
          ..orderBy([(t) => d.OrderingTerm.asc(t.name)]))
        .get();
    final needle = search.trim().toLowerCase();
    return rows
        .where((s) =>
            needle.isEmpty ||
            s.name.toLowerCase().contains(needle) ||
            (s.code ?? '').toLowerCase().contains(needle))
        .map(
          (s) => SubjectDto(
            id: s.id,
            name: s.name,
            code: s.code ?? '',
            isActive: true,
          ),
        )
        .toList();
  } catch (_) {
    return const [];
  }
}

/// [Fix-SUBJECTS-OFFLINE] V23 — persiste les matières de l'API dans le
/// cache Drift (best-effort, upsert par id).
Future<void> _cacheSubjectsFromDtos(
  Ref ref,
  List<SubjectDto> subjects,
) async {
  if (subjects.isEmpty) return;
  try {
    final db = ref.read(databaseProvider);
    final now = DateTime.now();
    await db.batch((batch) {
      for (final s in subjects) {
        batch.insert(
          db.subjects,
          SubjectsCompanion.insert(
            id: d.Value(s.id),
            name: s.name,
            code: d.Value(s.code.isEmpty ? null : s.code),
            syncedAt: d.Value(now),
            isDirty: const d.Value(false),
            isDeleted: const d.Value(false),
          ),
          mode: d.InsertMode.insertOrReplace,
        );
      }
    });
  } catch (_) {
    // Cache non essentiel : ne jamais bloquer l'affichage.
  }
}

/// Matières affectées à une classe : `GET /class-subjects?classroom_id=`.
///
/// Repli sur `/grades/class-subjects?classroom_id=` (endpoint du module Notes)
/// si le premier renvoie 404 — les deux exposent le même schéma ClassSubjectDto.
///
/// [Fix-SUBJECTS-OFFLINE] V23 — hors-ligne ou réseau coupé : cache Drift
/// (`class_subjects` + `subjects`, remplis par la synchro) — l'affectation
/// des matières d'une classe restait une erreur réseau avant ce repli.
final classSubjectsForClassroomProvider =
    FutureProvider.autoDispose.family<List<ClassSubjectDto>, int>(
        (ref, classroomId) async {
  ref.watch(syncGenerationProvider);
  final conn = ref.watch(
    connectionProvider.select(
      (c) => (
        isPaired: c.isPaired,
        serverUrl: c.serverUrl,
        canReachServer: c.canReachServer,
        isChecking: c.isChecking,
      ),
    ),
  );
  if (!conn.isPaired || conn.serverUrl == null) {
    return _classSubjectsFromLocal(ref, classroomId);
  }
  if (!conn.canReachServer && !conn.isChecking) {
    return _classSubjectsFromLocal(ref, classroomId);
  }

  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.getJson<dynamic>(
      buildUrl(conn.serverUrl!, ApiEndpoints.classSubjects),
      query: {'classroom_id': classroomId},
    );
    return _parseClassSubjectList(resp.data);
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 404) {
      // Repli sur l'endpoint grades/class-subjects (module Notes).
      try {
        final resp2 = await dio.getJson<dynamic>(
          buildUrl(conn.serverUrl!, ApiEndpoints.gradesClassSubjects),
          query: {'classroom_id': classroomId},
        );
        return _parseClassSubjectList(resp2.data);
      } catch (_) {
        return const [];
      }
    }
    if (api.statusCode == 403) return const [];
    _log.w('classSubjectsForClassroomProvider : ${api.message}');
    // [Fix-SUBJECTS-OFFLINE] réseau KO en cours de requête → cache Drift.
    if (api is NetworkException) {
      return _classSubjectsFromLocal(ref, classroomId);
    }
    rethrow;
  } catch (e) {
    _log.w('classSubjectsForClassroomProvider : $e');
    rethrow;
  }
});

/// [Fix-SUBJECTS-OFFLINE] V23 — matières d'une classe depuis le cache
/// Drift (jointure locale class_subjects × subjects × users).
Future<List<ClassSubjectDto>> _classSubjectsFromLocal(
  Ref ref,
  int classroomId,
) async {
  try {
    final db = ref.read(databaseProvider);
    final rows = await (db.select(db.classSubjects)
          ..where((t) => t.classroomId.equals(classroomId))
          ..where((t) => t.isDeleted.equals(false)))
        .get();
    if (rows.isEmpty) return const [];
    final subjects = {
      for (final s in await db.select(db.subjects).get()) s.id: s,
    };
    final users = await db.select(db.users).get();
    final userById = {
      for (final u in users) u.id: u,
    };
    return rows
        .map((cs) {
          final subject = subjects[cs.subjectId];
          final teacher = cs.teacherId == null ? null : userById[cs.teacherId];
          // Convention « NOM Prénoms » : cf. [Fix-SYNC-FIELD-MAP-V11] —
          // firstName reçoit `nom`, lastName reçoit `prenoms`.
          final teacherName = teacher == null
              ? null
              : [teacher.firstName, teacher.lastName]
                  .where((p) => p != null && p.isNotEmpty)
                  .join(' ');
          return ClassSubjectDto(
            id: cs.id,
            subjectId: cs.subjectId,
            subjectName: subject?.name ?? 'Matière #${cs.subjectId}',
            subjectCode: subject?.code ?? '',
            coefficient: cs.coefficient,
            assignedTeacherId: cs.teacherId,
            assignedTeacherName:
                (teacherName == null || teacherName.isEmpty) ? null : teacherName,
            classroomId: classroomId,
          );
        })
        .toList()
      ..sort((a, b) => a.subjectName.compareTo(b.subjectName));
  } catch (_) {
    return const [];
  }
}

// ===========================================================================
// Repository (écritures : create / update / affectation / suppression).
// ===========================================================================

/// Erreur métier renvoyée par [SubjectRepository].
class SubjectRepositoryException implements Exception {
  const SubjectRepositoryException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'SubjectRepositoryException(${statusCode ?? ''}): $message';
}

/// Repository des matières et affectations classe↔matière.
class SubjectRepository {
  SubjectRepository(this._ref);

  final Ref _ref;

  Dio get _dio => _ref.read(dioProvider);
  Outbox get _outbox => _ref.read(outboxProvider);
  String? get _serverUrl => _ref.read(connectionProvider).serverUrl;
  bool get _canReach => _ref.read(connectionProvider).canReachServer;

  /// Crée une matière : `POST /subjects` (RBAC SUBJECT_MANAGE).
  Future<SubjectDto> createSubject({
    required String name,
    String? code,
  }) async {
    final payload = <String, dynamic>{
      'name': name,
      if (code != null && code.isNotEmpty) 'code': code,
    };
    if (!_canReach || _serverUrl == null) {
      await _outbox.enqueue(
        table: 'subjects',
        operation: 'INSERT',
        recordId: null,
        payload: payload,
      );
      return SubjectDto(id: 0, name: name, code: code ?? '');
    }
    try {
      final resp = await _dio.postJson<Map<String, dynamic>>(
        buildUrl(_serverUrl!, ApiEndpoints.subjects),
        data: payload,
      );
      final created = SubjectDto.fromJson(resp.data ?? const {});
      _ref.invalidate(subjectsListProvider);
      return created;
    } on DioException catch (e) {
      final api = (e.error is ApiException)
          ? e.error as ApiException
          : dioErrorToApiException(e);
      throw SubjectRepositoryException(api.message, statusCode: api.statusCode);
    } catch (e) {
      throw SubjectRepositoryException('Échec de la création : $e');
    }
  }

  /// Met à jour une matière : `PATCH /subjects/{id}` (RBAC SUBJECT_MANAGE).
  Future<SubjectDto> updateSubject(
    int id, {
    required String name,
    String? code,
  }) async {
    final payload = <String, dynamic>{
      'name': name,
      if (code != null && code.isNotEmpty) 'code': code,
    };
    if (!_canReach || _serverUrl == null) {
      await _outbox.enqueue(
        table: 'subjects',
        operation: 'UPDATE',
        recordId: id,
        payload: payload,
      );
      return SubjectDto(id: id, name: name, code: code ?? '');
    }
    try {
      final resp = await _dio.patchJson<Map<String, dynamic>>(
        buildUrl(_serverUrl!, '/subjects/$id'),
        data: payload,
      );
      final saved = SubjectDto.fromJson(resp.data ?? const {});
      _ref.invalidate(subjectsListProvider);
      return saved;
    } on DioException catch (e) {
      final api = (e.error is ApiException)
          ? e.error as ApiException
          : dioErrorToApiException(e);
      throw SubjectRepositoryException(api.message, statusCode: api.statusCode);
    } catch (e) {
      throw SubjectRepositoryException('Échec de la mise à jour : $e');
    }
  }

  /// Affecte une matière à une classe : `POST /class-subjects`
  /// (RBAC SUBJECT_MANAGE).
  Future<ClassSubjectDto> assignSubjectToClass({
    required int classroomId,
    required int subjectId,
    double coefficient = 1.0,
    int? teacherId,
  }) async {
    final payload = <String, dynamic>{
      'classroom_id': classroomId,
      'subject_id': subjectId,
      'coefficient': coefficient,
      if (teacherId != null) 'teacher_id': teacherId,
    };
    if (!_canReach || _serverUrl == null) {
      await _outbox.enqueue(
        table: 'class_subjects',
        operation: 'INSERT',
        recordId: null,
        payload: payload,
      );
      return ClassSubjectDto(
        id: 0,
        classroomId: classroomId,
        subjectId: subjectId,
        subjectName: '',
        coefficient: coefficient,
        assignedTeacherId: teacherId,
      );
    }
    try {
      final resp = await _dio.postJson<Map<String, dynamic>>(
        buildUrl(_serverUrl!, ApiEndpoints.classSubjects),
        data: payload,
      );
      final created = ClassSubjectDto.fromJson(resp.data ?? const {});
      _ref.invalidate(classSubjectsForClassroomProvider(classroomId));
      return created;
    } on DioException catch (e) {
      final api = (e.error is ApiException)
          ? e.error as ApiException
          : dioErrorToApiException(e);
      throw SubjectRepositoryException(api.message, statusCode: api.statusCode);
    } catch (e) {
      throw SubjectRepositoryException('Échec de l\'affectation : $e');
    }
  }

  /// Met à jour une affectation classe↔matière : `PATCH /class-subjects/{id}`
  /// (RBAC SUBJECT_MANAGE).
  Future<ClassSubjectDto> updateClassSubject(
    int id, {
    required int classroomId,
    double? coefficient,
    int? teacherId,
    bool clearTeacher = false,
  }) async {
    final payload = <String, dynamic>{};
    if (coefficient != null) payload['coefficient'] = coefficient;
    if (clearTeacher) {
      payload['teacher_id'] = null;
    } else if (teacherId != null) {
      payload['teacher_id'] = teacherId;
    }
    if (payload.isEmpty) {
      throw const SubjectRepositoryException('Aucune modification à appliquer.');
    }
    if (!_canReach || _serverUrl == null) {
      await _outbox.enqueue(
        table: 'class_subjects',
        operation: 'UPDATE',
        recordId: id,
        payload: payload,
      );
      return ClassSubjectDto(
        id: id,
        classroomId: classroomId,
        subjectId: 0,
        subjectName: '',
        coefficient: coefficient ?? 1.0,
        assignedTeacherId: clearTeacher ? null : teacherId,
      );
    }
    try {
      final resp = await _dio.patchJson<Map<String, dynamic>>(
        buildUrl(_serverUrl!, ApiEndpoints.classSubject(id)),
        data: payload,
      );
      final saved = ClassSubjectDto.fromJson(resp.data ?? const {});
      _ref.invalidate(classSubjectsForClassroomProvider(classroomId));
      return saved;
    } on DioException catch (e) {
      final api = (e.error is ApiException)
          ? e.error as ApiException
          : dioErrorToApiException(e);
      throw SubjectRepositoryException(api.message, statusCode: api.statusCode);
    } catch (e) {
      throw SubjectRepositoryException('Échec de la mise à jour : $e');
    }
  }

  /// Supprime une affectation classe↔matière : `DELETE /class-subjects/{id}`
  /// (RBAC SUBJECT_MANAGE).
  Future<void> removeClassSubject(int id, {required int classroomId}) async {
    if (!_canReach || _serverUrl == null) {
      await _outbox.enqueue(
        table: 'class_subjects',
        operation: 'DELETE',
        recordId: id,
        payload: {'id': id},
      );
      _ref.invalidate(classSubjectsForClassroomProvider(classroomId));
      return;
    }
    try {
      await _dio.deleteJson<void>(
        buildUrl(_serverUrl!, ApiEndpoints.classSubject(id)),
      );
      _ref.invalidate(classSubjectsForClassroomProvider(classroomId));
    } on DioException catch (e) {
      final api = (e.error is ApiException)
          ? e.error as ApiException
          : dioErrorToApiException(e);
      // 404 = déjà supprimé côté serveur : pas une erreur.
      if (api.statusCode == 404) {
        _ref.invalidate(classSubjectsForClassroomProvider(classroomId));
        return;
      }
      throw SubjectRepositoryException(api.message, statusCode: api.statusCode);
    } catch (e) {
      throw SubjectRepositoryException('Suppression différée : $e');
    }
  }
}

final subjectRepositoryProvider =
    Provider<SubjectRepository>((ref) => SubjectRepository(ref));

// ===========================================================================
// Helpers de parsing
// ===========================================================================

List<SubjectDto> _parseSubjectList(dynamic data) {
  if (data is List) {
    return data
        .whereType<Map>()
        .map((e) => SubjectDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  if (data is Map && data['items'] is List) {
    return (data['items'] as List)
        .whereType<Map>()
        .map((e) => SubjectDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  return const [];
}

List<ClassSubjectDto> _parseClassSubjectList(dynamic data) {
  if (data is List) {
    return data
        .whereType<Map>()
        .map((e) => ClassSubjectDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  if (data is Map && data['items'] is List) {
    return (data['items'] as List)
        .whereType<Map>()
        .map((e) => ClassSubjectDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  return const [];
}
