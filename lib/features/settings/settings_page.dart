/// Page Paramètres : apparence (thème), connexion serveur, année/période
/// scolaire, accès au profil, à propos.
///
/// Héberge plusieurs sections (cartes) sous une [ListView]. Les sections
/// nécessitant un état local (thème, mode hors-ligne, dropdowns année/période)
/// sont des widgets séparés (`ConsumerWidget` ou `ConsumerStatefulWidget`).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app.dart';
import '../../core/config/app_config.dart';
import '../connections/connection_state.dart';
import '../connections/connections_controller.dart' show serverInfoProvider;
import '../../shared/models/classroom_dto.dart' show PeriodDto;
import '../../shared/widgets/widgets.dart';
import 'settings_controller.dart';

/// Page Paramètres (sans état propre — délègue aux sous-sections).
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Paramètres')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: const [
          _AppearanceSection(),
          SizedBox(height: 12),
          _ConnectionSection(),
          SizedBox(height: 12),
          _SchoolYearPeriodSection(),
          SizedBox(height: 12),
          _ProfileSection(),
          SizedBox(height: 12),
          _AboutSection(),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section : Apparence (thème clair / sombre / système)
// ---------------------------------------------------------------------------

class _AppearanceSection extends ConsumerWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final current = ref.watch(themeModeProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              title: 'Apparence',
              icon: Icons.palette_outlined,
            ),
            const SizedBox(height: 8),
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                  value: ThemeMode.light,
                  icon: Icon(Icons.light_mode_outlined),
                  label: Text('Clair'),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  icon: Icon(Icons.dark_mode_outlined),
                  label: Text('Sombre'),
                ),
                ButtonSegment(
                  value: ThemeMode.system,
                  icon: Icon(Icons.settings_brightness_outlined),
                  label: Text('Système'),
                ),
              ],
              selected: {current},
              onSelectionChanged: (selection) async {
                if (selection.isEmpty) return;
                final next = selection.first;
                ref.read(themeModeProvider.notifier).state = next;
                // Persiste le choix (restauration au démarrage futur).
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString(
                  AppConfig.prefThemeMode,
                  next.name, // 'light' | 'dark' | 'system'
                );
              },
            ),
            const SizedBox(height: 6),
            Text(
              'Le thème système suit le réglage de votre appareil.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section : Connexion serveur
// ---------------------------------------------------------------------------

class _ConnectionSection extends ConsumerWidget {
  const _ConnectionSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final conn = ref.watch(connectionProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              title: 'Connexion au serveur',
              icon: Icons.cloud_outlined,
            ),
            const SizedBox(height: 4),
            _kvRow(
              context,
              icon: Icons.link,
              label: 'URL serveur',
              value: conn.serverUrl ?? '—',
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.verified_outlined,
                    size: 18, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                const Text('Statut : '),
                StatusBadge.fromServerStatus(conn.status),
                if (conn.latency != null) ...[
                  const SizedBox(width: 10),
                  Text(
                    '${conn.latency!.inMilliseconds} ms',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Mode hors-ligne forcé'),
              subtitle: Text(
                conn.forceOffline
                    ? 'Toutes les requêtes réseau sont suspendues.'
                    : 'Les requêtes réseau sont actives.',
                style: theme.textTheme.bodySmall,
              ),
              value: conn.forceOffline,
              onChanged: (_) =>
                  ref.read(connectionProvider.notifier).toggleForceOffline(),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => context.push('/connections'),
                icon: const Icon(Icons.settings_ethernet, size: 18),
                label: const Text('Gérer les connexions'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kvRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
  }) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Text(label,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Section : Année scolaire / Période
// ---------------------------------------------------------------------------

class _SchoolYearPeriodSection extends ConsumerStatefulWidget {
  const _SchoolYearPeriodSection();

  @override
  ConsumerState<_SchoolYearPeriodSection> createState() =>
      _SchoolYearPeriodSectionState();
}

class _SchoolYearPeriodSectionState
    extends ConsumerState<_SchoolYearPeriodSection> {
  int? _selectedSchoolYearId;
  int? _selectedPeriodId;
  bool _prefsLoaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    if (_prefsLoaded) return;
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _selectedSchoolYearId =
          prefs.getInt(AppConfig.prefCurrentSchoolYearId);
      _selectedPeriodId = prefs.getInt(AppConfig.prefCurrentPeriodId);
      _prefsLoaded = true;
    });
  }

  Future<void> _persistSchoolYear(int? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(AppConfig.prefCurrentSchoolYearId);
    } else {
      await prefs.setInt(AppConfig.prefCurrentSchoolYearId, id);
    }
  }

  Future<void> _persistPeriod(int? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(AppConfig.prefCurrentPeriodId);
    } else {
      await prefs.setInt(AppConfig.prefCurrentPeriodId, id);
    }
  }

  /// Étiquette lisible pour une année scolaire (ex : "2024 - 2025").
  String _schoolYearLabel(Iterable<PeriodDto> yearPeriods) {
    final start = yearPeriods
        .map((p) => p.startDate)
        .whereType<DateTime>()
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final end = yearPeriods
        .map((p) => p.endDate)
        .whereType<DateTime>()
        .reduce((a, b) => a.isAfter(b) ? a : b);
    if (start.year == end.year) return '${start.year}';
    return '${start.year} - ${end.year}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final periodsAsync = ref.watch(periodsProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              title: 'Année scolaire / Période',
              subtitle: 'Sélection active pour les notes et bulletins.',
              icon: Icons.event_outlined,
            ),
            const SizedBox(height: 4),
            periodsAsync.when(
              data: (periods) {
                if (periods.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: EmptyState(
                      title: 'Aucune période',
                      message: _offlineMessage(ref),
                      icon: Icons.event_busy_outlined,
                    ),
                  );
                }

                // Regroupe les périodes par année scolaire (préserve l'ordre).
                final yearGroups = <int, List<PeriodDto>>{};
                for (final p in periods) {
                  final syId = p.schoolYearId ?? 0;
                  yearGroups.putIfAbsent(syId, () => []).add(p);
                }
                final yearIds = yearGroups.keys.toList();

                // Si la valeur sélectionnée n'est plus valide, on prend
                // l'année active (is_active) ou la première.
                if (_selectedSchoolYearId == null ||
                    !yearGroups.containsKey(_selectedSchoolYearId)) {
                  final active = periods.firstWhere(
                    (p) => p.isActive,
                    orElse: () => periods.first,
                  );
                  _selectedSchoolYearId = active.schoolYearId ?? 0;
                }
                final yearPeriods =
                    yearGroups[_selectedSchoolYearId!] ?? const [];

                // Filtre les périodes pour l'année sélectionnée.
                if (_selectedPeriodId != null &&
                    !yearPeriods.any((p) => p.id == _selectedPeriodId)) {
                  _selectedPeriodId = null;
                }
                if (_selectedPeriodId == null) {
                  final active = yearPeriods
                      .firstWhere((p) => p.isActive, orElse: () => yearPeriods.first);
                  _selectedPeriodId = active.id;
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DropdownButtonFormField<int>(
                      decoration: const InputDecoration(
                        labelText: 'Année scolaire',
                        prefixIcon: Icon(Icons.calendar_today_outlined),
                        border: OutlineInputBorder(),
                      ),
                      value: _selectedSchoolYearId,
                      items: yearIds
                          .map((id) => DropdownMenuItem(
                                value: id,
                                child: Text(_schoolYearLabel(yearGroups[id]!)),
                              ))
                          .toList(),
                      onChanged: (v) async {
                        setState(() {
                          _selectedSchoolYearId = v;
                          _selectedPeriodId = null;
                        });
                        await _persistSchoolYear(v);
                        // Re-sélectionne la période par défaut.
                        final list = yearGroups[v] ?? const <PeriodDto>[];
                        if (list.isNotEmpty) {
                          final def = list.firstWhere(
                            (p) => p.isActive,
                            orElse: () => list.first,
                          );
                          setState(() => _selectedPeriodId = def.id);
                          await _persistPeriod(def.id);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      decoration: const InputDecoration(
                        labelText: 'Période',
                        prefixIcon: Icon(Icons.date_range_outlined),
                        border: OutlineInputBorder(),
                      ),
                      value: _selectedPeriodId,
                      items: yearPeriods
                          .map((p) => DropdownMenuItem(
                                value: p.id,
                                child: Text(
                                  p.name +
                                      (p.isActive ? '  (active)' : ''),
                                ),
                              ))
                          .toList(),
                      onChanged: (v) async {
                        setState(() => _selectedPeriodId = v);
                        await _persistPeriod(v);
                      },
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Choix enregistré localement (appliqué aux prochaines vues).',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                );
              },
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2.4)),
              ),
              error: (err, _) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: AppErrorWidget(
                  message: 'Impossible de charger les périodes : $err',
                  compact: true,
                  onRetry: () => ref.invalidate(periodsProvider),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _offlineMessage(WidgetRef ref) {
    final conn = ref.watch(connectionProvider);
    if (!conn.canReachServer) {
      return 'Serveur hors-ligne — réessayez plus tard.';
    }
    return 'Aucune période n\'a été configurée côté serveur.';
  }
}

// ---------------------------------------------------------------------------
// Section : Profil (accès à la page d'édition)
// ---------------------------------------------------------------------------

class _ProfileSection extends ConsumerWidget {
  const _ProfileSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final auth = ref.watch(authProvider);
    final user = auth.user;
    final initials = _initials(user?.fullName);

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push('/settings/profile'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: theme.colorScheme.primary,
                child: Text(
                  initials,
                  style: TextStyle(
                    color: theme.colorScheme.onPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user?.fullName.isNotEmpty == true
                          ? user!.fullName
                          : (user?.username ?? 'Utilisateur'),
                      style: theme.textTheme.titleSmall,
                    ),
                    if (user?.email != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        user!.email!,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      'Appuyez pour modifier votre profil et votre mot de passe.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }

  String _initials(String? fullName) {
    final name = (fullName ?? '').trim();
    if (name.isEmpty) return 'U';
    final parts = name.split(RegExp(r'\s+'));
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }
}

// ---------------------------------------------------------------------------
// Section : À propos
// ---------------------------------------------------------------------------

class _AboutSection extends ConsumerWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final serverInfoAsync = ref.watch(serverInfoProvider);
    final establishmentAsync = ref.watch(establishmentProvider);

    final serverVersion = serverInfoAsync.maybeWhen(
      data: (s) => s?.serverVersion,
      orElse: () => null,
    );
    final establishmentName = establishmentAsync.maybeWhen(
      data: (e) => e?.name,
      orElse: () => null,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              title: 'À propos',
              icon: Icons.info_outline,
            ),
            const SizedBox(height: 4),
            _kvRow(context, 'Application', '${AppConfig.appName} v${AppConfig.appVersion}'),
            _kvRow(context, 'API', AppConfig.apiPrefix),
            _kvRow(
              context,
              'Établissement',
              establishmentName ?? '—',
            ),
            _kvRow(
              context,
              'Version serveur',
              serverVersion ?? '—',
            ),
            const SizedBox(height: 8),
            Text(
              '© ${DateTime.now().year} GeTech-SMS. Tous droits réservés.',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kvRow(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
