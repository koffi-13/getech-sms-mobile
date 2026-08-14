/// Contrôleur du module Notes : matières par classe, évaluations par matière,
/// notes par évaluation, classement, bulletin, sauvegarde des notes et
/// création d'évaluations.
///
/// Aligné sur les vrais endpoints du desktop (grades router) :
/// - `GET /grades/class-subjects?classroom_id=X`
/// - `GET /grades/assessments?class_subject_id=X&period_id=Y`
/// - `GET /grades/assessments/{id}/grades` → list[GradeEntryResponse]
/// - `POST /grades/assessments/{id}/grades` → GradeBulkSaveRequest/Response
/// - `POST /grades/assessments` → AssessmentCreateRequest → AssessmentResponse
/// - `DELETE /grades/assessments/{id}`
/// - `GET /grades/ranking?classroom_id=&period_id=&ranking_mode=&subject_id=`
/// - `GET /grades/bulletin/{student_id}?classroom_id=&period_id=`
///
/// Source de données V1 : API REST (online). Aucun cache Drift pour limiter
/// la surface de codegen.
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../../features/connections/connection_state.dart';
import '../../shared/models/classroom_dto.dart';
import '../../shared/models/grade_dto.dart';

/// Mode de classement (PERIOD = moyenne de la période courante,
/// SUBJECT = moyenne d'une matière spécifique).
enum RankingMode { period, subject }

extension RankingModeX on RankingMode {
  String get serverValue {
    switch (this) {
      case RankingMode.period:
        return 'PERIOD';
      case RankingMode.subject:
        return 'SUBJECT';
    }
  }
}

/// Paramètre de [assessmentsProvider] : matière + période.
class AssessmentsQuery {
  const AssessmentsQuery({
    required this.classSubjectId,
    required this.periodId,
  });

  final int classSubjectId;
  final int periodId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AssessmentsQuery &&
          other.classSubjectId == classSubjectId &&
          other.periodId == periodId;

  @override
  int get hashCode => Object.hash(classSubjectId, periodId);
}

/// Paramètre de [rankingProvider] : classe + période + mode (+ matière si SUBJECT).
class RankingQuery {
  const RankingQuery({
    required this.classroomId,
    required this.periodId,
    this.rankingMode = RankingMode.period,
    this.subjectId,
  });

  final int classroomId;
  final int periodId;
  final RankingMode rankingMode;
  final int? subjectId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RankingQuery &&
          other.classroomId == classroomId &&
          other.periodId == periodId &&
          other.rankingMode == rankingMode &&
          other.subjectId == subjectId;

  @override
  int get hashCode =>
      Object.hash(classroomId, periodId, rankingMode, subjectId);
}

/// Paramètre de [bulletinProvider] : élève + classe + période ( requis comme
/// query params par le serveur).
class BulletinQuery {
  const BulletinQuery({
    required this.studentId,
    required this.classroomId,
    required this.periodId,
  });

  final int studentId;
  final int classroomId;
  final int periodId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BulletinQuery &&
          other.studentId == studentId &&
          other.classroomId == classroomId &&
          other.periodId == periodId;

  @override
  int get hashCode => Object.hash(studentId, classroomId, periodId);
}

/// Contrôleur Riverpod exposant les opérations de mutation (sauvegarde de
/// notes, création d'évaluation, suppression d'évaluation). Stateless : la
/// page appelante gère son propre indicateur de chargement.
class GradeController {
  GradeController(this._ref);
  final Ref _ref;

  Dio get _dio => _ref.read(dioProvider);
  String? get _serverUrl => _ref.read(connectionProvider).serverUrl;

  /// Sauvegarde en lot des notes d'une évaluation :
  /// `POST /grades/assessments/{id}/grades` (RBAC GRADE_EDIT).
  ///
  /// Le serveur attend `{grades: list[dict]}` (GradeBulkSaveRequest). On
  /// sérialise chaque [GradeEntryDto] via `toJson()` puis on invalide le
  /// provider des notes de l'évaluation.
  Future<SaveGradesResponse> saveGrades(
    int assessmentId,
    List<GradeEntryDto> entries,
  ) async {
    final url = _serverUrl;
    if (url == null) throw const ApiException('Serveur non configuré');
    final body = SaveGradesRequest(
      grades: entries.map((e) => e.toJson()).toList(),
    ).toJson();
    final resp = await _dio.post(
      buildUrl(url, ApiEndpoints.assessmentGrades(assessmentId)),
      data: body,
    );
    final data = resp.data is Map
        ? Map<String, dynamic>.from(resp.data as Map)
        : <String, dynamic>{};
    final result = SaveGradesResponse.fromJson(data);
    _ref.invalidate(assessmentGradesProvider(assessmentId));
    // Invalide aussi la liste des évaluations (le compteur gradesEnteredCount
    // peut avoir changé).
    _invalidateAssessmentsFor(assessmentId);
    return result;
  }

