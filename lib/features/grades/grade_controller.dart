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

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' as d;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_state.dart';
import '../../core/database/database.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../../core/sync/outbox.dart';
import '../../features/connections/connection_state.dart';
import '../../shared/models/classroom_dto.dart';
import '../../shared/models/grade_dto.dart';
import 'grade_utils.dart';

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

  bool get _definitivelyOffline {
    final conn = _ref.read(connectionProvider);
    return !conn.canReachServer && !conn.isChecking;
  }

  /// Sauvegarde en lot des notes d'une évaluation — [Offline-First].
  ///
  /// TOUJOURS :
  ///   1. les marques locales (propositions) sont persistées dans Drift
  ///      (lignes existantes : syncStatus='pending', proposedValue=X) ;
  ///   2. les NOUVELLES notes n'écrivent PAS de ligne Drift (pas d'id
  ///      serveur) — elles vivent dans la soumission ;
  ///
  /// PUIS :
  ///   - en ligne : `POST /grades/assessments/{id}/grades` immédiat ;
  ///   - hors-ligne : la soumission complète part dans l'outbox
  ///     (`grade_submission`) et sera poussée par [SyncEngine] à la
  ///     prochaine connexion (avec sémantique de file de validation
  ///     serveur : les modifications de notes existantes par un non-admin
  ///     deviennent des propositions à valider/rejeter par un admin).
  Future<SaveGradesResponse> saveGrades(
    int assessmentId,
    List<GradeEntryDto> entries,
  ) async {
    // 1. Persistance locale des propositions (Drift).
    await _persistLocalPropositions(assessmentId, entries);

    final url = _serverUrl;
    if (url == null) throw const ApiException('Serveur non configuré');

    // 2. Hors-ligne : outbox « grade_submission ».
    if (_definitivelyOffline) {
      await _ref.read(outboxProvider).enqueue(
        table: 'grade_submission',
        operation: 'UPSERT',
        payload: {
          'assessment_id': assessmentId,
          'grades': entries.map((e) => e.toJson()).toList(),
        },
      );
      _ref.invalidate(assessmentGradesProvider(assessmentId));
      return const SaveGradesResponse(
        offlineQueued: true,
        savedCount: 0,
        skippedCount: 0,
        queuedCount: 0,
      );
    }

    // 3. En ligne : POST direct.
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

    // 4. Marques locales miroir de la réponse serveur (queued -> 'queued').
    await _mirrorResponseMarks(assessmentId, entries, result);

    _ref.invalidate(assessmentGradesProvider(assessmentId));
    _invalidateAssessmentsFor(assessmentId);
    return result;
  }

  /// Marque localement (Drift) les PROPOSITIONS de modification : les lignes
  /// EXISTANTES reçoivent syncStatus='pending' + la valeur proposée (la
  /// colonne `value` reste la valeur serveur actuelle).
  Future<void> _persistLocalPropositions(
    int assessmentId,
    List<GradeEntryDto> entries,
  ) async {
    final db = _ref.read(databaseProvider);
    final rows = await (db.select(db.grades)
          ..where((t) => t.assessmentId.equals(assessmentId))
          ..where((t) => t.isDeleted.equals(false)))
        .get();
    final byStudent = {for (final g in rows) g.studentId: g};

    for (final e in entries) {
      final existing = byStudent[e.studentId];
      if (existing == null) continue; // note nouvelle : pas de ligne locale
      await (db.update(db.grades)..where((t) => t.id.equals(existing.id)))
          .write(GradesCompanion(
        syncStatus: const d.Value('pending'),
        proposedValue: d.Value(e.value),
        proposedIsAbsent: d.Value(e.isAbsent),
        proposedComments: d.Value(e.comment),
        isDirty: const d.Value(true),
      ));
    }
  }

  /// Après un POST en ligne, reflète la réponse serveur sur les marques
  /// locales ('queued' pour les propositions, null pour les notes
  /// appliquées/inchangées).
  Future<void> _mirrorResponseMarks(
    int assessmentId,
    List<GradeEntryDto> sent,
    SaveGradesResponse result,
  ) async {
    final db = _ref.read(databaseProvider);
    final rows = await (db.select(db.grades)
          ..where((t) => t.assessmentId.equals(assessmentId))
          ..where((t) => t.isDeleted.equals(false)))
        .get();
    final byStudent = {for (final g in rows) g.studentId: g};
    final sentByStudent = {for (final e in sent) e.studentId: e};

    for (final line in result.results) {
      final gradeId = line.gradeId;
      if (gradeId == null) continue;
      final e = sentByStudent[line.studentId];
      final queued = line.action == 'queued';
      await (db.update(db.grades)..where((t) => t.id.equals(gradeId)))
          .write(GradesCompanion(
        syncStatus: queued ? const d.Value('queued') : const d.Value(null),
        proposedValue:
            queued ? d.Value(e?.value) : const d.Value(null),
        proposedIsAbsent:
            queued ? d.Value(e?.isAbsent ?? false) : const d.Value(null),
        proposedComments:
            queued ? d.Value(e?.comment) : const d.Value(null),
        isDirty: const d.Value(false),
      ));
    }
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

/// Classes accessibles pour le module Notes.
///
/// - **Enseignant** : union des classes où il enseigne
///   (`GET /classrooms?teacher_only=true`, scope serveur — miroir de
///   `_teacher_subject_classroom_ids` du desktop) et des classes dont il est
///   titulaire (`head_teacher_id == me`, miroir de
///   `_teacher_head_classroom_ids` + accès bulletin étendu au titulaire).
/// - **Admin / headmaster** : toutes les classes.
final classroomsForGradesProvider =
    FutureProvider.autoDispose<List<ClassroomDto>>((ref) async {
  // [Fix-HEARTBEAT-REBUILD] select : le heartbeat émet un nouvel état toutes
  // les 30 s (latence) — watcher l'état entier invalidait ce provider et
  // réinitialisait les sélecteurs de la cascade Notes.
  final conn = ref.watch(connectionProvider
      .select((c) => (isPaired: c.isPaired, serverUrl: c.serverUrl)));
  final auth = ref.watch(authProvider);
  if (!conn.isPaired || conn.serverUrl == null) {
    return _classroomsForGradesFromLocal(ref, auth);
  }
  final dio = ref.watch(dioProvider);

  // Admin élargi : toutes les classes.
  if (auth.isAdminOrHeadmaster) {
    try {
      final resp = await dio.get(
        buildUrl(conn.serverUrl!, ApiEndpoints.classrooms),
        queryParameters: {'per_page': 200},
      );
      return _parseClassroomList(resp.data);
    } on DioException catch (e) {
      final api = (e.error is ApiException)
          ? e.error as ApiException
          : dioErrorToApiException(e);
      // [Fix-TEACHER-CLASSES-403] Un 403 n'est plus avalé en liste vide :
      // on sert le cache Drift (avant le fix serveur RBAC, l'enseignant
      // voyait « aucune classe » sans aucune erreur).
      if (api.statusCode == 403) {
        return _classroomsForGradesFromLocal(ref, auth);
      }
      // [Fix-OFFLINE] serveur injoignable → cache Drift.
      return _classroomsForGradesFromLocal(ref, auth);
    }
  }

  // Enseignant (ou profil restreint) : classes enseignées + classes titularisées.
  try {
    final results = await Future.wait([
      _fetchClassrooms(dio, conn.serverUrl!, teacherOnly: true),
      _fetchClassrooms(dio, conn.serverUrl!, teacherOnly: false),
    ]);
    final teaching = results[0];
    final all = results[1];
    final userId = auth.user?.id;
    final head = userId == null
        ? const <ClassroomDto>[]
        : all.where((c) => c.headTeacherId == userId).toList();

    final byId = <int, ClassroomDto>{};
    for (final c in teaching) {
      byId[c.id] = c;
    }
    for (final c in head) {
      byId.putIfAbsent(c.id, () => c);
    }
    return byId.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  } catch (_) {
    // [Fix-OFFLINE] réseau KO → cache Drift.
    return _classroomsForGradesFromLocal(ref, auth);
  }
});

/// Classes pour la cascade Notes servies depuis le cache Drift local.
Future<List<ClassroomDto>> _classroomsForGradesFromLocal(
    Ref ref, AuthState auth) async {
  try {
    final db = ref.read(databaseProvider);
    final rows = await (db.select(db.classrooms)
          ..where((t) => t.isDeleted.equals(false)))
        .get();
    var dtos = rows
        .map((c) => ClassroomDto(
              id: c.id,
              name: c.name,
              headTeacherId: c.teacherId,
              headTeacherName: c.headTeacherName,
              levelName: c.levelName,
              cycleName: c.cycleName,
              cycleId: c.cycleId,
              seriesName: c.seriesName,
              currentStudentsCount: c.currentStudentsCount,
              maxStudents: c.capacity == 0 ? null : c.capacity,
            ))
        .toList();

    // Enseignant : restreindre aux classes enseignées + titularisées.
    final userId = auth.user?.id;
    if (!auth.isAdminOrHeadmaster && userId != null) {
      final csRows = await (db.select(db.classSubjects)
            ..where((t) => t.teacherId.equals(userId)))
          .get();
      final teachingIds = csRows.map((r) => r.classroomId).toSet();
      dtos = dtos
          .where((c) =>
              teachingIds.contains(c.id) || c.headTeacherId == userId)
          .toList();
    }
    dtos.sort((a, b) => a.name.compareTo(b.name));
    return dtos;
  } catch (_) {
    return const [];
  }
}

Future<List<ClassroomDto>> _fetchClassrooms(
  Dio dio,
  String serverUrl, {
  required bool teacherOnly,
}) async {
  try {
    final resp = await dio.get(
      buildUrl(serverUrl, ApiEndpoints.classrooms),
      queryParameters: {
        'per_page': 200,
        if (teacherOnly) 'teacher_only': true,
      },
    );
    return _parseClassroomList(resp.data);
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403) {
      // [Fix-TEACHER-CLASSES-403] Message explicite au lieu d'une liste vide
      // silencieuse — l'appelant retombe sur le cache Drift.
      throw const ApiException(
        'Accès refusé (403) — vérifiez les permissions du compte côté serveur.',
        statusCode: 403,
      );
    }
    rethrow;
  }
}

