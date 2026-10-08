/// Contrôleur du module Présence : démarrage d'une session de cours,
/// enregistrement des absences (lot), cahier de texte, historique d'absences
/// d'un élève.
///
/// Source de données V1 : API REST (online). Aucun cache Drift pour limiter
/// la surface de codegen.
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../../core/utils/formatters.dart';
import '../../features/connections/connection_state.dart';
import '../../shared/models/attendance_dto.dart';
import '../../shared/models/student_dto.dart';

/// Contrôleur Riverpod exposant les opérations de mutation (démarrage de
/// session, sauvegarde des absences, cahier de texte). Stateless : la page
/// appelante gère son propre indicateur de chargement.
class AttendanceController {
  AttendanceController(this._ref);
  final Ref _ref;

  Dio get _dio => _ref.read(dioProvider);
  String? get _serverUrl => _ref.read(connectionProvider).serverUrl;

  /// Démarre une session de cours : `POST /attendance/session`.
  Future<CourseSessionDto> startSession({
    required int classroomId,
    int? weeklyScheduleId,
    int? subjectId,
    int? teacherId,
    required DateTime date,
    String? startTime,
    String? endTime,
  }) async {
    final url = _serverUrl;
    if (url == null) throw const ApiException('Serveur non configuré');
    final body = <String, dynamic>{
      'classroom_id': classroomId,
      'date': date.toUtc().toIso8601String(),
      if (weeklyScheduleId != null) 'weekly_schedule_id': weeklyScheduleId,
      if (subjectId != null) 'subject_id': subjectId,
      if (teacherId != null) 'teacher_id': teacherId,
      if (startTime != null) 'start_time': startTime,
      if (endTime != null) 'end_time': endTime,
    };
    final resp = await _dio.post(
      buildUrl(url, ApiEndpoints.attendanceSession),
      data: body,
    );
    final data = resp.data is Map
        ? resp.data as Map<String, dynamic>
        : <String, dynamic>{};
    final session = CourseSessionDto.fromJson(data);
    _ref.invalidate(sessionAbsencesProvider(session.id));
    return session;
  }

  /// Enregistre les absences d'une session (lot) :
  /// `POST /attendance/session/{sessionId}/absences`.
  Future<void> saveAbsences(
      int sessionId, List<StudentAbsenceDto> absences) async {
    final url = _serverUrl;
    if (url == null) throw const ApiException('Serveur non configuré');
    await _dio.post(
      buildUrl(url, ApiEndpoints.attendanceAbsences(sessionId)),
      data: SaveAbsencesRequest(sessionId: sessionId, absences: absences)
          .toJson(),
    );
    _ref.invalidate(sessionAbsencesProvider(sessionId));
  }

  /// Marque une session comme terminée (PATCH /attendance/session/{id}).
  Future<CourseSessionDto> markSessionState(
      int sessionId, String state) async {
    final url = _serverUrl;
    if (url == null) throw const ApiException('Serveur non configuré');
    final resp = await _dio.patch(
      buildUrl(url, '${ApiEndpoints.attendanceSession}/$sessionId'),
      data: {'state': state},
    );
    final data = resp.data is Map
        ? resp.data as Map<String, dynamic>
        : <String, dynamic>{};
    final session = CourseSessionDto.fromJson(data);
    _ref.invalidate(sessionAbsencesProvider(sessionId));
    _ref.invalidate(lessonRecordProvider(sessionId));
    return session;
  }

  /// Sauvegarde le cahier de texte d'une session :
  /// `POST /attendance/session/{sessionId}/lesson-record`.
  Future<LessonRecordDto> saveLessonRecord({
    required int sessionId,
    required String content,
    String? homework,
    int? recordId,
  }) async {
    final url = _serverUrl;
    if (url == null) throw const ApiException('Serveur non configuré');
    final dto = LessonRecordDto(
      id: recordId,
      courseSessionId: sessionId,
      content: content,
      homework: homework,
    );
    final resp = await _dio.post(
      buildUrl(
          url, '${ApiEndpoints.attendanceSession}/$sessionId/lesson-record'),
      data: dto.toJson(),
    );
    final data = resp.data is Map
        ? resp.data as Map<String, dynamic>
        : <String, dynamic>{};
    final saved = LessonRecordDto.fromJson(data);
    _ref.invalidate(lessonRecordProvider(sessionId));
    return saved;
  }
}

final attendanceControllerProvider =
    Provider<AttendanceController>((ref) => AttendanceController(ref));

// ===========================================================================
// Providers de lecture.
// ===========================================================================

/// Liste des élèves d'une classe : `GET /students?classroom_id=`.
final classStudentsProvider = FutureProvider.autoDispose
    .family<List<StudentDto>, int>((ref, classroomId) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return const [];
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.get(
      buildUrl(conn.serverUrl!, ApiEndpoints.students),
      queryParameters: {'classroom_id': classroomId},
    );
    return _parseStudentList(resp.data);
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403) return const [];
    rethrow;
  }
});

