/// Formulaire de création / édition d'un élève.
library;

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/constants.dart';
import '../../core/utils/formatters.dart';
import '../../shared/models/classroom_dto.dart';
import '../../shared/models/student_dto.dart';
import '../../shared/widgets/widgets.dart';
import '../classrooms/classroom_controller.dart';
import 'student_controller.dart';

class StudentFormPage extends ConsumerStatefulWidget {
  final int? id;
  const StudentFormPage({super.key, this.id});

  @override
  ConsumerState<StudentFormPage> createState() => _StudentFormPageState();
}

class _StudentFormPageState extends ConsumerState<StudentFormPage> {
  final _formKey = GlobalKey<FormState>();
  final _nom = TextEditingController();
  final _prenoms = TextEditingController();
  final _matricule = TextEditingController();
  final _birthPlace = TextEditingController();
  DateTime? _dob;
  Sexe? _sexe;
  BloodType? _bloodType;
  int? _classroomId;

  bool _loading = false;

  @override
  void initState() {
    super.initState();
    if (widget.id != null) {
      _loadStudent();
    }
  }

  void _loadStudent() async {
    final s = await ref.read(studentDetailProvider(widget.id!).future);
    _nom.text = s.nom ?? '';
    _prenoms.text = s.prenoms ?? '';
    _matricule.text = s.matricule;
    _birthPlace.text = s.birthPlace ?? '';
    _dob = s.dob;
    _sexe = s.sexe;
    _classroomId = s.classroomId;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final classroomsAsync = ref.watch(classroomsProvider);

    return Scaffold(
      appBar: AppBar(title: Text(widget.id == null ? 'Nouvel élève' : 'Modifier élève')),
      body: _loading
          ? const AppLoading()
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  TextFormField(
                    controller: _nom,
                    decoration: const InputDecoration(labelText: 'Nom *'),
                    validator: (v) => v!.isEmpty ? 'Champ requis' : null,
                  ),
                  TextFormField(
                    controller: _prenoms,
                    decoration: const InputDecoration(labelText: 'Prénoms'),
                  ),
                  TextFormField(
                    controller: _matricule,
                    decoration: const InputDecoration(labelText: 'Matricule *'),
                    validator: (v) => v!.isEmpty ? 'Champ requis' : null,
                  ),
                  const SizedBox(height: 16),
                  ListTile(
                    title: const Text('Date de naissance'),
                    subtitle: Text(_dob == null ? 'Non définie' : DateFormatter.date(_dob!)),
                    trailing: const Icon(Icons.calendar_today),
                    onTap: _pickDate,
                  ),
                  DropdownButtonFormField<Sexe>(
                    value: _sexe,
                    items: Sexe.values.map((s) => DropdownMenuItem(value: s, child: Text(s.label))).toList(),
                    onChanged: (v) => setState(() => _sexe = v),
                    decoration: const InputDecoration(labelText: 'Sexe'),
                  ),
                  const SizedBox(height: 16),
                  classroomsAsync.when(
                    data: (list) => DropdownButtonFormField<int>(
                      value: _classroomId,
                      items: list.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))).toList(),
                      onChanged: (v) => setState(() => _classroomId = v),
                      decoration: const InputDecoration(labelText: 'Classe'),
                    ),
                    loading: () => const LinearProgressIndicator(),
                    error: (e, st) => Text('Erreur classes : $e'),
                  ),
                  const SizedBox(height: 32),
                  ElevatedButton(
                    onPressed: _submit,
                    child: const Text('Enregistrer'),
                  ),
                ],
              ),
            ),
    );
  }

  void _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(2010),
      firstDate: DateTime(1990),
      lastDate: DateTime.now(),
    );
    if (d != null) setState(() => _dob = d);
  }

  void _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      final dto = StudentDto(
        id: widget.id ?? 0,
        nom: _nom.text.trim(),
        prenoms: _prenoms.text.trim(),
        matricule: _matricule.text.trim(),
        dob: _dob,
        sexe: _sexe,
        birthPlace: _birthPlace.text.trim(),
        classroomId: _classroomId,
      );
      await ref.read(studentRepositoryProvider).save(dto);
      ref.invalidate(studentControllerProvider);
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur : $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}
