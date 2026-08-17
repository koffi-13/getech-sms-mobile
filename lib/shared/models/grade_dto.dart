/// DTOs Notes & Évaluations — alignés sur les schémas Pydantic du desktop.
///
/// Points clés du contrat serveur :
/// - `AssessmentResponse` : `name` (pas `title`), `assessment_type_id`/`name`/`category`,
///   `date_taken`, `is_counted_on_bulletin`, `grades_entered_count`, `total_students`.
/// - `GradeEntryResponse` : `value`, `is_absent`, `comment` (singulier), `is_locked`.
/// - `GradeBulkSaveResponse` : `{saved_count, skipped_count}`.
/// - `GradeResponse` : `score` (pas `value`).
/// - Ranking : `list[dict]` avec clés `{rank, student_id, student_name, matricule,
///   average, previous_period_averages, annual_average}`.
/// - Bulletin : `dict` avec `{student, subjects[], overall_average, rank, total_students}`.
library;

import '../../core/config/constants.dart';
import '../../core/utils/formatters.dart';

/// Évaluation (AssessmentResponse côté serveur).
class AssessmentDto {
  final int id;
  final String name; // serveur: "name" (pas "title")
  final int assessmentTypeId;
  final String assessmentTypeName;
  final String assessmentTypeCategory;
  final double maxScore;
  final String? dateTaken; // serveur: "date_taken" (string)
  final bool isCountedOnBulletin;
  final int gradesEnteredCount;
  final int totalStudents;
  // Champs de compatibilité (pour le mobile, non dans la réponse de base)
  final int? classSubjectId;
  final int? periodId;
  final String? periodName;
  final double coefficient;

  const AssessmentDto({
    required this.id,
    this.name = '',
    this.assessmentTypeId = 0,
    this.assessmentTypeName = '',
    this.assessmentTypeCategory = '',
    this.maxScore = defaultMaxScore,
    this.dateTaken,
    this.isCountedOnBulletin = true,
    this.gradesEnteredCount = 0,
    this.totalStudents = 0,
    this.classSubjectId,
    this.periodId,
    this.periodName,
    this.coefficient = 1.0,
  });

  /// Alias de compatibilité : title = name.
  String get title => name;
  /// Alias de compatibilité : date = dateTaken (parsé).
  DateTime? get date => DateFormatter.parse(dateTaken);
  /// Alias de compatibilité.
  AssessmentType get type => AssessmentType.values.firstWhere(
        (t) => t.code == assessmentTypeName.toUpperCase(),
        orElse: () => AssessmentType.devoir,
      );

  factory AssessmentDto.fromJson(Map<String, dynamic> j) => AssessmentDto(
        id: (j['id'] as num).toInt(),
        name: j['name'] as String? ?? '',
        assessmentTypeId: (j['assessment_type_id'] as num?)?.toInt() ?? 0,
        assessmentTypeName: j['assessment_type_name'] as String? ?? '',
        assessmentTypeCategory: j['assessment_type_category'] as String? ?? '',
        maxScore: (j['max_score'] as num?)?.toDouble() ?? defaultMaxScore,
        dateTaken: j['date_taken'] as String?,
        isCountedOnBulletin: (j['is_counted_on_bulletin'] as bool?) ?? true,
        gradesEnteredCount: (j['grades_entered_count'] as num?)?.toInt() ?? 0,
        totalStudents: (j['total_students'] as num?)?.toInt() ?? 0,
        classSubjectId: (j['class_subject_id'] as num?)?.toInt(),
        periodId: (j['period_id'] as num?)?.toInt(),
        periodName: j['period_name'] as String?,
        coefficient: (j['coefficient'] as num?)?.toDouble() ?? 1.0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'assessment_type_id': assessmentTypeId,
        'assessment_type_name': assessmentTypeName,
        'assessment_type_category': assessmentTypeCategory,
        'max_score': maxScore,
        'date_taken': dateTaken,
        'is_counted_on_bulletin': isCountedOnBulletin,
        'grades_entered_count': gradesEnteredCount,
        'total_students': totalStudents,
        'class_subject_id': classSubjectId,
        'period_id': periodId,
        'period_name': periodName,
        'coefficient': coefficient,
      };
}

/// Requête de création d'évaluation (AssessmentCreateRequest côté serveur).
class AssessmentCreateRequest {
  final int classSubjectId;
  final int periodId;
  final String name;
  final int assessmentTypeId;
  final double maxScore;
  final String? dateTaken;

