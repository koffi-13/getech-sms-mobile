/// DTOs Classes, Matières, Périodes, Années scolaires — alignés sur les
/// schémas Pydantic du desktop (schemas.py).
library;

import '../../core/config/constants.dart';
import '../../core/utils/formatters.dart';

/// Classe (ClassroomResponse côté serveur).
///
/// Champs serveur : {id, name, establishment_id, max_students, is_active,
/// head_teacher_id, head_teacher_name, level_name, cycle_name,
/// current_students_count, series_name}.
class ClassroomDto {
  final int id;
  final String name;
  final int? establishmentId;
  final int? maxStudents;
  final bool isActive;
  final int? headTeacherId;
  final String? headTeacherName;
  final String? levelName;
  final String? cycleName;
  final int? currentStudentsCount;
  final String? seriesName;

  const ClassroomDto({
    required this.id,
    required this.name,
    this.establishmentId,
    this.maxStudents,
    this.isActive = true,
    this.headTeacherId,
    this.headTeacherName,
    this.levelName,
    this.cycleName,
    this.currentStudentsCount,
    this.seriesName,
  });

  /// Alias de commodité : capacité = max_students.
  int get capacity => maxStudents ?? 0;

  /// Alias de commodité : effectif = current_students_count.
  int get studentCount => currentStudentsCount ?? 0;

  /// Taux d'occupation = effectif / capacité.
  double get occupancyRate =>
      capacity == 0 ? 0 : (studentCount / capacity).clamp(0, 1);

  /// Titulaire de classe.
  String get teacherName => headTeacherName ?? '';

  factory ClassroomDto.fromJson(Map<String, dynamic> j) => ClassroomDto(
        id: (j['id'] as num).toInt(),
        name: j['name'] as String? ?? '',
        establishmentId: (j['establishment_id'] as num?)?.toInt(),
        maxStudents: (j['max_students'] as num?)?.toInt(),
        isActive: (j['is_active'] as bool?) ?? true,
        headTeacherId: (j['head_teacher_id'] as num?)?.toInt(),
        headTeacherName: j['head_teacher_name'] as String?,
        levelName: j['level_name'] as String?,
        cycleName: j['cycle_name'] as String?,
        currentStudentsCount: (j['current_students_count'] as num?)?.toInt(),
        seriesName: j['series_name'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'establishment_id': establishmentId,
        'max_students': maxStudents,
        'is_active': isActive,
        'head_teacher_id': headTeacherId,
        'head_teacher_name': headTeacherName,
        'level_name': levelName,
        'cycle_name': cycleName,
        'current_students_count': currentStudentsCount,
        'series_name': seriesName,
      };
}

/// Réponse paginée de liste de classes (ClassroomListResponse).
class ClassroomListResponse {
  final List<ClassroomDto> items;
  final int total;

  const ClassroomListResponse({this.items = const [], this.total = 0});

  factory ClassroomListResponse.fromJson(Map<String, dynamic> j) =>
      ClassroomListResponse(
        items: (j['items'] as List?)
                ?.map((e) => ClassroomDto.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        total: (j['total'] as num?)?.toInt() ?? 0,
      );
}

/// Matière (SubjectResponse côté serveur).
///
/// Champs serveur : {id, name, code, is_facultative, is_active, domain_id,
/// domain_name, description}.
class SubjectDto {
  final int id;
  final String name;
  final String code;
  final bool isFacultative;
  final bool isActive;
  final int? domainId;
  final String? domainName;
  final String? description;

  const SubjectDto({
    required this.id,
    required this.name,
    this.code = '',
    this.isFacultative = false,
    this.isActive = true,
    this.domainId,
    this.domainName,
    this.description,
  });

  factory SubjectDto.fromJson(Map<String, dynamic> j) => SubjectDto(
        id: (j['id'] as num).toInt(),
        name: j['name'] as String? ?? '',
        code: j['code'] as String? ?? '',
        isFacultative: (j['is_facultative'] as bool?) ?? false,
        isActive: (j['is_active'] as bool?) ?? true,
        domainId: (j['domain_id'] as num?)?.toInt(),
        domainName: j['domain_name'] as String?,
        description: j['description'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'code': code,
        'is_facultative': isFacultative,
        'is_active': isActive,
        'domain_id': domainId,
        'domain_name': domainName,
        'description': description,
      };
}

/// Réponse paginée de liste de matières (SubjectListResponse).
class SubjectListResponse {
  final List<SubjectDto> items;
  final int total;

