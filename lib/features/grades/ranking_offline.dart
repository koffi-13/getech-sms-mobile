/// [Fix-RANKING-OFFLINE] V22 — Classement hors-ligne calculé sur le cache
/// Drift (tables `grades` / `assessments` / `assessment_types` /
/// `class_subjects` / `students` / `periods`), rempli par la synchro.
///
/// Miroir EXACT de la formule serveur
/// (`GradeService._student_general_average` + `get_class_ranking`) :
///
/// - par matière : moyenne_classe = moyenne des notes de catégorie CLASS ;
///   note_composition = moyenne des notes de catégorie EXAM ;
///   moyenne_matière = (moyenne_classe + note_composition) / 2
///   (ou celle disponible s'il n'y en a qu'une) ;
/// - notes ramenées sur 20 (value / max_score × 20) ; absent = 0 ;
/// - moyenne de période = Σ(moyenne_matière × coeff) / Σ(coeff)
///   (matières facultatives exclues — mode par défaut du serveur) ;
/// - mode SUBJECT : seules la matière demandée est retenue (coeff = le
///   coefficient de la matière) ;
/// - classement par moyenne décroissante (ex-æquo : même rang + lettres
///   « 3 », « 3 B », « 3 C »…) ;
/// - périodes précédentes : moyennes globales des périodes antérieures de
///   la même année (progression) ;
/// - moyenne annuelle : pondérée par Period.weight si présent, sinon
///   moyenne arithmétique des périodes ayant des données.
///
/// Écarts documentés vs serveur (politiques d'établissement non
/// répliquées) : `establishment_grading_policies`, mode facultatives
/// BONUS/COUNTED et `use_period_weights` — les établissements configurés
/// ainsi peuvent voir une petite différence entre le classement en ligne
/// et celui recalculé hors-ligne. Le cache SharedPreferences du
/// rankingProvider (écrit à chaque consultation en ligne) reste prioritaire
/// quand il existe.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database.dart';
import '../../shared/models/grade_dto.dart';
import 'grade_controller.dart'
    show RankingMode, RankingQuery, RankingModeX;

/// Résultat du classement local + un drapeau « approximation » quand la
/// catégorie d'évaluation n'a pas pu être résolue pour au moins une note.
class OfflineRankingResult {
  const OfflineRankingResult({
    required this.rows,
    required this.anyUnknownCategory,
  });
  final List<RankingRowDto> rows;
  final bool anyUnknownCategory;
}

