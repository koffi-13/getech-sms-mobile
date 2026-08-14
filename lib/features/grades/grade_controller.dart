/// Contrôleur du module Notes : matières par classe, évaluations par matière,
/// notes par évaluation, classement, bulletin, sauvegarde des notes et
/// création d'évaluations.
///
/// Source de données V1 : API REST (online). Aucun cache Drift pour limiter
/// la surface de codegen.
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/constants.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../../features/connections/connection_state.dart';
import '../../shared/models/classroom_dto.dart';
import '../../shared/models/grade_dto.dart';

/// Paramètre de [rankingProvider] : classe + période.
class RankingQuery {
  const RankingQuery({required this.classroomId, required this.periodId});
  final int classroomId;
  final int periodId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RankingQuery &&
          other.classroomId == classroomId &&
          other.periodId == periodId;

  @override
  int get hashCode => Object.hash(classroomId, periodId);
}

/// Contrôleur Riverpod exposant les opérations de mutation (sauvegarde de
/// notes, création d'évaluation). Stateless : la page appelante gère son
/// propre indicateur de chargement.
class GradeController {
  GradeController(this._ref);
  final Ref _ref;

  Dio get _dio => _ref.read(dioProvider);
  String? get _serverUrl => _ref.read(connectionProvider).serverUrl;

  /// Sauvegarde en lot des notes d'une évaluation :
  /// `POST /grades/assessments/{id}/grades` (RBAC GRADE_EDIT).
  Future<void> saveGrades(int assessmentId, List<GradeDto> grades) async {
    final url = _serverUrl;
    if (url == null) throw const ApiException('Serveur non configuré');
    await _dio.post(
      buildUrl(url, ApiEndpoints.assessmentGrades(assessmentId)),
      data: SaveGradesRequest(assessmentId: assessmentId, grades: grades)
          .toJson(),
    );
    _ref.invalidate(assessmentGradesProvider(assessmentId));
  }

  /// Crée une évaluation : `POST /grades/assessments` (RBAC GRADE_EDIT).
  Future<AssessmentDto> createAssessment({
    required int classSubjectId,
    required String title,
    AssessmentType type = AssessmentType.devoir,
    DateTime? date,
    double maxScore = defaultMaxScore,
    double coefficient = 1.0,
    int? periodId,
  }) async {
    final url = _serverUrl;
    if (url == null) throw const ApiException('Serveur non configuré');
    final body = <String, dynamic>{
      'class_subject_id': classSubjectId,
      'title': title,
      'type': type.code,
      'date': date?.toUtc().toIso8601String(),
      'max_score': maxScore,
      'coefficient': coefficient,
      if (periodId != null) 'period_id': periodId,
    };
    final resp = await _dio.post(
      buildUrl(url, ApiEndpoints.gradesAssessments),
      data: body,
    );
    final data = resp.data is Map
        ? resp.data as Map<String, dynamic>
        : <String, dynamic>{};
    final created = AssessmentDto.fromJson(data);
    _ref.invalidate(assessmentsProvider(classSubjectId));
    return created;
  }
}

final gradeControllerProvider =
    Provider<GradeController>((ref) => GradeController(ref));

// ===========================================================================
// Providers de lecture (family FutureProvider.autoDispose).
// ===========================================================================

/// Liste des classes pour le sélecteur : `GET /classrooms`.
final classroomsForGradesProvider =
    FutureProvider.autoDispose<List<ClassroomDto>>((ref) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return const [];
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.get(
      buildUrl(conn.serverUrl!, ApiEndpoints.classrooms),
    );
    return _parseClassroomList(resp.data);
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403) return const [];
    rethrow;
  }
});

List<ClassroomDto> _parseClassroomList(dynamic data) {
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

/// Liste des périodes : `GET /settings/periods`.
final periodsProvider =
    FutureProvider.autoDispose<List<PeriodDto>>((ref) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return const [];
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.get(
      buildUrl(conn.serverUrl!, ApiEndpoints.settingsPeriods),
    );
    return _parsePeriodList(resp.data);
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403) return const [];
    rethrow;
  }
});

