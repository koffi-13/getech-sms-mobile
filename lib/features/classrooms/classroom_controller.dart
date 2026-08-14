/// Contrôleur du module Classes : liste et détail (offline-first).
///
/// - En ligne : `GET /classrooms` et `GET /classrooms/{id}` via [dioProvider] +
///   [buildUrl], avec cache Drift upserté en retour.
/// - Hors-ligne : lecture depuis la base Drift locale (`db.classrooms`).
///
/// Les effectifs (`studentCount`) et le taux d'occupation sont calculés
/// localement à partir de `student_class_assignments` (mode hors-ligne) ou
/// fournis par le serveur (mode en ligne).
library;

import 'package:drift/drift.dart' show InsertMode, Value;
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

import '../../core/database/database.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../../features/connections/connection_state.dart';
import '../../shared/models/classroom_dto.dart';

final Logger _log = Logger(
  printer: PrettyPrinter(methodNames: false, noBoxingByDefault: true),
  level: Level.off,
);

// ---------------------------------------------------------------------------
// Helpers : mapping Drift row → DTO
// ---------------------------------------------------------------------------

/// Mappe une ligne Drift `Classroom` en [ClassroomDto] en enrichissant avec
/// le niveau/filière et l'effectif (depuis `student_class_assignments`).
Future<ClassroomDto> _mapClassroomRow(
  AppDatabase db,
  Classroom row, {
  int? studentCount,
}) async {
  String? levelName;
  String? streamName;
  String? teacherName;

  if (row.levelId != null) {
    final lvl = await (db.select(db.levels)
          ..where((t) => t.id.equals(row.levelId!))
          ..where((t) => t.isDeleted.equals(false)))
        .getSingleOrNull();
    levelName = lvl?.name;
  }
  if (row.streamId != null) {
    final str = await (db.select(db.streams)
          ..where((t) => t.id.equals(row.streamId!))
          ..where((t) => t.isDeleted.equals(false)))
        .getSingleOrNull();
    streamName = str?.name;
  }
  if (row.teacherId != null) {
    final usr = await (db.select(db.users)
          ..where((t) => t.id.equals(row.teacherId!))
          ..where((t) => t.isDeleted.equals(false)))
        .getSingleOrNull();
    teacherName = usr != null
        ? [usr.firstName, usr.lastName]
            .where((s) => s != null && s.isNotEmpty)
            .join(' ')
        : null;
  }

  // Effectif local (depuis les assignations non supprimées).
  final count = studentCount ??
      await (db.selectOnly(db.studentClassAssignments)
            ..addColumns([db.studentClassAssignments.id.count()])
            ..where(db.studentClassAssignments.classroomId.equals(row.id))
            ..where(db.studentClassAssignments.isDeleted.equals(false)))
          .map((r) => r.read(db.studentClassAssignments.id.count()) ?? 0)
          .getSingle();

  return ClassroomDto(
    id: row.id,
    name: row.name,
    code: row.code,
    levelId: row.levelId,
    levelName: levelName,
    streamId: row.streamId,
    streamName: streamName,
    seriesId: row.seriesId,
    teacherId: row.teacherId,
    teacherName: teacherName,
    capacity: row.capacity,
    studentCount: count,
    schoolYearId: row.schoolYearId,
  );
}

/// Mappe une ligne Drift `ClassSubject` en [ClassSubjectDto] (avec jointures
/// optionnelles sur Subjects/Users).
Future<ClassSubjectDto> _mapClassSubjectRow(
  AppDatabase db,
  ClassSubject row,
) async {
  final subject = await (db.select(db.subjects)
        ..where((t) => t.id.equals(row.subjectId))
        ..where((t) => t.isDeleted.equals(false)))
      .getSingleOrNull();
  String? teacherName;
  if (row.teacherId != null) {
    final usr = await (db.select(db.users)
          ..where((t) => t.id.equals(row.teacherId!))
          ..where((t) => t.isDeleted.equals(false)))
        .getSingleOrNull();
    teacherName = usr != null
        ? [usr.firstName, usr.lastName]
            .where((s) => s != null && s.isNotEmpty)
            .join(' ')
        : null;
  }
  return ClassSubjectDto(
    id: row.id,
    classroomId: row.classroomId,
    subjectId: row.subjectId,
    subjectName: subject?.name ?? '—',
    coefficient: row.coefficient,
    teacherId: row.teacherId,
    teacherName: teacherName,
  );
}

