/// Contrôleur du module Emploi du temps.
///
/// Contrat serveur (branche desktop `feature/desktop-control-center`) :
/// - `GET /schedule?classroom_id=&teacher_id=` — liste plate des entrées
///   (le paramètre `week_type` est accepté mais IGNORé par le serveur : le
///   filtrage A/B est fait côté client via [WeeklyScheduleDto.matchesWeek]).
/// - `GET /schedule/my` — cours de l'enseignant connecté.
/// - `POST /schedule/entries`, `PUT /schedule/entries/{id}`,
///   `DELETE /schedule/entries/{id}` — édition (admins uniquement) ; ces
///   endpoints nécessitent le **patch serveur GeTech-SMS** (voir `docs/`).
///   Sans le patch, l'UI d'édition affiche une invitation à mettre à jour le
///   serveur (404/405 interceptés).
///
/// RBAC (miroir du desktop) :
/// - Admin / headmaster (et superuser) → vue par classe **et** par enseignant,
///   édition complète (ajout / modification / suppression).
/// - Enseignant → « Mes cours » (ses cours, toutes classes) + « Mes classes »
///   (EDT complet des classes dont il est titulaire et où il enseigne),
///   strictement lecture seule.
library;

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' as d;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_state.dart';
import '../../core/auth/teacher_scope.dart';
import '../../core/config/constants.dart';
import '../../core/database/database.dart';
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

// ===========================================================================
// Lecture
// ===========================================================================

/// Liste des classes pour le sélecteur (réutilise `GET /classrooms`).
///
/// [Fix-OFFLINE] Local-first : hors-ligne, le cache Drift (classes)
/// alimente le sélecteur. Renvoie une liste vide silencieuse en cas de
/// 403 (permissions insuffisantes).
final classroomsForScheduleProvider =
    FutureProvider.autoDispose<List<ClassroomDto>>((ref) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) {
    return _classroomsFromLocal(ref);
  }
  final dio = ref.watch(dioProvider);
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
    if (api.statusCode == 403) return const [];
    // Serveur injoignable → cache local.
    return _classroomsFromLocal(ref);
  }
});

/// Classes servies depuis le cache Drift local (hors-ligne).
Future<List<ClassroomDto>> _classroomsFromLocal(Ref ref) async {
  try {
    final db = ref.read(databaseProvider);
    final rows = await (db.select(db.classrooms)
          ..where((t) => t.isDeleted.equals(false)))
        .get();
    return rows
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
  } catch (_) {
    return const [];
  }
}

/// Emploi du temps **complet** d'une classe (toutes semaines confondues) :
/// `GET /schedule?classroom_id=X`.
///
/// Le serveur ignore le paramètre `week_type` : on récupère tout puis on
/// filtre côté client (via [WeeklyScheduleDto.matchesWeek]) dans l'UI.
///
/// [Fix-OFFLINE] Local-first : le cache Drift (table `weekly_schedules`,
/// rempli par la synchro) est servi immédiatement — l'EDT reste
/// consultable hors-ligne. L'API ne sert qu'à rafraîchir le cache quand
/// le serveur répond.
final classroomScheduleProvider = FutureProvider.autoDispose
    .family<List<WeeklyScheduleDto>, int>((ref, classroomId) async {
  final conn = ref.watch(connectionProvider);

  // 1) Cache local immédiat (seule source hors-ligne).
  final local = await _scheduleFromLocal(ref, classroomId);

  if (!conn.isPaired || conn.serverUrl == null) return local;
  final definitelyOffline = !conn.canReachServer && !conn.isChecking;
  if (definitelyOffline) return local;

  // 2) Rafraîchissement API (échecs réseau tolérés → cache local).
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.get(
      buildUrl(conn.serverUrl!, ApiEndpoints.schedule),
      queryParameters: {'classroom_id': classroomId},
    );
    final remote = _parseWeeklyScheduleList(resp.data);
    await _saveScheduleToLocal(ref, remote);
    // Reservir le local enrichi (noms de matières résolus).
    final updated = await _scheduleFromLocal(ref, classroomId);
    return updated.isNotEmpty || remote.isEmpty ? updated : remote;
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403 || api.statusCode == 404) return local;
    return local; // réseau KO → cache
  } catch (_) {
    return local;
  }
});

