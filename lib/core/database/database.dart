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

  /// [Multi-serveurs] ouvre le fichier dédié au profil actif
  /// (`getech_sms.db` pour le profil hérité, `getech_sms_<id>.db` sinon).
  AppDatabase.forFile(String fileName) : super(_openConnection(fileName));

  @override
  int get schemaVersion => 3;

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
        onUpgrade: (m, from, to) async {
          // v1 → v2 : colonnes dénormalisées de `classrooms` (titulaire,
          // niveau, cycle, série, effectif, statut) pour l'affichage hors-ligne.
          if (from < 2) {
            await m.addColumn(classrooms, classrooms.establishmentId);
            await m.addColumn(classrooms, classrooms.headTeacherName);
            await m.addColumn(classrooms, classrooms.levelName);
            await m.addColumn(classrooms, classrooms.cycleName);
            await m.addColumn(classrooms, classrooms.cycleId);
            await m.addColumn(classrooms, classrooms.seriesName);
            await m.addColumn(classrooms, classrooms.currentStudentsCount);
            await m.addColumn(classrooms, classrooms.isActive);
          }
          // v2 → v3 [Grade-Validation] : marques de la file de validation
          // sur les notes (proposition en attente / rejetée + valeur
          // proposée). Voir lib/features/grades/grade_controller.dart.
          if (from < 3) {
            await m.addColumn(grades, grades.syncStatus);
            await m.addColumn(grades, grades.proposedValue);
            await m.addColumn(grades, grades.proposedIsAbsent);
            await m.addColumn(grades, grades.proposedComments);
          }
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

LazyDatabase _openConnection([String fileName = 'getech_sms.db']) {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, fileName));
    return NativeDatabase.createInBackground(file);
  });
}

/// Nom du fichier de base du profil actif — piloté par le registre
/// multi-serveurs (`activeDbFileNameProvider.notifier.state = ...`).
final activeDbFileNameProvider = StateProvider<String>((ref) => 'getech_sms.db');

/// Provider Riverpod de la base de données.
///
/// WATCH le fichier actif : lors d'une bascule de serveur, l'ancienne base
/// est fermée (onDispose) et la base du nouveau serveur est ouverte.
final databaseProvider = Provider<AppDatabase>((ref) {
  final fileName = ref.watch(activeDbFileNameProvider);
  final db = AppDatabase.forFile(fileName);
  ref.onDispose(db.close);
  return db;
});

/// Helper : convertit un [DateTime] en millisecondes Unix pour SQLite.
int dateTimeToUnix(DateTime dt) => dt.millisecondsSinceEpoch;

DateTime unixToDateTime(int ms) =>
    DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