// ---------------------------------------------------------------------------
// Providers de lecture
// ---------------------------------------------------------------------------

/// Liste des classes.
///
/// En ligne : `GET /classrooms` + cache Drift. Hors-ligne : lecture Drift.
final classroomsListProvider =
    FutureProvider.autoDispose<List<ClassroomDto>>((ref) async {
  final conn = ref.watch(connectionProvider);
  final db = ref.watch(databaseProvider);

  if (conn.canReachServer && conn.serverUrl != null) {
    try {
      final dio = ref.watch(dioProvider);
      final url = buildUrl(conn.serverUrl!, ApiEndpoints.classrooms);
      final resp = await dio.getJson<dynamic>(url);
      final data = resp.data;
      final List items;
      if (data is List) {
        items = data;
      } else if (data is Map && data['items'] is List) {
        items = data['items'] as List;
      } else {
        items = const [];
      }
      final dtos = items
          .whereType<Map>()
          .map((e) => ClassroomDto.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      await _cacheClassrooms(db, dtos);
      return dtos;
    } on ApiException catch (e) {
      _log.w('classroomsListProvider (online) : ${e.message} → repli local');
      return _loadClassroomsLocal(db);
    } catch (e) {
      _log.w('classroomsListProvider (online) : $e → repli local');
      return _loadClassroomsLocal(db);
    }
  }
  return _loadClassroomsLocal(db);
});

/// Détail d'une classe par ID.
final classroomDetailProvider =
    FutureProvider.autoDispose.family<ClassroomDto, int>((ref, id) async {
  final conn = ref.watch(connectionProvider);
  final db = ref.watch(databaseProvider);

  if (conn.canReachServer && conn.serverUrl != null) {
    try {
      final dio = ref.watch(dioProvider);
      final url = buildUrl(conn.serverUrl!, ApiEndpoints.classroom(id));
      final resp = await dio.getJson<Map<String, dynamic>>(url);
      final dto = ClassroomDto.fromJson(resp.data ?? const {});
      await _cacheClassrooms(db, [dto]);
      return dto;
    } on ApiException catch (e) {
      _log.w('classroomDetailProvider (online) : ${e.message} → repli local');
      return _loadClassroomDetailLocal(db, id);
    } catch (e) {
      _log.w('classroomDetailProvider (online) : $e → repli local');
      return _loadClassroomDetailLocal(db, id);
    }
  }
  return _loadClassroomDetailLocal(db, id);
});

/// Matières affectées à une classe : `GET /classrooms/{id}/subjects` si
/// disponible côté serveur, sinon lecture Drift depuis `class_subjects`.
final classSubjectsForClassroomProvider =
    FutureProvider.autoDispose.family<List<ClassSubjectDto>, int>(
        (ref, classroomId) async {
  final conn = ref.watch(connectionProvider);
  final db = ref.watch(databaseProvider);

  if (conn.canReachServer && conn.serverUrl != null) {
    try {
      final dio = ref.watch(dioProvider);
      // Endpoint secondaire dérivé de /classrooms/{id} — on tente subjects.
      final url =
          '${buildUrl(conn.serverUrl!, ApiEndpoints.classroom(classroomId))}/subjects';
      final resp = await dio.getJson<dynamic>(url);
      final data = resp.data;
      final List items;
      if (data is List) {
        items = data;
      } else if (data is Map && data['items'] is List) {
        items = data['items'] as List;
      } else {
        items = const [];
      }
      final dtos = items
          .whereType<Map>()
          .map((e) => ClassSubjectDto.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      await _cacheClassSubjects(db, dtos);
      return dtos;
    } on ApiException catch (e) {
      _log.w('classSubjectsForClassroomProvider (online) : ${e.message} → local');
      return _loadClassSubjectsLocal(db, classroomId);
    } catch (e) {
      _log.w('classSubjectsForClassroomProvider (online) : $e → local');
      return _loadClassSubjectsLocal(db, classroomId);
    }
  }
  return _loadClassSubjectsLocal(db, classroomId);
});

// ---------------------------------------------------------------------------
// Cache local (écriture Drift)
// ---------------------------------------------------------------------------

Future<void> _cacheClassrooms(AppDatabase db, List<ClassroomDto> dtos) async {
  if (dtos.isEmpty) return;
  try {
    await db.batch((b) {
      for (final dto in dtos) {
        b.insert(
          db.classrooms,
          ClassroomsCompanion.insert(
            id: Value(dto.id),
            name: dto.name,
            code: Value(dto.code),
            levelId: Value(dto.levelId),
            streamId: Value(dto.streamId),
            seriesId: Value(dto.seriesId),
            teacherId: Value(dto.teacherId),
            capacity: Value(dto.capacity),
            schoolYearId: Value(dto.schoolYearId),
            syncedAt: Value(DateTime.now().toUtc()),
            isDirty: const Value(false),
            isDeleted: const Value(false),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  } catch (e) {
    _log.w('_cacheClassrooms : échec partiel ($e)');
  }
}

Future<void> _cacheClassSubjects(
  AppDatabase db,
  List<ClassSubjectDto> dtos,
) async {
  if (dtos.isEmpty) return;
  try {
    await db.batch((b) {
      for (final dto in dtos) {
        b.insert(
          db.classSubjects,
          ClassSubjectsCompanion.insert(
            id: Value(dto.id),
            classroomId: dto.classroomId,
            subjectId: dto.subjectId,
            coefficient: Value(dto.coefficient),
            teacherId: Value(dto.teacherId),
            syncedAt: Value(DateTime.now().toUtc()),
            isDirty: const Value(false),
            isDeleted: const Value(false),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  } catch (e) {
    _log.w('_cacheClassSubjects : échec partiel ($e)');
  }
}

// ---------------------------------------------------------------------------
// Lecture locale (offline)
// ---------------------------------------------------------------------------

Future<List<ClassroomDto>> _loadClassroomsLocal(AppDatabase db) async {
  final rows = await (db.select(db.classrooms)
        ..where((t) => t.isDeleted.equals(false))
        ..orderBy([(t) => OrderingTerm.asc(t.name)]))
      .get();
  final result = <ClassroomDto>[];
  for (final row in rows) {
    result.add(await _mapClassroomRow(db, row));
  }
  return result;
}

Future<ClassroomDto> _loadClassroomDetailLocal(
  AppDatabase db,
  int id,
) async {
  final row = await (db.select(db.classrooms)
        ..where((t) => t.id.equals(id))
        ..where((t) => t.isDeleted.equals(false)))
      .getSingleOrNull();
  if (row == null) {
    throw Exception('Classe introuvable localement.');
  }
  return _mapClassroomRow(db, row);
}

Future<List<ClassSubjectDto>> _loadClassSubjectsLocal(
  AppDatabase db,
  int classroomId,
) async {
  final rows = await (db.select(db.classSubjects)
        ..where((t) => t.classroomId.equals(classroomId))
        ..where((t) => t.isDeleted.equals(false))
        ..orderBy([(t) => OrderingTerm.asc(t.id)]))
      .get();
  final result = <ClassSubjectDto>[];
  for (final row in rows) {
    result.add(await _mapClassSubjectRow(db, row));
  }
  return result;
}
