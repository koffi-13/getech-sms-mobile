/// Page de détail d'une classe : onglets Infos, Élèves, Emploi du temps.
library;

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/constants.dart' hide Sexe;
import '../../core/utils/permissions.dart';
import '../../shared/models/attendance_dto.dart';
import '../../shared/models/classroom_dto.dart';
import '../../shared/widgets/widgets.dart';
import '../connections/connection_state.dart';
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
  WeekType _weekType = WeekType.a;

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
    final conn = ref.watch(connectionProvider);
    if (!conn.canReachServer) {
      return const Center(
        child: EmptyState(
          icon: Icons.cloud_off,
          title: 'Hors-ligne',
          message: 'L\'emploi du temps nécessite une connexion au serveur.',
        ),
      );
    }
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

/// Grille hebdomadaire : 6 colonnes (Lundi..Samedi), lignes = créneaux.
class _WeeklyScheduleGrid extends StatelessWidget {
  final List<WeeklyScheduleDto> entries;
  const _WeeklyScheduleGrid({required this.entries});

  static const _days = ['Lun', 'Mar', 'Mer', 'Jeu', 'Ven', 'Sam'];

  @override
  Widget build(BuildContext context) {
    // Grouper les entrées par créneau (start_time).
    final timeSlots = <String>{};
    for (final e in entries) {
      timeSlots.add('${e.startTime}-${e.endTime}');
    }
    final sortedSlots = timeSlots.toList()..sort();

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SingleChildScrollView(
        child: DataTable(
          columnSpacing: 8,
          columns: [
            const DataColumn(label: Text('Créneau', style: TextStyle(fontSize: 12))),
            ..._days.map((d) => DataColumn(label: Text(d, style: const TextStyle(fontSize: 12)))),
          ],
          rows: sortedSlots.map((slot) {
            final parts = slot.split('-');
            final startTime = parts.isNotEmpty ? parts[0] : '';
            final endTime = parts.length > 1 ? parts[1] : '';
            final cells = <DataCell>[];
            cells.add(DataCell(Text('$startTime\n$endTime', style: const TextStyle(fontSize: 10))));
            for (int day = 1; day <= 6; day++) {
              final entry = entries.where((e) => e.dayOfWeek == day && '${e.startTime}-${e.endTime}' == slot).firstOrNull;
              cells.add(DataCell(
                entry != null
                    ? Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(entry.subjectName ?? '',
                                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                            if (entry.teacherName != null)
                              Text(entry.teacherName!,
                                  style: const TextStyle(fontSize: 8)),
                          ],
                        ),
                      )
                    : const Text(''),
              ));
            }
            return DataRow(cells: cells);
          }).toList(),
        ),
      ),
    );
  }
}
