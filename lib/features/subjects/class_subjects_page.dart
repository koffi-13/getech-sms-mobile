/// Page des matières d'une classe.
library;

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/models/classroom_dto.dart';
import '../../shared/widgets/widgets.dart';
import '../classrooms/classroom_controller.dart';

class ClassSubjectsPage extends ConsumerStatefulWidget {
  final int classroomId;
  const ClassSubjectsPage({super.key, required this.classroomId});

  @override
  ConsumerState<ClassSubjectsPage> createState() => _ClassSubjectsPageState();
}

class _ClassSubjectsPageState extends ConsumerState<ClassSubjectsPage> {
  @override
  Widget build(BuildContext context) {
    final classroomAsync = ref.watch(classroomDetailProvider(widget.classroomId));

    return Scaffold(
      appBar: AppBar(
        title: classroomAsync.when(
          data: (c) => Text('Matières : ${c.name}'),
          loading: () => const Text('Matières'),
          error: (_, __) => const Text('Matières'),
        ),
      ),
      body: const Center(child: Text('Liste des matières non implémentée')),
    );
  }
}