/// EDT d'une classe depuis le cache Drift (noms de matières résolus via
/// la table locale `subjects`).
Future<List<WeeklyScheduleDto>> _scheduleFromLocal(
    Ref ref, int? classroomId) async {
  try {
    final db = ref.read(databaseProvider);
    final query = db.select(db.weeklySchedules)
      ..where((t) => t.isDeleted.equals(false));
    if (classroomId != null) {
      query.where((t) => t.classroomId.equals(classroomId));
    }
    final rows = await query.get();
    if (rows.isEmpty) return const [];

    final subjects = {
      for (final s in await db.select(db.subjects).get()) s.id: s.name,
    };
    final classrooms = {
      for (final c in await db.select(db.classrooms).get()) c.id: c.name,
    };

    return rows
        .map((r) => WeeklyScheduleDto(
              id: r.id,
              classroomId: r.classroomId,
              classroomName: classrooms[r.classroomId],
              subjectId: r.subjectId,
              subjectName: subjects[r.subjectId],
              teacherId: r.teacherId,
              timeSlotId: r.timeSlotId,
              dayOfWeek: r.dayOfWeek,
              startTime: r.startTime ?? '',
              endTime: r.endTime ?? '',
              room: r.room,
              weekTypeRaw: r.weekType,
            ))
        .toList();
  } catch (_) {
    return const [];
  }
}

/// Persiste les entrées EDT dans le cache Drift (upsert par id).
Future<void> _saveScheduleToLocal(
    Ref ref, List<WeeklyScheduleDto> entries) async {
  try {
    final db = ref.read(databaseProvider);
    await db.batch((batch) {
      for (final e in entries) {
        batch.replace(
          db.weeklySchedules,
          WeeklySchedulesCompanion.insert(
            id: d.Value(e.id),
            classroomId: d.Value(e.classroomId),
            subjectId: d.Value(e.subjectId),
            teacherId: d.Value(e.teacherId),
            timeSlotId: e.timeSlotId,
            dayOfWeek: e.dayOfWeek,
            startTime: d.Value(e.startTime),
            endTime: d.Value(e.endTime),
            room: d.Value(e.room),
            weekType: d.Value(e.weekTypeRaw ?? 'A'),
            syncedAt: d.Value(DateTime.now()),
          ),
        );
      }
    });
  } catch (_) {
    // Best-effort : le cache ne doit jamais casser l'affichage.
  }
}

/// Compatibilité : emploi du temps d'une classe filtré par semaine
/// (utilisé par le module Présence et l'onglet EDT du détail de classe).
final weeklyScheduleProvider = FutureProvider.autoDispose
    .family<List<WeeklyScheduleDto>, ScheduleQuery>((ref, query) async {
  final all = await ref.watch(classroomScheduleProvider(query.classroomId).future);
  return all.where((s) => s.matchesWeek(query.weekType)).toList();
});

/// Emploi du temps d'un enseignant : `GET /schedule?teacher_id=Y`
/// (vue admin « Par enseignant »).
///
/// [Fix-OFFLINE] Repli cache Drift si le serveur ne répond pas.
final teacherScheduleByIdProvider = FutureProvider.autoDispose
    .family<List<WeeklyScheduleDto>, int>((ref, teacherId) async {
  final conn = ref.watch(connectionProvider);
  if (!conn.isPaired || conn.serverUrl == null) {
    return _teacherScheduleFromLocal(ref, teacherId);
  }
  final dio = ref.watch(dioProvider);
  try {
    final resp = await dio.get(
      buildUrl(conn.serverUrl!, ApiEndpoints.schedule),
      queryParameters: {'teacher_id': teacherId},
    );
    return _parseWeeklyScheduleList(resp.data);
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    if (api.statusCode == 403 || api.statusCode == 404) {
      return _teacherScheduleFromLocal(ref, teacherId);
    }
    return _teacherScheduleFromLocal(ref, teacherId);
  } catch (_) {
    return _teacherScheduleFromLocal(ref, teacherId);
  }
});

