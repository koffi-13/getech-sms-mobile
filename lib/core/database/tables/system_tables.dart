/// Tables Drift "system" : utilisateurs (cache local), métadonnées de synchro,
/// outbox (file d'attente des writes offline), appareils appairés.
library;

import 'package:drift/drift.dart';

/// Utilisateur (cache local pour noms/rôles).
class Users extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get username => text().withLength(min: 1, max: 64)();
  TextColumn get firstName => text().nullable()();
  TextColumn get lastName => text().nullable()();
  TextColumn get email => text().nullable()();
  TextColumn get phone => text().nullable()();
  TextColumn get photoPath => text().nullable()();
  TextColumn get sexe => text().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  BoolColumn get isSuperuser => boolean().withDefault(const Constant(false))();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
}

/// Métadonnées de synchro par table : watermark `last_synced_at`.
class SyncMetadata extends Table {
  TextColumn get tableName => text().withLength(min: 1, max: 64)();
  DateTimeColumn get lastSyncedAt => dateTime().nullable()();
  IntColumn get lastCount => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {tableName};
}

/// Opération en attente de push (outbox pattern).
///
/// Chaque write offline (création/édition/suppression) génère une ligne ici.
/// Le sync engine dépile l'outbox et POST vers `/sync/push`.
class OutboxEntries extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get tableName => text()();
  TextColumn get operation => text()(); // 'INSERT' | 'UPDATE' | 'DELETE'
  IntColumn get recordId => integer().nullable()();
  TextColumn get payload => text()(); // JSON sérialisé
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();
  BoolColumn get processed => boolean().withDefault(const Constant(false))();
}

/// Appareil appairé (cache local de la liste serveur).
class PairedDevices extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get deviceName => text()();
  TextColumn get deviceType => text().withDefault(const Constant('MOBILE'))();
  TextColumn get deviceUuid => text()();
  DateTimeColumn get pairedAt => dateTime().nullable()();
  DateTimeColumn get lastSeen => dateTime().nullable()();
  BoolColumn get isRevoked => boolean().withDefault(const Constant(false))();
  IntColumn get userId => integer().nullable()();
  DateTimeColumn get syncedAt => dateTime().nullable()();
}
