/// DTOs Présence (sessions de cours, absences, cahier de texte) + Emploi du temps.
library;

import '../../core/config/constants.dart';
import '../../core/utils/formatters.dart';

/// Session de cours (une occurrence datée d'un cours de l'emploi du temps).
class CourseSessionDto {
  final int id;
  final int? weeklyScheduleId;
  final int? classroomId;
  final String? classroomName;
  final int? subjectId;
  final String? subjectName;
  final int? teacherId;
  final String? teacherName;
  final DateTime date;
  final String? startTime;
  final String? endTime;
  final CourseSessionState state;
  final int? lessonRecordId;

  const CourseSessionDto({
    required this.id,
    this.weeklyScheduleId,
    this.classroomId,
    this.classroomName,
    this.subjectId,
    this.subjectName,
    this.teacherId,
    this.teacherName,
    required this.date,
    this.startTime,
    this.endTime,
    this.state = CourseSessionState.pending,
    this.lessonRecordId,
  });

  factory CourseSessionDto.fromJson(Map<String, dynamic> j) => CourseSessionDto(
        id: (j['id'] as num).toInt(),
        weeklyScheduleId: (j['weekly_schedule_id'] as num?)?.toInt(),
        classroomId: (j['classroom_id'] as num?)?.toInt(),
        classroomName: j['classroom_name'] as String?,
        subjectId: (j['subject_id'] as num?)?.toInt(),
        subjectName: j['subject_name'] as String?,
        teacherId: (j['teacher_id'] as num?)?.toInt(),
        teacherName: j['teacher_name'] as String?,
        date: DateFormatter.parse(j['date'] as String?) ?? DateTime.now(),
        startTime: j['start_time'] as String?,
        endTime: j['end_time'] as String?,
        state: CourseSessionState.fromCode(j['state'] as String?) ??
            CourseSessionState.pending,
        lessonRecordId: (j['lesson_record_id'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'weekly_schedule_id': weeklyScheduleId,
        'classroom_id': classroomId,
        'classroom_name': classroomName,
        'subject_id': subjectId,
        'subject_name': subjectName,
        'teacher_id': teacherId,
        'teacher_name': teacherName,
        'date': DateFormatter.toIso(date),
        'start_time': startTime,
        'end_time': endTime,
        'state': state.code,
        'lesson_record_id': lessonRecordId,
      };
}

/// Absence d'un élève pour une session (pas d'absence = présent).
class StudentAbsenceDto {
  final int? id;
  final int courseSessionId;
  final int studentId;
  final String studentName;
  final String? matricule;
  final bool isJustified;
  final String? reason;

  const StudentAbsenceDto({
    this.id,
    required this.courseSessionId,
    required this.studentId,
    required this.studentName,
    this.matricule,
    this.isJustified = false,
    this.reason,
  });

  factory StudentAbsenceDto.fromJson(Map<String, dynamic> j) => StudentAbsenceDto(
        id: (j['id'] as num?)?.toInt(),
        courseSessionId: (j['course_session_id'] as num).toInt(),
        studentId: (j['student_id'] as num).toInt(),
        studentName: j['student_name'] as String? ?? '',
        matricule: j['matricule'] as String?,
        isJustified: (j['is_justified'] as bool?) ?? false,
        reason: j['reason'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'course_session_id': courseSessionId,
        'student_id': studentId,
        'student_name': studentName,
        'matricule': matricule,
        'is_justified': isJustified,
        'reason': reason,
      };
}

/// Requête d'enregistrement des absences : `POST /attendance/session/{id}/absences`.
class SaveAbsencesRequest {
  final int sessionId;
  final List<StudentAbsenceDto> absences;

  const SaveAbsencesRequest({required this.sessionId, required this.absences});

  Map<String, dynamic> toJson() => {
        'session_id': sessionId,
        'absences': absences.map((a) => a.toJson()).toList(),
      };
}

/// Cahier de texte (contenu du cours + devoirs).
class LessonRecordDto {
  final int? id;
  final int courseSessionId;
  final String content;
  final String? homework;

  const LessonRecordDto({
    this.id,
    required this.courseSessionId,
    required this.content,
    this.homework,
  });

  factory LessonRecordDto.fromJson(Map<String, dynamic> j) => LessonRecordDto(
        id: (j['id'] as num?)?.toInt(),
        courseSessionId: (j['course_session_id'] as num).toInt(),
        content: j['content'] as String? ?? '',
        homework: j['homework'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'course_session_id': courseSessionId,
        'content': content,
        'homework': homework,
      };
}

/// Créneau horaire de l'emploi du temps.
class TimeSlotDto {
  final int id;
  final int dayOfWeek; // 1..6 (Lundi..Samedi)
  final String startTime;
  final String endTime;
  final int? breakAfter;

  const TimeSlotDto({
    required this.id,
    required this.dayOfWeek,
    required this.startTime,
    required this.endTime,
    this.breakAfter,
  });

  SchoolDay? get day => SchoolDay.fromIndex(dayOfWeek);

  factory TimeSlotDto.fromJson(Map<String, dynamic> j) => TimeSlotDto(
        id: (j['id'] as num).toInt(),
        dayOfWeek: (j['day_of_week'] as num).toInt(),
        startTime: j['start_time'] as String? ?? '',
        endTime: j['end_time'] as String? ?? '',
        breakAfter: (j['break_after'] as num?)?.toInt(),
      );
}

/// Cours récurrent (emploi du temps hebdomadaire).
class WeeklyScheduleDto {
  final int id;
  final int? classroomId;
  final String? classroomName;
  final int? subjectId;
  final String? subjectName;
  final int? teacherId;
  final String? teacherName;
  final int timeSlotId;
  final int dayOfWeek;
  final String startTime;
  final String endTime;
  final String? room;
  final WeekType weekType;

  const WeeklyScheduleDto({
    required this.id,
    this.classroomId,
    this.classroomName,
    this.subjectId,
    this.subjectName,
    this.teacherId,
    this.teacherName,
    required this.timeSlotId,
    required this.dayOfWeek,
    required this.startTime,
    required this.endTime,
    this.room,
    this.weekType = WeekType.a,
  });

  SchoolDay? get day => SchoolDay.fromIndex(dayOfWeek);

  factory WeeklyScheduleDto.fromJson(Map<String, dynamic> j) => WeeklyScheduleDto(
        id: (j['id'] as num).toInt(),
        classroomId: (j['classroom_id'] as num?)?.toInt(),
        classroomName: j['classroom_name'] as String?,
        subjectId: (j['subject_id'] as num?)?.toInt(),
        subjectName: j['subject_name'] as String?,
        teacherId: (j['teacher_id'] as num?)?.toInt(),
        teacherName: j['teacher_name'] as String?,
        timeSlotId: (j['time_slot_id'] as num).toInt(),
        dayOfWeek: (j['day_of_week'] as num).toInt(),
        startTime: j['start_time'] as String? ?? '',
        endTime: j['end_time'] as String? ?? '',
        room: j['room'] as String?,
        weekType: (j['week_type'] as String?) == 'B' ? WeekType.b : WeekType.a,
      );
}