/// EDT d'un enseignant depuis le cache Drift local.
Future<List<WeeklyScheduleDto>> _teacherScheduleFromLocal(
    Ref ref, int teacherId) async {
  try {
    final db = ref.read(databaseProvider);
    final rows = await (db.select(db.weeklySchedules)
          ..where((t) => t.teacherId.equals(teacherId))
          ..where((t) => t.isDeleted.equals(false)))
        .get();
    if (rows.isEmpty) return const [];
    final subjects = {
      for (final s in await db.select(db.subjects).get()) s.id: s.name,
    };
    return rows
        .map((r) => WeeklyScheduleDto(
              id: r.id,
              classroomId: r.classroomId,
              subjectId: r.subjectId,
              subjectName: subjects[r.subjectId],
              teacherId: r.teacherId,
              timeSlotId: r.timeSlotId,
              dayOfWeek: r.dayOfWeek,
              startTime: r.startTime ?? '',
              endTime: r.endTime ?? '',
              room: r.room,
              weekTypeRaw: r.weekType,
            ))
        .toList();
  } catch (_) {
    return const [];
  }
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

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
          .map((e) =>
              WeeklyScheduleDto.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
  }
  return const [];
}

// ===========================================================================
// Écriture (admins uniquement — nécessite le patch serveur GeTech-SMS)
// ===========================================================================

/// Requête de création d'une entrée d'emploi du temps.
///
/// Le patch serveur résout le créneau (`TimeSlot`) et la session
/// (`ScheduleSession`) à partir de `day_of_week` + `start_time`/`end_time`,
/// avec détection de conflits classe + enseignant (miroir de
/// `ScheduleService.create_schedule_entry` du desktop).
class ScheduleEntryCreateRequest {
  final int classroomId;
  final int classSubjectId;
  final int dayOfWeek; // 1..6
  final String startTime; // "HH:mm"
  final String endTime; // "HH:mm"
  final String? weekType; // 'A' | 'B' | null (toutes les semaines)
  final String? room;

  const ScheduleEntryCreateRequest({
    required this.classroomId,
    required this.classSubjectId,
    required this.dayOfWeek,
    required this.startTime,
    required this.endTime,
    this.weekType,
    this.room,
  });

  Map<String, dynamic> toJson() => {
        'classroom_id': classroomId,
        'class_subject_id': classSubjectId,
        'day_of_week': dayOfWeek,
        'start_time': startTime,
        'end_time': endTime,
        if (weekType != null) 'week_type': weekType,
        if (room != null && room!.isNotEmpty) 'room': room,
      };
}

/// Requête de modification d'une entrée (tous les champs optionnels).
class ScheduleEntryUpdateRequest {
  final int? timeSlotId;
  final int? dayOfWeek;
  final String? startTime;
  final String? endTime;
  final String? weekType;
  final String? room;

  const ScheduleEntryUpdateRequest({
    this.timeSlotId,
    this.dayOfWeek,
    this.startTime,
    this.endTime,
    this.weekType,
    this.room,
  });

  Map<String, dynamic> toJson() => {
        if (timeSlotId != null) 'time_slot_id': timeSlotId,
        if (dayOfWeek != null) 'day_of_week': dayOfWeek,
        if (startTime != null) 'start_time': startTime,
        if (endTime != null) 'end_time': endTime,
        // Permet de repasser en « toutes les semaines » avec la clé explicite.
        'week_type': weekType,
        if (room != null) 'room': room,
      };
}

/// Erreur d'édition EDT : soit un conflit détecté par le serveur (409/400),
/// soit l'absence du patch serveur (404/405 → [patchRequired]).
class ScheduleEditException implements Exception {
  final String message;
  final int? statusCode;

  /// Vrai quand le serveur n'expose pas les endpoints d'écriture (patch
  /// serveur GeTech-SMS non appliqué).
  final bool patchRequired;