/// Liste de tous les élèves (pour le sélecteur d'historique d'absences) :
/// `GET /students`.
final allStudentsProvider =
    FutureProvider.autoDispose<List<StudentDto>>((ref) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return const [];
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.get(
      buildUrl(conn.serverUrl!, ApiEndpoints.students),
    );
    return _parseStudentList(resp.data);
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403) return const [];
    rethrow;
  }
});

List<StudentDto> _parseStudentList(dynamic data) {
  if (data is List) {
    return data
        .whereType<Map>()
        .map((e) => StudentDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  if (data is Map && data['items'] is List) {
    return (data['items'] as List)
        .whereType<Map>()
        .map((e) => StudentDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  return const [];
}

/// Absences enregistrées pour une session : `GET /attendance/session/{id}/absences`.
final sessionAbsencesProvider = FutureProvider.autoDispose
    .family<List<StudentAbsenceDto>, int>((ref, sessionId) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return const [];
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.get(
      buildUrl(conn.serverUrl!, ApiEndpoints.attendanceAbsences(sessionId)),
    );
    return _parseAbsenceList(resp.data);
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403 || api.statusCode == 404) return const [];
    rethrow;
  }
});

/// Cahier de texte d'une session :
/// `GET /attendance/session/{id}/lesson-record`. Renvoie `null` si absent.
final lessonRecordProvider = FutureProvider.autoDispose
    .family<LessonRecordDto?, int>((ref, sessionId) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return null;
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.get(
      buildUrl(
          conn.serverUrl!, '${ApiEndpoints.attendanceSession}/$sessionId/lesson-record'),
    );
    if (resp.data is Map) {
      return LessonRecordDto.fromJson(resp.data as Map<String, dynamic>);
    }
    return null;
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 404) return null;
    rethrow;
  }
});

/// Historique des absences d'un élève : `GET /attendance/absences?student_id=`.
final absenceHistoryProvider = FutureProvider.autoDispose
    .family<List<StudentAbsenceDto>, int>((ref, studentId) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return const [];
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.get(
      buildUrl(conn.serverUrl!, ApiEndpoints.attendanceAbsencesHistory),
      queryParameters: {'student_id': studentId},
    );
    return _parseAbsenceList(resp.data);
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403) return const [];
    rethrow;
  }
});

/// Vue enrichie d'une absence pour l'historique : inclut la date du cours et
/// le nom de la matière (dénormalisés côté serveur dans la réponse
/// `/attendance/absences`). [StudentAbsenceDto] ne expose pas ces champs, on
/// les parse donc défensivement ici.
class AbsenceHistoryEntry {
  const AbsenceHistoryEntry({
    this.id,
    required this.studentId,
    required this.studentName,
    required this.courseSessionId,
    this.date,
    this.courseName,
    this.isJustified = false,
    this.reason,
  });

  final int? id;
  final int studentId;
  final String studentName;
  final int courseSessionId;
  final DateTime? date;
  final String? courseName;
  final bool isJustified;
  final String? reason;

  factory AbsenceHistoryEntry.fromJson(Map<String, dynamic> j) =>
      AbsenceHistoryEntry(
        id: (j['id'] as num?)?.toInt(),
        studentId: (j['student_id'] as num?)?.toInt() ?? 0,
        studentName: j['student_name'] as String? ?? '',
        courseSessionId: (j['course_session_id'] as num?)?.toInt() ?? 0,
        date: DateFormatter.parse(j['date'] as String?),
        courseName:
            j['course_name'] as String? ?? j['subject_name'] as String?,
        isJustified: (j['is_justified'] as bool?) ?? false,
        reason: j['reason'] as String?,
      );
}

/// Historique enrichi : `GET /attendance/absences?student_id=` →
/// `List<AbsenceHistoryEntry>` (avec date + matière).
final absenceHistoryEntriesProvider = FutureProvider.autoDispose
    .family<List<AbsenceHistoryEntry>, int>((ref, studentId) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return const [];
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.get(
      buildUrl(conn.serverUrl!, ApiEndpoints.attendanceAbsencesHistory),
      queryParameters: {'student_id': studentId},
    );
    final raw = <Map<String, dynamic>>[];
    if (resp.data is List) {
      raw.addAll(
          (resp.data as List).whereType<Map>().map(Map<String, dynamic>.from));
    } else if (resp.data is Map && (resp.data as Map)['items'] is List) {
      raw.addAll(((resp.data as Map)['items'] as List)
          .whereType<Map>()
          .map(Map<String, dynamic>.from));
    }
    return raw.map(AbsenceHistoryEntry.fromJson).toList();
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403) return const [];
    rethrow;
  }
});

List<StudentAbsenceDto> _parseAbsenceList(dynamic data) {
  if (data is List) {
    return data
        .whereType<Map>()
        .map((e) => StudentAbsenceDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  if (data is Map && data['items'] is List) {
    return (data['items'] as List)
        .whereType<Map>()
        .map((e) => StudentAbsenceDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  return const [];
}
