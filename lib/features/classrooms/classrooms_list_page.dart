/// Page "Classes" : liste avec effectif, titulaire et taux d'occupation
/// (LinearProgressIndicator). Pull-to-refresh + bannière hors-ligne.
///
/// [Fix-TEACHER-CLASSES-SCOPE] Un enseignant (non-admin) ne voit QUE les
/// classes dans lesquelles il intervient (enseignement + titulariat) —
/// périmètre [TeacherScope]. L'admin/directeur voit toutes les classes.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_state.dart';
import '../../core/auth/teacher_scope.dart';
import '../../features/connections/connection_state.dart';
import '../../shared/models/classroom_dto.dart';
import '../../shared/widgets/widgets.dart';
import 'classroom_controller.dart';

class ClassroomsListPage extends ConsumerStatefulWidget {
  const ClassroomsListPage({super.key});

  @override
  ConsumerState<ClassroomsListPage> createState() => _ClassroomsListPageState();
}

class _ClassroomsListPageState extends ConsumerState<ClassroomsListPage> {
  Future<void> _refresh() async {
    ref.invalidate(teacherScopeProvider);
    ref.invalidate(classroomsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final async = ref.watch(classroomsProvider);
    // [Fix-TEACHER-CLASSES-SCOPE] Résolution du périmètre enseignant : un
    // non-admin attend le verdict du scope AVANT d'afficher quoi que ce
    // soit (sinon toutes les classes de l'établissement seraient visibles
    // une fraction de seconde avant filtrage).
    final scopeAsync = ref.watch(teacherScopeProvider);

    final isTeacherish = !auth.isAdminOrHeadmaster;
    final scopeReady = !isTeacherish || scopeAsync.hasValue;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Classes'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Rafraîchir',
            onPressed: _refresh,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _OfflineBanner()),
            if (!scopeReady)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: AppLoading(label: 'Chargement de vos classes…'),
              )
            else
              async.when(
                data: (classrooms) {
                  final scope = scopeAsync.valueOrNull;
                  final restricted = scope != null &&
                      scope.isTeacher &&
                      !scope.isAdminOrHeadmaster;
                  var visible = classrooms;
                  var headIds = const <int>{};
                  if (restricted) {
                    // [Fix-TEACHER-CLASSES-SCOPE-V9] INTERSECTION (l'ancien
                    // code faisait une UNION : il partait de TOUTES les
                    // classes puis y AJOUTAIT celles du périmètre →
                    // l'enseignant voyait TOUTES les classes de
                    // l'établissement). L'enseignant ne voit que SES classes
                    // (enseignement ∪ titulariat) ; les cartes du scope
                    // complètent celles absentes de /classrooms (matière
                    // inactive → classe synthétisée depuis l'EDT).
                    final myIds = scope.myClassroomIds;
                    final byId = <int, ClassroomDto>{
                      for (final c in classrooms)
                        if (myIds.contains(c.id)) c.id: c,
                    };
                    for (final c in scope.myClassrooms) {
                      byId.putIfAbsent(c.id, () => c);
                    }
                    headIds = scope.headClassrooms.map((c) => c.id).toSet();
                    visible = byId.values.toList()
                      ..sort((a, b) => a.name.compareTo(b.name));
                  }
                  if (visible.isEmpty) {
                    return SliverFillRemaining(
                      hasScrollBody: false,
                      child: EmptyState(
                        icon: Icons.school_outlined,
                        title: 'Aucune classe',
                        message: restricted
                            ? 'Vous n\'intervenez dans aucune classe. Contactez '
                                'l\'administration de l\'établissement.'
                            : 'Aucune classe disponible localement. Synchronisez '
                                'pour récupérer les données du serveur.',
                      ),
                    );
                  }
                  return SliverPadding(
                    padding: const EdgeInsets.all(12),
                    sliver: SliverList.separated(
                      itemCount: visible.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final c = visible[i];
                        final isHead = headIds.contains(c.id);
                        return _ClassroomTile(
                            classroom: c, isHeadTeacher: isHead);
                      },
                    ),
                  );
                },
                loading: () => const SliverFillRemaining(
                  hasScrollBody: false,
                  child: AppLoading(label: 'Chargement des classes…'),
                ),
                error: (e, _) => SliverFillRemaining(
                  hasScrollBody: false,
                  child: AppErrorWidget(
                    message: e.toString(),
                    onRetry: _refresh,
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bannière hors-ligne
// ---------------------------------------------------------------------------

class _OfflineBanner extends ConsumerWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider);
    if (conn.canReachServer) return const SizedBox.shrink();
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.cloud_off,
                size: 18,
                color: Theme.of(context).colorScheme.onSecondaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Mode hors-ligne — données locales (sync différée).',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tuile classe
// ---------------------------------------------------------------------------

class _ClassroomTile extends StatelessWidget {
  const _ClassroomTile({required this.classroom, this.isHeadTeacher = false});
  final ClassroomDto classroom;

  /// Vrai si l'utilisateur connecté est titulaire (prof. principal) de
  /// cette classe → badge étoile.
  final bool isHeadTeacher;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final occupancy = classroom.occupancyRate;
    final occupancyColor = occupancy >= 1
        ? Colors.red
        : (occupancy >= 0.8 ? Colors.orange : theme.colorScheme.primary);

    final subtitleParts = <String>[];
    if (classroom.levelName != null) subtitleParts.add(classroom.levelName!);
    if (classroom.cycleName != null) subtitleParts.add(classroom.cycleName!);
    if (classroom.seriesName != null) subtitleParts.add(classroom.seriesName!);

    return Card(
      child: InkWell(
        onTap: () => context.push('/classrooms/${classroom.id}'),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: isHeadTeacher
                          ? Colors.amber.withValues(alpha: 0.25)
                          : theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      isHeadTeacher ? Icons.star : Icons.school,
                      color: isHeadTeacher
                          ? Colors.amber.shade800
                          : theme.colorScheme.primary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          classroom.name,
                          style: theme.textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (subtitleParts.isNotEmpty)
                          Text(
                            subtitleParts.join(' · '),
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        // Titulaire (jamais null : chaîne vide si inconnu).
                        if (classroom.teacherName.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            'Titulaire : ${classroom.teacherName}',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        if (isHeadTeacher) ...[
                          const SizedBox(height: 2),
                          Text(
                            'Votre classe (vous êtes titulaire)',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.amber.shade800,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _OccupancyBadge(
                    count: classroom.studentCount,
                    capacity: classroom.capacity,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Barre de taux d'occupation.
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: occupancy,
                        minHeight: 6,
                        backgroundColor:
                            theme.colorScheme.surfaceContainerHighest,
                        color: occupancyColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${(occupancy * 100).round()}%',
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: occupancyColor, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OccupancyBadge extends StatelessWidget {
  const _OccupancyBadge({required this.count, required this.capacity});
  final int count;
  final int capacity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ratio = capacity == 0 ? 0.0 : count / capacity;
    final color = ratio >= 1
        ? Colors.red
        : (ratio >= 0.8 ? Colors.orange : theme.colorScheme.primary);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$count / $capacity',
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
      ),
    );
  }
}
