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
/// Clés serveur : {rank, student_id, student_name, matricule, average,
/// previous_period_averages, annual_average, student_status_id}.
class RankingRowDto {
  final int rank;
  final int studentId;
  final String studentName;
  final String? matricule;
  final double? average;
  final List<double> previousPeriodAverages;
  final double? annualAverage;
  final int? studentStatusId;
  // Champs de compatibilité (non dans la réponse de base)
  final double? previousAverage;
  final int? previousRank;
  final String? appreciation;

  const RankingRowDto({
    required this.rank,
    required this.studentId,
    required this.studentName,
    this.matricule,
    this.average,
    this.previousPeriodAverages = const [],
    this.annualAverage,
    this.studentStatusId,
    this.previousAverage,
    this.previousRank,
    this.appreciation,
  });

  /// Progression vs période précédente.
  double get progression {
    if (previousPeriodAverages.isEmpty || average == null) return 0;
    return average! - previousPeriodAverages.last;
  }

  factory RankingRowDto.fromJson(Map<String, dynamic> j) => RankingRowDto(
        rank: (j['rank'] as num?)?.toInt() ?? 0,
        studentId: (j['student_id'] as num).toInt(),
        studentName: j['student_name'] as String? ?? '',
        matricule: j['matricule'] as String?,
        average: (j['average'] as num?)?.toDouble(),
        previousPeriodAverages: (j['previous_period_averages'] as List?)
                ?.map((e) => (e as num).toDouble())
                .toList() ??
            const [],
        annualAverage: (j['annual_average'] as num?)?.toDouble(),
        studentStatusId: (j['student_status_id'] as num?)?.toInt(),
        previousAverage: (j['previous_average'] as num?)?.toDouble(),
        previousRank: (j['previous_rank'] as num?)?.toInt(),
        appreciation: j['appreciation'] as String?,
      );
}

/// Bulletin d'un élève (dict renvoyé par `GET /grades/bulletin/{student_id}`).
///
/// Structure serveur : {student: {...}, subjects: [...], overall_average,
/// rank, total_students}.
class BulletinDto {
  final int studentId;
  final String studentName;
  final String? matricule;
  final String classroomName;
  final String periodName;
  final String? schoolYearName;
  final double? overallAverage;
  final int? rank;
  final int? totalStudents;
  final List<BulletinSubjectDto> subjects;
  final String? appreciation;

  const BulletinDto({
    required this.studentId,
    required this.studentName,
    this.matricule,
    required this.classroomName,
    required this.periodName,
    this.schoolYearName,
    this.overallAverage,
    this.rank,
    this.totalStudents,
    this.subjects = const [],
    this.appreciation,
  });

  /// Alias de compatibilité.
  double get generalAverage => overallAverage ?? 0;

  factory BulletinDto.fromJson(Map<String, dynamic> j) {
    final student = j['student'] as Map<String, dynamic>? ?? {};
    return BulletinDto(
      studentId: (student['student_id'] as num?)?.toInt() ??
          (j['student_id'] as num?)?.toInt() ??
          0,
      studentName: student['student_name'] as String? ??
          j['student_name'] as String? ??
          '',
      matricule: student['matricule'] as String? ?? j['matricule'] as String?,
      classroomName: student['classroom_name'] as String? ??
          j['classroom_name'] as String? ??
          '',
      periodName: j['period_name'] as String? ?? '',
      schoolYearName: j['school_year_name'] as String?,
      overallAverage: (j['overall_average'] as num?)?.toDouble() ??
          (j['general_average'] as num?)?.toDouble(),
      rank: (j['rank'] as num?)?.toInt(),
      totalStudents: (j['total_students'] as num?)?.toInt(),
      subjects: (j['subjects'] as List?)
              ?.map((e) =>
                  BulletinSubjectDto.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      appreciation: j['appreciation'] as String?,
    );
  }
}

/// Matière dans un bulletin.
///
/// Clés serveur : {subject_id, subject_name, subject_code, coefficient,
/// is_facultative, teacher, average, moyenne_classe, assessments[]}.
class BulletinSubjectDto {
  final int? subjectId;
  final String subjectName;
  final String? subjectCode;
  final int coefficient;
  final bool isFacultative;
  final String? teacher;
  final double? average;
  final double? moyenneClasse;
  final List<BulletinAssessmentDto> assessments;
  final String? appreciation;

  const BulletinSubjectDto({
    this.subjectId,
    required this.subjectName,
    this.subjectCode,
    this.coefficient = 1,
    this.isFacultative = false,
    this.teacher,
    this.average,
    this.moyenneClasse,
    this.assessments = const [],
    this.appreciation,
  });

  factory BulletinSubjectDto.fromJson(Map<String, dynamic> j) =>
      BulletinSubjectDto(
        subjectId: (j['subject_id'] as num?)?.toInt(),
        subjectName: j['subject_name'] as String? ?? '',
        subjectCode: j['subject_code'] as String?,
        coefficient: (j['coefficient'] as num?)?.toInt() ?? 1,
        isFacultative: (j['is_facultative'] as bool?) ?? false,
        teacher: j['teacher'] as String? ?? j['teacher_name'] as String?,
        average: (j['average'] as num?)?.toDouble(),
        moyenneClasse: (j['moyenne_classe'] as num?)?.toDouble(),
        assessments: (j['assessments'] as List?)
                ?.map((e) =>
                    BulletinAssessmentDto.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        appreciation: j['appreciation'] as String?,
      );
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
}