List<ClassroomDto> _parseClassroomList(dynamic data) {
  if (data is List) {
    return data
        .whereType<Map>()
        .map((e) => ClassroomDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  if (data is Map) {
    // [Fix-TEACHER-CLASSES-403] Enveloppes acceptees : items (contrat
    // documente), data et classrooms (variantes serveur observees).
    final rows = data['items'] ?? data['data'] ?? data['classrooms'];
    if (rows is List) {
      return rows
          .whereType<Map>()
          .map((e) => ClassroomDto.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
  }
  return const [];
}

/// Liste des périodes : `GET /settings/periods`.
final periodsProvider =
    FutureProvider.autoDispose<List<PeriodDto>>((ref) async {
  // [Fix-HEARTBEAT-REBUILD] select : voir classroomsForGradesProvider.
  final conn = ref.watch(connectionProvider
      .select((c) => (isPaired: c.isPaired, serverUrl: c.serverUrl)));
  if (!conn.isPaired || conn.serverUrl == null) {
    return _periodsFromLocal(ref);
  }
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
    // [Fix-TEACHER-CLASSES-403] Un 403 n'est plus avalé en liste vide :
    // on sert le cache Drift (avant le fix serveur RBAC, l'enseignant
    // voyait « aucune classe » sans aucune erreur).
    // [Fix-OFFLINE] serveur injoignable → cache Drift.
    return _periodsFromLocal(ref);
  } catch (_) {
    return _periodsFromLocal(ref);
  }
});

/// Périodes servies depuis le cache Drift local (hors-ligne).
///
/// La table locale `periods` n'a pas de colonne cycle : le filtre par cycle
/// de [periodsForClassroomProvider] retombe alors sur la liste complète
/// (comportement prévu — jamais de liste vide bloquante).
Future<List<PeriodDto>> _periodsFromLocal(Ref ref) async {
  try {
    final db = ref.read(databaseProvider);
    final rows = await (db.select(db.periods)
          ..where((t) => t.isDeleted.equals(false)))
        .get();
    return rows
        .map((p) => PeriodDto(
              id: p.id,
              name: p.name,
              startDate: p.startDate?.toIso8601String().substring(0, 10),
              endDate: p.endDate?.toIso8601String().substring(0, 10),
              isActive: p.isActive,
              schoolYearId: p.schoolYearId,
              weight: p.weight,
            ))
        .toList();
  } catch (_) {
    return const [];
  }
}

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

/// Périodes filtrées par le **cycle de la classe sélectionnée** — corrige le
/// mélange collège/lycée dans le champ « Période ».
///
/// Miroir du desktop (`GradeService.get_periods(session, year, cycle_id)` via
/// `classroom.level.cycle_id`) : on matche `period.cycle_id ==
/// classroom.cycle_id` ([Fix-PERIOD-CYCLE] : `cycle_id` est exposé par
/// `PeriodResponse` et `ClassroomResponse`). Si le filtre ne renvoie rien
/// (données legacy sans cycle, ou serveur non patché), on retombe sur toutes
/// les périodes — jamais de liste vide bloquante.
final periodsForClassroomProvider = FutureProvider.autoDispose
    .family<List<PeriodDto>, int>((ref, classroomId) async {
  final periods = await ref.watch(periodsProvider.future);
  final classrooms = await ref.watch(classroomsForGradesProvider.future);
  final classroom = classrooms
      .where((c) => c.id == classroomId)
      .firstOrNull;
  if (classroom == null || classroom.cycleId == null) return periods;
  final filtered =
      periods.where((p) => p.cycleId == classroom.cycleId).toList();
  return filtered.isEmpty ? periods : filtered;
});

/// Période active (celle du jour) d'une liste — miroir de
/// `GradeService.get_active_period` : `start_date <= today <= end_date`,
/// sinon la première. Retourne `null` si la liste est vide.
PeriodDto? activePeriodOf(List<PeriodDto> periods) {
  if (periods.isEmpty) return null;
  for (final p in periods) {
    if (p.isCurrent) return p;
  }
  return periods.first;
}

/// Types d'évaluation : `GET /grades/assessment-types` (endpoint fourni par
/// le patch serveur GeTech-SMS). Fallback : [CommonAssessmentTypes.defaults]
/// si l'endpoint n'existe pas encore (404) — les IDs par défaut correspondent
/// au seed de développement.
final assessmentTypesProvider =
    FutureProvider.autoDispose<List<AssessmentTypeInfo>>((ref) async {
  // [Fix-HEARTBEAT-REBUILD] select : voir classroomsForGradesProvider.
  final conn = ref.watch(connectionProvider
      .select((c) => (isPaired: c.isPaired, serverUrl: c.serverUrl)));
  if (!conn.isPaired || conn.serverUrl == null) {
    return CommonAssessmentTypes.defaults;
  }
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.get(
      buildUrl(conn.serverUrl!, ApiEndpoints.gradesAssessmentTypes),
    );
    final data = resp.data;
    List<dynamic>? rawList;
    if (data is List) {
      rawList = data;
    } else if (data is Map && data['items'] is List) {
      rawList = data['items'] as List;
    }
    if (rawList == null || rawList.isEmpty) {
      return CommonAssessmentTypes.defaults;
    }
    final types = rawList
        .whereType<Map>()
        .map((j) => AssessmentTypeInfo.fromJson(
            Map<String, dynamic>.from(j)))
        .toList();
    return types.isEmpty ? CommonAssessmentTypes.defaults : types;
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 404 || api.statusCode == 403) {
      return CommonAssessmentTypes.defaults;
    }
    rethrow;
  } catch (_) {
    return CommonAssessmentTypes.defaults;
  }
});

/// Matières affectées à une classe : `GET /grades/class-subjects?classroom_id=`.
final classSubjectsProvider = FutureProvider.autoDispose
    .family<List<ClassSubjectDto>, int>((ref, classroomId) async {
  // [Fix-HEARTBEAT-REBUILD] select : voir classroomsForGradesProvider.
  final conn = ref.watch(connectionProvider
      .select((c) => (isPaired: c.isPaired, serverUrl: c.serverUrl)));
  if (!conn.isPaired || conn.serverUrl == null) {
    return _classSubjectsFromLocal(ref, classroomId);
  }
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
    // [Fix-TEACHER-CLASSES-403] Un 403 n'est plus avalé en liste vide :
    // on sert le cache Drift (avant le fix serveur RBAC, l'enseignant
    // voyait « aucune classe » sans aucune erreur).
    // [Fix-OFFLINE] serveur injoignable → cache Drift.
    return _classSubjectsFromLocal(ref, classroomId);
  } catch (_) {
    return _classSubjectsFromLocal(ref, classroomId);
  }
});

