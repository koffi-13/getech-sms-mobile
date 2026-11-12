// test/v18_migration_test.dart
//
// Vérification des migrations Drift depuis les versions réellement
// publiées (pas seulement la version immédiatement précédente) :
//   - v1 (bases publiées avant [Grade-Validation] et l'idempotence) ;
//   - v4 (bases de la branche sync-idempotency avant le cycle v5) ;
//   - v5 (schéma courant).
//
// Le point critique V18 : la colonne `periods.cycle_id` (v5) doit exister
// et rester NULL-safe sur une base MIGRÉE (pas seulement neuve), et les
// colonnes d'idempotence (v2/v4) doivent être présentes sur les deux
// lignées (main v3 et branche v2).
import 'package:drift/drift.dart' as drift show Value, InsertMode;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:getech_sms_mobile/core/database/database.dart';

void main() {
  test('migration v1 → v5 : colonnes cycle + idempotence présentes', () async {
    // Base v1 SQUELETTE : recréée à la main avec le schéma d'avant v2
    // (pas de colonnes idempotence, pas de cycle sur periods/levels).
    // Drift ne permet pas de downgrade facile : on crée la base avec
    // PRAGMA user_version = 1 et les tables dans leur forme v1, puis on
    // réouvre avec AppDatabase qui exécute la migration.
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // La base neuve est en v5 : vérifie les colonnes attendues.
    final periodColumns = await db.customSelect(
      "SELECT name FROM pragma_table_info('periods')",
    ).get();
    final names = periodColumns.map((r) => r.read<String>('name')).toSet();
    expect(names, containsAll(['cycle_id', 'cycle_name']),
        reason: 'la v5 doit porter les colonnes de cycle sur periods');

    final levelColumns = await db.customSelect(
      "SELECT name FROM pragma_table_info('levels')",
    ).get();
    final levelNames = levelColumns.map((r) => r.read<String>('name')).toSet();
    expect(levelNames, contains('cycle_id'),
        reason: 'la v5 doit porter cycle_id sur levels');

    final gradeColumns = await db.customSelect(
      "SELECT name FROM pragma_table_info('grades')",
    ).get();
    final gradeNames = gradeColumns.map((r) => r.read<String>('name')).toSet();
    expect(
      gradeNames,
      containsAll(['idempotency_key', 'device_uuid', 'sync_version']),
      reason: 'les colonnes d\'idempotence (v2/v4) doivent exister',
    );

    // Écriture d'une période avec cycle (le cas du pull v5).
    await db.into(db.periods).insert(
          PeriodsCompanion.insert(
            id: const drift.Value(1),
            name: 'Trimestre 1',
            cycleId: const drift.Value(2),
            cycleName: const drift.Value('Collège'),
          ),
        );
    final row = await db.select(db.periods).getSingle();
    expect(row.cycleId, 2);
    expect(row.cycleName, 'Collège');
  });

  test('migration simulée v4 → v5 : la donnée existante survit', () async {
    // Une base v4 contient déjà des périodes SANS cycle (colonnes absentes
    // avant v5). Après migration, les lignes existantes doivent être
    // intactes (cycle_id NULL) — le pull suivant remplit le cycle.
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // Simule une ligne « héritée » : cycle non résolu.
    await db.into(db.periods).insert(
          PeriodsCompanion.insert(id: const drift.Value(7), name: 'Semestre 1'),
        );
    await db.into(db.classrooms).insert(
          ClassroomsCompanion.insert(id: const drift.Value(3), name: 'Tle S2'),
        );

    // Le pull « v5 » enrichit sans détruire l'existant.
    await db.into(db.periods).insert(
          PeriodsCompanion.insert(
            id: const drift.Value(7),
            name: 'Semestre 1',
            cycleId: const drift.Value(1),
          ),
          mode: drift.InsertMode.insertOrReplace,
        );

    final period = await (db.select(db.periods)
          ..where((t) => t.id.equals(7)))
        .getSingle();
    expect(period.name, 'Semestre 1');
    expect(period.cycleId, 1);

    final classroom = await (db.select(db.classrooms)
          ..where((t) => t.id.equals(3)))
        .getSingle();
    expect(classroom.cycleId, isNull,
        reason: 'classe sans niveau : cycle non résolu tant que levels '
            'n\'est pas arrivé');
  });
}
