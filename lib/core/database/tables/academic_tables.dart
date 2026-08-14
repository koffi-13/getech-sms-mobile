/// Tables Drift "academic" : classes, matières, affectations, évaluations, notes.
library;

import 'package:drift/drift.dart';

/// Classe.
class Classrooms extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 128)();
  TextColumn get code => text().nullable()();
  IntColumn get levelId => integer().nullable()();
  IntColumn get streamId => integer().nullable()();
  IntColumn get seriesId => integer().nullable()();
  IntColumn get teacherId => integer().nullable()();
  IntColumn get capacity => integer().withDefault(const Constant(0))();
  IntColumn get schoolYearId => integer().nullable()();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

/// Matière.
class Subjects extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 128)();
  TextColumn get code => text().nullable()();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

/// Matière affectée à une classe (avec coefficient).
class ClassSubjects extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get classroomId => integer()();
  IntColumn get subjectId => integer()();
  RealColumn get coefficient => real().withDefault(const Constant(1.0))();
  IntColumn get teacherId => integer().nullable()();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

/// Évaluation.
class Assessments extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get classSubjectId => integer()();
  IntColumn get periodId => integer().nullable()();
  TextColumn get title => text().withLength(min: 1, max: 255)();
  TextColumn get type => text().withDefault(const Constant('DEVOIR'))();
  DateTimeColumn get date => dateTime().nullable()();
  RealColumn get maxScore => real().withDefault(const Constant(20.0))();
  RealColumn get coefficient => real().withDefault(const Constant(1.0))();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

/// Note d'un élève pour une évaluation.
class Grades extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get assessmentId => integer()();
  IntColumn get studentId => integer()();
  RealColumn get value => real().nullable()();
  BoolColumn get isAbsent => boolean().withDefault(const Constant(false))();
  TextColumn get comments => text().nullable()();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}
