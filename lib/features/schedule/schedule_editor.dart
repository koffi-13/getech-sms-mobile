/// Éditeur d'emploi du temps (admins uniquement).
///
/// [ScheduleGridScreen] encapsule [ScheduleGridView] avec :
/// - un FAB « Ajouter un cours » (si [canEdit]) ;
/// - le tap sur un cours → bottom sheet d'édition / suppression ;
/// - le formulaire d'ajout : matière (depuis `/grades/class-subjects` de la
///   classe), jour, heures début/fin, semaine (Toutes/A/B), salle.
///
/// Les mutations passent par [ScheduleEditController] (`POST/PUT/DELETE
/// /schedule/entries` — endpoints fournis par le patch serveur GeTech-SMS).
/// Si le serveur ne les expose pas, une [ScheduleEditException] claire est
/// remontée à l'utilisateur (invitation à appliquer le patch).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/constants.dart';
import '../../shared/models/attendance_dto.dart';
import '../../shared/widgets/widgets.dart';
import '../grades/grade_controller.dart';
import 'schedule_controller.dart';
import 'schedule_grid.dart';

/// Écran de grille EDT avec édition (admin) ou lecture seule.
class ScheduleGridScreen extends ConsumerStatefulWidget {
  const ScheduleGridScreen({
    super.key,
    required this.entries,
    required this.mode,
    this.classroomId,
    this.canEdit = false,
    this.showAddButton = false,
    this.emptyMessage,
  });

  final List<WeeklyScheduleDto> entries;
  final ScheduleDisplayMode mode;

  /// Classe cible (requis pour l'ajout de cours).
  final int? classroomId;

  /// Active l'édition des cours existants.
  final bool canEdit;

  /// Affiche le FAB « Ajouter un cours » (nécessite [classroomId]).
  final bool showAddButton;

  final String? emptyMessage;

  @override
  ConsumerState<ScheduleGridScreen> createState() => _ScheduleGridScreenState();
}

class _ScheduleGridScreenState extends ConsumerState<ScheduleGridScreen> {
  bool _editUnsupported = false;

  @override
  Widget build(BuildContext context) {
    if (widget.entries.isEmpty) {
      return Stack(
        children: [
          EmptyState(
            title: 'Aucun cours programmé',
            message: widget.emptyMessage ??
                'L\'emploi du temps est vide pour cette sélection.',
            icon: Icons.event_busy,
          ),
          if (widget.showAddButton && widget.classroomId != null)
            Positioned(
              right: 16,
              bottom: 16,
              child: FloatingActionButton.extended(
                onPressed: () => _openAddSheet(),
                icon: const Icon(Icons.add),
                label: const Text('Ajouter un cours'),
              ),
            ),
        ],
      );
    }

    return Stack(
      children: [
        ScheduleGridView(
          schedule: widget.entries,
          mode: widget.mode,
          onEntryTap: widget.canEdit ? (e) => _openEditSheet(e) : null,
        ),
        if (widget.showAddButton && widget.classroomId != null)
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton.extended(
              onPressed: () => _openAddSheet(),
              icon: const Icon(Icons.add),
              label: const Text('Ajouter un cours'),
            ),
          ),
      ],
    );
  }

  void _openAddSheet() {
    if (_editUnsupported) {
      _showPatchBanner();
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AddCourseSheet(classroomId: widget.classroomId!),
    ).then((_) {
      // Le sheet peut avoir modifié les données : rien à faire ici, les
      // providers sont invalidés par le contrôleur.
    });
  }

  void _openEditSheet(WeeklyScheduleDto entry) {
    if (_editUnsupported) {
      _showPatchBanner();
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _EditCourseSheet(entry: entry),
    );
  }

  void _showPatchBanner() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Édition indisponible : appliquez le patch serveur GeTech-SMS '
          '(voir documentation du projet mobile).',
        ),
        duration: Duration(seconds: 4),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Formulaire d'ajout
// ---------------------------------------------------------------------------

class _AddCourseSheet extends ConsumerStatefulWidget {
  const _AddCourseSheet({required this.classroomId});
  final int classroomId;

