/// [Fix-BULLETIN-OFFLINE] V23 — Bulletin d'un élève calculé sur le cache
/// Drift (tables `grades` / `assessments` / `assessment_types` /
/// `class_subjects` / `subjects` / `students` / `periods` / `student_absences`),
/// rempli par la synchro.
///
/// Miroir de `GradeService.get_student_bulletin` (serveur) :
/// - par matière : moyenne_classe (notes CLASS) + note_composition
///   (notes EXAM) → moyenne_matière = (moy_classe + compo) / 2 (ou celle
///   disponible), notes ramenées sur 20, absent = 0 ;
/// - moyenne générale = Σ(moyenne_matière × coeff) / Σ(coeff) — matières
///   facultatives exclues (mode serveur par défaut) ;
/// - rang : position de l'élève dans le classement de la classe
///   (calcul via [computeRankingOffline], ex-æquo inclus) ;
/// - mention : mêmes seuils que le serveur (Excellent ≥18, Très Bien ≥16,
///   Bien ≥14, Assez Bien ≥12, Passable ≥10, Insuffisant <10) ;
/// - absences : décompte des absences de la période (sessions datées dans
///   l'intervalle start/end de la période, best-effort).
///
/// Écarts documentés (idem ranking_offline.dart) : politiques
/// d'établissement non répliquées (BONUS/COUNTED des facultatives,
/// use_period_weights). Le bulletin en ligne reste la référence quand le
/// serveur répond.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database.dart';
import '../../shared/models/grade_dto.dart';
import 'grade_controller.dart'
    show BulletinQuery, RankingMode, RankingQuery, RankingModeX;
import 'ranking_offline.dart';

/// Mention miroir de `GradeService.get_mention`.
String? mentionForAverage(double? average) {
  if (average == null) return null;
  if (average >= 18) return 'Excellent';
  if (average >= 16) return 'Très Bien';
  if (average >= 14) return 'Bien';
  if (average >= 12) return 'Assez Bien';
  if (average >= 10) return 'Passable';
  return 'Insuffisant';
}