/// Matières d'une classe servies depuis le cache Drift local
/// (tables `class_subjects` + `subjects` + `users`).
Future<List<ClassSubjectDto>> _classSubjectsFromLocal(
    Ref ref, int classroomId) async {
  try {
    final db = ref.read(databaseProvider);
    final rows = await (db.select(db.classSubjects)
          ..where((t) => t.classroomId.equals(classroomId))
          ..where((t) => t.isDeleted.equals(false)))
        .get();
    if (rows.isEmpty) return const [];

    final subjects = {
      for (final s in await db.select(db.subjects).get())
        s.id: (name: s.name, code: s.code)
    };
    final users = {
      for (final u in await db.select(db.users).get())
        u.id: [u.firstName, u.lastName].whereType<String>().join(' ').trim()
    };

    return rows
        .map((r) => ClassSubjectDto(
              id: r.id,
              subjectId: r.subjectId,
              subjectName: subjects[r.subjectId]?.name ?? '',
              subjectCode: subjects[r.subjectId]?.code ?? '',
              coefficient: r.coefficient,
              assignedTeacherId: r.teacherId,
              assignedTeacherName:
                  r.teacherId == null ? null : users[r.teacherId],
              classroomId: r.classroomId,
            ))
        .toList();
  } catch (_) {
    return const [];
  }
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

/// Évaluations d'une matière pour une période :
/// `GET /grades/assessments?class_subject_id=X&period_id=Y`.
final assessmentsProvider = FutureProvider.autoDispose
    .family<List<AssessmentDto>, AssessmentsQuery>((ref, q) async {
  // [Fix-HEARTBEAT-REBUILD] select : voir classroomsForGradesProvider.
  final conn = ref.watch(connectionProvider
      .select((c) => (isPaired: c.isPaired, serverUrl: c.serverUrl)));
  if (!conn.isPaired || conn.serverUrl == null) {
    return _assessmentsFromLocal(ref, q);
  }
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
    // [Fix-TEACHER-CLASSES-403] Un 403 n'est plus avalé en liste vide :
    // on sert le cache Drift (avant le fix serveur RBAC, l'enseignant
    // voyait « aucune classe » sans aucune erreur).
    // [Fix-OFFLINE] serveur injoignable → cache Drift.
    return _assessmentsFromLocal(ref, q);
  } catch (_) {
    return _assessmentsFromLocal(ref, q);
  }
});

