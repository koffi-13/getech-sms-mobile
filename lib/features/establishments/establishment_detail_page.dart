/// Page "Détail établissement" : en-tête (logo/initiales, nom, code) + cartes
/// d'informations (adresse, contact, devise, pays) + badge "Établissement
/// courant" si `id == auth.establishmentId`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_state.dart';
import '../../shared/models/auth_dto.dart';
import '../../shared/widgets/widgets.dart';
import 'establishment_controller.dart';

class EstablishmentDetailPage extends ConsumerWidget {
  const EstablishmentDetailPage({super.key, required this.id});

  final int id;

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(establishmentDetailProvider(id));
    ref.invalidate(currentEstablishmentProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final isCurrent = auth.establishmentId == id;
    final async = ref.watch(establishmentDetailProvider(id));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Établissement'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Rafraîchir',
            onPressed: () => _refresh(ref),
          ),
        ],
      ),
      body: async.when(
        data: (est) => _DetailBody(
          establishment: est,
          isCurrent: isCurrent,
          onRefresh: () => _refresh(ref),
        ),
        loading: () => const AppLoading(label: 'Chargement de l\'établissement…'),
        error: (e, _) => AppErrorWidget(
          message: e.toString(),
          onRetry: () => _refresh(ref),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Body
// ---------------------------------------------------------------------------

class _DetailBody extends StatelessWidget {
  const _DetailBody({
    required this.establishment,
    required this.isCurrent,
    required this.onRefresh,
  });

  final EstablishmentDto establishment;
  final bool isCurrent;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _Header(establishment: establishment, isCurrent: isCurrent),
          const SizedBox(height: 16),
          _AddressCard(establishment: establishment),
          const SizedBox(height: 12),
          _ContactCard(establishment: establishment),
          const SizedBox(height: 12),
          _FinanceCard(establishment: establishment),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// En-tête
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({required this.establishment, required this.isCurrent});
  final EstablishmentDto establishment;
  final bool isCurrent;

  String get _initials {
    final name = establishment.name;
    if (name.isEmpty) return '?';
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final logo = establishment.logoPath;
    final hasLogo = logo != null && logo.isNotEmpty;
    final isUrl = hasLogo &&
        (logo!.startsWith('http://') || logo!.startsWith('https://'));

    return Center(
      child: Column(
        children: [
          CircleAvatar(
            radius: 44,
            backgroundColor: theme.colorScheme.primaryContainer,
            child: hasLogo && isUrl
                ? ClipOval(
                    child: Image.network(
                      logo!,
                      fit: BoxFit.cover,
                      width: 88,
                      height: 88,
                      errorBuilder: (_, __, ___) => Text(
                        _initials,
                        style: TextStyle(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                          fontSize: 32,
                        ),
                      ),
                    ),
                  )
                : Text(
                    _initials,
                    style: TextStyle(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                      fontSize: 32,
                    ),
                  ),
          ),
          const SizedBox(height: 12),
          Text(
            establishment.name,
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.tag,
                  size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(
                establishment.code,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          if (isCurrent) ...[
            const SizedBox(height: 12),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.4),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle,
                      color: theme.colorScheme.primary, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'Établissement courant',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Cartes d'informations
// ---------------------------------------------------------------------------

class _AddressCard extends StatelessWidget {
  const _AddressCard({required this.establishment});
  final EstablishmentDto establishment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = <_InfoLine>[
      _InfoLine(
        icon: Icons.location_on_outlined,
        label: 'Adresse',
        value: establishment.address,
      ),
      _InfoLine(
        icon: Icons.location_city_outlined,
        label: 'Ville',
        value: establishment.city,
      ),
      _InfoLine(
        icon: Icons.flag_outlined,
        label: 'Pays',
        value: establishment.country,
      ),
    ].where((l) => l.value != null && l.value!.isNotEmpty).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.place, color: theme.colorScheme.primary, size: 22),
                const SizedBox(width: 8),
                Text('Adresse',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 8),
            if (lines.isEmpty)
              Text(
                'Aucune adresse renseignée.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              )
            else
              ...lines.map((l) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: _InfoRow(line: l),
                  )),
          ],
        ),
      ),
    );
  }
}

class _ContactCard extends StatelessWidget {
  const _ContactCard({required this.establishment});
  final EstablishmentDto establishment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = <_InfoLine>[
      _InfoLine(
        icon: Icons.phone_outlined,
        label: 'Téléphone',
        value: establishment.phone,
      ),
      _InfoLine(
        icon: Icons.email_outlined,
        label: 'Email',
        value: establishment.email,
      ),
    ].where((l) => l.value != null && l.value!.isNotEmpty).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.contact_phone_outlined,
                    color: theme.colorScheme.primary, size: 22),
                const SizedBox(width: 8),
                Text('Contact',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 8),
            if (lines.isEmpty)
              Text(
                'Aucun contact renseigné.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              )
            else
              ...lines.map((l) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: _InfoRow(line: l),
                  )),
          ],
        ),
      ),
    );
  }
}

class _FinanceCard extends StatelessWidget {
  const _FinanceCard({required this.establishment});
  final EstablishmentDto establishment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.payments_outlined,
                    color: theme.colorScheme.primary, size: 22),
                const SizedBox(width: 8),
                Text('Devise',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 8),
            _InfoRow(
              line: _InfoLine(
                icon: Icons.attach_money,
                label: 'Devise',
                value: establishment.currency,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Modèle pour les lignes d'info
// ---------------------------------------------------------------------------

class _InfoLine {
  final IconData icon;
  final String label;
  final String? value;
  const _InfoLine({
    required this.icon,
    required this.label,
    required this.value,
  });
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.line});
  final _InfoLine line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(line.icon,
            size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                line.label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 11,
                ),
              ),
              Text(
                line.value ?? '—',
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
