/// Point d'entrée de l'application : [MaterialApp.router] avec GoRouter,
/// thème clair/sombre, localisation française.
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'app_shell.dart';
import 'core/auth/auth_state.dart';
import 'core/config/theme.dart';
import 'features/attendance/attendance_history_page.dart';
import 'features/attendance/attendance_page.dart';
import 'features/auth/login_page.dart';
import 'features/classrooms/classroom_detail_page.dart';
import 'features/classrooms/classrooms_list_page.dart';
import 'features/connections/connection_state.dart';
import 'features/connections/connections_page.dart';
import 'features/connections/device_pairing_page.dart';
import 'features/connections/qr_scanner_page.dart';
import 'features/dashboard/dashboard_page.dart';
import 'features/grades/bulletin_page.dart';
import 'features/grades/grade_entry_page.dart';
import 'features/grades/ranking_page.dart';
import 'features/schedule/schedule_page.dart';
import 'features/settings/profile_page.dart';
import 'features/settings/settings_page.dart';
import 'features/students/student_detail_page.dart';
import 'features/students/student_form_page.dart';
import 'features/students/students_list_page.dart';

/// Provider du mode de thème (système / clair / sombre).
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

/// Notifier qui déclenche le re-calcul du routeur quand l'auth ou la connexion
/// change (pour les redirects de garde).
class _RouterNotifier extends ChangeNotifier {
  _RouterNotifier(this._ref) {
    _ref.listen<AuthState>(authProvider, (_, __) => notifyListeners());
    _ref.listen(connectionProvider, (_, __) => notifyListeners());
  }
  final Ref _ref;
}

/// Provider du routeur GoRouter.
final goRouterProvider = Provider<GoRouter>((ref) {
  final notifier = _RouterNotifier(ref);
  ref.onDispose(notifier.dispose);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: notifier,
    redirect: (context, state) {
      final conn = ref.read(connectionProvider);
      final auth = ref.read(authProvider);
      final loc = state.matchedLocation;
      final isPairing = loc == '/pairing' || loc.startsWith('/pairing');
      final isLogin = loc == '/login';
      final isConnections = loc == '/connections';

      // 1) Pas encore appairé → onboarding d'appairage.
      if (!conn.isPaired) {
        return isPairing ? null : '/pairing';
      }
      // 2) Appairé mais non authentifié → login.
      if (!auth.isAuthenticated) {
        return isLogin ? null : '/login';
      }
      // 3) Authentifié : empêcher l'accès aux écrans d'onboarding.
      if (isPairing || isLogin) return '/dashboard';
      // 4) Racine → dashboard.
      if (loc == '/') return '/dashboard';
      return null;
    },
    routes: [
      GoRoute(
        path: '/pairing',
        builder: (context, state) => const DevicePairingPage(),
      ),
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginPage(),
      ),
      GoRoute(
        path: '/connections',
        builder: (context, state) => const ConnectionsPage(),
      ),
      GoRoute(
        path: '/qr-scanner',
        builder: (context, state) => const QrScannerPage(),
      ),
      // Shell avec barre de navigation inférieure.
      ShellRoute(
        builder: (context, state, child) {
          final index = _shellIndexFor(state.matchedLocation);
          return AppShell(child: child, index: index);
        },
        routes: [
          GoRoute(
            path: '/dashboard',
            builder: (context, state) => const DashboardPage(),
          ),
          GoRoute(
            path: '/classrooms',
            builder: (context, state) => const ClassroomsListPage(),
          ),
          GoRoute(
            path: '/students',
            builder: (context, state) => const StudentsListPage(),
          ),
          GoRoute(
            path: '/grades',
            builder: (context, state) => const GradeEntryPage(),
          ),
          GoRoute(
            path: '/more',
            builder: (context, state) => const _MoreGridPage(),
          ),
        ],
      ),
      // Routes plein écran (détails / formulaires / modules secondaires).
      GoRoute(
        path: '/classrooms/:id',
        builder: (context, state) => ClassroomDetailPage(
          id: int.parse(state.pathParameters['id']!),
        ),
      ),
      GoRoute(
        path: '/students/new',
        builder: (context, state) => const StudentFormPage(),
      ),
      GoRoute(
        path: '/students/:id/edit',
        builder: (context, state) => StudentFormPage(
          id: int.parse(state.pathParameters['id']!),
        ),
      ),
      GoRoute(
        path: '/students/:id',
        builder: (context, state) => StudentDetailPage(
          id: int.parse(state.pathParameters['id']!),
        ),
      ),
      GoRoute(
        path: '/schedule',
        builder: (context, state) => const SchedulePage(),
      ),
      GoRoute(
        path: '/grades/ranking',
        builder: (context, state) => const RankingPage(),
      ),
      GoRoute(
        path: '/grades/bulletin/:studentId',
        builder: (context, state) => BulletinPage(
          studentId: int.parse(state.pathParameters['studentId']!),
        ),
      ),
      GoRoute(
        path: '/attendance',
        builder: (context, state) => const AttendancePage(),
      ),
      GoRoute(
        path: '/attendance/history',
        builder: (context, state) => AttendanceHistoryPage(
          studentId: int.tryParse(
              state.uri.queryParameters['student_id'] ?? ''),
        ),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsPage(),
      ),
      GoRoute(
        path: '/settings/profile',
        builder: (context, state) => const ProfilePage(),
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      appBar: AppBar(title: const Text('Page introuvable')),
      body: Center(child: Text(state.error?.toString() ?? 'Route inconnue')),
    ),
  );
});

