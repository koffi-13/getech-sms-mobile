/// [Fix-ATTENDANCE-REVIEW] V22 — Contrôleur de CONSULTATION des présences
/// (admins / direction), 100 % servi par le cache Drift :
///
/// - sessions de cours récentes (`course_sessions`, résolues vers
///   classe/matière/enseignant via `class_subjects` + `classrooms` +
///   `subjects` + `users` — cf. [Fix-SYNC-COURSE-SESSIONS-RESOLVE]) ;
/// - absences par session (`student_absences`) et par élève ;
/// - vue par élève : total des absences (justifiées / non justifiées).
///
/// Pourquoi Drift et pas l'API : la règle métier « la présence se SAISIT
/// en connexion » ([Fix-PRESENCE-ONLINE]) reste inchangée — mais la
/// CONSULTATION par l'administration doit marcher hors-ligne (retour
/// utilisateur 2026-11-07 : « les admins ne saisissent pas de présence
/// mais affichent les présences des autres »). Le pull de synchro réplique
/// déjà `course_sessions` + `student_absences` de TOUT l'établissement
/// (sync_registry.py) : il ne restait qu'à l'afficher.
///
/// Rafraîchissement : `syncGenerationProvider` est surveillé — après
/// chaque synchro utile (reconnexion, auto-sync V15), les listes se
/// rechargent seules.
library;

import 'package:drift/drift.dart' as d;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database.dart';
import '../../core/sync/sync_engine.dart' show syncGenerationProvider;

/// Vue consolidée d'une session de cours pour la consultation.
class AttendanceSessionView {
  const AttendanceSessionView({
    required this.id,
    required this.date,
    this.startTime,
    this.endTime,
    this.state,
    required this.classroomId,
    this.classroomName,
    this.subjectName,
    this.teacherId,
    this.teacherName,
    required this.absentCount,
    required this.justifiedCount,
  });

  final int id;
  final DateTime date;
  final String? startTime; // 'HH:mm'
  final String? endTime;
  final String? state; // PENDING | COMPLETED…
  final int classroomId;
  final String? classroomName;
  final String? subjectName;
  final int? teacherId;
  final String? teacherName;
  final int absentCount;
  final int justifiedCount;

  bool get isCompleted => (state ?? '').toUpperCase() == 'COMPLETED';
}

/// Vue consolidée d'une absence d'élève (pour le détail d'une session).
class AttendanceAbsenceView {
  const AttendanceAbsenceView({
    required this.id,
    required this.studentId,
    required this.studentName,
    required this.matricule,
    required this.isJustified,
    this.reason,
  });

  final int id;
  final int studentId;
  final String studentName;
  final String? matricule;
  final bool isJustified;
  final String? reason;
}

/// Récapitulatif d'absences d'un élève (vue « par élève »).
class AttendanceStudentSummary {
  const AttendanceStudentSummary({
    required this.studentId,
    required this.studentName,
    required this.classroomName,
    required this.classroomId,
    required this.totalAbsences,
    required this.justifiedAbsences,
  });

  final int studentId;
  final String studentName;
  final String classroomName;
  final int classroomId;
  final int totalAbsences;
  final int justifiedAbsences;

  int get unjustifiedAbsences => totalAbsences - justifiedAbsences;
}

/// Paramètre : nombre de jours d'historique des sessions.
const int kAttendanceReviewWindowDays = 30;

/// Sessions récentes avec décompte d'absences — servies depuis Drift.
final attendanceSessionsProvider = FutureProvider.autoDispose<
    List<AttendanceSessionView>>((ref) async {
  // [Fix-AUTO-SYNC] rechargement après chaque synchro utile.
  ref.watch(syncGenerationProvider);
  final db = ref.read(databaseProvider);

  final since =
      DateTime.now().subtract(const Duration(days: kAttendanceReviewWindowDays));

  final sessions = await (db.select(db.courseSessions)
        ..where((t) => t.date.isBiggerOrEqual(d.Constant(since)))
        ..where((t) => t.isDeleted.equals(false))
        ..orderBy([(t) => d.OrderingTerm.desc(t.date)]))
      .get();
  if (sessions.isEmpty) return const [];

  final absences = await db.select(db.studentAbsences).get();
  final absencesBySession = <int, List<dynamic>>{};
  for (final a in absences) {
    absencesBySession.putIfAbsent(a.courseSessionId, () => []).add(a);
  }

  final classrooms = {
    for (final c in await db.select(db.classrooms).get()) c.id: c.name,
  };
  final subjects = {
    for (final s in await db.select(db.subjects).get()) s.id: s.name,
  };
  final users = await db.select(db.users).get();
  final userById = {
    for (final u in users) u.id: u,
  };

  return sessions.map((s) {
    final sessionAbsences = absencesBySession[s.id] ?? const <dynamic>[];
    final absentCount = sessionAbsences.length;
    final justifiedCount = sessionAbsences
        .whereType<dynamic>()
        .where((a) => (a.isJustified as bool?) ?? false)
        .length;
    return AttendanceSessionView(
      id: s.id,
      date: s.date,
      startTime: s.startTime,
      endTime: s.endTime,
      state: s.state,
      classroomId: s.classroomId ?? 0,
      classroomName: classrooms[s.classroomId],
      subjectName: subjects[s.subjectId],
      teacherId: s.teacherId,
      teacherName: _displayName(userById[s.teacherId]),
      absentCount: absentCount,
      justifiedCount: justifiedCount,
    );
  }).toList();
});

