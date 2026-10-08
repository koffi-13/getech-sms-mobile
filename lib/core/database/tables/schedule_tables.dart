/// Tables Drift "schedule & attendance" : emploi du temps, créneaux,
/// sessions de cours, absences, cahier de texte.
library;

import 'package:drift/drift.dart';

/// Créneau horaire (jour + heure).
class TimeSlots extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get dayOfWeek => integer()(); // 1..6 (Lundi..Samedi)
  TextColumn get startTime => text()(); // 'HH:mm'
  TextColumn get endTime => text()(); // 'HH:mm'
  IntColumn get breakAfter => integer().nullable()();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

/// Cours récurrent (emploi du temps hebdomadaire).
class WeeklySchedules extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get classroomId => integer().nullable()();
  IntColumn get subjectId => integer().nullable()();
  IntColumn get teacherId => integer().nullable()();
  IntColumn get timeSlotId => integer()();
  IntColumn get dayOfWeek => integer()();
  TextColumn get startTime => text().nullable()();
  TextColumn get endTime => text().nullable()();
  TextColumn get room => text().nullable()();
  TextColumn get weekType => text().withDefault(const Constant('A'))(); // 'A' | 'B'
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

/// Session de cours (occurrence datée).
class CourseSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get weeklyScheduleId => integer().nullable()();
  IntColumn get classroomId => integer().nullable()();
  IntColumn get subjectId => integer().nullable()();
  IntColumn get teacherId => integer().nullable()();
  DateTimeColumn get date => dateTime()();
  TextColumn get startTime => text().nullable()();
  TextColumn get endTime => text().nullable()();
  TextColumn get state => text().withDefault(const Constant('PENDING'))();
  IntColumn get lessonRecordId => integer().nullable()();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

/// Absence d'un élève pour une session.
class StudentAbsences extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get courseSessionId => integer()();
  IntColumn get studentId => integer()();
  BoolColumn get isJustified => boolean().withDefault(const Constant(false))();
  TextColumn get reason => text().nullable()();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

/// Cahier de texte (contenu du cours + devoirs).
class LessonRecords extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get courseSessionId => integer()();
  TextColumn get content => text()();
  TextColumn get homework => text().nullable()();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}