  const AssessmentCreateRequest({
    required this.classSubjectId,
    required this.periodId,
    required this.name,
    required this.assessmentTypeId,
    this.maxScore = defaultMaxScore,
    this.dateTaken,
  });

  Map<String, dynamic> toJson() => {
        'class_subject_id': classSubjectId,
        'period_id': periodId,
        'name': name,
        'assessment_type_id': assessmentTypeId,
        'max_score': maxScore,
        'date_taken': dateTaken,
      };
}

/// Note d'un élève pour une évaluation (GradeEntryResponse côté serveur).
///
/// Champs serveur : {student_id, student_name, student_matricule, grade_id,
/// value, is_absent, comment, is_locked}.
class GradeEntryDto {
  final int studentId;
  final String studentName;
  final String studentMatricule;
  final int? gradeId;
  final double? value;
  final bool isAbsent;
  final String? comment; // serveur: "comment" (singulier)
  final bool isLocked;

  const GradeEntryDto({
    required this.studentId,
    this.studentName = '',
    this.studentMatricule = '',
    this.gradeId,
    this.value,
    this.isAbsent = false,
    this.comment,
    this.isLocked = false,
  });

  factory GradeEntryDto.fromJson(Map<String, dynamic> j) => GradeEntryDto(
        studentId: (j['student_id'] as num).toInt(),
        studentName: j['student_name'] as String? ?? '',
        studentMatricule: j['student_matricule'] as String? ?? '',
        gradeId: (j['grade_id'] as num?)?.toInt(),
        value: (j['value'] as num?)?.toDouble(),
        isAbsent: (j['is_absent'] as bool?) ?? false,
        comment: j['comment'] as String?,
        isLocked: (j['is_locked'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'student_id': studentId,
        'student_name': studentName,
        'student_matricule': studentMatricule,
        'grade_id': gradeId,
        'value': value,
        'is_absent': isAbsent,
        'comment': comment,
        'is_locked': isLocked,
      };
}

/// Requête de sauvegarde en lot des notes (GradeBulkSaveRequest).
class SaveGradesRequest {
  final List<Map<String, dynamic>> grades;

  const SaveGradesRequest({required this.grades});

  Map<String, dynamic> toJson() => {'grades': grades};
}

/// Réponse de sauvegarde en lot (GradeBulkSaveResponse).
class SaveGradesResponse {
  final int savedCount;
  final int skippedCount;

  const SaveGradesResponse({this.savedCount = 0, this.skippedCount = 0});

  factory SaveGradesResponse.fromJson(Map<String, dynamic> j) => SaveGradesResponse(
        savedCount: (j['saved_count'] as num?)?.toInt() ?? 0,
        skippedCount: (j['skipped_count'] as num?)?.toInt() ?? 0,
      );
}

/// DTO de compatibilité pour une note individuelle (utilisé dans l'UI de saisie).
class GradeDto {
  final int? id;
  final int assessmentId;
  final int studentId;
  final String studentName;
  final String? matricule;
  final double? value;
  final bool isAbsent;
  final String? comments;
  final bool isLocked;

  const GradeDto({
    this.id,
    required this.assessmentId,
    required this.studentId,
    required this.studentName,
    this.matricule,
    this.value,
    this.isAbsent = false,
    this.comments,
    this.isLocked = false,
  });

  double? get effectiveValue => isAbsent ? null : value;

  factory GradeDto.fromJson(Map<String, dynamic> j) => GradeDto(
        id: (j['id'] as num?)?.toInt(),
        assessmentId: (j['assessment_id'] as num?)?.toInt() ?? 0,
        studentId: (j['student_id'] as num).toInt(),
        studentName: j['student_name'] as String? ?? '',
        matricule: j['student_matricule'] as String? ?? j['matricule'] as String?,
        value: (j['value'] as num?)?.toDouble() ?? (j['score'] as num?)?.toDouble(),
        isAbsent: (j['is_absent'] as bool?) ?? false,
        comments: j['comment'] as String? ?? j['comments'] as String?,
        isLocked: (j['is_locked'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'assessment_id': assessmentId,
        'student_id': studentId,
        'student_name': studentName,
        'student_matricule': matricule,
        'value': value,
        'is_absent': isAbsent,
        'comment': comments,
        'is_locked': isLocked,
      };
}

/// Ligne de classement (dict renvoyé par `GET /grades/ranking`).
///
/// ⚠️ Aligné sur la vraie structure du desktop (grade_service.get_class_ranking) :
/// {student_id, nom, prenoms, matricule, sexe, average, class_avg, exam_avg,
///  weighted_period_avg, weighted_max_score, ranking_mode, subject_id,
///  inscription_type_id, student_status_id, previous_period_averages (Map
///  {period_id: avg}), annual_average}.
///
/// Note : le rang (`rank`) n'est PAS dans la réponse serveur — il est calculé
/// par la position dans la liste (déjà triée par moyenne décroissante).
class RankingRowDto {
  final int rank;
  final int studentId;
  final String nom;
  final String prenoms;
  final String? matricule;
  final String? sexe;
  final double? average;
  final double? classAvg;
  final double? examAvg;
  final double? weightedPeriodAvg;
  final double? weightedMaxScore;
  final String? rankingMode;
  final int? subjectId;
  final int? inscriptionTypeId;
  final int? studentStatusId;
  final Map<int, double> previousPeriodAverages;
  final double? annualAverage;

  const RankingRowDto({
    this.rank = 0,
    required this.studentId,
    this.nom = '',
    this.prenoms = '',
    this.matricule,
    this.sexe,
    this.average,
    this.classAvg,
    this.examAvg,
    this.weightedPeriodAvg,
    this.weightedMaxScore,
    this.rankingMode,
    this.subjectId,
    this.inscriptionTypeId,
    this.studentStatusId,
    this.previousPeriodAverages = const {},
    this.annualAverage,
  });

  /// Nom complet = prenoms + nom.
  String get studentName =>
      [prenoms, nom].where((s) => s.isNotEmpty).join(' ');

  /// Progression vs dernière période précédente.
  double get progression {
    if (previousPeriodAverages.isEmpty || average == null) return 0;
    final lastPrev = previousPeriodAverages.values.last;
    return average! - lastPrev;
  }

  factory RankingRowDto.fromJson(Map<String, dynamic> j) {
    // previous_period_averages peut être un Map {period_id: avg} ou une List.
    final ppa = j['previous_period_averages'];
    Map<int, double> ppaMap = {};
    if (ppa is Map) {
      ppa.forEach((k, v) {
        if (v is num) ppaMap[int.tryParse(k.toString()) ?? 0] = v.toDouble();
      });
    } else if (ppa is List) {
      for (var i = 0; i < ppa.length; i++) {
        if (ppa[i] is num) ppaMap[i + 1] = (ppa[i] as num).toDouble();
      }
    }
    return RankingRowDto(
      rank: (j['rank'] as num?)?.toInt() ?? 0,
      studentId: (j['student_id'] as num).toInt(),
      nom: j['nom'] as String? ?? '',
      prenoms: j['prenoms'] as String? ?? '',
      matricule: j['matricule'] as String?,
      sexe: j['sexe'] as String?,
      average: (j['average'] as num?)?.toDouble(),
      classAvg: (j['class_avg'] as num?)?.toDouble(),
      examAvg: (j['exam_avg'] as num?)?.toDouble(),
      weightedPeriodAvg: (j['weighted_period_avg'] as num?)?.toDouble(),
      weightedMaxScore: (j['weighted_max_score'] as num?)?.toDouble(),
      rankingMode: j['ranking_mode'] as String?,
      subjectId: (j['subject_id'] as num?)?.toInt(),
      inscriptionTypeId: (j['inscription_type_id'] as num?)?.toInt(),
      studentStatusId: (j['student_status_id'] as num?)?.toInt(),
      previousPeriodAverages: ppaMap,
      annualAverage: (j['annual_average'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'rank': rank,
        'student_id': studentId,
        'nom': nom,
        'prenoms': prenoms,
        'matricule': matricule,
        'sexe': sexe,
        'average': average,
        'class_avg': classAvg,
        'exam_avg': examAvg,
        'weighted_period_avg': weightedPeriodAvg,
        'weighted_max_score': weightedMaxScore,
        'ranking_mode': rankingMode,
        'subject_id': subjectId,
        'inscription_type_id': inscriptionTypeId,
        'student_status_id': studentStatusId,
        'previous_period_averages': previousPeriodAverages,
        'annual_average': annualAverage,
      };
}

/// Bulletin d'un élève (dict renvoyé par `GET /grades/bulletin/{student_id}`).
///
/// ⚠️ Aligné sur la vraie structure du desktop (grade_service.get_student_bulletin) :
/// {student: {id, nom, prenoms, matricule, sexe, status_label},
///  subjects: [{subject_id, subject_name, subject_code, domain, coefficient,
///   is_facultative, teacher, average, moyenne_classe, note_composition,
///   class_average, assessments[], mention, is_from_previous_grade}],
///  overall_average, rank (string avec ex-æquo!), total_students, mention}.
class BulletinDto {
  final int studentId;
  final String nom;
  final String prenoms;
  final String? matricule;
  final String? sexe;
  final String? statusLabel;
  final String classroomName;
  final String periodName;
  final String? schoolYearName;
  final double? overallAverage;
  final String? rank; // string avec ex-æquo (ex: "2 A")
  final int? totalStudents;
  final String? mention;
  final List<BulletinSubjectDto> subjects;
  // Champs optionnels (honors / conduite — pas encore dans l'API de base)
  final BulletinHonorsDto? honors;
  final String? conduct;
  final int? absencesCount;
  final int? delaysCount;
  final String? appreciation;

  const BulletinDto({
    required this.studentId,
    this.nom = '',
    this.prenoms = '',
    this.matricule,
    this.sexe,
    this.statusLabel,
    this.classroomName = '',
    this.periodName = '',
    this.schoolYearName,
    this.overallAverage,
    this.rank,
    this.totalStudents,
    this.mention,
    this.subjects = const [],
    this.honors,
    this.conduct,
    this.absencesCount,
    this.delaysCount,
    this.appreciation,
  });

  /// Nom complet = prenoms + nom.
  String get studentName =>
      [prenoms, nom].where((s) => s.isNotEmpty).join(' ');

  /// Alias de compatibilité.
  double get generalAverage => overallAverage ?? 0;

  factory BulletinDto.fromJson(Map<String, dynamic> j) {
    final student = j['student'] as Map<String, dynamic>? ?? {};
    return BulletinDto(
      studentId: (student['id'] as num?)?.toInt() ??
          (j['student_id'] as num?)?.toInt() ??
          0,
      nom: student['nom'] as String? ?? j['nom'] as String? ?? '',
      prenoms: student['prenoms'] as String? ?? j['prenoms'] as String? ?? '',
      matricule: student['matricule'] as String? ?? j['matricule'] as String?,
      sexe: student['sexe'] as String? ?? j['sexe'] as String?,
      statusLabel: student['status_label'] as String?,
      classroomName: j['classroom_name'] as String? ?? '',
      periodName: j['period_name'] as String? ?? '',
      schoolYearName: j['school_year_name'] as String?,
      overallAverage: (j['overall_average'] as num?)?.toDouble() ??
          (j['general_average'] as num?)?.toDouble(),
      rank: j['rank']?.toString(),
      totalStudents: (j['total_students'] as num?)?.toInt(),
      mention: j['mention'] as String?,
      subjects: (j['subjects'] as List?)
              ?.map((e) =>
                  BulletinSubjectDto.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      honors: j['honors'] == null
          ? null
          : BulletinHonorsDto.fromJson(j['honors'] as Map<String, dynamic>),
      conduct: j['conduct'] as String?,
      absencesCount: (j['absences_count'] as num?)?.toInt(),
      delaysCount: (j['delays_count'] as num?)?.toInt(),
      appreciation: j['appreciation'] as String?,
    );
  }
}

/// Honneurs / distinctions d'un bulletin (StudentBulletinHonors côté desktop).
///
/// Non encore retournés par l'API de base, mais le modèle existe côté serveur
/// et sera intégré. L'UI mobile les affiche si présents.
class BulletinHonorsDto {
  final bool honorRoll;
  final bool encouragement;
  final bool congratulations;
  final bool warningBlame;
  final int absencesCount;
  final int delaysCount;

  const BulletinHonorsDto({
    this.honorRoll = false,
    this.encouragement = false,
    this.congratulations = false,
    this.warningBlame = false,
    this.absencesCount = 0,
    this.delaysCount = 0,
  });

  /// Indique s'il y a au moins une distinction.
  bool get hasAny =>
      honorRoll || encouragement || congratulations || warningBlame;

  /// Libellé de la distinction principale.
  String? get primaryLabel {
    if (honorRoll) return 'Tableau d\'honneur';
    if (congratulations) return 'Félicitations';
    if (encouragement) return 'Encouragements';
    if (warningBlame) return 'Avertissement';
    return null;
  }

  factory BulletinHonorsDto.fromJson(Map<String, dynamic> j) =>
      BulletinHonorsDto(
        honorRoll: (j['honor_roll'] as bool?) ?? false,
        encouragement: (j['encouragement'] as bool?) ?? false,
        congratulations: (j['congratulations'] as bool?) ?? false,
        warningBlame: (j['warning_blame'] as bool?) ?? false,
        absencesCount: (j['absences_count'] as num?)?.toInt() ?? 0,
        delaysCount: (j['delays_count'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'honor_roll': honorRoll,
        'encouragement': encouragement,
        'congratulations': congratulations,
        'warning_blame': warningBlame,
        'absences_count': absencesCount,
        'delays_count': delaysCount,
      };
}

/// Matière dans un bulletin.
///
/// ⚠️ Aligné sur la vraie structure du desktop :
/// {subject_id, subject_name, subject_code, domain, coefficient,
///  is_facultative, teacher, average, moyenne_classe, note_composition,
///  class_average, assessments[], mention, is_from_previous_grade}.
class BulletinSubjectDto {
  final int? subjectId;
  final String subjectName;
  final String? subjectCode;
  final String? domain;
  final int coefficient;
  final bool isFacultative;
  final String? teacher;
  final double? average;
  final double? moyenneClasse; // moyenne de l'élève hors composition
  final double? noteComposition; // note de composition (examen)
  final double? classAverage; // moyenne de la classe entière
  final List<BulletinAssessmentDto> assessments;
  final String? mention;
  final bool isFromPreviousGrade;
  final String? appreciation;

  const BulletinSubjectDto({
    this.subjectId,
    required this.subjectName,
    this.subjectCode,
    this.domain,
    this.coefficient = 1,
    this.isFacultative = false,
    this.teacher,
    this.average,
    this.moyenneClasse,
    this.noteComposition,
    this.classAverage,
    this.assessments = const [],
    this.mention,
    this.isFromPreviousGrade = false,
    this.appreciation,
  });

  factory BulletinSubjectDto.fromJson(Map<String, dynamic> j) =>
      BulletinSubjectDto(
        subjectId: (j['subject_id'] as num?)?.toInt(),
        subjectName: j['subject_name'] as String? ?? '',
        subjectCode: j['subject_code'] as String?,
        domain: j['domain'] as String?,
        coefficient: (j['coefficient'] as num?)?.toInt() ?? 1,
        isFacultative: (j['is_facultative'] as bool?) ?? false,
        teacher: j['teacher'] as String? ?? j['teacher_name'] as String?,
        average: (j['average'] as num?)?.toDouble(),
        moyenneClasse: (j['moyenne_classe'] as num?)?.toDouble(),
        noteComposition: (j['note_composition'] as num?)?.toDouble(),
        classAverage: (j['class_average'] as num?)?.toDouble(),
        assessments: (j['assessments'] as List?)
                ?.map((e) =>
                    BulletinAssessmentDto.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        mention: j['mention'] as String?,
        isFromPreviousGrade: (j['is_from_previous_grade'] as bool?) ?? false,
        appreciation: j['appreciation'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'subject_id': subjectId,
        'subject_name': subjectName,
        'subject_code': subjectCode,
        'domain': domain,
        'coefficient': coefficient,
        'is_facultative': isFacultative,
        'teacher': teacher,
        'average': average,
        'moyenne_classe': moyenneClasse,
        'note_composition': noteComposition,
        'class_average': classAverage,
        'assessments': assessments.map((e) => e.toJson()).toList(),
        'mention': mention,
        'is_from_previous_grade': isFromPreviousGrade,
        'appreciation': appreciation,
      };
}

/// Évaluation dans un bulletin.
/// Clés serveur : {name, type, max_score, value, is_absent, date}.
class BulletinAssessmentDto {
  final String name;
  final String type;
  final double maxScore;
  final double? value;
  final bool isAbsent;
  final String? date;

  const BulletinAssessmentDto({
    required this.name,
    this.type = '',
    this.maxScore = defaultMaxScore,
    this.value,
    this.isAbsent = false,
    this.date,
  });

  factory BulletinAssessmentDto.fromJson(Map<String, dynamic> j) =>
      BulletinAssessmentDto(
        name: j['name'] as String? ?? '',
        type: j['type'] as String? ?? '',
        maxScore: (j['max_score'] as num?)?.toDouble() ?? defaultMaxScore,
        value: (j['value'] as num?)?.toDouble(),
        isAbsent: (j['is_absent'] as bool?) ?? false,
        date: j['date'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'type': type,
        'max_score': maxScore,
        'value': value,
        'is_absent': isAbsent,
        'date': date,
      };
}
