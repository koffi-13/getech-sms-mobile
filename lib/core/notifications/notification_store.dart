/// Historique local des notifications affichées — GeTech-SMS Mobile.
///
/// [Notif-V8] Complète le système de notifications :
/// - [NotificationService] émet des notifications système (rappels de cours,
///   validation des notes, synchronisation) ;
/// - [NotificationStore] PERSISTE chacune (SharedPreferences, plafonnée à
///   50) pour le Centre de notifications : cloche + badge dans l'AppBar de
///   l'Accueil, liste lisible, marquage lu/non lu, effacement.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Catégories de notifications (icône + couleur du centre).
enum NotificationCategory {
  grades('Notes'),
  sync('Synchronisation'),
  course('Cours'),
  system('Informations');

  const NotificationCategory(this.label);
  final String label;
}

/// Une notification persistée.
class NotificationEntry {
  final int id;
  final String title;
  final String body;
  final NotificationCategory category;

  /// Route à ouvrir au clic (ex. '/grades'), null si aucune.
  final String? route;

  /// Date d'affichage (ISO 8601).
  final DateTime createdAt;

  /// Déjà lue dans le centre ?
  final bool read;

  const NotificationEntry({
    required this.id,
    required this.title,
    required this.body,
    required this.category,
    this.route,
    required this.createdAt,
    this.read = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'category': category.name,
        'route': route,
        'created_at': createdAt.toIso8601String(),
        'read': read,
      };

  static NotificationEntry? fromJson(Map<String, dynamic> j) {
    final cat = NotificationCategory.values
        .where((c) => c.name == j['category'])
        .firstOrNull;
    if (cat == null) return null;
    final created = DateTime.tryParse(j['created_at']?.toString() ?? '');
    if (created == null) return null;
    return NotificationEntry(
      id: (j['id'] as num?)?.toInt() ?? 0,
      title: j['title']?.toString() ?? '',
      body: j['body']?.toString() ?? '',
      category: cat,
      route: j['route']?.toString(),
      createdAt: created,
      read: j['read'] == true,
    );
  }

  NotificationEntry copyWith({bool? read}) => NotificationEntry(
        id: id,
        title: title,
        body: body,
        category: category,
        route: route,
        createdAt: createdAt,
        read: read ?? this.read,
      );
}

/// Stockage local des notifications (SharedPreferences, plafonnées à
/// [_maxEntries], la plus récente en premier).
class NotificationStore {
  static const String _key = 'getech.notifications.history';
  static const int _maxEntries = 50;

  Future<List<NotificationEntry>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const [];
    try {
      final rows = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((e) =>
              NotificationEntry.fromJson(Map<String, dynamic>.from(e)))
          .whereType<NotificationEntry>()
          .toList();
      rows.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return rows;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _save(List<NotificationEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    final capped =
        (entries..sort((a, b) => b.createdAt.compareTo(a.createdAt)))
            .take(_maxEntries)
            .toList();
    await prefs.setString(
        _key, jsonEncode(capped.map((e) => e.toJson()).toList()));
  }

  /// Ajoute une notification en tête d'historique (non lue).
  Future<void> add(NotificationEntry entry) async {
    final entries = [...await load()];
    // Déduplication : même id (déjà présent) → on remplace.
    entries.removeWhere((e) => e.id == entry.id);
    entries.add(entry);
    await _save(entries);
  }

  Future<void> markAllRead() async {
    final entries = await load();
    await _save([for (final e in entries) e.copyWith(read: true)]);
  }

  Future<void> markRead(int id) async {
    final entries = await load();
    await _save([
      for (final e in entries)
        if (e.id == id) e.copyWith(read: true) else e,
    ]);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

/// Provider du store.
final notificationStoreProvider =
    Provider<NotificationStore>((ref) => NotificationStore());

/// État du centre : liste + compteur non-lus.
class NotificationCenterState {
  final List<NotificationEntry> entries;
  const NotificationCenterState({this.entries = const []});

  int get unreadCount =>
      entries.where((e) => !e.read).length;
}

/// Provider de l'état du centre de notifications (liste persistée).
/// Toute modification repasse par [reloadNotificationCenter].
final notificationCenterProvider =
    StateNotifierProvider<NotificationCenterController, NotificationCenterState>(
  (ref) => NotificationCenterController(ref),
);

class NotificationCenterController
    extends StateNotifier<NotificationCenterState> {
  NotificationCenterController(this._ref)
      : super(const NotificationCenterState()) {
    reload();
  }

  final Ref _ref;

  Future<void> reload() async {
    final entries = await _ref.read(notificationStoreProvider).load();
    state = NotificationCenterState(entries: entries);
  }

  Future<void> add(NotificationEntry entry) async {
    await _ref.read(notificationStoreProvider).add(entry);
    await reload();
  }

  Future<void> markAllRead() async {
    await _ref.read(notificationStoreProvider).markAllRead();
    await reload();
  }

  Future<void> markRead(int id) async {
    await _ref.read(notificationStoreProvider).markRead(id);
    await reload();
  }

  Future<void> clear() async {
    await _ref.read(notificationStoreProvider).clear();
    await reload();
  }
}