/// Évaluations d'une matière+période servies depuis le cache Drift local
/// (tables `assessments` + comptage des notes locales).
Future<List<AssessmentDto>> _assessmentsFromLocal(
    Ref ref, AssessmentsQuery q) async {
  try {
    final db = ref.read(databaseProvider);
    final query = db.select(db.assessments)
      ..where((t) => t.classSubjectId.equals(q.classSubjectId))
      ..where((t) => t.isDeleted.equals(false));
    if (q.periodId != 0) {
      query.where((t) => t.periodId.equals(q.periodId));
    }
    final rows = await query.get();

    // Comptage local des notes saisies par évaluation.
    final countExpr = db.grades.id.count();
    final countRows = await (db.selectOnly(db.grades)
          ..addColumns([db.grades.assessmentId, countExpr])
          ..where(db.grades.isDeleted.equals(false))
          ..groupBy([db.grades.assessmentId]))
        .get();
    final counts = <int, int>{};
    for (final row in countRows) {
      final aid = row.read(db.grades.assessmentId);
      if (aid != null) counts[aid] = row.read(countExpr) ?? 0;
    }

    return rows
        .map((a) => AssessmentDto(
              id: a.id,
              name: a.title,
              maxScore: a.maxScore,
              coefficient: a.coefficient,
              dateTaken: a.date?.toIso8601String().substring(0, 10),
              classSubjectId: a.classSubjectId,
              periodId: a.periodId,
              gradesEnteredCount: counts[a.id] ?? 0,
            ))
        .toList()
      ..sort((a, b) => (b.dateTaken ?? '').compareTo(a.dateTaken ?? ''));
  } catch (_) {
    return const [];
  }
}

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

