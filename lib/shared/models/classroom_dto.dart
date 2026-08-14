/// DTOs Classes, Matières, Périodes, Années scolaires.
library;

import '../../core/config/constants.dart';
import '../../core/utils/formatters.dart';

class ClassroomDto {
  final int id;
  final String name;
  final String? code;
  final int? levelId;
  final String? levelName;
  final int? streamId;
  final String? streamName;
  final int? seriesId;
  final int? teacherId;
  final String? teacherName;
  final int capacity;
  final int studentCount;
  final int? schoolYearId;
  final String? schoolYearName;

  const ClassroomDto({
    required this.id,
    required this.name,
    this.code,
    this.levelId,
    this.levelName,
    this.streamId,
    this.streamName,
    this.seriesId,
    this.teacherId,
    this.teacherName,
    this.capacity = 0,
    this.studentCount = 0,
    this.schoolYearId,
    this.schoolYearName,
  });

  /// Taux d'occupation = effectif / capacité.
  double get occupancyRate =>
      capacity == 0 ? 0 : (studentCount / capacity).clamp(0, 1);

  factory ClassroomDto.fromJson(Map<String, dynamic> j) => ClassroomDto(
        id: (j['id'] as num).toInt(),
        name: j['name'] as String? ?? '',
        code: j['code'] as String?,
        levelId: (j['level_id'] as num?)?.toInt(),
        levelName: j['level_name'] as String?,
        streamId: (j['stream_id'] as num?)?.toInt(),
        streamName: j['stream_name'] as String?,
        seriesId: (j['series_id'] as num?)?.toInt(),
        teacherId: (j['teacher_id'] as num?)?.toInt(),
        teacherName: j['teacher_name'] as String?,
        capacity: (j['capacity'] as num?)?.toInt() ?? 0,
        studentCount: (j['student_count'] as num?)?.toInt() ?? 0,
        schoolYearId: (j['school_year_id'] as num?)?.toInt(),
        schoolYearName: j['school_year_name'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'code': code,
        'level_id': levelId,
        'level_name': levelName,
        'stream_id': streamId,
        'stream_name': streamName,
        'series_id': seriesId,
        'teacher_id': teacherId,
        'teacher_name': teacherName,
        'capacity': capacity,
        'student_count': studentCount,
        'school_year_id': schoolYearId,
        'school_year_name': schoolYearName,
      };
}

class SubjectDto {
  final int id;
  final String name;
  final String? code;

  const SubjectDto({required this.id, required this.name, this.code});

  factory SubjectDto.fromJson(Map<String, dynamic> j) => SubjectDto(
        id: (j['id'] as num).toInt(),
        name: j['name'] as String? ?? '',
        code: j['code'] as String?,
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'code': code};
}

/// Matière affectée à une classe (avec coefficient).
class ClassSubjectDto {
  final int id;
  final int classroomId;
  final int subjectId;
  final String subjectName;
  final double coefficient;
  final int? teacherId;
  final String? teacherName;

  const ClassSubjectDto({
    required this.id,
    required this.classroomId,
    required this.subjectId,
    required this.subjectName,
    this.coefficient = 1.0,
    this.teacherId,
    this.teacherName,
  });

  factory ClassSubjectDto.fromJson(Map<String, dynamic> j) => ClassSubjectDto(
        id: (j['id'] as num).toInt(),
        classroomId: (j['classroom_id'] as num).toInt(),
        subjectId: (j['subject_id'] as num).toInt(),
        subjectName: j['subject_name'] as String? ?? '',
        coefficient: (j['coefficient'] as num?)?.toDouble() ?? 1.0,
        teacherId: (j['teacher_id'] as num?)?.toInt(),
        teacherName: j['teacher_name'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'classroom_id': classroomId,
        'subject_id': subjectId,
        'subject_name': subjectName,
        'coefficient': coefficient,
        'teacher_id': teacherId,
        'teacher_name': teacherName,
      };
}

class SchoolYearDto {
  final int id;
  final String name;
  final DateTime? startDate;
  final DateTime? endDate;
  final bool isActive;
  final DateTime? alternatingWeekStartDate;

  const SchoolYearDto({
    required this.id,
    required this.name,
    this.startDate,
    this.endDate,
    this.isActive = false,
    this.alternatingWeekStartDate,
  });

  /// Indique si l'année utilise des semaines alternées A/B.
  bool get hasAlternatingWeeks => alternatingWeekStartDate != null;

  factory SchoolYearDto.fromJson(Map<String, dynamic> j) => SchoolYearDto(
        id: (j['id'] as num).toInt(),
        name: j['name'] as String? ?? '',
        startDate: DateFormatter.parse(j['start_date'] as String?),
        endDate: DateFormatter.parse(j['end_date'] as String?),
        isActive: (j['is_active'] as bool?) ?? false,
        alternatingWeekStartDate:
            DateFormatter.parse(j['alternating_week_start_date'] as String?),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'start_date': DateFormatter.toIso(startDate),
        'end_date': DateFormatter.toIso(endDate),
        'is_active': isActive,
        'alternating_week_start_date': DateFormatter.toIso(alternatingWeekStartDate),
      };
}

class PeriodDto {
  final int id;
  final String name;
  final int? schoolYearId;
  final DateTime? startDate;
  final DateTime? endDate;
  final double weight;
  final bool isActive;

  const PeriodDto({
    required this.id,
    required this.name,
    this.schoolYearId,
    this.startDate,
    this.endDate,
    this.weight = 1.0,
    this.isActive = false,
  });

  factory PeriodDto.fromJson(Map<String, dynamic> j) => PeriodDto(
        id: (j['id'] as num).toInt(),
        name: j['name'] as String? ?? '',
        schoolYearId: (j['school_year_id'] as num?)?.toInt(),
        startDate: DateFormatter.parse(j['start_date'] as String?),
        endDate: DateFormatter.parse(j['end_date'] as String?),
        weight: (j['weight'] as num?)?.toDouble() ?? 1.0,
        isActive: (j['is_active'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'school_year_id': schoolYearId,
        'start_date': DateFormatter.toIso(startDate),
        'end_date': DateFormatter.toIso(endDate),
        'weight': weight,
        'is_active': isActive,
      };
}
