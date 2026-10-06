/// Page de détail d'une classe : onglets Infos, Élèves, Emploi du temps.
library;

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/constants.dart' hide Sexe;
import '../../core/utils/permissions.dart';
import '../../shared/models/attendance_dto.dart';
import '../../shared/models/classroom_dto.dart';
import '../../shared/models/student_dto.dart';
import '../../shared/widgets/widgets.dart';
import '../schedule/schedule_controller.dart';
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
            _ScheduleTab(
              classroomId: classroom.id,
              weekType: _weekType,
              onWeekChanged: (w) => setState(() => _weekType = w),
            ),
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
        ListTile(
          title: const Text('Niveau'),
          subtitle: Text(classroom.levelName ?? 'N/A'),
        ),
        ListTile(
          title: const Text('Cycle'),
          subtitle: Text(classroom.cycleName ?? 'N/A'),
        ),
        ListTile(
          title: const Text('Titulaire'),
          subtitle: Text(classroom.teacherName.isNotEmpty ? classroom.teacherName : 'N/A'),
        ),
        ListTile(
          title: const Text('Série'),
          subtitle: Text(classroom.seriesName ?? 'N/A'),
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

    return async.when(
      data: (students) {
        if (students.isEmpty) {
          return const EmptyState(
            icon: Icons.person_off,
            title: 'Aucun élève',
            message: 'Cette classe est vide ou aucun élève n\'est assigné.',
          );
        }
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Text('${students.length} élève(s)',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                  Icon(Icons.group, color: Theme.of(context).colorScheme.primary),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: students.length,
                itemBuilder: (context, i) {
                  final s = students[i];
                  return ListTile(
                    leading: CircleAvatar(child: Text(s.displayInitials)),
                    title: Text(s.fullName),
                    subtitle: Text(s.matricule),
                    onTap: () => context.push('/students/${s.id}'),
                  );
                },
              ),
            ),
          ],
        );
      },
      loading: () => const AppLoading(label: 'Chargement des élèves…'),
      error: (e, st) => AppErrorWidget(message: e.toString()),
    );
  }
}

class _ScheduleTab extends ConsumerWidget {
  final int classroomId;
  final WeekType weekType;
  final ValueChanged<WeekType> onWeekChanged;

  const _ScheduleTab({
    required this.classroomId,
    required this.weekType,
    required this.onWeekChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ScheduleQuery(classroomId: classroomId, weekType: weekType);
    final async = ref.watch(weeklyScheduleProvider(query));

    return Column(
      children: [
        // Sélecteur de semaine A/B
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              const Text('Semaine: '),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('A'),
                selected: weekType == WeekType.a,
                onSelected: (_) => onWeekChanged(WeekType.a),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('B'),
                selected: weekType == WeekType.b,
                onSelected: (_) => onWeekChanged(WeekType.b),
              ),
            ],
          ),
        ),
        Expanded(
          child: async.when(
            data: (entries) {
              if (entries.isEmpty) {
                return const EmptyState(
                  icon: Icons.calendar_view_day,
                  title: 'Aucun cours',
                  message: 'L\'emploi du temps de cette classe est vide.',
                );
              }
              return _WeeklyScheduleGrid(entries: entries);
            },
            loading: () => const AppLoading(label: 'Chargement de l\'EDT…'),
            error: (e, st) => AppErrorWidget(message: e.toString()),
          ),
        ),
      ],
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
