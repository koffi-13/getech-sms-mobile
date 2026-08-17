/// Page de détail d'une classe : onglets Infos, Élèves, Emploi du temps.
library;

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/constants.dart' hide Sexe;
import '../../core/utils/permissions.dart';
import '../../shared/models/classroom_dto.dart';
import '../../shared/models/student_dto.dart';
import '../../shared/widgets/widgets.dart';
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
            const Center(child: Text('EDT non implémenté')),
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
          title: const Text('Titulaire'),
          subtitle: Text(classroom.teacherName),
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
            message: 'Cette classe est vide.',
          );
        }
        return ListView.builder(
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
        );
      },
      loading: () => const AppLoading(),
      error: (e, st) => AppErrorWidget(message: e.toString()),
    );
  }
}