/// Calcule le classement d'une classe pour une période depuis le cache
/// Drift. Retourne une liste vide si le cache ne contient aucune note.
Future<OfflineRankingResult> computeRankingOffline(
  Ref ref,
  RankingQuery q,
) async {
  final db = ref.read(databaseProvider);

  // ── Contexte local ────────────────────────────────────────────────────
  final periods = await _periodsOfYear(db, q.periodId);
  final periodIds = [for (final p in periods) p.id];
  final currentIdx = periodIds.indexOf(q.periodId);
  final previousPeriodIds =
      currentIdx > 0 ? periodIds.sublist(0, currentIdx) : <int>[];

  // Élèves actifs de la classe (assignations de l'année ; les élèves
  // partis portent isDeleted=true, posé par le pull V11).
  final assignments = await (db.select(db.studentClassAssignments)
        ..where((t) => t.classroomId.equals(q.classroomId))
        ..where((t) => t.isDeleted.equals(false)))
      .get();
  final studentIds = assignments.map((a) => a.studentId).toSet();
  if (studentIds.isEmpty) {
    return const OfflineRankingResult(rows: [], anyUnknownCategory: false);
  }
  final studentsRows = await (db.select(db.students)
        ..where((t) => t.id.isIn(studentIds))
        ..where((t) => t.isDeleted.equals(false)))
      .get();
  final students = {
    for (final s in studentsRows) s.id: s,
  };

  // Matières de la classe (mode SUBJECT : filtrage sur la matière demandée).
  final classSubjects = await (db.select(db.classSubjects)
        ..where((t) => t.classroomId.equals(q.classroomId))
        ..where((t) => t.isDeleted.equals(false)))
      .get();
  final effectiveCs = (q.rankingMode == RankingMode.subject && q.subjectId != null)
      ? classSubjects.where((c) => c.subjectId == q.subjectId).toList()
      : classSubjects;
  if (effectiveCs.isEmpty) {
    return const OfflineRankingResult(rows: [], anyUnknownCategory: false);
  }

  // Référentiel des catégories d'évaluation.
  final typeRows = await db.select(db.assessmentTypes).get();
  final categoryByTypeId = {
    for (final t in typeRows) t.id: t.category.toUpperCase(),
  };

  // Évaluations + notes (toutes périodes nécessaires en UNE passe).
  final csIds = [for (final cs in effectiveCs) cs.id];
  final neededPeriods = {...periodIds, q.periodId, ...previousPeriodIds};
  final assessments = await (db.select(db.assessments)
        ..where((t) => t.classSubjectId.isIn(csIds))
        ..where((t) => t.periodId.isIn(neededPeriods.toList()))
        ..where((t) => t.isDeleted.equals(false)))
      .get();
  final assessmentIds = [for (final a in assessments) a.id];
  final grades = assessmentIds.isEmpty
      ? const <Grade>[]
      : await (db.select(db.grades)
            ..where((t) => t.assessmentId.isIn(assessmentIds))
            ..where((t) => t.isDeleted.equals(false)))
          .get();

  // Index : assessmentId → {assessment, catégorie}
  final assessmentById = {
    for (final a in assessments) a.id: a,
  };
  final gradesByStudent = <int, List<Grade>>{};
  for (final g in grades) {
    gradesByStudent.putIfAbsent(g.studentId, () => []).add(g);
  }

  var anyUnknownCategory = false;

  // ── Moyenne d'un élève pour une période (miroir serveur) ──────────────
  double? studentPeriodAverage(int studentId, int periodId) {
    final List<(double note, double coeff)> classNotes = [];
    final List<(double note, double coeff)> examNotes = [];
    final studentsGrades = gradesByStudent[studentId] ?? const <Grade>[];

    for (final cs in effectiveCs) {
      for (final g in studentsGrades) {
        final a = assessmentById[g.assessmentId];
        if (a == null || a.classSubjectId != cs.id) continue;
        if ((a.periodId ?? -1) != periodId) continue;
        if (g.value == null) continue;

        final maxScore = a.maxScore <= 0 ? 20.0 : a.maxScore;
        final note = g.isAbsent
            ? 0.0
            : (g.value! / maxScore) * 20.0;

        // Catégorie : référentiel local → repli sur le champ `type`
        // (code d'évaluation, ex. DEVOIR/COMPO) → inconnue.
        var category = a.assessmentTypeId == null
            ? null
            : categoryByTypeId[a.assessmentTypeId];
        if (category == null) {
          category = _categoryFromLegacyType(a.type);
          if (category == null) anyUnknownCategory = true;
        }
        final coeff = cs.coefficient <= 0 ? 1.0 : cs.coefficient;
        if (category == 'EXAM') {
          examNotes.add((note, coeff));
        } else {
          // CLASS par défaut (l'inconnue est traitée comme CLASS).
          classNotes.add((note, coeff));
        }
      }
    }

    // Agrégation miroir serveur : (moy_classe + moy_exam) / 2 par matière,
    // puis Σ(moy_matière × coeff) / Σ(coeff). Ici l'agrégation est faite
    // sur TOUTES les matières d'un coup (le serveur procède par matière
    // puis pondère : pour la moyenne PÉRIODE les deux formules coïncident
    // quand chaque matière utilise la même liste de coefficients ; on
    // conserve la pondération par coeff de matière).
    double? classAvg = _weightedAverage(classNotes);
    double? examAvg = _weightedAverage(examNotes);

    double? periodAvg;
    if (classAvg != null && examAvg != null) {
      periodAvg = (classAvg + examAvg) / 2;
    } else if (classAvg != null) {
      periodAvg = classAvg;
    } else {
      periodAvg = examAvg;
    }
    return periodAvg;
  }

  // Moyenne pondérée globalement (toutes matières) — utilisée pour le
  // rendu de la moyenne de PÉRIODE en mode PERIOD.
  double? studentWeightedPeriodAverage(int studentId, int periodId) {
    final subjectAvgs = <(double avg, double coeff)>[];
    final studentsGrades = gradesByStudent[studentId] ?? const <Grade>[];

    for (final cs in effectiveCs) {
      final classNotes = <(double, double)>[];
      final examNotes = <(double, double)>[];
      for (final g in studentsGrades) {
        final a = assessmentById[g.assessmentId];
        if (a == null || a.classSubjectId != cs.id) continue;
        if ((a.periodId ?? -1) != periodId) continue;
        if (g.value == null) continue;
        final maxScore = a.maxScore <= 0 ? 20.0 : a.maxScore;
        final note = g.isAbsent ? 0.0 : (g.value! / maxScore) * 20.0;
        var category = a.assessmentTypeId == null
            ? null
            : categoryByTypeId[a.assessmentTypeId];
        if (category == null) {
          category = _categoryFromLegacyType(a.type);
          if (category == null) anyUnknownCategory = true;
        }
        final coeff = cs.coefficient <= 0 ? 1.0 : cs.coefficient;
        if (category == 'EXAM') {
          examNotes.add((note, coeff));
        } else {
          classNotes.add((note, coeff));
        }
      }
      final classAvg = _weightedAverage(classNotes);
      final examAvg = _weightedAverage(examNotes);
      double? subjectAvg;
      if (classAvg != null && examAvg != null) {
        subjectAvg = (classAvg + examAvg) / 2;
      } else if (classAvg != null) {
        subjectAvg = classAvg;
      } else {
        subjectAvg = examAvg;
      }
      if (subjectAvg != null) {
        subjectAvgs.add((subjectAvg, cs.coefficient <= 0 ? 1.0 : cs.coefficient));
      }
    }
    return _weightedAverage(subjectAvgs);
  }

  // ── Lignes du classement ──────────────────────────────────────────────
  final rows = <RankingRowDto>[];
  for (final s in students.values) {
    final average =
        q.rankingMode == RankingMode.subject && q.subjectId != null
            ? studentPeriodAverage(s.id, q.periodId)
            : studentWeightedPeriodAverage(s.id, q.periodId);

    // Périodes précédentes (progression) + moyenne annuelle.
    final previousAverages = <int, double>{};
    for (final pid in previousPeriodIds) {
      final avg = studentWeightedPeriodAverage(s.id, pid);
      if (avg != null) previousAverages[pid] = avg;
    }
    double? annualAverage;
    if (periodIds.isNotEmpty) {
      final annual = <(double avg, double? weight)>[];
      for (final p in periods) {
        final avg = studentWeightedPeriodAverage(s.id, p.id);
        if (avg != null) annual.add((avg, p.weight));
      }
      if (annual.isNotEmpty) {
        final hasWeights =
            annual.any((e) => e.$2 != null && e.$2! > 0);
        if (hasWeights) {
          var tw = 0.0;
          var tc = 0.0;
          for (final (avg, w) in annual) {
            final eff = (w == null || w <= 0) ? 1.0 : w;
            tw += avg * eff;
            tc += eff;
          }
          annualAverage = tc > 0 ? tw / tc : null;
        } else {
          annualAverage =
              annual.map((e) => e.$1).reduce((a, b) => a + b) / annual.length;
        }
      }
    }

    rows.add(RankingRowDto(
      studentId: s.id,
      nom: s.nom,
      prenoms: s.prenoms ?? '',
      matricule: s.matricule,
      sexe: s.sexe,
      average: average,
      rankingMode: q.rankingMode.serverValue,
      subjectId: q.subjectId,
      previousPeriodAverages: previousAverages,
      annualAverage: annualAverage,
    ));
  }

  if (rows.every((r) => r.average == null)) {
    // Aucune note en cache pour cette classe/période.
    return OfflineRankingResult(rows: [], anyUnknownCategory: anyUnknownCategory);
  }

  // ── Tri + rangs (ex-æquo, miroir serveur) ─────────────────────────────
  rows.sort((a, b) {
    int cmp;
    if (a.average != null && b.average != null) {
      cmp = b.average!.compareTo(a.average!);
    } else if (a.average != null) {
      cmp = -1;
    } else if (b.average != null) {
      cmp = 1;
    } else {
      cmp = 0;
    }
    if (cmp != 0) return cmp;
    cmp = a.nom.compareTo(b.nom);
    if (cmp != 0) return cmp;
    return a.prenoms.compareTo(b.prenoms);
  });

  const letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  var rank = 1;
  var i = 0;
  final out = <RankingRowDto>[];
  while (i < rows.length) {
    final avg = rows[i].average;
    if (avg == null) {
      // Aucune note : rang 0 (l'UI affiche l'index+1 en repli).
      out.add(rows[i]);
      i++;
      continue;
    }
    var j = i;
    while (j < rows.length &&
        rows[j].average != null &&
        rows[j].average == avg) {
      j++;
    }
    final count = j - i;
    for (var k = 0; k < count; k++) {
      final label = count == 1
          ? '$rank'
          : '$rank ${letters[k % letters.length]}';
      out.add(RankingRowDto(
        rank: rank,
        rankLabel: label,
        studentId: rows[i + k].studentId,
        nom: rows[i + k].nom,
        prenoms: rows[i + k].prenoms,
        matricule: rows[i + k].matricule,
        sexe: rows[i + k].sexe,
        average: rows[i + k].average,
        classAvg: rows[i + k].classAvg,
        rankingMode: rows[i + k].rankingMode,
        subjectId: rows[i + k].subjectId,
        previousPeriodAverages: rows[i + k].previousPeriodAverages,
        annualAverage: rows[i + k].annualAverage,
      ));
    }
    rank += count;
    i = j;
  }

  return OfflineRankingResult(rows: out, anyUnknownCategory: anyUnknownCategory);
}

