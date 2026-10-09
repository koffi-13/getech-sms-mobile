/// Page de détail d'une classe : onglets Infos, Élèves, Emploi du temps.
library;

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/models/classroom_dto.dart';
import '../../shared/widgets/widgets.dart';
import '../schedule/schedule_controller.dart';
import '../schedule/schedule_grid.dart';
import '../students/student_controller.dart';
import 'classroom_controller.dart';

class ClassroomDetailPage extends ConsumerStatefulWidget {
  final int id;
  const ClassroomDetailPage({super.key, required this.id});

  @override
  ConsumerState<ClassroomDetailPage> createState() => _ClassroomDetailPageState();
}

class _ClassroomDetailPageState extends ConsumerState<ClassroomDetailPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(classroomDetailProvider(widget.id));

    return async.when(
      data: (classroom) => Scaffold(
        appBar: AppBar(
          title: Text(classroom.name),
          bottom: TabBar(
            controller: _tabController,
            tabs: const [
              Tab(text: 'Infos'),
              Tab(text: 'Élèves'),
              Tab(text: 'Emploi du temps'),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabController,
          children: [
            _InfoTab(classroom: classroom),
            _StudentsTab(classroomId: classroom.id),
            _ScheduleTab(classroom: classroom),
          ],
        ),
      ),
      loading: () => const Scaffold(body: AppLoading()),
      error: (e, st) => Scaffold(body: AppErrorWidget(message: e.toString())),
    );
  }
}

class _InfoTab extends StatelessWidget {
  final ClassroomDto classroom;
  const _InfoTab({required this.classroom});

  @override
  Widget build(BuildContext context) {
    final levelLabel = classroom.levelLabel;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        KpiCard(
          label: 'Effectif',
          value: '${classroom.studentCount} / ${classroom.capacity}',
          icon: Icons.people,
          color: Colors.blue,
        ),
        const SizedBox(height: 16),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.stairs_outlined),
                title: const Text('Niveau'),
                subtitle: Text(
                    classroom.levelName ?? 'N/A'),
              ),
              if (classroom.cycleName != null)
                ListTile(
                  leading: const Icon(Icons.loop_outlined),
                  title: const Text('Cycle'),
                  subtitle: Text(classroom.cycleName!),
                ),
              if (classroom.seriesName != null)
                ListTile(
                  leading: const Icon(Icons.category_outlined),
                  title: const Text('Série'),
                  subtitle: Text(classroom.seriesName!),
                ),
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: const Text('Titulaire'),
                subtitle: Text(
                  classroom.teacherName.isEmpty
                      ? 'Non renseigné'
                      : classroom.teacherName,
                ),
              ),
              if (levelLabel.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.label_outline),
                  title: const Text('Identification'),
                  subtitle: Text(levelLabel),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StudentsTab extends ConsumerWidget {
  final int classroomId;
  const _StudentsTab({required this.classroomId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = StudentFilter(classroomId: classroomId);
    final async = ref.watch(studentsListProvider(filter));

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(studentControllerProvider);
      },
      child: async.when(
        data: (students) {
          if (students.isEmpty) {
            return ListView(
              children: const [
                SizedBox(height: 80),
                EmptyState(
                  icon: Icons.person_off,
                  title: 'Aucun élève',
                  message:
                      'Cette classe est vide. Tirez pour rafraîchir ou vérifiez la synchro.',
                ),
              ],
            );
          }
          return ListView.builder(
            itemCount: students.length,
            itemBuilder: (context, i) {
              final s = students[i];
              return ListTile(
                leading: CircleAvatar(child: Text(s.displayInitials)),
                title: Text(s.fullName),
                subtitle: Text(
                  [
                    if (s.matricule.isNotEmpty) s.matricule,
                    if (s.status != null) s.status!.label,
                  ].join(' • '),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/students/${s.id}'),
              );
            },
          );
        },
        loading: () => const AppLoading(),
        error: (e, st) => AppErrorWidget(message: e.toString()),
      ),
    );
  }
}

/// Onglet Emploi du temps : grille hebdomadaire complète de la classe
/// (toutes semaines), lecture seule — l'édition se fait dans le module
/// Emploi du temps (admins uniquement).
class _ScheduleTab extends ConsumerWidget {
  final ClassroomDto classroom;
  const _ScheduleTab({required this.classroom});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // [Fix-OFFLINE] Plus de garde bloquante : classroomScheduleProvider est
    // local-first (cache Drift) — l'onglet EDT reste consultable hors-ligne.
    final async = ref.watch(classroomScheduleProvider(classroom.id));
    return async.when(
      data: (list) {
        if (list.isEmpty) {
          return const Center(
            child: EmptyState(
              icon: Icons.event_busy,
              title: 'Aucun cours programmé',
              message:
                  'L\'emploi du temps de cette classe n\'a pas encore été défini.',
            ),
          );
        }
        return Column(
          children: [
            Expanded(
              child: ScheduleGridView(
                schedule: list,
                mode: ScheduleDisplayMode.classroom,
                compact: true,
                onEntryTap: (e) => showScheduleEntryDetails(context, e),
              ),
            ),
          ],
        );
      },
      loading: () => const AppLoading(label: 'Chargement de l\'emploi du temps…'),
      error: (e, _) => Center(
        child: AppErrorWidget(
          message: e.toString(),
          onRetry: () =>
              ref.invalidate(classroomScheduleProvider(classroom.id)),
        ),
      ),
    );
  }
}
