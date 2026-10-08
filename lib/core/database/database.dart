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
  int get schemaVersion => 4;

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
          // Ces colonnes sont déjà dans le schéma de la table (academic_tables.dart).
          // [Fix-SYNC-IDEMPOTENCE] Ajout des colonnes idempotency_key, device_uuid,
          // sync_version sur grades et student_absences.
          if (from < 2) {
            await m.addColumn(grades, grades.idempotencyKey);
            await m.addColumn(grades, grades.deviceUuid);
            await m.addColumn(grades, grades.syncVersion);

            await m.addColumn(studentAbsences, studentAbsences.idempotencyKey);
            await m.addColumn(studentAbsences, studentAbsences.deviceUuid);
            await m.addColumn(studentAbsences, studentAbsences.syncVersion);
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
          // v3 → v4 [Merge sync-idempotency] : aligne les deux lignées.
          // Les bases issues de main (v3) n'ont PAS les colonnes
          // d'idempotence ; celles de la branche (v2) les ont déjà reçues
          // via from<2. Ajout tolérant : on ne touche pas aux colonnes
          // déjà présentes (introspection pragma_table_info).
          if (from < 4) {
            Future<void> addIfMissing(
              TableInfo t,
              GeneratedColumn c,
            ) async {
              final present = await customSelect(
                "SELECT 1 FROM pragma_table_info('${t.actualTableName}') "
                "WHERE name = '${c.name}' LIMIT 1",
              ).get();
              if (present.isEmpty) {
                await m.addColumn(t, c);
              }
            }

            await addIfMissing(grades, grades.idempotencyKey);
            await addIfMissing(grades, grades.deviceUuid);
            await addIfMissing(grades, grades.syncVersion);
            await addIfMissing(studentAbsences, studentAbsences.idempotencyKey);
            await addIfMissing(studentAbsences, studentAbsences.deviceUuid);
            await addIfMissing(studentAbsences, studentAbsences.syncVersion);
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
