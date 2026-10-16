/// Contrôleur du module Classes : liste et détail (offline-first).
///
/// La liste suit le pattern en 3 temps :
/// 1. lecture du cache Drift immédiate (affichage instantané) ;
/// 2. `GET /classrooms` (toutes les pages) puis persistance **complète** —
///    y compris les champs dénormalisés (titulaire, niveau, cycle, série,
///    effectif) dans la table `classrooms` (schéma v2) ;
/// 3. re-lecture locale : le titulaire et l'effectif survivent désormais au
///    passage par le cache, y compris hors-ligne.
library;

import 'package:drift/drift.dart' as d;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart' as log_pkg;

import '../../core/auth/teacher_scope.dart';
import '../../core/database/database.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../../core/sync/sync_engine.dart' show syncGenerationProvider;
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
  // [Fix-CLASSES-REACTIVE] Surveille le compteur de génération de sync :
  // après une synchro qui rafraîchit le cache (et potentiellement écrase
  // `current_students_count` — voir fix sync_engine case 'classrooms'),
  // ce provider se recalcule et l'UI affiche l'effectif à jour (cf. Bug 2).
  // Miroir du pattern utilisé dans `grade_controller.dart:408`.
  ref.watch(syncGenerationProvider);
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
      // [Fix-CLASSES-500] `checking` (démarrage à froid) ne doit pas
      // bloquer : on tente l'API, la requête échouera d'elle-même si le
      // serveur est injoignable — le cache local reste affiché.
      final conn = _ref.read(connectionProvider);
      final definitivelyOffline =
          !conn.canReachServer && !conn.isChecking;
      if (definitivelyOffline) {
        if (localClassrooms.isEmpty) {
          state = AsyncValue.data(const []);
        }
        return;
      }

      // 2. Tenter de rafraîchir depuis l'API (toutes les pages, avec
      // échelle de dégradation en cas d'erreur serveur).
      final apiClassrooms = await _fetchFromApi();
      if (apiClassrooms.isNotEmpty) {
        await _saveToLocal(apiClassrooms);
      }

      // 3. Re-charger depuis le local (avec les champs dénormalisés persistés)
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
    final conn = _ref.read(connectionProvider);
    final serverUrl = conn.serverUrl;
    final definitivelyOffline =
        !conn.canReachServer && !conn.isChecking;
    if (!definitivelyOffline && serverUrl != null) {
      try {
        final dio = _ref.read(dioProvider);
        final response = await dio.get(
          buildUrl(serverUrl, ApiEndpoints.classroom(id)),
        );
        if (response.data is Map) {
          final remote = ClassroomDto.fromJson(
              Map<String, dynamic>.from(response.data as Map));
          // Fusion avec l'état local (effectif rattrapé par le comptage local).
          final local = (state.value ?? const <ClassroomDto>[])
              .where((c) => c.id == id)
              .firstOrNull;
          if (local != null &&
              (remote.currentStudentsCount ?? 0) <
                  (local.currentStudentsCount ?? 0)) {
            return remote.copyWith(
                currentStudentsCount: local.currentStudentsCount);
          }
          return remote;
        }
      } catch (e) {
        _log.w('Détail classe #$id : API indisponible, repli local ($e)');
      }
    }
    // [Fix-CLASSROOM-DETAIL-ERROR] Chaîne de repli SANS exception brute :
    // 1. état en mémoire (liste déjà chargée) ;
    // 2. cache Drift local ;
    // 3. périmètre enseignant (les classes « Mes classes » de l'Accueil
    //    peuvent être synthétisées depuis l'EDT et absentes du cache) ;
    // 4. sinon message clair (plus jamais « donnée inattendue »).
    final inMemory = (state.value ?? const <ClassroomDto>[])
        .where((c) => c.id == id)
        .firstOrNull;
    if (inMemory != null) return inMemory;

    final localList = await _fetchFromLocal();
    final local = localList.where((c) => c.id == id).firstOrNull;
    if (local != null) return local;

    try {
      final scope = await _ref.read(teacherScopeProvider.future)
          .timeout(const Duration(seconds: 3));
      final fromScope = scope.myClassrooms
          .where((c) => c.id == id)
          .firstOrNull;
      if (fromScope != null) return fromScope;
    } catch (_) {
      // Scope indisponible (hors-ligne complet) — on continue.
    }

    throw const ApiException(
      'Classe introuvable. Tirez pour rafraîchir la liste des classes '
      'puis réessayez.',
    );
  }

  /// `GET /classrooms` avec pagination complète (per_page=200, toutes pages)
  /// et échelle de dégradation [Fix-CLASSES-500] :
  ///   1. tentatives complètes (per_page=200, toutes pages) ;
  ///   2. en cas d'erreur serveur (5xx/4xx/réseau) : UNE page per_page=50 ;
  ///   3. sinon l'appelant replie sur le cache local.
  Future<List<ClassroomDto>> _fetchFromApi() async {
    try {
      return await _fetchFromApiPaged(200);
    } catch (e) {
      _log.w('API classes (mode complet) échouée, tentative dégradée : $e');
      try {
        return await _fetchFromApiPaged(50, maxPages: 1);
      } catch (e2) {
        _log.w('API classes (mode dégradé) échouée, repli local : $e2');
        rethrow;
      }
    }
  }

  Future<List<ClassroomDto>> _fetchFromApiPaged(int perPage,
      {int maxPages = 20}) async {
    final dio = _ref.read(dioProvider);
    final serverUrl = _ref.read(connectionProvider).serverUrl!;
    final result = <ClassroomDto>[];
    var page = 1;
    // Garde-fou : `maxPages` pages maximum.
    while (page <= maxPages) {
      final response = await dio.get(
        buildUrl(serverUrl, ApiEndpoints.classrooms),
        queryParameters: {'page': page, 'per_page': perPage},
      );
      final data = response.data;
      List<ClassroomDto> chunk;
      if (data is List) {
        chunk = data
            .whereType<Map>()
            .map((j) => ClassroomDto.fromJson(Map<String, dynamic>.from(j)))
            .toList();
      } else if (data is Map && data['items'] is List) {
        chunk = (data['items'] as List)
            .whereType<Map>()
            .map((j) => ClassroomDto.fromJson(Map<String, dynamic>.from(j)))
            .toList();
      } else {
        chunk = const [];
      }
      result.addAll(chunk);
      if (chunk.length < perPage) break; // dernière page atteinte
      page++;
    }
    return result;
  }

  /// Reconstruit les DTO depuis le cache Drift, en combinant l'effectif servi
  /// (current_students_count persisté) et le comptage local des assignations :
  /// le serveur reste la source de vérité, le comptage local rattrape le cas
  /// où le serveur renverrait 0 alors que des élèves sont synchronisés.
  Future<List<ClassroomDto>> _fetchFromLocal() async {
    final db = _ref.read(databaseProvider);

    final classrooms = await (db.select(db.classrooms)
          ..where((t) => t.isDeleted.equals(false)))
        .get();

    // Comptage local groupé en une seule requête (pas de N+1).
    // [Fix-COUNTS-EXITED] + [Fix-COUNTS-YEAR-FILTER] — voir
    // `localActiveStudentCounts` (helper mutualisé avec `teacher_scope`).
    final localCounts = await localActiveStudentCounts(db);

    final dtos = <ClassroomDto>[];
    for (final c in classrooms) {
      final localCount = localCounts[c.id] ?? 0;
      final serverCount = c.currentStudentsCount ?? 0;
      // Effectif effectif : valeur serveur si renseignée (> 0), sinon le
      // comptage local des assignations synchronisées.
      final effectiveCount = serverCount > 0 ? serverCount : localCount;
      dtos.add(ClassroomDto(
        id: c.id,
        name: c.name,
        establishmentId: c.establishmentId,
        maxStudents: c.capacity,
        isActive: c.isActive,
        headTeacherId: c.teacherId,
        headTeacherName: c.headTeacherName,
        levelName: c.levelName,
        cycleName: c.cycleName,
        cycleId: c.cycleId,
        seriesName: c.seriesName,
        currentStudentsCount: effectiveCount,
      ));
    }
    dtos.sort((a, b) => a.name.compareTo(b.name));
    return dtos;
  }

  /// Persiste l'intégralité des champs de `ClassroomResponse` (schéma v2).
  Future<void> _saveToLocal(List<ClassroomDto> list) async {
    final db = _ref.read(databaseProvider);
    await db.batch((batch) {
      for (final dto in list) {
        batch.insert(
          db.classrooms,
          ClassroomsCompanion.insert(
            id: d.Value(dto.id),
            name: dto.name,
            code: const d.Value(null),
            capacity: d.Value(dto.maxStudents ?? 0),
            teacherId: d.Value(dto.headTeacherId),
            establishmentId: d.Value(dto.establishmentId),
            headTeacherName: d.Value(dto.headTeacherName),
            levelName: d.Value(dto.levelName),
            cycleName: d.Value(dto.cycleName),
            cycleId: d.Value(dto.cycleId),
            seriesName: d.Value(dto.seriesName),
            currentStudentsCount: d.Value(dto.currentStudentsCount),
            isActive: d.Value(dto.isActive),
            isDirty: const d.Value(false),
          ),
          mode: d.InsertMode.insertOrReplace,
        );
      }
    });
  }
}

