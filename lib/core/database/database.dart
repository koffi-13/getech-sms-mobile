/// Base de données locale Drift (SQLite) — réplique offline-first du schéma
/// central GeTech-SMS.
///
/// 19 tables répliquées + tables système (sync_metadata, outbox, paired_devices).
///
/// ⚠️ Codegen : après `flutter pub get`, exécuter :
///   dart run build_runner build --delete-conflicting-outputs
/// pour générer `database.g.dart`.
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'tables/academic_tables.dart';
import 'tables/core_tables.dart';
import 'tables/people_tables.dart';
import 'tables/schedule_tables.dart';
import 'tables/system_tables.dart';

part 'database.g.dart';

/// Liste ordonnée de toutes les tables répliquées (pour le sync engine).
const List<String> replicatedTables = [
  'establishments',
  'school_years',
  'periods',
  'levels',
  'series',
  'streams',
  'classrooms',
  'subjects',
  'class_subjects',
  'assessments',
  'grades',
  'students',
  'student_contacts',
  'student_medicals',
  'student_scholastics',
  'student_parents',
  'guardians',
  'student_guardians',
  'student_class_assignments',
  'student_statuses',
  'inscription_types',
  'time_slots',
  'weekly_schedules',
  'course_sessions',
  'student_absences',
  'lesson_records',
  'users',
];

@DriftDatabase(tables: [
  Establishments,
  SchoolYears,
  Periods,
  Levels,
  Series,
  Streams,
  Classrooms,
  Subjects,
  ClassSubjects,
  Assessments,
  Grades,
  Students,
  StudentContacts,
  StudentMedicals,
  StudentScholastics,
  StudentParents,
  Guardians,
  StudentGuardians,
  StudentClassAssignments,
  StudentStatuses,
  InscriptionTypes,
  TimeSlots,
  WeeklySchedules,
  CourseSessions,
  StudentAbsences,
  LessonRecords,
  Users,
  SyncMetadata,
  OutboxEntries,
  PairedDevices,
],)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  /// Pour tests : permettre d'injecter une connexion in-memory.
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          // Seed des métadonnées de synchro pour chaque table répliquée.
          await batch((b) {
            b.insertAll(
              syncMetadata,
              replicatedTables
                  .map((t) => SyncMetadataCompanion.insert(tableNameColumn: t))
                  .toList(),
              mode: InsertMode.insertOrIgnore,
            );
          });
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON;');
          await customStatement('PRAGMA journal_mode = WAL;');
        },
      );

  /// Efface TOUTES les données des tables répliquées (Reset).
  Future<void> clearAllData() async {
    await transaction(() async {
      for (final table in allTables) {
        // On ne vide pas les tables système comme paired_devices ou outbox_entries
        // sauf si explicitement demandé. Ici on se concentre sur les données métier.
        if (table.actualTableName != 'sync_metadata' && 
            table.actualTableName != 'paired_devices') {
          await delete(table).go();
        }
      }
    });
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'getech_sms.db'));
    return NativeDatabase.createInBackground(file);
  });
}

/// Provider Riverpod de la base de données (singleton).
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

/// Helper : convertit un [DateTime] en millisecondes Unix pour SQLite.
int dateTimeToUnix(DateTime dt) => dt.millisecondsSinceEpoch;

DateTime unixToDateTime(int ms) =>
    DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
