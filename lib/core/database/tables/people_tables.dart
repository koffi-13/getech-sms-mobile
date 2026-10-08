/// Tables Drift "people" : élèves + satellites (contact, médical, scolarité,
/// parents, tuteurs) + assignations + référentiels statut/inscription.
library;

import 'package:drift/drift.dart';

/// Élève (identité + lieu de naissance étendu).
class Students extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get matricule => text().withLength(min: 1, max: 64)();
  TextColumn get nom => text().withLength(min: 1, max: 128)();
  TextColumn get prenoms => text().nullable()();
  DateTimeColumn get dob => dateTime().nullable()();
  TextColumn get sexe => text().nullable()(); // 'M' | 'F'
  TextColumn get birthPlace => text().nullable()();
  TextColumn get birthPrefecture => text().nullable()();
  TextColumn get birthRegion => text().nullable()();
  TextColumn get birthCountry => text().nullable()();
  TextColumn get photoPath => text().nullable()();
  TextColumn get groupe => text().nullable()();
  IntColumn get establishmentId => integer().nullable()();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

/// Contact d'un élève (1-1).
class StudentContacts extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get studentId => integer()();
  TextColumn get phone => text().nullable()();
  TextColumn get email => text().nullable()();
  TextColumn get address => text().nullable()();
  TextColumn get city => text().nullable()();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

/// Dossier médical d'un élève (1-1).
class StudentMedicals extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get studentId => integer()();
  TextColumn get bloodType => text().nullable()();
  TextColumn get allergies => text().nullable()();
  TextColumn get doctor => text().nullable()();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

/// Scolarité antérieure d'un élève (1-1).
class StudentScholastics extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get studentId => integer()();
  TextColumn get previousSchool => text().nullable()();
  TextColumn get transport => text().nullable()();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

/// Parent d'un élève (père ou mère).
class StudentParents extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get studentId => integer()();
  TextColumn get role => text()(); // 'PERE' | 'MERE'
  TextColumn get nom => text().nullable()();
  TextColumn get prenoms => text().nullable()();
  TextColumn get phone => text().nullable()();
  TextColumn get profession => text().nullable()();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

/// Tuteur légal.
class Guardians extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get nom => text().nullable()();
  TextColumn get prenoms => text().nullable()();
  TextColumn get phone => text().nullable()();
  TextColumn get email => text().nullable()();
  TextColumn get relation => text().nullable()();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

/// Association élève ↔ tuteur (N-N).
class StudentGuardians extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get studentId => integer()();
  IntColumn get guardianId => integer()();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

/// Assignation élève ↔ classe pour une année scolaire.
class StudentClassAssignments extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get studentId => integer()();
  IntColumn get classroomId => integer()();
  IntColumn get schoolYearId => integer().nullable()();
  TextColumn get status => text().nullable()(); // NOUVEAU | REDOUBLANT
  TextColumn get inscriptionType => text().nullable()(); // NOUVEAU | ANCIEN | EXCLU | ABANDON
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

/// Statut d'élève (référentiel).
class StudentStatuses extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get code => text().withLength(min: 1, max: 32)();
  TextColumn get label => text().withLength(min: 1, max: 64)();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

/// Type d'inscription (référentiel).
class InscriptionTypes extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get code => text().withLength(min: 1, max: 32)();
  TextColumn get label => text().withLength(min: 1, max: 64)();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}
