import 'package:flutter/material.dart';

import '../../features/connections/connection_state.dart'
    show ServerStatus;

/// Badge de statut coloré (en ligne / hors-ligne / etc.).
class StatusBadge extends StatelessWidget {
  const StatusBadge({
    super.key,
    required this.label,
    required this.color,
    this.icon,
    this.filled = true,
  });

  factory StatusBadge.online() => const StatusBadge(
        label: 'En ligne',
        color: Colors.green,
        icon: Icons.cloud_done,
      );

  factory StatusBadge.offline() => const StatusBadge(
        label: 'Hors-ligne',
        color: Colors.orange,
        icon: Icons.cloud_off,
      );

  factory StatusBadge.checking() => const StatusBadge(
        label: 'Vérification…',
        color: Colors.blueGrey,
        icon: Icons.sync,
      );

  factory StatusBadge.fromServerStatus(ServerStatus status) {
    switch (status) {
      case ServerStatus.online:
        return StatusBadge.online();
      case ServerStatus.offline:
        return StatusBadge.offline();
      case ServerStatus.checking:
        return StatusBadge.checking();
      case ServerStatus.unpaired:
        return const StatusBadge(
          label: 'Non appairé',
          color: Colors.grey,
          icon: Icons.link_off,
        );
    }
  }

  final String label;
  final Color color;
  final IconData? icon;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: filled ? color.withValues(alpha: 0.14) : Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        border: filled ? null : Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