List<PeriodDto> _parsePeriodList(dynamic data) {
  if (data is List) {
    return data
        .whereType<Map>()
        .map((e) => PeriodDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  if (data is Map && data['items'] is List) {
    return (data['items'] as List)
        .whereType<Map>()
        .map((e) => PeriodDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  return const [];
}

/// Matières affectées à une classe : `GET /grades/class-subjects?classroom_id=`.
final classSubjectsProvider = FutureProvider.autoDispose
    .family<List<ClassSubjectDto>, int>((ref, classroomId) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return const [];
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.get(
      buildUrl(conn.serverUrl!, ApiEndpoints.gradesClassSubjects),
      queryParameters: {'classroom_id': classroomId},
    );
    return _parseClassSubjectList(resp.data);
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403) return const [];
    rethrow;
  }
});

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

/// Évaluations d'une matière : `GET /grades/assessments?class_subject_id=`.
final assessmentsProvider = FutureProvider.autoDispose
    .family<List<AssessmentDto>, int>((ref, classSubjectId) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return const [];
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.get(
      buildUrl(conn.serverUrl!, ApiEndpoints.gradesAssessments),
      queryParameters: {'class_subject_id': classSubjectId},
    );
    return _parseAssessmentList(resp.data);
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403) return const [];
    rethrow;
  }
});

List<AssessmentDto> _parseAssessmentList(dynamic data) {
  if (data is List) {
    return data
        .whereType<Map>()
        .map((e) => AssessmentDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  if (data is Map && data['items'] is List) {
    return (data['items'] as List)
        .whereType<Map>()
        .map((e) => AssessmentDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  return const [];
}

/// Notes d'une évaluation : `GET /grades/assessments/{id}/grades`.
final assessmentGradesProvider = FutureProvider.autoDispose
    .family<List<GradeDto>, int>((ref, assessmentId) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return const [];
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.get(
      buildUrl(conn.serverUrl!, ApiEndpoints.assessmentGrades(assessmentId)),
    );
    return _parseGradeList(resp.data);
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403) return const [];
    rethrow;
  }
});

List<GradeDto> _parseGradeList(dynamic data) {
  if (data is List) {
    return data
        .whereType<Map>()
        .map((e) => GradeDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  if (data is Map && data['items'] is List) {
    return (data['items'] as List)
        .whereType<Map>()
        .map((e) => GradeDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  return const [];
}

/// Classement d'une classe pour une période :
/// `GET /grades/ranking?classroom_id=&period_id=`.
final rankingProvider = FutureProvider.autoDispose
    .family<List<RankingRowDto>, RankingQuery>((ref, q) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return const [];
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.get(
      buildUrl(conn.serverUrl!, ApiEndpoints.gradesRanking),
      queryParameters: {
        'classroom_id': q.classroomId,
        'period_id': q.periodId,
      },
    );
    return _parseRankingList(resp.data);
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403) return const [];
    rethrow;
  }
});

List<RankingRowDto> _parseRankingList(dynamic data) {
  if (data is List) {
    return data
        .whereType<Map>()
        .map((e) => RankingRowDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  if (data is Map && data['items'] is List) {
    return (data['items'] as List)
        .whereType<Map>()
        .map((e) => RankingRowDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  return const [];
}

/// Bulletin d'un élève : `GET /grades/bulletin/{student_id}`.
final bulletinProvider = FutureProvider.autoDispose
    .family<BulletinDto, int>((ref, studentId) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) {
    throw const ApiException('Serveur non configuré');
  }
  final dio = ref.watch(dioProvider);
  final resp = await dio.get(
    buildUrl(conn.serverUrl!, ApiEndpoints.bulletin(studentId)),
  );
  if (resp.data is! Map) {
    throw const ApiException('Réponse bulletin invalide');
  }
  return BulletinDto.fromJson(resp.data as Map<String, dynamic>);
});
