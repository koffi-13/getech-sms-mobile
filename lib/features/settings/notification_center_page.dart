/// Centre de notifications — historique lisible des notifications émises
/// par l'application (validation des notes, synchronisation, informations).
///
/// [Notif-V8] Accessible depuis la cloche de l'AppBar de l'Accueil (badge
/// non-lus) et depuis Paramètres → Notifications. Chaque entrée peut
/// ouvrir une route (ex. module Notes).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/notifications/notification_store.dart';
import '../../shared/widgets/widgets.dart';

class NotificationCenterPage extends ConsumerWidget {
  const NotificationCenterPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(notificationCenterProvider);
    final entries = state.entries;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          if (entries.any((e) => !e.read))
            TextButton(
              onPressed: () =>
                  ref.read(notificationCenterProvider.notifier).markAllRead(),
              child: const Text('Tout lire'),
            ),
          if (entries.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Effacer l\'historique',
              onPressed: () => _confirmClear(context, ref),
            ),
        ],
      ),
      body: entries.isEmpty
          ? const EmptyState(
              icon: Icons.notifications_none,
              title: 'Aucune notification',
              message:
                  'Les validations de notes, les résultats de synchronisation '
                  'et les informations importantes apparaîtront ici.',
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: entries.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final e = entries[i];
                final theme = Theme.of(context);
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: e.read
                        ? theme.colorScheme.surfaceContainerHighest
                        : theme.colorScheme.primaryContainer,
                    child: Icon(
                      _iconFor(e.category),
                      size: 20,
                      color: e.read
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  title: Text(
                    e.title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: e.read ? FontWeight.w400 : FontWeight.w700,
                    ),
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(e.body, maxLines: 3, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 2),
                        Text(
                          DateFormat('EEEE d MMMM y · HH:mm', 'fr_FR')
                              .format(e.createdAt),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  isThreeLine: true,
                  trailing: e.read
                      ? null
                      : Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                  onTap: () {
                    ref
                        .read(notificationCenterProvider.notifier)
                        .markRead(e.id);
                    if (e.route != null && e.route!.isNotEmpty) {
                      context.push(e.route!);
                    }
                  },
                );
              },
            ),
    );
  }

  static IconData _iconFor(NotificationCategory category) {
    switch (category) {
      case NotificationCategory.grades:
        return Icons.grading_outlined;
      case NotificationCategory.sync:
        return Icons.sync_outlined;
      case NotificationCategory.course:
        return Icons.schedule_outlined;
      case NotificationCategory.system:
        return Icons.info_outline;
    }
  }

  void _confirmClear(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Effacer l\'historique ?'),
        content: const Text(
            'Toutes les notifications enregistrées seront supprimées. '
            'Cette action est irréversible.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(notificationCenterProvider.notifier).clear();
            },
            child: const Text('Effacer'),
          ),
        ],
      ),
    );
  }
}
