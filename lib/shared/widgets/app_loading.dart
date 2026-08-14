import 'package:flutter/material.dart';

/// Indicateur de chargement centré avec libellé optionnel.
class AppLoading extends StatelessWidget {
  const AppLoading({super.key, this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(strokeWidth: 3),
          if (label != null) ...[
            const SizedBox(height: 16),
            Text(
              label!,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ],
      ),
    );
  }
}

/// SizedBox de chargement pour les slivers.
class SliverAppLoading extends StatelessWidget {
  const SliverAppLoading({super.key, this.label});
  final String? label;

  @override
  Widget build(BuildContext context) {
    return SliverFillRemaining(
      hasScrollBody: false,
      child: AppLoading(label: label),
    );
  }
}
