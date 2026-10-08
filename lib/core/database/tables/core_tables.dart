/// Tables Drift "core" : établissement, années scolaires, périodes,
/// référentiels (niveaux, séries, filières).
///
/// Chaque table répliquée porte les colonnes de synchro :
/// `synced_at` (nullable), `is_dirty` (default false), `is_deleted` (default false).
library;

import 'package:drift/drift.dart';

/// Établissement scolaire (1 seul localement, multi-tenant côté serveur).
class Establishments extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get code => text().withLength(min: 1, max: 64)();
  TextColumn get name => text().withLength(min: 1, max: 255)();
  TextColumn get address => text().nullable()();
  TextColumn get city => text().nullable()();
  TextColumn get phone => text().nullable()();
  TextColumn get email => text().nullable()();
  TextColumn get logoPath => text().nullable()();
  TextColumn get currency => text().withDefault(const Constant('XOF'))();
  TextColumn get country => text().nullable()();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

/// Année scolaire.
class SchoolYears extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 64)();
  DateTimeColumn get startDate => dateTime().nullable()();
  DateTimeColumn get endDate => dateTime().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(false))();
  DateTimeColumn get alternatingWeekStartDate => dateTime().nullable()();
  IntColumn get establishmentId => integer().nullable()();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

/// Période (trimestre/semestre).
class Periods extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 64)();
  IntColumn get schoolYearId => integer().nullable()();
  DateTimeColumn get startDate => dateTime().nullable()();
  DateTimeColumn get endDate => dateTime().nullable()();
  RealColumn get weight => real().withDefault(const Constant(1.0))();
  BoolColumn get isActive => boolean().withDefault(const Constant(false))();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

/// Niveau (ex: 6ème, Terminale).
class Levels extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 64)();
  TextColumn get code => text().nullable()();
  IntColumn get order => integer().withDefault(const Constant(0))();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

/// Série (ex: D, C, A).
class Series extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 64)();
  TextColumn get code => text().nullable()();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

/// Filière (ex: Sciences, Lettres).
class Streams extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 64)();
  TextColumn get code => text().nullable()();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}
