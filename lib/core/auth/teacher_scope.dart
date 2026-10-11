/// Périmètre d'enseignement de l'utilisateur connecté (module partagé par
/// l'Accueil, les Notes et l'Emploi du temps).
///
/// Un utilisateur est considéré comme enseignant si :
/// - le rôle `TEACHER` est déclaré (RoleBrief.code du login / auth/me), OU
/// - il a des relations de données d'enseignement : des matières assignées
///   (`ClassSubject.assigned_teacher_id == me`, détecté via
///   `GET /classrooms?teacher_only=true`) ou des cours planifiés
///   (`GET /schedule/my` non vide).
///
/// Les administrateurs (superuser, ADMIN, HEADMASTER) ne sont JAMAIS restreints
/// au périmètre enseignant — miroir de `_user_is_admin_or_headmaster` du desktop.
///
/// Données exposées par [TeacherScope] :
/// - [teachingClassrooms] : classes où l'utilisateur enseigne ≥ 1 matière
///   (endpoint `/classrooms?teacher_only=true`, scope serveur) **union** les
///   classes de ses cours dans l'emploi du temps (`GET /schedule/my` —
///   [Fix-EDT-SCOPE] : l'EDT est la source de vérité, certaines matières
///   peuvent être inactives ou d'une autre année scolaire).
/// - [headClassrooms] : classes dont il est titulaire
///   (`ClassroomResponse.head_teacher_id == me`, filtrage client).
/// - [mySchedule] : ses cours planifiés (`GET /schedule/my`).
library;

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' as d;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/connections/connection_state.dart';
import '../../shared/models/attendance_dto.dart';
import '../../shared/models/classroom_dto.dart';
import '../auth/auth_state.dart';
import '../config/constants.dart';
import '../database/database.dart';
import '../network/api_endpoints.dart';
import '../network/api_exceptions.dart';
import '../network/dio_client.dart';

/// Périmètre enseignant immuable.
class TeacherScope {
  /// Vrai si l'utilisateur est un enseignant (rôle déclaré OU relations
  /// détectées) sans droits admin élargis.
  final bool isTeacher;

  /// Vrai pour superuser / ADMIN / HEADMASTER (accès non restreint).
  final bool isAdminOrHeadmaster;

  /// Classes où l'utilisateur enseigne au moins une matière.
  final List<ClassroomDto> teachingClassrooms;

  /// Classes dont l'utilisateur est titulaire (head_teacher).
  final List<ClassroomDto> headClassrooms;

  /// Cours planifiés de l'utilisateur (toutes classes confondues).
  final List<WeeklyScheduleDto> mySchedule;

  const TeacherScope({
    this.isTeacher = false,
    this.isAdminOrHeadmaster = false,
    this.teachingClassrooms = const [],
    this.headClassrooms = const [],
    this.mySchedule = const [],
  });

  static const empty = TeacherScope();