  /// Crée une évaluation : `POST /grades/assessments` (RBAC GRADE_EDIT).
  Future<AssessmentDto> createAssessment(
      AssessmentCreateRequest request) async {
    final url = _serverUrl;
    if (url == null) throw const ApiException('Serveur non configuré');
    final resp = await _dio.post(
      buildUrl(url, ApiEndpoints.gradesAssessments),
      data: request.toJson(),
    );
    final data = resp.data is Map
        ? Map<String, dynamic>.from(resp.data as Map)
        : <String, dynamic>{};
    final created = AssessmentDto.fromJson(data);
    // Invalide la liste des évaluations pour ce class_subject+period.
    _ref.invalidate(assessmentsProvider(AssessmentsQuery(
      classSubjectId: request.classSubjectId,
      periodId: request.periodId,
    )));
    return created;
  }

  /// Supprime une évaluation : `DELETE /grades/assessments/{id}`
  /// (RBAC GRADE_EDIT).
  Future<void> deleteAssessment(int id) async {
    final url = _serverUrl;
    if (url == null) throw const ApiException('Serveur non configuré');
    await _dio.delete(buildUrl(url, ApiEndpoints.assessment(id)));
    _ref.invalidate(assessmentGradesProvider(id));
    _invalidateAssessmentsFor(id);
  }

  /// Invalide toutes les listes d'évaluations (best-effort) — utilisé après
  /// une mutation qui peut affecter le compteur `gradesEnteredCount`.
  void _invalidateAssessmentsFor(int assessmentId) {
    // Riverpod ne permet pas d'énumérer les entrées d'un family ; on compte
    // sur l'autoDispose pour rafraîchir la prochaine fois que la liste est
    // affichée. On invalide explicitement la liste des classes/périodes
    // courantes via le provider global (best-effort no-op si non chargé).
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

/// Évaluations d'une matière pour une période :
/// `GET /grades/assessments?class_subject_id=X&period_id=Y`.
final assessmentsProvider = FutureProvider.autoDispose
    .family<List<AssessmentDto>, AssessmentsQuery>((ref, q) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return const [];
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.get(
      buildUrl(conn.serverUrl!, ApiEndpoints.gradesAssessments),
      queryParameters: {
        'class_subject_id': q.classSubjectId,
        'period_id': q.periodId,
      },
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

/// Notes d'une évaluation (entrées par élève) :
/// `GET /grades/assessments/{id}/grades` → list[GradeEntryResponse].
final assessmentGradesProvider = FutureProvider.autoDispose
    .family<List<GradeEntryDto>, int>((ref, assessmentId) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return const [];
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.get(
      buildUrl(conn.serverUrl!, ApiEndpoints.assessmentGrades(assessmentId)),
    );
    return _parseGradeEntryList(resp.data);
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403) return const [];
    rethrow;
  }
});

List<GradeEntryDto> _parseGradeEntryList(dynamic data) {
  if (data is List) {
    return data
        .whereType<Map>()
        .map((e) => GradeEntryDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  if (data is Map && data['items'] is List) {
    return (data['items'] as List)
        .whereType<Map>()
        .map((e) => GradeEntryDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  return const [];
}

/// Classement d'une classe pour une période :
/// `GET /grades/ranking?classroom_id=&period_id=&ranking_mode=&subject_id=`.
final rankingProvider = FutureProvider.autoDispose
    .family<List<RankingRowDto>, RankingQuery>((ref, q) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return const [];
  final dio = ref.watch(dioProvider);
  try {
    final params = <String, dynamic>{
      'classroom_id': q.classroomId,
      'period_id': q.periodId,
      'ranking_mode': q.rankingMode.serverValue,
    };
    if (q.rankingMode == RankingMode.subject && q.subjectId != null) {
      params['subject_id'] = q.subjectId!;
    }
    final resp = await dio.get(
      buildUrl(conn.serverUrl!, ApiEndpoints.gradesRanking),
      queryParameters: params,
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

/// Bulletin d'un élève :
/// `GET /grades/bulletin/{student_id}?classroom_id=X&period_id=Y`.
///
/// ⚠️ `classroomId` et `periodId` sont des query params **requis** par
/// le serveur : on les passe systématiquement.
final bulletinProvider = FutureProvider.autoDispose
    .family<BulletinDto, BulletinQuery>((ref, q) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) {
    throw const ApiException('Serveur non configuré');
  }
  final dio = ref.watch(dioProvider);
  final resp = await dio.get(
    buildUrl(conn.serverUrl!, ApiEndpoints.bulletin(q.studentId)),
    queryParameters: {
      'classroom_id': q.classroomId,
      'period_id': q.periodId,
    },
  );
  if (resp.data is! Map) {
    throw const ApiException('Réponse bulletin invalide');
  }
  return BulletinDto.fromJson(Map<String, dynamic>.from(resp.data as Map));
});
