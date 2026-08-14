/// Contrôleur du module Matières : liste (recherche), matières par classe,
/// et repository (création / mise à jour / affectation / suppression)
/// offline-first.
///
/// - En ligne (`connection.canReachServer`) : appels REST `/subjects/*` et
///   `/class-subjects/*` via [dioProvider] + [buildUrl]. Aucun cache Drift en
///   V1 (les matières sont des données d'administration — surface de codegen
///   limitée).
/// - Hors-ligne : les écritures sont mises en file d'attente via
///   [outboxProvider] pour être poussées ultérieurement par le [SyncEngine].
///
/// RBAC : SUBJECT_MANAGE pour toutes les écritures (création / édition /
/// affectation / suppression). La lecture est ouverte à GRADE_READ (les
/// enseignants consultent les matières pour la saisie des notes).
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../../core/sync/outbox.dart';
import '../../features/connections/connection_state.dart';
import '../../shared/models/classroom_dto.dart';

final Logger _log = Logger(
  printer: PrettyPrinter(methodNames: false, noBoxingByDefault: true),
  level: Level.off,
);

// ===========================================================================
// Providers de lecture (family FutureProvider.autoDispose).
// ===========================================================================

/// Liste des matières filtrée par recherche : `GET /subjects?search=`.
///
/// Renvoie une liste vide si le serveur est non appairé. Les erreurs 403
/// (RBAC insuffisant) sont transformées en liste vide.
final subjectsListProvider =
    FutureProvider.autoDispose.family<List<SubjectDto>, String>(
        (ref, search) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return const [];

  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.getJson<dynamic>(
      buildUrl(conn.serverUrl!, ApiEndpoints.subjects),
      query: {
        if (search.trim().isNotEmpty) 'search': search.trim(),
        'per_page': 200,
      },
    );
    return _parseSubjectList(resp.data);
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403) return const [];
    _log.w('subjectsListProvider : ${api.message}');
    rethrow;
  } catch (e) {
    _log.w('subjectsListProvider : $e');
    rethrow;
  }
});

/// Matières affectées à une classe : `GET /class-subjects?classroom_id=`.
///
/// Repli sur `/grades/class-subjects?classroom_id=` (endpoint du module Notes)
/// si le premier renvoie 404 — les deux exposent le même schéma ClassSubjectDto.
final classSubjectsForClassroomProvider =
    FutureProvider.autoDispose.family<List<ClassSubjectDto>, int>(
        (ref, classroomId) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return const [];

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
    rethrow;
  } catch (e) {
    _log.w('classSubjectsForClassroomProvider : $e');
    rethrow;
  }
});

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
      return SubjectDto(id: 0, name: name, code: code);
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
      return SubjectDto(id: id, name: name, code: code);
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
        coefficient: coefficient.toInt(),
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
        coefficient: (coefficient ?? 1).toInt(),
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