String? _displayName(dynamic user) {
  if (user == null) return null;
  final first = user.firstName as String?;
  final last = user.lastName as String?;
  // Convention « NOM Prénoms ». ATTENTION au mappage du pull V11 (fix
  // [Fix-SYNC-FIELD-MAP-V11], sync_engine case 'users') : la colonne Drift
  // `firstName` reçoit le `nom` de famille serveur et `lastName` reçoit
  // les `prenoms` — l'ordre d'affichage « NOM Prénoms » est donc
  // firstName PUIS lastName.
  final full = [first, last].where((p) => p != null && p.isNotEmpty).join(' ');
  return full.isEmpty ? (user.username as String?) : full;
}

/// Absences détaillées d'une session (noms d'élèves résolus localement).
final sessionAbsenceDetailsProvider = FutureProvider.autoDispose
    .family<List<AttendanceAbsenceView>, int>((ref, sessionId) async {
  ref.watch(syncGenerationProvider);
  final db = ref.read(databaseProvider);

  final absences = await (db.select(db.studentAbsences)
        ..where((t) => t.courseSessionId.equals(sessionId)))
      .get();
  if (absences.isEmpty) return const [];

  final studentIds = absences.map((a) => a.studentId).toSet();
  final students = await (db.select(db.students)
        ..where((t) => t.id.isIn(studentIds)))
      .get();
  final studentById = {
    for (final s in students) s.id: s,
  };

  final views = absences.map((a) {
    final s = studentById[a.studentId];
    final name = s == null
        ? 'Élève #${a.studentId}'
        : [s.nom, s.prenoms].where((p) => p != null && p.isNotEmpty).join(' ');
    return AttendanceAbsenceView(
      id: a.id,
      studentId: a.studentId,
      studentName: name,
      matricule: s?.matricule,
      isJustified: a.isJustified,
      reason: a.reason,
    );
  }).toList()
    ..sort((a, b) => a.studentName.compareTo(b.studentName));
  return views;
});

/// Récapitulatif d'absences par élève (toutes classes, fenêtre glissante).
final attendanceStudentSummariesProvider = FutureProvider.autoDispose<
    List<AttendanceStudentSummary>>((ref) async {
  ref.watch(syncGenerationProvider);
  final db = ref.read(databaseProvider);

  final since =
      DateTime.now().subtract(const Duration(days: kAttendanceReviewWindowDays));

  // Sessions de la fenêtre (pour ne compter que les absences récentes).
  final sessions = await (db.select(db.courseSessions)
        ..where((t) => t.date.isBiggerOrEqual(d.Constant(since)))
        ..where((t) => t.isDeleted.equals(false)))
      .get();
  if (sessions.isEmpty) return const [];
  final sessionIds = sessions.map((s) => s.id).toSet();
  final sessionClassroom = {
    for (final s in sessions) s.id: s.classroomId ?? 0,
  };

  final absences = await (db.select(db.studentAbsences)
        ..where((t) => t.courseSessionId.isIn(sessionIds.toList())))
      .get();
  if (absences.isEmpty) return const [];

  final classrooms = {
    for (final c in await db.select(db.classrooms).get()) c.id: c.name,
  };
  final studentIds = absences.map((a) => a.studentId).toSet();
  final students = await (db.select(db.students)
        ..where((t) => t.id.isIn(studentIds)))
      .get();

  final byStudent = <int, List<dynamic>>{};
  for (final a in absences) {
    byStudent.putIfAbsent(a.studentId, () => []).add(a);
  }

  final summaries = <AttendanceStudentSummary>[];
  for (final s in students) {
    final list = byStudent[s.id] ?? const <dynamic>[];
    if (list.isEmpty) continue;
    final classroomId =
        sessionClassroom[(list.first as dynamic).courseSessionId] ?? 0;
    final justified =
        list.where((a) => (a.isJustified as bool?) ?? false).length;
    final name = [s.nom, s.prenoms]
        .where((p) => p != null && p.isNotEmpty)
        .join(' ');
    summaries.add(AttendanceStudentSummary(
      studentId: s.id,
      studentName: name,
      classroomName: classrooms[classroomId] ?? '—',
      classroomId: classroomId,
      totalAbsences: list.length,
      justifiedAbsences: justified,
    ));
  }
  summaries.sort((a, b) {
    final cmp = b.totalAbsences.compareTo(a.totalAbsences);
    if (cmp != 0) return cmp;
    return a.studentName.compareTo(b.studentName);
  });
  return summaries;
});