/// Périodes de l'année scolaire contenant `periodId`, triées par id
/// (le serveur trie par position dans l'année : les ids suivent l'ordre de
/// création des périodes dans GeTech-SMS).
Future<List<Period>> _periodsOfYear(AppDatabase db, int periodId) async {
  final current = await (db.select(db.periods)
        ..where((t) => t.id.equals(periodId)))
      .getSingleOrNull();
  if (current == null) return const [];
  final rows = await (db.select(db.periods)
        ..where((t) => t.schoolYearId.equals(current.schoolYearId!))
        ..where((t) => t.isDeleted.equals(false)))
      .get();
  rows.sort((a, b) => a.id.compareTo(b.id));
  return rows;
}

double? _weightedAverage(List<(double note, double coeff)> notes) {
  if (notes.isEmpty) return null;
  var tw = 0.0;
  var tc = 0.0;
  for (final (note, coeff) in notes) {
    tw += note * coeff;
    tc += coeff;
  }
  return tc > 0 ? tw / tc : null;
}

/// Catégorie déduite du champ legacy `type` (code d'évaluation envoyé
/// historiquement). Miroir des codes canoniques du seed serveur
/// (scripts/seed_assessment_types.py) : DEVOIR/INTERRO/PROJET/
/// CONTROLE_CONTINU → CLASS ; COMPO/EXAMEN → EXAM.
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