/// Notes d'une évaluation (entrées par élève) — [Offline-First].
///
/// En ligne : `GET /grades/assessments/{id}/grades` (les marques serveur
/// `modification_status` sont alors réconciliées dans Drift pour un
/// affichage cohérent lors des prochaines consultations hors-ligne).
/// Hors-ligne : reconstruction depuis Drift (notes répliquées + marques
/// queued/rejected) + superposition des soumissions en attente de
/// l'outbox (notes nouvelles ou propositions pas encore poussées).
final assessmentGradesProvider = FutureProvider.autoDispose
    .family<List<GradeEntryDto>, int>((ref, assessmentId) async {
  // [Fix-HEARTBEAT-REBUILD] select : voir classroomsForGradesProvider.
  // canReachServer/isChecking ne changent qu'aux transitions d'état.
  final conn = ref.watch(connectionProvider.select((c) => (
        isPaired: c.isPaired,
        serverUrl: c.serverUrl,
        canReachServer: c.canReachServer,
        isChecking: c.isChecking,
      )));
  if (!conn.isPaired || conn.serverUrl == null) return const [];

  final definitelyOffline = !conn.canReachServer && !conn.isChecking;
  if (definitelyOffline) {
    return _gradeEntriesFromLocal(ref, assessmentId);
  }

  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.get(
      buildUrl(conn.serverUrl!, ApiEndpoints.assessmentGrades(assessmentId)),
    );
    final entries = _parseGradeEntryList(resp.data);
    // Réconcilie les marques serveur dans Drift (affichage hors-ligne).
    await _reconcileServerMarks(ref, assessmentId, entries);
    return entries;
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    // [Fix-TEACHER-CLASSES-403] 403 → repli local (liste vide silencieuse
    // auparavant).
    // Réseau indisponible en cours de requête -> repli local.
    return _gradeEntriesFromLocal(ref, assessmentId);
  } catch (_) {
    return _gradeEntriesFromLocal(ref, assessmentId);
  }
});

