/// Outbox pattern — file d'attente des écritures locales en attente de push.
///
/// Chaque modification locale (création / édition / suppression) est
/// enregistrée dans la table `outbox_entries`. Le [SyncEngine] dépile
/// ensuite cette file lors d'un [SyncEngine.push] pour envoyer les
/// changements au serveur.
///
/// Le `payload` de chaque entrée est sérialisé en JSON (texte) pour rester
/// agnostique du type de table.
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';

/// Extension pratique pour décoder le `payload` JSON d'une entrée d'outbox.
extension OutboxEntryX on OutboxEntry {
  /// Décode le `payload` (JSON texte) en [Map].
  ///
  /// Retourne une map vide si le décodage échoue (payload corrompu).
  Map<String, dynamic> get payloadMap {
    try {
      return Map<String, dynamic>.from(jsonDecode(payload) as Map);
    } catch (_) {
      return const <String, dynamic>{};
    }
  }
}

/// Gestionnaire de l'outbox (file d'attente des writes offline).
///
/// Toutes les méthodes sont asynchrones et opèrent directement sur la base
/// Drift locale via [AppDatabase].
class Outbox {
  Outbox(this._db);

  final AppDatabase _db;

  /// Ajoute une opération en file d'attente.
  ///
  /// [table] : nom de la table ciblée (snake_case, ex. `students`).
  /// [operation] : type d'opération (`INSERT`, `UPDATE`, `DELETE`).
  /// [recordId] : identifiant de l'enregistrement concerné (nullable pour
  ///   un INSERT dont l'ID est généré côté serveur).
  /// [payload] : représentation JSON de l'enregistrement à envoyer au serveur.
  Future<void> enqueue({
    required String table,
    required String operation,
    int? recordId,
    required Map<String, dynamic> payload,
  }) async {
    await _db.into(_db.outboxEntries).insert(
          OutboxEntriesCompanion.insert(
            tableNameColumn: table,
            operation: operation,
            recordId: Value(recordId),
            payload: jsonEncode(payload),
          ),
        );
  }

  /// Retourne la liste des entrées non traitées, triées par date de création
  /// décroissante (plus récentes en premier).
  Future<List<OutboxEntry>> pending() async {
    final query = _db.select(_db.outboxEntries)
      ..where((t) => t.processed.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]);
    return query.get();
  }

  /// Marque une entrée comme traitée.
  ///
  /// [error] : message d'erreur optionnel si l'opération a échoué côté serveur
  /// (conflit server-wins, validation, etc.). L'entrée est tout de même marquée
  /// traitée pour éviter les re-tentatives infinies.
  Future<void> markProcessed(int id, {String? error}) async {
    await (_db.update(_db.outboxEntries)..where((t) => t.id.equals(id)))
        .write(
      OutboxEntriesCompanion(
        processed: const Value(true),
        lastError: Value(error),
      ),
    );
  }

  /// Supprime toutes les entrées marquées comme traitées (nettoyage).
  Future<void> clearProcessed() async {
    await (_db.delete(_db.outboxEntries)..where((t) => t.processed.equals(true)))
        .go();
  }

  /// Supprime TOUTES les entrées (pending et processed).
  Future<void> clearAll() async {
    await _db.delete(_db.outboxEntries).go();
  }

  /// Retourne le nombre d'entrées en attente de push.
  Future<int> pendingCount() async {
    final query = _db.selectOnly(_db.outboxEntries)
      ..addColumns([_db.outboxEntries.id.count()])
      ..where(_db.outboxEntries.processed.equals(false));
    final row = await query.getSingle();
    return row.read(_db.outboxEntries.id.count()) ?? 0;
  }
}

/// Provider Riverpod de l'outbox (singleton lié à la base de données).
final outboxProvider = Provider<Outbox>((ref) {
  return Outbox(ref.read(databaseProvider));
});

/// Provider exposant les entrées en attente de l'outbox.
final pendingOutboxProvider = FutureProvider.autoDispose<List<OutboxEntry>>((ref) {
  return ref.watch(outboxProvider).pending();
});
