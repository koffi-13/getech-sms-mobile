import 'package:flutter/material.dart';

/// Carte KPI pour le tableau de bord.
///
/// [Fix-FONT-SCALE-OVERFLOW] V17 — retour utilisateur (S4) : « problème
/// d'affichage des overflows qui survient surtout lorsqu'un utilisateur
/// utilise une taille de police grande ». Les tuiles KPI utilisaient un
/// `Column` rigide avec `mainAxisAlignment.spaceBetween` : en grande
/// police, la valeur (headlineMedium) + le label dépassaient la hauteur
/// de la carte (childAspectRatio fixe) → bandes jaunes « OVERFLOWED ».
///
/// Désormais :
/// - la carte enveloppe son contenu dans un `FittedBox` pour la VALEUR
///   (le chiffre se rétrécit au lieu de déborder) ;
/// - le label passe sur 2 lignes max avec ellipsis ;
/// - l'icône garde sa taille fixe (décorative) ;
/// - la tendance reste sur une ligne mais se limite (ellipsis).
class KpiCard extends StatelessWidget {
  const KpiCard({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.trend,
    this.trendUp,
    this.onTap,
    this.color,
  });

  final String label;
  final String value;
  final IconData? icon;
  final String? trend;
  final bool? trendUp;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = color ?? theme.colorScheme.primary;
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (icon != null)
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(icon, size: 18, color: accent),
                    ),
                  const Spacer(),
                  if (trend != null)
                    Flexible(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            trendUp == true
                                ? Icons.trending_up
                                : Icons.trending_down,
                            size: 14,
                            color: trendUp == true
                                ? Colors.green
                                : Colors.red.shade400,
                          ),
                          const SizedBox(width: 2),
                          Flexible(
                            child: Text(
                              trend!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: trendUp == true
                                    ? Colors.green
                                    : Colors.red.shade400,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              // [Fix-FONT-SCALE-OVERFLOW] : le chiffre s'adapte à la place
              // disponible (FittedBox) au lieu de déborder verticalement.
              Flexible(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      value,
                      maxLines: 1,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
