/// Shell principal : Scaffold avec barre de navigation inférieure + drawer
/// pour les modules secondaires. Gère le RBAC (affichage conditionnel).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/auth_state.dart';
import '../core/config/constants.dart';
import '../core/utils/permissions.dart';

/// Index de l'onglet courant.
final shellNavIndexProvider = StateProvider<int>((ref) => 0);

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child, required this.index});

  final Widget child;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final perms = auth.permissions;

    final destinations = <_NavDestination>[
      _NavDestination(
        icon: Icons.dashboard_outlined,
        activeIcon: Icons.dashboard,
        label: 'Accueil',
        route: '/dashboard',
      ),
      _NavDestination(
        icon: Icons.school_outlined,
        activeIcon: Icons.school,
        label: 'Classes',
        route: '/classrooms',
        permission: RbacPermissions.studentRead,
      ),
      _NavDestination(
        icon: Icons.people_outline,
        activeIcon: Icons.people,
        label: 'Élèves',
        route: '/students',
        permission: RbacPermissions.studentRead,
      ),
      _NavDestination(
        icon: Icons.grading_outlined,
        activeIcon: Icons.grading,
        label: 'Notes',
        route: '/grades',
        permission: RbacPermissions.gradeRead,
      ),
      _NavDestination(
        icon: Icons.more_horiz,
        activeIcon: Icons.more_horiz,
        label: 'Plus',
        route: '/more',
      ),
    ].where((d) => d.permission == null || hasPermission(perms, d.permission!)).toList();

    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: index < destinations.length ? index : 0,
        onDestinationSelected: (i) {
          final dest = destinations[i];
          context.go(dest.route);
        },
        destinations: destinations
            .map((d) => NavigationDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.activeIcon),
                  label: d.label,
                ))
            .toList(),
      ),
      drawer: const _AppDrawer(),
    );
  }
}

class _NavDestination {
  const _NavDestination({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.route,
    this.permission,
  });
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final String route;
  final String? permission;
}

class _AppDrawer extends ConsumerWidget {
  const _AppDrawer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final perms = auth.permissions;
    final theme = Theme.of(context);

    final items = <_DrawerItem>[
      _DrawerItem(
        icon: Icons.calendar_view_week_outlined,
        label: 'Emploi du temps',
        route: '/schedule',
        permission: RbacPermissions.studentRead,
      ),
      _DrawerItem(
        icon: Icons.fact_check_outlined,
        label: 'Présence',
        route: '/attendance',
        permission: RbacPermissions.studentRead,
      ),
      _DrawerItem(
        icon: Icons.leaderboard_outlined,
        label: 'Classement',
        route: '/grades/ranking',
        permission: RbacPermissions.gradeRead,
      ),
      _DrawerItem(
        icon: Icons.menu_book_outlined,
        label: 'Matières',
        route: '/subjects',
        permission: RbacPermissions.gradeRead,
      ),
      _DrawerItem(
        icon: Icons.payments_outlined,
        label: 'Paiements',
        route: '/finance',
        permission: RbacPermissions.paymentRead,
      ),
      _DrawerItem(
        icon: Icons.account_balance_wallet_outlined,
        label: 'Soldes élèves',
        route: '/finance/balances',
        permission: RbacPermissions.paymentRead,
      ),
      _DrawerItem(
        icon: Icons.manage_accounts_outlined,
        label: 'Utilisateurs',
        route: '/users',
        permission: RbacPermissions.userRead,
      ),
      _DrawerItem(
        icon: Icons.upload_file_outlined,
        label: 'Importer des élèves',
        route: '/students/import',
        permission: RbacPermissions.studentCreate,
      ),
      _DrawerItem(
        icon: Icons.domain_outlined,
        label: 'Établissements',
        route: '/establishments',
      ),
      _DrawerItem(
        icon: Icons.link_outlined,
        label: 'Connexions',
        route: '/connections',
      ),
      _DrawerItem(
        icon: Icons.settings_outlined,
        label: 'Paramètres',
        route: '/settings',
      ),
    ];

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UserAccountsDrawerHeader(
              accountName: Text(auth.user?.fullName ?? 'Utilisateur'),
              accountEmail: Text(auth.user?.email ??
                  auth.user?.username ??
                  'GeTech-SMS'),
              currentAccountPicture: CircleAvatar(
                backgroundColor: theme.colorScheme.primary,
                child: Text(
                  (auth.user?.fullName.isNotEmpty == true
                          ? auth.user!.fullName[0]
                          : 'G')
                      .toUpperCase(),
                  style: TextStyle(
                      fontSize: 24, color: theme.colorScheme.onPrimary),
                ),
              ),
              decoration: BoxDecoration(color: theme.colorScheme.primary),
            ),
            Expanded(
              child: ListView(
                children: items
                    .where((i) =>
                        i.permission == null ||
                        hasPermission(perms, i.permission!))
                    .map((i) => ListTile(
                          leading: Icon(i.icon),
                          title: Text(i.label),
                          onTap: () {
                            Navigator.pop(context);
                            context.go(i.route);
                          },
                        ))
                    .toList(),
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.red),
              title: const Text('Déconnexion'),
              onTap: () async {
                Navigator.pop(context);
                await ref.read(authProvider.notifier).logout();
                if (context.mounted) context.go('/login');
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerItem {
  const _DrawerItem({
    required this.icon,
    required this.label,
    required this.route,
    this.permission,
  });
  final IconData icon;
  final String label;
  final String route;
  final String? permission;
}