int _shellIndexFor(String location) {
  if (location.startsWith('/dashboard')) return 0;
  if (location.startsWith('/classrooms')) return 1;
  if (location.startsWith('/students')) return 2;
  if (location.startsWith('/grades')) return 3;
  if (location.startsWith('/more')) return 4;
  return 0;
}

/// Grille "Plus" : accès aux modules secondaires (Emploi du temps, Présence,
/// Classement, Connexions, Paramètres).
class _MoreGridPage extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final perms = auth.permissions;
    final items = <_MoreItem>[
      _MoreItem(
        icon: Icons.calendar_view_week,
        label: 'Emploi du temps',
        color: Colors.teal,
        route: '/schedule',
        permission: 'STUDENT_READ',
      ),
      _MoreItem(
        icon: Icons.fact_check,
        label: 'Présence',
        color: Colors.deepOrange,
        route: '/attendance',
        permission: 'STUDENT_READ',
      ),
      _MoreItem(
        icon: Icons.leaderboard,
        label: 'Classement',
        color: Colors.purple,
        route: '/grades/ranking',
        permission: 'GRADE_READ',
      ),
      _MoreItem(
        icon: Icons.receipt_long,
        label: 'Bulletins',
        color: Colors.indigo,
        route: '/grades',
        permission: 'GRADE_READ',
      ),
      _MoreItem(
        icon: Icons.link,
        label: 'Connexions',
        color: Colors.green,
        route: '/connections',
      ),
      _MoreItem(
        icon: Icons.settings,
        label: 'Paramètres',
        color: Colors.blueGrey,
        route: '/settings',
      ),
    ].where((i) =>
        i.permission == null ||
        perms.contains('*') ||
        perms.contains(i.permission!)).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Plus')),
      body: GridView.count(
        crossAxisCount: 3,
        padding: const EdgeInsets.all(16),
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.95,
        children: items
            .map((i) => Card(
                  child: InkWell(
                    onTap: () => context.push(i.route),
                    borderRadius: BorderRadius.circular(16),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: i.color.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(i.icon, color: i.color, size: 28),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            i.label,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ],
                      ),
                    ),
                  ),
                ))
            .toList(),
      ),
    );
  }
}

class _MoreItem {
  const _MoreItem({
    required this.icon,
    required this.label,
    required this.color,
    required this.route,
    this.permission,
  });
  final IconData icon;
  final String label;
  final Color color;
  final String route;
  final String? permission;
}

/// Widget racine de l'application.
class GeTechApp extends ConsumerWidget {
  const GeTechApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(goRouterProvider);
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      title: 'GeTech-SMS',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      locale: const Locale('fr'),
      supportedLocales: const [Locale('fr'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      routerConfig: router,
    );
  }
}