  /// Union dédupliquée des classes liées à l'enseignant (enseignement + titulariat).
  List<ClassroomDto> get myClassrooms {
    final byId = <int, ClassroomDto>{};
    for (final c in teachingClassrooms) {
      byId[c.id] = c;
    }
    for (final c in headClassrooms) {
      byId.putIfAbsent(c.id, () => c);
    }
    final list = byId.values.toList()..sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  /// Identifiants des classes de l'enseignant (pour le scoping des listes).
  Set<int> get myClassroomIds => myClassrooms.map((c) => c.id).toSet();

  /// Matières distinctes enseignées (d'après l'emploi du temps).
  int get mySubjectCount =>
      mySchedule.map((s) => s.subjectId).whereType<int>().toSet().length;

  /// Cours du jour [today] (lundi=1..samedi=6 ; dimanche → aucune ligne).
  List<WeeklyScheduleDto> coursesForDate(DateTime today,
      {WeekType? currentWeek}) {
    // ISO weekday : lundi=1 .. dimanche=7 → notre convention 1..6.
    final dow = today.weekday;
    if (dow > 6) return const [];
    final week = currentWeek;
    return mySchedule
        .where((s) => s.dayOfWeek == dow)
        .where((s) => week == null || s.isAllWeeks || s.weekType == week)
        .toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
  }

  /// Prochains créneaux à partir de [from] (heure « HH:mm »), aujourd'hui puis
  /// jours suivants, limité à [limit] éléments.
  List<WeeklyScheduleDto> upcomingCourses(DateTime from,
      {WeekType? currentWeek, int limit = 5}) {
    final all = <WeeklyScheduleDto>[...mySchedule]
      ..sort((a, b) {
        final d = a.dayOfWeek.compareTo(b.dayOfWeek);
        if (d != 0) return d;
        return a.startTime.compareTo(b.startTime);
      });
    final nowMinutes = from.hour * 60 + from.minute;
    final today = from.weekday;
    final result = <WeeklyScheduleDto>[];
    for (final s in all) {
      if (currentWeek != null &&
          !s.isAllWeeks &&
          s.weekType != currentWeek) {
        continue;
      }
      if (s.dayOfWeek < today) continue;
      if (s.dayOfWeek == today) {
        final parts = s.startTime.split(':');
        final startMinutes =
            (int.tryParse(parts.isNotEmpty ? parts[0] : '0') ?? 0) * 60 +
                (parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0);
        if (startMinutes < nowMinutes) continue;
      }
      result.add(s);
      if (result.length >= limit) break;
    }
    return result;
  }
}

/// Provider du périmètre enseignant.
///
/// - Admin élargi → [TeacherScope.empty] avec `isAdminOrHeadmaster = true`
///   (aucun appel réseau inutile).
/// - Sinon → appels parallèles `/classrooms?teacher_only=true`,
///   `/classrooms` (pour la titulariat) et `/schedule/my`.
///
/// Se re-déclenche à chaque changement d'état d'authentification ou de
/// connexion (login/logout, appairage).
final teacherScopeProvider =
    FutureProvider.autoDispose<TeacherScope>((ref) async {
  final auth = ref.watch(authProvider);
  // [Fix-HEARTBEAT-REBUILD] select : le heartbeat émet un nouvel état toutes
  // les 30 s (latence) — ne pas invalider le scope enseignant pour autant.
  final conn = ref.watch(connectionProvider
      .select((c) => (isPaired: c.isPaired, serverUrl: c.serverUrl)));

  if (!auth.isAuthenticated || !conn.isPaired || conn.serverUrl == null) {
    return TeacherScope.empty;
  }

  final isAdmin = auth.isAdminOrHeadmaster;
  if (isAdmin) {
    return const TeacherScope(isAdminOrHeadmaster: true);
  }

  final dio = ref.watch(dioProvider);
  final serverUrl = conn.serverUrl!;

  // Appels parallèles : classes enseignées, toutes les classes (titulariat),
  // emploi du temps personnel.
  //
  // [Fix-FAILL-SOFT] Chaque appel est tolérant à l'échec individuellement :
  // un 403 sur `/classrooms` (serveur ancien au RBAC incomplet) ne doit PAS
  // faire perdre les données de `/schedule/my` — l'ancien `Future.wait`
  // échouait EN BLOC dès qu'un seul des trois appels renvoyait une erreur,
  // et le repli Drift écrasait alors des cours pourtant disponibles.
  // C'était une cause directe de « aucune amélioration » côté enseignant
  // quand le serveur n'était pas encore à jour.
  var anyCallFailed = false;
  List<ClassroomDto> teaching = const [];
  List<ClassroomDto> all = const [];
  List<WeeklyScheduleDto> schedule = const [];

  Future<List<ClassroomDto>> guardedTeaching() => _fetchClassrooms(
        dio,
        serverUrl,
        teacherOnly: true,
      ).catchError((_) {
        anyCallFailed = true;
        return const <ClassroomDto>[];
      });

  Future<List<ClassroomDto>> guardedAll() => _fetchClassrooms(
        dio,
        serverUrl,
        teacherOnly: false,
      ).catchError((_) {
        anyCallFailed = true;
        return const <ClassroomDto>[];
      });

  Future<List<WeeklyScheduleDto>> guardedSchedule() => _fetchMySchedule(
        dio,
        serverUrl,
      ).catchError((_) {
        anyCallFailed = true;
        return const <WeeklyScheduleDto>[];
      });

  final results = await Future.wait([
    guardedTeaching(),
    guardedAll(),
    guardedSchedule(),
  ]);
  teaching = results[0] as List<ClassroomDto>;
  all = results[1] as List<ClassroomDto>;
  schedule = results[2] as List<WeeklyScheduleDto>;

  // [Fix-DASHBOARD-ZERO] Persister l'EDT personnel dans le cache Drift
  // (best-effort) : le périmètre enseignant est AUSSI la source de l'Accueil
  // (« Mes cours aujourd'hui », « Mes matières »). Sans cette écriture, le
  // cache local ne se remplissait que si l'enseignant visitait l'onglet EDT
  // classe par classe — et l'Accueil montrait 0 dès que le serveur ne
  // répondait pas.
  if (schedule.isNotEmpty) {
    await _persistScheduleToLocal(ref, schedule);
  }

  // [Fix-SCOPE-OFFLINE] Repli sur le cache Drift local CHAMP PAR CHAMP dès
  // que le réseau n'a rien fourni — pas seulement quand un appel a échoué
  // (un serveur ancien peut répondre 200 avec des listes vides : sans EDT
  // union côté serveur, un enseignant « EDT uniquement » obtenait un scope
  // vide sans aucun échec détectable, d'où l'Accueil à 0 alors que les
  // données existaient localement). Le cache local ne COMPLÈTE que les
  // champs vides : il ne contredit jamais une réponse réseau exploitable.
  // Les erreurs réseau ne remontent PLUS en erreur UI : l'ancien
  // comportement affichait « Impossible de déterminer votre profil
  // enseignant » dès que le serveur tombait.
  if (teaching.isEmpty || all.isEmpty || schedule.isEmpty) {
    try {
      final local = await _localTeacherScope(ref, auth.user?.id);
      if (teaching.isEmpty) teaching = local.teachingClassrooms;
      if (all.isEmpty) all = local.allClassrooms;
      if (schedule.isEmpty) schedule = local.mySchedule;
    } catch (_) {
      // Données locales indisponibles → périmètre tel quel (pas d'erreur UI).
    }
  }

  final userId = auth.user?.id;
  final head = userId == null
      ? const <ClassroomDto>[]
      : all.where((c) => c.headTeacherId == userId).toList();

  // [Fix-EDT-SCOPE] Une classe où l'enseignant a un cours dans l'EDT
  // (`GET /schedule/my`) compte comme classe enseignée, même si
  // `/classrooms?teacher_only=true` ne la renvoie pas (matière inactive ou
  // rattachée à une autre année côté serveur). On complète depuis `all`
  // (toutes les classes), et on synthétise une carte minimale si la classe
  // n'est même pas listée là.
  final byId = <int, ClassroomDto>{
    for (final c in teaching) c.id: c,
  };
  for (final s in schedule) {
    final cid = s.classroomId;
    if (cid == null || byId.containsKey(cid)) continue;
    final fromAll = all.where((c) => c.id == cid).firstOrNull;
    byId[cid] = fromAll ??
        ClassroomDto(
          id: cid,
          name: s.classroomName ?? 'Classe $cid',
        );
  }
  teaching = byId.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  // Enseignant = rôle déclaré OU relations détectées.
  final isTeacher = auth.hasDeclaredTeacherRole ||
      teaching.isNotEmpty ||
      schedule.isNotEmpty ||
      head.isNotEmpty;

  return TeacherScope(
    isTeacher: isTeacher,
    isAdminOrHeadmaster: false,
    teachingClassrooms: teaching,
    headClassrooms: head,
    mySchedule: schedule,
  );
});

/// Périmètre enseignant reconstruit depuis le cache Drift local.
Future<_LocalTeacherScope> _localTeacherScope(Ref ref, int? userId) async {
  final db = ref.read(databaseProvider);

  final classrooms = await (db.select(db.classrooms)
        ..where((t) => t.isDeleted.equals(false)))
      .get();

  List<ClassroomDto> all = classrooms
      .map((c) => ClassroomDto(
            id: c.id,
            name: c.name,
            // La colonne locale teacherId EST le titulaire (head teacher).
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

  List<ClassroomDto> teaching = const [];
  if (userId != null) {
    // [Fix-EDT-SCOPE] Union : matières assignées (class_subjects) + cours
    // planifiés (weekly_schedules, rempli par la synchro de l'EDT).
    final csRows = await (db.select(db.classSubjects)
          ..where((t) => t.teacherId.equals(userId)))
        .get();
    final wsRows = await (db.select(db.weeklySchedules)
          ..where((t) => t.teacherId.equals(userId))
          ..where((t) => t.isDeleted.equals(false)))
        .get();
    final teachingIds = {
      ...csRows.map((r) => r.classroomId),
      ...wsRows.map((r) => r.classroomId),
    };
    teaching =
        all.where((c) => teachingIds.contains(c.id)).toList();
  }

  List<WeeklyScheduleDto> schedule = const [];
  if (userId != null) {
    final rows = await (db.select(db.weeklySchedules)
          ..where((t) => t.teacherId.equals(userId))
          ..where((t) => t.isDeleted.equals(false)))
        .get();
    final subjects = {
      for (final s in await db.select(db.subjects).get()) s.id: s.name,
    };
    schedule = rows
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
  }

  return _LocalTeacherScope(
    allClassrooms: all,
    teachingClassrooms: teaching,
    mySchedule: schedule,
  );
}

class _LocalTeacherScope {
  final List<ClassroomDto> allClassrooms;
  final List<ClassroomDto> teachingClassrooms;
  final List<WeeklyScheduleDto> mySchedule;
  const _LocalTeacherScope({
    required this.allClassrooms,
    required this.teachingClassrooms,
    required this.mySchedule,
  });
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
    // [Fix-TEACHER-CLASSES-403] Un 403 n'est plus avalé : on relance pour
    // que l'appelant retombe sur le cache Drift (avant le fix serveur RBAC,
    // l'enseignant voyait « aucune classe » sans aucune erreur).
    if (api.statusCode == 403) {
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
    // [Fix-TEACHER-CLASSES-403] Enveloppes acceptées : items / data /
    // classrooms.
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

Future<List<WeeklyScheduleDto>> _fetchMySchedule(
    Dio dio, String serverUrl) async {
  try {
    final resp =
        await dio.get(buildUrl(serverUrl, ApiEndpoints.scheduleMy));
    return _parseScheduleList(resp.data);
  } on DioException catch (e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    // [Fix-DASHBOARD-ZERO] 403/404 → on RELANCE (au lieu d'avaler en liste
    // vide) : l'appelant marque l'échec et le repli Drift peut s'appliquer.
    // Un serveur ancien sans `/schedule/my` (404) ou un compte sans
    // GRADE_READ (403) produisait un périmètre EDT VIDE silencieux —
    // l'Accueil affichait « Mes matières : 0 » / « Cours aujourd'hui : 0 »
    // sans aucun indice pour l'utilisateur.
    if (api.statusCode == 403 || api.statusCode == 404) {
      throw api;
    }
    rethrow;
  }
}

List<WeeklyScheduleDto> _parseScheduleList(dynamic data) {
  if (data is List) {
    return data
        .whereType<Map>()
        .map((e) => WeeklyScheduleDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
  if (data is Map) {
    final items = data['items'] ?? data['schedule'];
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

/// [Fix-DASHBOARD-ZERO] Persiste l'EDT personnel (`GET /schedule/my`) dans
/// le cache Drift `weekly_schedules` (upsert par id, best-effort).
///
/// Miroir de `_saveScheduleToLocal` du schedule_controller (que l'on ne
/// peut pas importer ici — dépendance circulaire). Ce cache alimente :
/// - le repli hors-ligne du périmètre enseignant (Accueil à 0 sinon) ;
/// - l'onglet EDT hors-ligne (le contrôleur EDT sert ce même cache).
Future<void> _persistScheduleToLocal(
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
    // Best-effort : le cache ne doit jamais casser le périmètre.
  }
}

/// Semaine alternée courante (A ou B) calculée depuis l'année scolaire active
/// stockée en base locale Drift (`school_years.alternating_week_start_date`,
/// répliquée par le sync engine).
///
/// Miroir de `ScheduleService.week_type_for_date` du desktop :
/// `((date - start).days / 7) % 2 == 0 → A sinon B`. Retourne `null` si les
/// semaines alternées ne sont pas configurées.
final currentWeekTypeProvider = FutureProvider.autoDispose<WeekType?>((ref) {
  return WeekTypeHelper.currentWeekType(ref);
});

/// Helper de calcul de la semaine alternée courante (A/B).
///
/// Miroir de `ScheduleService.week_type_for_date` du desktop :
/// `((date - alternating_week_start_date).inDays / 7) % 2 == 0 → A sinon B`.
/// Retourne `null` si les semaines alternées ne sont pas configurées.
class WeekTypeHelper {
  WeekTypeHelper._();

  /// Calcule le type de semaine d'une date à partir de la date de démarrage
  /// des semaines alternées (premier lundi de la semaine A).
  static WeekType? weekTypeForDate(DateTime date, DateTime? alternatingStart) {
    if (alternatingStart == null) return null;
    final deltaDays = date.difference(DateTime(
      alternatingStart.year,
      alternatingStart.month,
      alternatingStart.day,
    )).inDays;
    if (deltaDays < 0) return null;
    final weekNumber = deltaDays ~/ 7;
    return weekNumber % 2 == 0 ? WeekType.a : WeekType.b;
  }

  /// Lit l'année scolaire active depuis la base Drift locale
  /// (`school_years.alternating_week_start_date`, répliquée par le sync engine)
  /// et en déduit la semaine courante.
  static Future<WeekType?> currentWeekType(Ref? ref) async {
    try {
      final db = ref != null
          ? ref.read(databaseProvider)
          : _fallbackDatabase;
      if (db == null) return null;
      final years = await db.select(db.schoolYears).get();
      if (years.isEmpty) return null;
      final actives = years.where((y) => y.isActive).toList();
      final active = actives.isNotEmpty
          ? actives.first
          : years.reduce((a, b) => a.id > b.id ? a : b);
      return weekTypeForDate(DateTime.now(), active.alternatingWeekStartDate);
    } catch (_) {
      return null;
    }
  }

  static AppDatabase? _fallbackDatabase;

  /// Permet d'utiliser le helper sans [Ref] (tests, code impératif).
  static void registerDatabase(AppDatabase db) => _fallbackDatabase = db;
}