  const ScheduleEditException(this.message,
      {this.statusCode, this.patchRequired = false});

  @override
  String toString() => 'ScheduleEditException(${statusCode ?? ''}): $message';
}

/// Contrôleur d'édition de l'emploi du temps (admins uniquement — la page
/// vérifie `isAdminOrHeadmaster` avant d'exposer les actions).
class ScheduleEditController {
  ScheduleEditController(this._ref);
  final Ref _ref;

  Dio get _dio => _ref.read(dioProvider);
  String? get _serverUrl => _ref.read(connectionProvider).serverUrl;

  Future<Map<String, dynamic>> _send(
      Future<Map<String, dynamic>> Function(String url) send) async {
    final url = _serverUrl;
    if (url == null) throw const ScheduleEditException('Serveur non configuré');
    try {
      return await send(url);
    } on DioException catch (e) {
      final api = (e.error is ApiException)
          ? e.error as ApiException
          : dioErrorToApiException(e);
      final code = api.statusCode;
      if (code == 404 || code == 405) {
        throw ScheduleEditException(
          'L\'édition de l\'emploi du temps nécessite la mise à jour du '
          'serveur desktop GeTech-SMS (patch « schedule-edit »). Contactez '
          'l\'administrateur ou consultez la documentation.',
          statusCode: code,
          patchRequired: true,
        );
      }
      throw ScheduleEditException(api.message, statusCode: code);
    }
  }

  /// Crée un cours : `POST /schedule/entries`.
  Future<WeeklyScheduleDto> createEntry(ScheduleEntryCreateRequest req) async {
    final data = await _send((url) async {
      final resp = await _dio.post(
        buildUrl(url, ApiEndpoints.scheduleEntries),
        data: req.toJson(),
      );
      return Map<String, dynamic>.from(resp.data as Map);
    });
    _invalidateAll();
    return WeeklyScheduleDto.fromJson(data);
  }

  /// Modifie un cours : `PUT /schedule/entries/{id}`.
  Future<WeeklyScheduleDto> updateEntry(
      int id, ScheduleEntryUpdateRequest req) async {
    final data = await _send((url) async {
      final resp = await _dio.put(
        buildUrl(url, ApiEndpoints.scheduleEntry(id)),
        data: req.toJson(),
      );
      return Map<String, dynamic>.from(resp.data as Map);
    });
    _invalidateAll();
    return WeeklyScheduleDto.fromJson(data);
  }

  /// Supprime un cours : `DELETE /schedule/entries/{id}`.
  Future<void> deleteEntry(int id) async {
    await _send((url) async {
      final resp = await _dio.delete(
        buildUrl(url, ApiEndpoints.scheduleEntry(id)),
      );
      return Map<String, dynamic>.from(resp.data as Map? ?? const {});
    });
    _invalidateAll();
  }

  /// Invalide toutes les vues d'emploi du temps après une mutation.
  void _invalidateAll() {
    _ref.invalidate(classroomsForScheduleProvider);
    // Les family providers (classroomScheduleProvider / teacherScheduleByIdProvider
    // / weeklyScheduleProvider / teacherScopeProvider) se rafraîchissent via
    // leur autoDispose au prochain accès ; on invalide explicitement le scope
    // enseignant pour rafraîchir l'Accueil.
    _ref.invalidate(teacherScopeProvider);
  }
}

final scheduleEditControllerProvider =
    Provider<ScheduleEditController>((ref) => ScheduleEditController(ref));

// ===========================================================================
// Sélecteurs de rôle
// ===========================================================================

/// Vrai si l'utilisateur connecté peut éditer l'emploi du temps
/// (superuser / ADMIN / HEADMASTER — miroir du desktop : admin, headmaster,
/// secretary éditent ; ici on aligne sur `_user_is_admin_or_headmaster`).
final canEditScheduleProvider = Provider<bool>((ref) {
  final auth = ref.watch(authProvider);
  return auth.isAuthenticated && auth.isAdminOrHeadmaster;
});