/// [Fix-COUNTS-LOCAL-HELPER] Comptage local des assignations actives par
/// classe, partagé entre le contrôleur Classes et le périmètre enseignant
/// (`teacher_scope._localTeacherScope`).
///
/// Filtres appliqués (miroir du helper serveur
/// `_current_students_counts` dans `api/routers/classrooms.py`) :
/// - `isDeleted = false` (lignes marquées supprimées) ;
/// - année scolaire active (ou NULL — données héritées pré-V11) ;
/// - `inscriptionType` ni EXCLU ni ABANDON (ou NULL — élève sans type).
///
/// Si `classroomIds` est fourni, le comptage est restreint à cet ensemble
/// (sinon : toutes les classes — pour le périmètre enseignant).
///
/// Retourne une map `{classroom_id: count}` (0 si aucune assignation).
Future<Map<int, int>> localActiveStudentCounts(
  AppDatabase db, {
  List<int>? classroomIds,
}) async {
  // Année active : on ne compte QUE les assignations de l'année active (ou
  // sans année — données héritées pré-V11). Sans ce filtre, les assignations
  // des années antérieures (restées actives côté serveur) gonflent l'effectif
  // affiché. Repli sans filtre année si aucune année active.
  final activeYears = await (db.select(db.schoolYears)
        ..where((t) => t.isActive.equals(true))
        ..orderBy([(t) => d.OrderingTerm.desc(t.id)])
        ..limit(1))
      .get();
  final activeYearId = activeYears.isEmpty ? null : activeYears.first.id;

  final countExpr = db.studentClassAssignments.id.count();
  var query = db.selectOnly(db.studentClassAssignments)
    ..addColumns([db.studentClassAssignments.classroomId, countExpr])
    ..where(db.studentClassAssignments.isDeleted.equals(false));
  if (classroomIds != null && classroomIds.isNotEmpty) {
    query = query
      ..where(db.studentClassAssignments.classroomId.isIn(classroomIds));
  }
  if (activeYearId != null) {
    query = query
      ..where(db.studentClassAssignments.schoolYearId.equals(activeYearId) |
          db.studentClassAssignments.schoolYearId.isNull());
  }
  query = query
    ..where(db.studentClassAssignments.inscriptionType
            .isNotIn(['EXCLU', 'ABANDON']) |
        db.studentClassAssignments.inscriptionType.isNull())
    ..groupBy([db.studentClassAssignments.classroomId]);
  final rows = await query.get();
  final out = <int, int>{};
  for (final row in rows) {
    final cid = row.read(db.studentClassAssignments.classroomId);
    if (cid == null) continue;
    out[cid] = row.read(countExpr) ?? 0;
  }
  return out;
}