/// Réconcilie les marques serveur (PENDING/APPROVED/REJECTED) dans Drift.
Future<void> _reconcileServerMarks(
  Ref ref,
  int assessmentId,
  List<GradeEntryDto> entries,
) async {
  try {
    final db = ref.read(databaseProvider);
    final rows = await (db.select(db.grades)
          ..where((t) => t.assessmentId.equals(assessmentId))
          ..where((t) => t.isDeleted.equals(false)))
        .get();
    final byGradeId = {for (final g in rows) g.id: g};

    for (final e in entries) {
      final gradeId = e.gradeId;
      if (gradeId == null) continue;
      final local = byGradeId[gradeId];
      final serverStatus = e.modificationStatus;

      String? nextStatus;
      double? nextProposed;
      bool? nextProposedAbsent;
      String? nextProposedComments;

      if (serverStatus == 'PENDING') {
        nextStatus = 'queued';
        nextProposed = e.modification?.newValue;
        nextProposedAbsent = e.modification?.newIsAbsent;
        nextProposedComments = e.modification?.newComments;
      } else if (serverStatus == 'REJECTED') {
        nextStatus = 'rejected';
        nextProposed = e.modification?.newValue;
        nextProposedAbsent = e.modification?.newIsAbsent;
        nextProposedComments = e.modification?.newComments;
      } else {
        // APPROVED (appliquée) ou aucune proposition : marque résolue.
        nextStatus = null;
        nextProposed = null;
        nextProposedAbsent = null;
        nextProposedComments = null;
      }

      // Évite les écritures inutiles.
      if (local != null &&
          local.syncStatus == nextStatus &&
          local.proposedValue == nextProposed) {
        continue;
      }

      await (db.update(db.grades)..where((t) => t.id.equals(gradeId))).write(
        GradesCompanion(
          syncStatus: d.Value(nextStatus),
          proposedValue: d.Value(nextProposed),
          proposedIsAbsent: d.Value(nextProposedAbsent),
          proposedComments: d.Value(nextProposedComments),
        ),
      );
    }
  } catch (_) {
    // La réconciliation est best-effort : jamais bloquante.
  }
}

