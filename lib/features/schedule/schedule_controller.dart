/// Contrôleur du module Emploi du temps : liste des classes et emploi du
/// temps hebdomadaire (semaine A ou B) d'une classe.
///
/// Source de données V1 : API REST (online). Aucun cache Drift pour limiter
/// la surface de codegen — l'UI affiche un message hors-ligne lorsque le
/// serveur n'est pas joignable ([ConnectionState.canReachServer] = false).
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/constants.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../../features/connections/connection_state.dart';
import '../../shared/models/attendance_dto.dart';
import '../../shared/models/classroom_dto.dart';

/// Paramètres de [weeklyScheduleProvider] : classe + type de semaine.
class ScheduleQuery {
  const ScheduleQuery({required this.classroomId, required this.weekType});
  final int classroomId;
  final WeekType weekType;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScheduleQuery &&
          other.classroomId == classroomId &&
          other.weekType == weekType;

  @override
  int get hashCode => Object.hash(classroomId, weekType);
}

/// Liste des classes pour le sélecteur (réutilise `GET /classrooms`).
///
/// Renvoie une liste vide silencieuse en cas de 403 (permissions insuffisantes).
final classroomsForScheduleProvider =
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

/// Emploi du temps hebdomadaire d'une classe pour une semaine (A ou B) :
/// `GET /schedule?classroom_id=&week_type=` → `List<WeeklyScheduleDto>`.
final weeklyScheduleProvider = FutureProvider.autoDispose
    .family<List<WeeklyScheduleDto>, ScheduleQuery>((ref, query) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) return const [];
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.get(
      buildUrl(conn.serverUrl!, ApiEndpoints.schedule),
      queryParameters: {
        'classroom_id': query.classroomId,
        'week_type': query.weekType == WeekType.b ? 'B' : 'A',
      },
    );
    return _parseWeeklyScheduleList(resp.data);
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403 || api.statusCode == 404) return const [];
    rethrow;
  }
});

List<WeeklyScheduleDto> _parseWeeklyScheduleList(dynamic data) {
  if (data is List) {
    return data
        .whereType<Map>()
        .map((e) => WeeklyScheduleDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  if (data is Map) {
    final items = data['items'] ?? data['schedule'] ?? data['weekly_schedules'];
    if (items is List) {
      return items
          .whereType<Map>()
          .map((e) => WeeklyScheduleDto.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
  }
  return const [];
}
