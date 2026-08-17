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
import '../../core/auth/auth_state.dart';
import '../../core/config/app_config.dart';
import '../connections/connection_state.dart';
import '../connections/connections_controller.dart' show serverInfoProvider;
import '../../shared/models/classroom_dto.dart' show PeriodDto;
import '../../shared/widgets/widgets.dart';
import 'settings_controller.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Paramètres'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _ProfileSection(),
          const SizedBox(height: 16),
          const _AppearanceSection(),
          const SizedBox(height: 16),
          const _SyncSection(),
          const SizedBox(height: 16),
          const _AboutSection(),
          const SizedBox(height: 32),
          Center(
            child: TextButton.icon(
              onPressed: () => _handleLogout(context, ref),
              icon: const Icon(Icons.logout),
              label: const Text('Déconnexion'),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
          const SizedBox(height: 48),
        ],
      ),
    );
  }

  Future<void> _handleLogout(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Déconnexion'),
        content: const Text('Voulez-vous vraiment vous déconnecter ?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Se déconnecter'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(authProvider.notifier).logout();
    }
  }
}

class _ProfileSection extends ConsumerWidget {
  const _ProfileSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final user = auth.user;
    final theme = Theme.of(context);

    return Card(
      child: Column(
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text(
                user?.username.substring(0, 1).toUpperCase() ?? 'U',
                style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
              ),
            ),
            title: Text(user?.fullName ?? 'Utilisateur'),
            subtitle: Text(user?.email ?? 'Aucun email'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/profile'),
          ),
        ],
      ),
    );
  }
}

class _AppearanceSection extends ConsumerWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final themeMode = settings.themeMode;

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('Apparence',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Thème'),
            subtitle: Text(_themeModeLabel(themeMode)),
            onTap: () => _showThemePicker(context, ref, themeMode),
          ),
        ],
      ),
    );
  }

  String _themeModeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return 'Système';
      case ThemeMode.light:
        return 'Clair';
      case ThemeMode.dark:
        return 'Sombre';
    }
  }

  void _showThemePicker(BuildContext context, WidgetRef ref, ThemeMode current) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.brightness_auto_outlined),
              title: const Text('Système'),
              trailing: current == ThemeMode.system ? const Icon(Icons.check) : null,
              onTap: () {
                ref.read(settingsProvider.notifier).setThemeMode(ThemeMode.system);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.light_mode_outlined),
              title: const Text('Clair'),
              trailing: current == ThemeMode.light ? const Icon(Icons.check) : null,
              onTap: () {
                ref.read(settingsProvider.notifier).setThemeMode(ThemeMode.light);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.dark_mode_outlined),
              title: const Text('Sombre'),
              trailing: current == ThemeMode.dark ? const Icon(Icons.check) : null,
              onTap: () {
                ref.read(settingsProvider.notifier).setThemeMode(ThemeMode.dark);
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SyncSection extends ConsumerWidget {
  const _SyncSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider);
    final settings = ref.watch(settingsProvider);

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('Synchronisation & Connexion',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          ListTile(
            leading: const Icon(Icons.wifi_tethering),
            title: const Text('Serveur local'),
            subtitle: Text(conn.serverIp ?? 'Non configuré'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/pairing'),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.cloud_off_outlined),
            title: const Text('Mode hors-ligne forcé'),
            subtitle: const Text('Désactive toute tentative de connexion.'),
            value: settings.forceOffline,
            onChanged: (v) {
              ref.read(settingsProvider.notifier).setForceOffline(v);
            },
          ),
        ],
      ),
    );
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('À propos',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Version'),
            subtitle: Text('GeTech-SMS Mobile v1.0.0'),
          ),
          ListTile(
            leading: Icon(Icons.copyright_outlined),
            title: Text('Éditeur'),
            subtitle: Text('© 2024 GeTech-SMS'),
          ),
        ],
      ),
    );
  }
}
