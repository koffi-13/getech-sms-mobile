/// Contrôleur du module Élèves : liste filtrée, détail, et repository
/// (création/édition/suppression) offline-first.
library;

import 'package:drift/drift.dart' as d;
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart' as log_pkg;

import '../../core/config/constants.dart' as cfg;
import '../../core/database/database.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../../core/sync/outbox.dart';
import '../../features/connections/connection_state.dart';
import '../../shared/models/student_dto.dart';

final log_pkg.Logger _log = log_pkg.Logger(
  printer: log_pkg.PrettyPrinter(noBoxingByDefault: true),
  level: log_pkg.Level.off,
);

// ---------------------------------------------------------------------------
// StudentFilter
// ---------------------------------------------------------------------------

class StudentFilter {
  final int? classroomId;
  final String search;
  final cfg.Sexe? sexe;
  final cfg.StudentStatus? status;

  const StudentFilter({
    this.classroomId,
    this.search = '',
    this.sexe,
    this.status,
  });

  static const empty = StudentFilter();

  StudentFilter copyWith({
    int? classroomId,
    String? search,
    cfg.Sexe? sexe,
    cfg.StudentStatus? status,
    bool clearClassroom = false,
  }) =>
      StudentFilter(
        classroomId: clearClassroom ? null : (classroomId ?? this.classroomId),
        search: search ?? this.search,
        sexe: sexe ?? this.sexe,
        status: status ?? this.status,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StudentFilter &&
          other.classroomId == classroomId &&
          other.search == search &&
          other.sexe == sexe &&
          other.status == status;

  @override
  int get hashCode =>
      classroomId.hashCode ^ search.hashCode ^ sexe.hashCode ^ status.hashCode;
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

final studentControllerProvider =
    StateNotifierProvider.autoDispose<StudentController, AsyncValue<List<StudentDto>>>((ref) {
  return StudentController(ref);
});

final studentFilterProvider = StateProvider<StudentFilter>((ref) => StudentFilter.empty);

final studentsListProvider = Provider.autoDispose.family<AsyncValue<List<StudentDto>>, StudentFilter>((ref, filter) {
  final asyncList = ref.watch(studentControllerProvider);
  return asyncList.whenData((list) {
    return list.where((s) {
      if (filter.classroomId != null && s.classroomId != filter.classroomId) return false;
      if (filter.sexe != null && s.sexe != filter.sexe) return false;
      if (filter.status != null && s.status != filter.status) return false;
      if (filter.search.isNotEmpty) {
        final search = filter.search.toLowerCase();
        return (s.nom?.toLowerCase().contains(search) ?? false) ||
               (s.prenoms?.toLowerCase().contains(search) ?? false) ||
               s.matricule.toLowerCase().contains(search);
      }
      return true;
    }).toList();
  });
});

final studentDetailProvider = FutureProvider.autoDispose.family<StudentDto, int>((ref, id) async {
  final repo = ref.read(studentRepositoryProvider);
  return repo.getById(id);
});

// ---------------------------------------------------------------------------
// StudentController
// ---------------------------------------------------------------------------

class StudentController extends StateNotifier<AsyncValue<List<StudentDto>>> {
  final Ref _ref;

  StudentController(this._ref) : super(const AsyncValue.loading()) {
    refresh();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    try {
      final canReach = _ref.read(connectionProvider).canReachServer;

      List<StudentDto> students;
      if (canReach) {
        students = await _fetchFromApi();
        await _saveToLocal(students);
      } else {
        students = await _fetchFromLocal();
      }

      state = AsyncValue.data(students);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<List<StudentDto>> _fetchFromApi() async {
    final dio = _ref.read(dioProvider);
    final response = await dio.get(ApiEndpoints.students);
    final list = response.data as List;
    return list.map((j) => StudentDto.fromJson(j)).toList();
  }

  Future<List<StudentDto>> _fetchFromLocal() async {
    final db = _ref.read(databaseProvider);
    final query = db.select(db.students).join([
      d.leftOuterJoin(db.studentClassAssignments,
          db.studentClassAssignments.studentId.equalsExp(db.students.id)),
      d.leftOuterJoin(db.classrooms,
          db.classrooms.id.equalsExp(db.studentClassAssignments.classroomId)),
    ]);

    final rows = await query.get();
    return rows.map<StudentDto>((row) {
      final s = row.readTable(db.students);
      final c = row.readTableOrNull(db.classrooms);
      final assign = row.readTableOrNull(db.studentClassAssignments);

      return StudentDto(
        id: s.id,
        nom: s.nom,
        prenoms: s.prenoms,
        matricule: s.matricule,
        dob: s.dob,
        sexe: cfg.Sexe.fromCode(s.sexe),
        birthPlace: s.birthPlace,
        classroomName: c?.name ?? 'Non classé',
        classroomId: c?.id,
        photoPath: s.photoPath,
        status: cfg.StudentStatus.fromCode(assign?.status),
        inscriptionType: cfg.InscriptionType.fromCode(assign?.inscriptionType),
      );
    }).toList();
  }

  Future<void> _saveToLocal(List<StudentDto> students) async {
    final db = _ref.read(databaseProvider);
    await db.batch((batch) {
      for (final s in students) {
        batch.insert(
          db.students,
          StudentsCompanion.insert(
            id: d.Value(s.id),
            nom: s.nom ?? '',
            prenoms: d.Value(s.prenoms),
            matricule: s.matricule,
            dob: d.Value(s.dob),
            sexe: d.Value(s.sexe?.code),
            birthPlace: d.Value(s.birthPlace),
            photoPath: d.Value(s.photoPath),
            isDirty: const d.Value(false),
          ),
          mode: d.InsertMode.insertOrReplace,
        );
      }
    });
  }
}

// ---------------------------------------------------------------------------
// StudentRepository
// ---------------------------------------------------------------------------

final studentRepositoryProvider = Provider<StudentRepository>((ref) {
  return StudentRepository(ref);
});

class StudentRepository {
  final Ref _ref;
  StudentRepository(this._ref);

  Future<StudentDto> getById(int id) async {
    final canReach = _ref.read(connectionProvider).canReachServer;
    if (canReach) {
      final dio = _ref.read(dioProvider);
      final response = await dio.get('${ApiEndpoints.students}/$id');
      return StudentDto.fromJson(response.data);
    } else {
      final db = _ref.read(databaseProvider);
      final query = db.select(db.students)..where((t) => t.id.equals(id));
      final s = await query.getSingle();
      return StudentDto(
        id: s.id,
        nom: s.nom,
        prenoms: s.prenoms,
        matricule: s.matricule,
        dob: s.dob,
        sexe: cfg.Sexe.fromCode(s.sexe),
        birthPlace: s.birthPlace,
        photoPath: s.photoPath,
      );
    }
  }

  Future<StudentDto> save(StudentDto student) async {
    if (student.id == 0) {
      return create(StudentCreateRequest(
        nom: student.nom ?? '',
        prenoms: student.prenoms ?? '',
        matricule: student.matricule,
        dob: student.dob,
        sexe: student.sexe,
        birthPlace: student.birthPlace,
        classroomId: student.classroomId ?? 0,
      ));
    } else {
      await update(student.id, StudentUpdateRequest(
        nom: student.nom ?? '',
        prenoms: student.prenoms ?? '',
        matricule: student.matricule,
        dob: student.dob,
        sexe: student.sexe,
        birthPlace: student.birthPlace,
      ));
      return student;
    }
  }

  Future<StudentDto> create(StudentCreateRequest req) async {
    final db = _ref.read(databaseProvider);
    final canReach = _ref.read(connectionProvider).canReachServer;

    final companion = StudentsCompanion.insert(
      nom: req.nom,
      prenoms: d.Value(req.prenoms),
      matricule: req.matricule,
      dob: d.Value(req.dob),
      sexe: d.Value(req.sexe?.code),
      birthPlace: d.Value(req.birthPlace),
      isDirty: d.Value(!canReach),
    );
    final id = await db.into(db.students).insert(companion);

    final dto = StudentDto(
      id: id,
      nom: req.nom,
      prenoms: req.prenoms,
      matricule: req.matricule,
      dob: req.dob,
      sexe: req.sexe,
      birthPlace: req.birthPlace,
      classroomId: req.classroomId,
    );

    if (canReach) {
      try {
        final dio = _ref.read(dioProvider);
        final response = await dio.post(ApiEndpoints.students, data: req.toJson());
        return StudentDto.fromJson(response.data);
      } catch (_) {
        await _queueForSync('POST', id, req.toJson());
      }
    } else {
      await _queueForSync('POST', id, req.toJson());
    }

    return dto;
  }

  Future<void> update(int id, StudentUpdateRequest req) async {
    final db = _ref.read(databaseProvider);
    final canReach = _ref.read(connectionProvider).canReachServer;

    await (db.update(db.students)..where((t) => t.id.equals(id))).write(
      StudentsCompanion(
        nom: d.Value(req.nom),
        prenoms: d.Value(req.prenoms),
        matricule: d.Value(req.matricule),
        dob: d.Value(req.dob),
        sexe: d.Value(req.sexe?.code),
        birthPlace: d.Value(req.birthPlace),
        isDirty: d.Value(!canReach),
      ),
    );

    if (canReach) {
      try {
        final dio = _ref.read(dioProvider);
        await dio.patch('${ApiEndpoints.students}/$id', data: req.toJson());
      } catch (_) {
        await _queueForSync('PATCH', id, req.toJson());
      }
    } else {
      await _queueForSync('PATCH', id, req.toJson());
    }
  }

  Future<void> delete(int id) async {
    final db = _ref.read(databaseProvider);
    final canReach = _ref.read(connectionProvider).canReachServer;

    await (db.delete(db.students)..where((t) => t.id.equals(id))).go();

    if (canReach) {
      try {
        final dio = _ref.read(dioProvider);
        await dio.delete('${ApiEndpoints.students}/$id');
      } catch (_) {
        await _queueForSync('DELETE', id, null);
      }
    } else {
      await _queueForSync('DELETE', id, null);
    }
  }

  Future<void> _queueForSync(String method, int entityId, Map<String, dynamic>? data) async {
    await _ref.read(outboxProvider).enqueue(
      table: 'students',
      operation: method,
      recordId: entityId,
      payload: data ?? {},
    );
  }
}

class StudentCreateRequest {
  final String nom;
  final String prenoms;
  final String matricule;
  final DateTime? dob;
  final cfg.Sexe? sexe;
  final String? birthPlace;
  final int classroomId;

  StudentCreateRequest({
    required this.nom,
    required this.prenoms,
    required this.matricule,
    this.dob,
    this.sexe,
    this.birthPlace,
    required this.classroomId,
  });

  Map<String, dynamic> toJson() => {
        'nom': nom,
        'prenoms': prenoms,
        'matricule': matricule,
        'dob': dob?.toIso8601String(),
        'sexe': sexe?.code,
        'birth_place': birthPlace,
        'classroom_id': classroomId,
      };
}

class StudentUpdateRequest {
  final String nom;
  final String prenoms;
  final String matricule;
  final DateTime? dob;
  final cfg.Sexe? sexe;
  final String? birthPlace;

  StudentUpdateRequest({
    required this.nom,
    required this.prenoms,
    required this.matricule,
    this.dob,
    this.sexe,
    this.birthPlace,
  });

  Map<String, dynamic> toJson() => {
        'nom': nom,
        'prenoms': prenoms,
        'matricule': matricule,
        'dob': dob?.toIso8601String(),
        'sexe': sexe?.code,
        'birth_place': birthPlace,
      };
}

class StudentRepositoryException implements Exception {
  final String message;
  StudentRepositoryException(this.message);
  @override
  String toString() => message;
}