/// Construit le bulletin hors-ligne. Retourne null si l'élève/la classe/la
/// période sont inconnus du cache OU qu'aucune note n'existe (l'appelant
/// affiche alors le message historique « aucune donnée en cache »).
Future<BulletinDto?> computeBulletinOffline(
  Ref ref,
  BulletinQuery q,
) async {
  final db = ref.read(databaseProvider);

  // ── Contexte ───────────────────────────────────────────────────────────
  final student = await (db.select(db.students)
        ..where((t) => t.id.equals(q.studentId)))
      .getSingleOrNull();
  if (student == null) return null;
  final period = await (db.select(db.periods)
        ..where((t) => t.id.equals(q.periodId)))
      .getSingleOrNull();
  if (period == null) return null;
  final classroom = await (db.select(db.classrooms)
        ..where((t) => t.id.equals(q.classroomId)))
      .getSingleOrNull();

  // Classement local (rang + effectif) — réutilise le miroir serveur.
  final ranking = await computeRankingOffline(
    ref,
    RankingQuery(
      classroomId: q.classroomId,
      periodId: q.periodId,
      rankingMode: RankingMode.period,
    ),
  );
  final rankingRow = ranking.rows
      .where((r) => r.studentId == q.studentId)
      .firstOrNull;
  // Aucune note nulle part → pas de bulletin hors-ligne exploitable.
  if (ranking.rows.isEmpty || rankingRow == null) return null;

  // ── Matières du bulletin ───────────────────────────────────────────────
  final classSubjects = await (db.select(db.classSubjects)
        ..where((t) => t.classroomId.equals(q.classroomId))
        ..where((t) => t.isDeleted.equals(false)))
      .get();
  final subjects = {
    for (final s in await db.select(db.subjects).get()) s.id: s,
  };
  final users = await db.select(db.users).get();
  final userById = {for (final u in users) u.id: u};

  final typeRows = await db.select(db.assessmentTypes).get();
  final categoryByTypeId = {
    for (final t in typeRows) t.id: t.category.toUpperCase(),
  };

  final csIds = [for (final cs in classSubjects) cs.id];
  final assessments = csIds.isEmpty
      ? const <Assessment>[]
      : await (db.select(db.assessments)
            ..where((t) => t.classSubjectId.isIn(csIds))
            ..where((t) => t.periodId.equals(q.periodId))
            ..where((t) => t.isDeleted.equals(false)))
          .get();
  final assessmentIds = [for (final a in assessments) a.id];
  final grades = assessmentIds.isEmpty
      ? const <Grade>[]
      : await (db.select(db.grades)
            ..where((t) => t.assessmentId.isIn(assessmentIds))
            ..where((t) => t.studentId.equals(q.studentId))
            ..where((t) => t.isDeleted.equals(false)))
          .get();
  final gradesByAssessment = {
    for (final g in grades) g.assessmentId: g,
  };

  final subjectDtos = <BulletinSubjectDto>[];
  for (final cs in classSubjects) {
    final subject = subjects[cs.subjectId];
    final teacher = cs.teacherId == null ? null : userById[cs.teacherId];
    // Convention « NOM Prénoms » : cf. [Fix-SYNC-FIELD-MAP-V11] —
    // firstName reçoit `nom`, lastName reçoit `prenoms`.
    final teacherName = teacher == null
        ? null
        : [teacher.firstName, teacher.lastName]
            .where((p) => p != null && p.isNotEmpty)
            .join(' ');

    final classNotes = <double>[];
    final examNotes = <double>[];
    final assessmentDtos = <BulletinAssessmentDto>[];

    for (final a in assessments.where((a) => a.classSubjectId == cs.id)) {
      final g = gradesByAssessment[a.id];
      final maxScore = a.maxScore <= 0 ? 20.0 : a.maxScore;
      final note = g == null || g.value == null
          ? null
          : (g.isAbsent ? 0.0 : (g.value! / maxScore) * 20.0);
      var category = a.assessmentTypeId == null
          ? null
          : categoryByTypeId[a.assessmentTypeId];
      if (category == null) {
        category = _categoryFromLegacyType(a.type);
      }
      if (note != null) {
        if (category == 'EXAM') {
          examNotes.add(note);
        } else {
          classNotes.add(note);
        }
      }
      assessmentDtos.add(BulletinAssessmentDto(
        name: a.title,
        type: a.type,
        maxScore: a.maxScore,
        value: g?.value,
        isAbsent: g?.isAbsent ?? false,
        date: a.date?.toIso8601String().substring(0, 10),
      ));
    }

    final moyenneClasse = classNotes.isEmpty
        ? null
        : classNotes.reduce((a, b) => a + b) / classNotes.length;
    final noteComposition = examNotes.isEmpty
        ? null
        : examNotes.reduce((a, b) => a + b) / examNotes.length;
    double? subjectAvg;
    if (moyenneClasse != null && noteComposition != null) {
      subjectAvg = (moyenneClasse + noteComposition) / 2;
    } else if (moyenneClasse != null) {
      subjectAvg = moyenneClasse;
    } else {
      subjectAvg = noteComposition;
    }

    subjectDtos.add(BulletinSubjectDto(
      subjectId: cs.subjectId,
      subjectName: subject?.name ?? 'Matière #${cs.subjectId}',
      subjectCode: subject?.code,
      coefficient: cs.coefficient.round(),
      teacher: teacherName,
      average: subjectAvg,
      moyenneClasse: moyenneClasse,
      noteComposition: noteComposition,
      assessments: assessmentDtos,
      mention: mentionForAverage(subjectAvg),
    ));
  }

  // ── Absences de la période (best-effort : sessions dans l'intervalle) ──
  int? absencesCount;
  try {
    final absences = await (db.select(db.studentAbsences)
          ..where((t) => t.studentId.equals(q.studentId)))
        .get();
    if (absences.isNotEmpty && period.startDate != null) {
      // Résolution des sessions pour filtrer par date de période.
      final sessionIds = absences.map((a) => a.courseSessionId).toSet();
      final sessions = sessionIds.isEmpty
          ? const <CourseSession>[]
          : await (db.select(db.courseSessions)
                ..where((t) => t.id.isIn(sessionIds.toList())))
              .get();
      final start = period.startDate!;
      final end = period.endDate ?? DateTime.now();
      absencesCount = absences
          .where((a) {
            final s =
                sessions.where((x) => x.id == a.courseSessionId).firstOrNull;
            return s != null &&
                !s.date.isBefore(start) &&
                (end == null || !s.date.isAfter(end));
          })
          .length;
    }
  } catch (_) {
    // Décompte best-effort : hors périmètre d'un échec du bulletin.
  }

  return BulletinDto(
    studentId: student.id,
    nom: student.nom,
    prenoms: student.prenoms ?? '',
    matricule: student.matricule,
    sexe: student.sexe,
    classroomName: classroom?.name ?? '',
    periodName: period.name,
    overallAverage: rankingRow.average,
    rank: rankingRow.rankLabel ?? '${rankingRow.rank}',
    totalStudents: ranking.rows.length,
    mention: mentionForAverage(rankingRow.average),
    subjects: subjectDtos,
    absencesCount: absencesCount,
  );
}

/// Catégorie déduite du champ legacy `type` (miroir ranking_offline.dart).
String? _categoryFromLegacyType(String? type) {
  if (type == null || type.isEmpty) return null;
  switch (type.toUpperCase()) {
    case 'COMPO':
    case 'COMPOSITION':
    case 'EXAMEN':
    case 'EXAM':
      return 'EXAM';
    case 'DEVOIR':
    case 'INTERRO':
    case 'INTERROGATION':
    case 'PROJET':
    case 'CONTROLE_CONTINU':
      return 'CLASS';
    default:
      return null;
  }
}