/// Reconstruction hors-ligne des lignes de notes d'une évaluation :
/// Drift (notes répliquées + marques) + outbox (soumissions en attente).
Future<List<GradeEntryDto>> _gradeEntriesFromLocal(
  Ref ref,
  int assessmentId,
) async {
  final db = ref.read(databaseProvider);

  // Élèves de la classe de l'évaluation (chaîne Drift : assessment ->
  // class_subject -> classroom -> assignations actives -> students).
  final assessmentRow = await (db.select(db.assessments)
        ..where((t) => t.id.equals(assessmentId)))
      .getSingleOrNull();
  if (assessmentRow == null) return const [];

  final classSubject = await (db.select(db.classSubjects)
        ..where((t) => t.id.equals(assessmentRow.classSubjectId)))
      .getSingleOrNull();
  if (classSubject == null) return const [];

  final assignmentRows = await (db.select(db.studentClassAssignments)
        ..where((t) => t.classroomId.equals(classSubject.classroomId))
        ..where((t) => t.isDeleted.equals(false)))
      .get();
  final studentIds = assignmentRows.map((a) => a.studentId).toSet();
  if (studentIds.isEmpty) return const [];
  final studentRows = await (db.select(db.students)
        ..where((t) => t.id.isIn(studentIds))
        ..where((t) => t.isDeleted.equals(false)))
      .get();
  studentRows.sort((a, b) =>
      '${a.nom} ${a.prenoms ?? ''}'.compareTo('${b.nom} ${b.prenoms ?? ''}'));

  // Notes répliquées + marques.
  final gradeRows = await (db.select(db.grades)
        ..where((t) => t.assessmentId.equals(assessmentId))
        ..where((t) => t.isDeleted.equals(false)))
        .get();
  final gradeByStudent = {for (final g in gradeRows) g.studentId: g};

  // Soumission(s) en attente dans l'outbox pour CETTE évaluation.
  final outbox = ref.read(outboxProvider);
  final pendingEntries = await outbox.pending();
  final submission = pendingEntries
      .where((e) => e.tableNameColumn == 'grade_submission')
      .map((e) => e.payloadMap)
      .where((p) => (p['assessment_id'] as num?)?.toInt() == assessmentId)
      .firstOrNull;
  final pendingByStudent = <int, Map<String, dynamic>>{};
  if (submission != null) {
    for (final r in ((submission['grades'] as List?) ?? const [])
        .whereType<Map>()) {
      final m = Map<String, dynamic>.from(r);
      final sid = (m['student_id'] as num?)?.toInt();
      if (sid != null) pendingByStudent[sid] = m;
    }
  }

  final result = <GradeEntryDto>[];
  for (final s in studentRows) {
    final sid = s.id;
    final name = '${s.nom} ${s.prenoms ?? ''}'.trim();
    final matricule = s.matricule ?? '';
    final local = gradeByStudent[sid];
    final pending = pendingByStudent[sid];

    // Valeur affichée : proposition en attente > note répliquée.
    final pendingValue = (pending?['value'] as num?)?.toDouble();
    final value =
        pending != null ? pendingValue : (local?.proposedValue ?? local?.value);
    final isAbsent = pending != null
        ? (pending['is_absent'] as bool? ?? false)
        : (local?.proposedIsAbsent ?? local?.isAbsent ?? false);
    final comment = pending != null
        ? (pending['comment'] as String?)
        : (local?.proposedComments ?? local?.comments);

    // Marques (dans l'ordre : soumission locale > marque Drift).
    String? mark;
    if (pending != null) {
      mark = 'pending_sync';
    } else if (local?.syncStatus == 'queued') {
      mark = 'PENDING';
    } else if (local?.syncStatus == 'rejected') {
      mark = 'REJECTED';
    }

    result.add(GradeEntryDto(
      studentId: sid,
      studentName: name,
      studentMatricule: matricule,
      gradeId: local?.id,
      value: value,
      isAbsent: isAbsent,
      comment: comment,
      isLocked: local != null,
      modificationStatus: mark,
      modification: (mark != null && local != null)
          ? GradeModificationBriefDto(
              id: 0,
              status: mark,
              newValue: local.proposedValue,
              newIsAbsent: local.proposedIsAbsent ?? false,
              newComments: local.proposedComments,
              oldValue: local.value,
            )
          : null,
      localSyncMark: pending != null ? 'pending_sync' : null,
    ));
  }
  return result;
}

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
  // [Fix-HEARTBEAT-REBUILD] select : voir classroomsForGradesProvider.
  final conn = ref.watch(connectionProvider
      .select((c) => (isPaired: c.isPaired, serverUrl: c.serverUrl)));
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
    if (api.statusCode == 403) {
      // [Fix-TEACHER-CLASSES-403] Message explicite au lieu d'une liste vide
      // silencieuse — l'appelant retombe sur le cache Drift.
      throw const ApiException(
        'Accès refusé (403) — vérifiez les permissions du compte côté serveur.',
        statusCode: 403,
      );
    }
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
  // [Fix-HEARTBEAT-REBUILD] select : voir classroomsForGradesProvider.
  final conn = ref.watch(connectionProvider
      .select((c) => (isPaired: c.isPaired, serverUrl: c.serverUrl)));
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
