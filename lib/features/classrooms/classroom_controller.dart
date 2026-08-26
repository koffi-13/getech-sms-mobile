/// Contrôleur du module Classes : liste et détail (offline-first).
library;

import 'package:drift/drift.dart' as d;
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart' as log_pkg;

import '../../core/database/database.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../../features/connections/connection_state.dart';
import '../../shared/models/classroom_dto.dart';

final log_pkg.Logger _log = log_pkg.Logger(
  printer: log_pkg.PrettyPrinter(noBoxingByDefault: true),
  level: log_pkg.Level.off,
);

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

final classroomsProvider = StateNotifierProvider.autoDispose<ClassroomController, AsyncValue<List<ClassroomDto>>>((ref) {
  return ClassroomController(ref);
});

final classroomDetailProvider = FutureProvider.autoDispose.family<ClassroomDto, int>((ref, id) async {
  final controller = ref.read(classroomsProvider.notifier);
  return controller.getById(id);
});

// ---------------------------------------------------------------------------
// ClassroomController
// ---------------------------------------------------------------------------

class ClassroomController extends StateNotifier<AsyncValue<List<ClassroomDto>>> {
  final Ref _ref;

  ClassroomController(this._ref) : super(const AsyncValue.loading()) {
    refresh();
  }

  Future<void> refresh() async {
    // 1. Charger immédiatement les données locales
    final localClassrooms = await _fetchFromLocal();
    if (localClassrooms.isNotEmpty) {
      state = AsyncValue.data(localClassrooms);
    }

    try {
      final canReach = _ref.read(connectionProvider).canReachServer;
      if (!canReach) {
        if (localClassrooms.isEmpty) {
          state = AsyncValue.data(const []);
        }
        return;
      }

      // 2. Tenter de rafraîchir depuis l'API
      final apiClassrooms = await _fetchFromApi();
      await _saveToLocal(apiClassrooms);
      
      // 3. Re-charger depuis le local
      final updatedLocal = await _fetchFromLocal();
      state = AsyncValue.data(updatedLocal);
    } catch (e, st) {
      if (state.hasValue && state.value!.isNotEmpty) {
        _log.w('Erreur rafraîchissement API classes (utilisation cache) : $e');
      } else {
        state = AsyncValue.error(e, st);
      }
    }
  }

  Future<ClassroomDto> getById(int id) async {
    final canReach = _ref.read(connectionProvider).canReachServer;
    if (canReach) {
      final dio = _ref.read(dioProvider);
      final response = await dio.get('${ApiEndpoints.classrooms}/$id');
      return ClassroomDto.fromJson(response.data);
    } else {
      final classrooms = state.value ?? await _fetchFromLocal();
      return classrooms.firstWhere((c) => c.id == id);
    }
  }

  Future<List<ClassroomDto>> _fetchFromApi() async {
    final dio = _ref.read(dioProvider);
    final response = await dio.get(ApiEndpoints.classrooms);
    final data = response.data;
    if (data is List) {
      return data.map((j) => ClassroomDto.fromJson(j)).toList();
    } else if (data is Map && data['items'] is List) {
      return (data['items'] as List)
          .map((j) => ClassroomDto.fromJson(j))
          .toList();
    }
    return const [];
  }

  Future<List<ClassroomDto>> _fetchFromLocal() async {
    final db = _ref.read(databaseProvider);

    final classrooms = await db.select(db.classrooms).get();

    final List<ClassroomDto> dtos = [];
    for (final c in classrooms) {
      final countExpr = db.studentClassAssignments.id.count();
      final studentCountLocal = await (db.selectOnly(db.studentClassAssignments)
        ..addColumns([countExpr])
        ..where(db.studentClassAssignments.classroomId.equals(c.id)))
        .map((r) => r.read(countExpr))
        .getSingle();

      dtos.add(ClassroomDto(
        id: c.id,
        name: c.name,
        establishmentId: 0,
        maxStudents: c.capacity,
        isActive: true,
        currentStudentsCount: studentCountLocal ?? 0,
      ));
    }
    return dtos;
  }

  Future<void> _saveToLocal(List<ClassroomDto> list) async {
    final db = _ref.read(databaseProvider);
    await db.batch((batch) {
      for (final dto in list) {
        batch.insert(
          db.classrooms,
          ClassroomsCompanion.insert(
            id: d.Value(dto.id),
            name: dto.name,
            capacity: d.Value(dto.maxStudents ?? 0),
          ),
          mode: d.InsertMode.insertOrReplace,
        );
      }
    });
  }
}