  @override
  ConsumerState<_AddCourseSheet> createState() => _AddCourseSheetState();
}

class _AddCourseSheetState extends ConsumerState<_AddCourseSheet> {
  final _formKey = GlobalKey<FormState>();
  final _roomCtrl = TextEditingController();

  int? _classSubjectId;
  SchoolDay _day = SchoolDay.lundi;
  TimeOfDay _start = const TimeOfDay(hour: 8, minute: 0);
  TimeOfDay _end = const TimeOfDay(hour: 10, minute: 0);
  String? _weekType; // null = toutes les semaines
  bool _saving = false;

  @override
  void dispose() {
    _roomCtrl.dispose();
    super.dispose();
  }

  String _hhmm(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_classSubjectId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sélectionnez une matière.')),
      );
      return;
    }
    if (_end.hour * 60 + _end.minute <= _start.hour * 60 + _start.minute) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('L\'heure de fin doit être après l\'heure de début.')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(scheduleEditControllerProvider).createEntry(
            ScheduleEntryCreateRequest(
              classroomId: widget.classroomId,
              classSubjectId: _classSubjectId!,
              dayOfWeek: _day.dayIndex,
              startTime: _hhmm(_start),
              endTime: _hhmm(_end),
              weekType: _weekType,
              room: _roomCtrl.text.trim().isEmpty ? null : _roomCtrl.text.trim(),
            ),
          );
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cours ajouté à l\'emploi du temps.')),
        );
      }
    } on ScheduleEditException catch (e) {
      _showError(e.patchRequired
          ? e.message
          : 'Échec de l\'ajout : ${e.message}');
    } catch (e) {
      _showError('Erreur : $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red.shade700),
    );
  }

  @override
  Widget build(BuildContext context) {
    final subjectsAsync = ref.watch(classSubjectsProvider(widget.classroomId));

    return Padding(
      padding: EdgeInsets.fromLTRB(
        16, 8, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Ajouter un cours',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),

              // Matière (ClassSubject de la classe).
              subjectsAsync.when(
                data: (list) {
                  if (list.isEmpty) {
                    return const Text(
                      'Aucune matière affectée à cette classe. Affectez '
                      'd\'abord des matières (module Matières du desktop).',
                      style: TextStyle(fontStyle: FontStyle.italic),
                    );
                  }
                  return DropdownButtonFormField<int>(
                    value: _classSubjectId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Matière *',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: list
                        .map((cs) => DropdownMenuItem(
                              value: cs.id,
                              child: Text(
                                '${cs.subjectName} (coef. ${cs.coefficient})',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ))
                        .toList(),
                    onChanged: (v) => setState(() => _classSubjectId = v),
                  );
                },
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: LinearProgressIndicator(),
                ),
                error: (e, _) => Text('Erreur matières : $e'),
              ),
              const SizedBox(height: 12),

              // Jour.
              DropdownButtonFormField<SchoolDay>(
                value: _day,
                decoration: const InputDecoration(
                  labelText: 'Jour *',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: SchoolDay.values
                    .map((d) =>
                        DropdownMenuItem(value: d, child: Text(d.label)))
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _day = v);
                },
              ),
              const SizedBox(height: 12),

              // Horaires.
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () async {
                        final t = await showTimePicker(
                            context: context, initialTime: _start);
                        if (t != null) setState(() => _start = t);
                      },
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Début *',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        child: Text(_hhmm(_start)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: InkWell(
                      onTap: () async {
                        final t = await showTimePicker(
                            context: context, initialTime: _end);
                        if (t != null) setState(() => _end = t);
                      },
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Fin *',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        child: Text(_hhmm(_end)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Semaine.
              DropdownButtonFormField<String?>(
                value: _weekType,
                decoration: const InputDecoration(
                  labelText: 'Semaine',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(value: null, child: Text('Toutes les semaines')),
                  DropdownMenuItem(value: 'A', child: Text('Semaine A')),
                  DropdownMenuItem(value: 'B', child: Text('Semaine B')),
                ],
                onChanged: (v) => setState(() => _weekType = v),
              ),
              const SizedBox(height: 12),

              TextFormField(
                controller: _roomCtrl,
                decoration: const InputDecoration(
                  labelText: 'Salle (optionnel)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed:
                    _saving ? null : _submit,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check),
                label: const Text('Ajouter'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Formulaire d'édition / suppression
// ---------------------------------------------------------------------------

class _EditCourseSheet extends ConsumerStatefulWidget {
  const _EditCourseSheet({required this.entry});
  final WeeklyScheduleDto entry;

  @override
  ConsumerState<_EditCourseSheet> createState() => _EditCourseSheetState();
}

class _EditCourseSheetState extends ConsumerState<_EditCourseSheet> {
  TimeOfDay? _start;
  TimeOfDay? _end;
  String? _weekType;
  final _roomCtrl = TextEditingController();
  bool _saving = false;
  bool _deleting = false;

  WeeklyScheduleDto get e => widget.entry;

  @override
  void initState() {
    super.initState();
    _start = _parseHhmm(e.startTime) ?? const TimeOfDay(hour: 8, minute: 0);
    _end = _parseHhmm(e.endTime) ?? const TimeOfDay(hour: 10, minute: 0);
    _weekType = e.isAllWeeks ? null : (e.weekType == WeekType.b ? 'B' : 'A');
    _roomCtrl.text = e.room ?? '';
  }

  static TimeOfDay? _parseHhmm(String? s) {
    if (s == null) return null;
    final parts = s.split(':');
    if (parts.length < 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return TimeOfDay(hour: h, minute: m);
  }

  String _hhmm(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  void dispose() {
    _roomCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_end!.hour * 60 + _end!.minute <= _start!.hour * 60 + _start!.minute) {
      _showError('L\'heure de fin doit être après l\'heure de début.');
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(scheduleEditControllerProvider).updateEntry(
            e.id,
            ScheduleEntryUpdateRequest(
              startTime: _hhmm(_start!),
              endTime: _hhmm(_end!),
              weekType: _weekType,
              room: _roomCtrl.text.trim(),
            ),
          );
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cours modifié.')),
        );
      }
    } on ScheduleEditException catch (err) {
      _showError(err.message);
    } catch (err) {
      _showError('Erreur : $err');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer le cours'),
        content: Text(
            'Supprimer « ${e.subjectName ?? 'ce cours'} » '
            '(${e.day?.label ?? ''} ${e.startTime}–${e.endTime}) ?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Annuler')),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade50,
              foregroundColor: Colors.red.shade700,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _deleting = true);
    try {
      await ref.read(scheduleEditControllerProvider).deleteEntry(e.id);
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cours supprimé.')),
        );
      }
    } on ScheduleEditException catch (err) {
      _showError(err.message);
    } catch (err) {
      _showError('Erreur : $err');
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red.shade700),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 8, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Modifier le cours',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            [
              e.subjectName ?? 'Cours',
              e.classroomName,
              '${e.day?.label ?? ''} ${e.startTime}–${e.endTime}',
            ].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () async {
                    final t = await showTimePicker(
                        context: context, initialTime: _start!);
                    if (t != null) setState(() => _start = t);
                  },
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Début',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    child: Text(_hhmm(_start!)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: InkWell(
                  onTap: () async {
                    final t = await showTimePicker(
                        context: context, initialTime: _end!);
                    if (t != null) setState(() => _end = t);
                  },
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Fin',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    child: Text(_hhmm(_end!)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            value: _weekType,
            decoration: const InputDecoration(
              labelText: 'Semaine',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: const [
              DropdownMenuItem(value: null, child: Text('Toutes les semaines')),
              DropdownMenuItem(value: 'A', child: Text('Semaine A')),
              DropdownMenuItem(value: 'B', child: Text('Semaine B')),
            ],
            onChanged: (v) => setState(() => _weekType = v),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _roomCtrl,
            decoration: const InputDecoration(
              labelText: 'Salle',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: const Text('Enregistrer'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.red.shade700,
            ),
            onPressed: _deleting ? null : _delete,
            icon: _deleting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.delete_outline),
            label: const Text('Supprimer ce cours'),
          ),
        ],
      ),
    );
  }
}