  const SubjectListResponse({this.items = const [], this.total = 0});

  factory SubjectListResponse.fromJson(Map<String, dynamic> j) =>
      SubjectListResponse(
        items: (j['items'] as List?)
                ?.map((e) => SubjectDto.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        total: (j['total'] as num?)?.toInt() ?? 0,
      );
}

/// Matière affectée à une classe (ClassSubjectResponse côté serveur).
///
/// ⚠️ `coefficient` est un **int** (pas double) côté serveur.
/// Champs serveur : {id, subject_id, subject_name, subject_code, coefficient,
/// is_facultative, assigned_teacher_id, assigned_teacher_name}.
class ClassSubjectDto {
  final int id;
  final int subjectId;
  final String subjectName;
  final String subjectCode;
  final int coefficient;
  final bool isFacultative;
  final int? assignedTeacherId;
  final String? assignedTeacherName;

  const ClassSubjectDto({
    required this.id,
    this.subjectId = 0,
    this.subjectName = '',
    this.subjectCode = '',
    this.coefficient = 1,
    this.isFacultative = false,
    this.assignedTeacherId,
    this.assignedTeacherName,
    // Champs de compatibilité (pour le mobile offline)
    this.classroomId,
  });

  /// Alias de compatibilité : teacherId = assignedTeacherId.
  int? get teacherId => assignedTeacherId;
  String? get teacherName => assignedTeacherName;

  factory ClassSubjectDto.fromJson(Map<String, dynamic> j) => ClassSubjectDto(
        id: (j['id'] as num).toInt(),
        subjectId: (j['subject_id'] as num?)?.toInt() ?? 0,
        subjectName: j['subject_name'] as String? ?? '',
        subjectCode: j['subject_code'] as String? ?? '',
        coefficient: (j['coefficient'] as num?)?.toInt() ?? 1,
        isFacultative: (j['is_facultative'] as bool?) ?? false,
        assignedTeacherId: (j['assigned_teacher_id'] as num?)?.toInt(),
        assignedTeacherName: j['assigned_teacher_name'] as String?,
        classroomId: (j['classroom_id'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'subject_id': subjectId,
        'subject_name': subjectName,
        'subject_code': subjectCode,
        'coefficient': coefficient,
        'is_facultative': isFacultative,
        'assigned_teacher_id': assignedTeacherId,
        'assigned_teacher_name': assignedTeacherName,
        'classroom_id': classroomId,
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

/// Période (PeriodResponse côté serveur).
///
/// ⚠️ `start_date`/`end_date` sont des **strings** (pas datetime) côté serveur.
/// Champs serveur : {id, name, start_date: str, end_date: str, is_active}.
class PeriodDto {
  final int id;
  final String name;
  final String? startDate;
  final String? endDate;
  final bool isActive;
  // Champs de compatibilité (non dans la réponse serveur de base)
  final int? schoolYearId;
  final double weight;

  const PeriodDto({
    required this.id,
    required this.name,
    this.startDate,
    this.endDate,
    this.isActive = false,
    this.schoolYearId,
    this.weight = 1.0,
  });

  factory PeriodDto.fromJson(Map<String, dynamic> j) => PeriodDto(
        id: (j['id'] as num).toInt(),
        name: j['name'] as String? ?? '',
        startDate: j['start_date'] as String?,
        endDate: j['end_date'] as String?,
        isActive: (j['is_active'] as bool?) ?? false,
        schoolYearId: (j['school_year_id'] as num?)?.toInt(),
        weight: (j['weight'] as num?)?.toDouble() ?? 1.0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'start_date': startDate,
        'end_date': endDate,
        'is_active': isActive,
        'school_year_id': schoolYearId,
        'weight': weight,
      };
}
