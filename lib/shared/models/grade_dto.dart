/// DTOs Notes & Évaluations (saisie, classement, bulletin).
library;

import '../../core/config/constants.dart';
import '../../core/utils/formatters.dart';

class AssessmentDto {
  final int id;
  final int classSubjectId;
  final String? subjectName;
  final int? periodId;
  final String? periodName;
  final String title;
  final AssessmentType type;
  final DateTime? date;
  final double maxScore;
  final double coefficient;

  const AssessmentDto({
    required this.id,
    required this.classSubjectId,
    this.subjectName,
    this.periodId,
    this.periodName,
    required this.title,
    this.type = AssessmentType.devoir,
    this.date,
    this.maxScore = defaultMaxScore,
    this.coefficient = 1.0,
  });

  factory AssessmentDto.fromJson(Map<String, dynamic> j) => AssessmentDto(
        id: (j['id'] as num).toInt(),
        classSubjectId: (j['class_subject_id'] as num).toInt(),
        subjectName: j['subject_name'] as String?,
        periodId: (j['period_id'] as num?)?.toInt(),
        periodName: j['period_name'] as String?,
        title: j['title'] as String? ?? '',
        type: AssessmentType.values.firstWhere(
          (t) => t.code == (j['type'] as String?),
          orElse: () => AssessmentType.devoir,
        ),
        date: DateFormatter.parse(j['date'] as String?),
        maxScore: (j['max_score'] as num?)?.toDouble() ?? defaultMaxScore,
        coefficient: (j['coefficient'] as num?)?.toDouble() ?? 1.0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'class_subject_id': classSubjectId,
        'subject_name': subjectName,
        'period_id': periodId,
        'period_name': periodName,
        'title': title,
        'type': type.code,
        'date': DateFormatter.toIso(date),
        'max_score': maxScore,
        'coefficient': coefficient,
      };
}

class GradeDto {
  final int? id;
  final int assessmentId;
  final int studentId;
  final String studentName;
  final String? matricule;
  final double? value;
  final bool isAbsent;
  final String? comments;

  const GradeDto({
    this.id,
    required this.assessmentId,
    required this.studentId,
    required this.studentName,
    this.matricule,
    this.value,
    this.isAbsent = false,
    this.comments,
  });

  /// Note effective (null si absent).
  double? get effectiveValue => isAbsent ? null : value;

  factory GradeDto.fromJson(Map<String, dynamic> j) => GradeDto(
        id: (j['id'] as num?)?.toInt(),
        assessmentId: (j['assessment_id'] as num).toInt(),
        studentId: (j['student_id'] as num).toInt(),
        studentName: j['student_name'] as String? ?? '',
        matricule: j['matricule'] as String?,
        value: (j['value'] as num?)?.toDouble(),
        isAbsent: (j['is_absent'] as bool?) ?? false,
        comments: j['comments'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'assessment_id': assessmentId,
        'student_id': studentId,
        'student_name': studentName,
        'matricule': matricule,
        'value': value,
        'is_absent': isAbsent,
        'comments': comments,
      };
}

/// Requête de sauvegarde en lot des notes : `POST /grades/assessments/{id}/grades`.
class SaveGradesRequest {
  final int assessmentId;
  final List<GradeDto> grades;

  const SaveGradesRequest({required this.assessmentId, required this.grades});

  Map<String, dynamic> toJson() => {
        'assessment_id': assessmentId,
        'grades': grades.map((g) => g.toJson()).toList(),
      };
}

/// Ligne de classement d'un élève.
class RankingRowDto {
  final int rank;
  final int studentId;
  final String studentName;
  final String? matricule;
  final double average;
  final double? previousAverage;
  final int? previousRank;
  final String? appreciation;

  const RankingRowDto({
    required this.rank,
    required this.studentId,
    required this.studentName,
    this.matricule,
    required this.average,
    this.previousAverage,
    this.previousRank,
    this.appreciation,
  });

  /// Progression vs période précédente (positive = amélioration).
  double get progression =>
      previousAverage == null ? 0 : average - previousAverage!;

  factory RankingRowDto.fromJson(Map<String, dynamic> j) => RankingRowDto(
        rank: (j['rank'] as num).toInt(),
        studentId: (j['student_id'] as num).toInt(),
        studentName: j['student_name'] as String? ?? '',
        matricule: j['matricule'] as String?,
        average: (j['average'] as num?)?.toDouble() ?? 0,
        previousAverage: (j['previous_average'] as num?)?.toDouble(),
        previousRank: (j['previous_rank'] as num?)?.toInt(),
        appreciation: j['appreciation'] as String?,
      );
}

/// Bulletin d'un élève (vue structurée).
class BulletinDto {
  final int studentId;
  final String studentName;
  final String? matricule;
  final String classroomName;
  final String periodName;
  final String? schoolYearName;
  final double generalAverage;
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
    required this.generalAverage,
    this.rank,
    this.totalStudents,
    this.subjects = const [],
    this.appreciation,
  });

  factory BulletinDto.fromJson(Map<String, dynamic> j) => BulletinDto(
        studentId: (j['student_id'] as num).toInt(),
        studentName: j['student_name'] as String? ?? '',
        matricule: j['matricule'] as String?,
        classroomName: j['classroom_name'] as String? ?? '',
        periodName: j['period_name'] as String? ?? '',
        schoolYearName: j['school_year_name'] as String?,
        generalAverage: (j['general_average'] as num?)?.toDouble() ?? 0,
        rank: (j['rank'] as num?)?.toInt(),
        totalStudents: (j['total_students'] as num?)?.toInt(),
        subjects: (j['subjects'] as List?)
                ?.map((e) => BulletinSubjectDto.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        appreciation: j['appreciation'] as String?,
      );
}

class BulletinSubjectDto {
  final String subjectName;
  final double coefficient;
  final double average;
  final int? rank;
  final String? teacherName;
  final String? appreciation;

  const BulletinSubjectDto({
    required this.subjectName,
    this.coefficient = 1.0,
    required this.average,
    this.rank,
    this.teacherName,
    this.appreciation,
  });

  factory BulletinSubjectDto.fromJson(Map<String, dynamic> j) => BulletinSubjectDto(
        subjectName: j['subject_name'] as String? ?? '',
        coefficient: (j['coefficient'] as num?)?.toDouble() ?? 1.0,
        average: (j['average'] as num?)?.toDouble() ?? 0,
        rank: (j['rank'] as num?)?.toInt(),
        teacherName: j['teacher_name'] as String?,
        appreciation: j['appreciation'] as String?,
      );
}
