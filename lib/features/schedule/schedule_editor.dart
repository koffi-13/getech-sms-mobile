/// Éditeur d'emploi du temps (admins uniquement).
///
/// [ScheduleGridScreen] encapsule [ScheduleGridView] avec :
/// - un FAB « Ajouter un cours » (si [canEdit]) ;
/// - le tap sur un cours → bottom sheet d'édition / suppression ;
/// - le formulaire d'ajout / modification ALIGNÉ SUR LE DESKTOP :
///   Matière* → Enseignant* → Créneau* (grille horaire) → Semaine → Salle.
///
/// [Fix-EDT-FORM-DESKTOP] Concordance avec le formulaire desktop
/// (« Ajouter un cours » / « Modifier le cours » de main_page.py) :
/// - le cours se pose sur un CRÉNEAU de la grille horaire
///   (`GET /schedule/time-slots`) et non sur des heures libres — repli
///   saisie manuelle jour + heures si l'établissement n'a pas de grille ;
/// - l'ENSEIGNANT est choisi dans la liste canonique
///   (`GET /users?role=teacher`) et devient l'enseignant affecté de la
///   matière (le serveur met à jour ClassSubject.assigned_teacher_id,
///   miroir du do_save desktop) ;
/// - la semaine admet « Toutes / A uniquement / B uniquement » ;
/// - la salle est optionnelle.
///
/// Les mutations passent par [ScheduleEditController] (`POST/PUT/DELETE
/// /schedule/entries`). Si le serveur ne les expose pas, une
/// [ScheduleEditException] claire est remontée à l'utilisateur.
library;

import 'package:collection/collection.dart'; // firstOrNull
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/constants.dart';
import '../../shared/models/attendance_dto.dart';
import '../../shared/widgets/widgets.dart';
import '../grades/grade_controller.dart';
import '../users/user_controller.dart';
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
          'Édition indisponible : mettez à jour le serveur GeTech-SMS '
          'puis réessayez.',
        ),
        duration: Duration(seconds: 4),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Champs partagés (miroir du formulaire desktop)
// ---------------------------------------------------------------------------

/// Champ « Enseignant * » : liste canonique `GET /users?role=teacher`.
///
/// [selectedId] présélectionne l'enseignant affecté de la matière ;
/// la première ouverture auto-sélectionne le premier enseignant si aucun
/// n'est fourni (le champ est obligatoire, comme sur le desktop).
class _TeacherField extends ConsumerWidget {
  const _TeacherField({required this.selectedId, required this.onChanged});

  final int? selectedId;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final teachersAsync = ref.watch(teachersListProvider);
    return teachersAsync.when(
      data: (teachers) {
        if (teachers.isEmpty) {
          return const Text(
            'Aucun enseignant trouvé. Créez d\'abord des comptes '
            'enseignants (module Utilisateurs).',
            style: TextStyle(fontStyle: FontStyle.italic),
          );
        }
        var effective = selectedId;
        if (effective == null || !teachers.any((t) => t.id == effective)) {
          effective = teachers.first.id;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (effective != null) onChanged(effective);
          });
        }
        return DropdownButtonFormField<int>(
          value: effective,
          // [Fix-OVERFLOW] libellés longs contraints à la largeur du champ.
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Enseignant *',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: teachers
              .map((t) => DropdownMenuItem(
                    value: t.id,
                    child: Text(
                      t.fullName.isEmpty ? t.username : t.fullName,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ))
              .toList(),
          onChanged: (v) => onChanged(v),
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: LinearProgressIndicator(),
      ),
      error: (e, _) => Text('Erreur enseignants : $e',
          style:
              TextStyle(color: Theme.of(context).colorScheme.error)),
    );
  }
}

/// Résultat du sélecteur de créneau : soit un créneau de la grille
/// ([slotId]), soit une saisie manuelle (jour + heures).
class _SlotSelection {
  const _SlotSelection({this.slotId, this.dayOfWeek, this.startTime, this.endTime});
  final int? slotId;
  final int? dayOfWeek;
  final String? startTime;
  final String? endTime;

  bool get isValid =>
      slotId != null ||
      (dayOfWeek != null &&
          startTime != null &&
          endTime != null &&
          endTime!.compareTo(startTime!) > 0);
}

/// Champ « Créneau * » : dropdown de la grille horaire (miroir desktop),
/// groupé par jour. Repli manuel (jour + heures) si la grille est vide —
/// le serveur résout/crée alors le TimeSlot correspondant.
class _SlotPicker extends ConsumerStatefulWidget {
  const _SlotPicker({
    required this.selection,
    required this.onChanged,
  });

  final _SlotSelection selection;
  final ValueChanged<_SlotSelection> onChanged;

  @override
  ConsumerState<_SlotPicker> createState() => _SlotPickerState();
}

class _SlotPickerState extends ConsumerState<_SlotPicker> {
  SchoolDay _manualDay = SchoolDay.lundi;
  TimeOfDay _manualStart = const TimeOfDay(hour: 8, minute: 0);
  TimeOfDay _manualEnd = const TimeOfDay(hour: 10, minute: 0);

  static String _hhmm(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  void _emitManual() {
    widget.onChanged(_SlotSelection(
      dayOfWeek: _manualDay.dayIndex,
      startTime: _hhmm(_manualStart),
      endTime: _hhmm(_manualEnd),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final slotsAsync = ref.watch(timeSlotsProvider);
    return slotsAsync.when(
      data: (slots) {
        if (slots.isEmpty) {
          // ── Repli : saisie manuelle jour + heures (le serveur crée le
          // créneau). Cas d'un établissement sans grille horaire configurée.
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<SchoolDay>(
                value: _manualDay,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Jour *',
                  helperText: 'Grille horaire non configurée — saisie manuelle.',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: SchoolDay.values
                    .map((d) => DropdownMenuItem(value: d, child: Text(d.label)))
                    .toList(),
                onChanged: (v) {
                  if (v != null) {
                    setState(() => _manualDay = v);
                    _emitManual();
                  }
                },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () async {
                        final t = await showTimePicker(
                            context: context, initialTime: _manualStart);
                        if (t != null) {
                          setState(() => _manualStart = t);
                          _emitManual();
                        }
                      },
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Début *',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        child: Text(_hhmm(_manualStart)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: InkWell(
                      onTap: () async {
                        final t = await showTimePicker(
                            context: context, initialTime: _manualEnd);
                        if (t != null) {
                          setState(() => _manualEnd = t);
                          _emitManual();
                        }
                      },
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Fin *',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        child: Text(_hhmm(_manualEnd)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        }
        // ── Cas nominal : dropdown des créneaux de la grille.
        final selectedId = widget.selection.slotId;
        final effective =
            (selectedId != null && slots.any((s) => s.id == selectedId))
                ? selectedId
                : slots.first.id;
        if (effective != selectedId) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final slot = slots.where((s) => s.id == effective).first;
            widget.onChanged(_SlotSelection(
              slotId: slot.id,
              dayOfWeek: slot.dayOfWeek,
              startTime: slot.startTime,
              endTime: slot.endTime,
            ));
          });
        }
        return DropdownButtonFormField<int>(
          value: effective,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Créneau *',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: slots
              .map((s) => DropdownMenuItem(
                    value: s.id,
                    child: Text(
                      s.displayLabel,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ))
              .toList(),
          onChanged: (id) {
            final slot = slots.where((s) => s.id == id).firstOrNull;
            if (slot != null) {
              widget.onChanged(_SlotSelection(
                slotId: slot.id,
                dayOfWeek: slot.dayOfWeek,
                startTime: slot.startTime,
                endTime: slot.endTime,
              ));
            }
          },
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: LinearProgressIndicator(),
      ),
      error: (e, _) => Text('Erreur créneaux : $e',
          style: TextStyle(color: Theme.of(context).colorScheme.error)),
    );
  }
}

/// Libellé « Toutes les semaines / Semaine A uniquement / … » (miroir
/// exact des libellés desktop).
class _WeekTypeField extends StatelessWidget {
  const _WeekTypeField({required this.value, required this.onChanged});

  final String? value; // null = toutes les semaines
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String?>(
      value: value,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Semaine',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: const [
        DropdownMenuItem(value: null, child: Text('Toutes les semaines')),
        DropdownMenuItem(value: 'A', child: Text('Semaine A uniquement')),
        DropdownMenuItem(value: 'B', child: Text('Semaine B uniquement')),
      ],
      onChanged: (v) => onChanged(v),
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
  int? _teacherId;
  _SlotSelection _slot = const _SlotSelection();
  String? _weekType; // null = toutes les semaines
  bool _saving = false;

  @override
  void dispose() {
    _roomCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_classSubjectId == null) {
      _showError('Sélectionnez une matière.');
      return;
    }
    if (_teacherId == null) {
      _showError('Sélectionnez un enseignant.');
      return;
    }
    if (!_slot.isValid) {
      _showError('Sélectionnez un créneau (l\'heure de fin doit suivre '
          'l\'heure de début).');
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(scheduleEditControllerProvider).createEntry(
            ScheduleEntryCreateRequest(
              classroomId: widget.classroomId,
              classSubjectId: _classSubjectId!,
              dayOfWeek: _slot.dayOfWeek!,
              startTime: _slot.startTime!,
              endTime: _slot.endTime!,
              weekType: _weekType,
              room: _roomCtrl.text.trim().isEmpty ? null : _roomCtrl.text.trim(),
              // [Fix-EDT-FORM-DESKTOP] miroir desktop : l'enseignant choisi
              // devient l'enseignant affecté de la matière.
              teacherId: _teacherId,
            ),
          );
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cours ajouté à l\'emploi du temps.')),
        );
      }
    } on ScheduleEditException catch (e) {
      _showError(e.patchRequired ? e.message : 'Échec de l\'ajout : ${e.message}');
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

              // Matière (ClassSubject de la classe) — préselectionne
              // l'enseignant affecté à cette matière (miroir desktop).
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
                    onChanged: (v) => setState(() {
                      _classSubjectId = v;
                      // L'enseignant suit la matière sélectionnée tant que
                      // l'utilisateur n'a pas choisi manuellement.
                      _teacherId = list
                          .where((cs) => cs.id == v)
                          .firstOrNull
                          ?.assignedTeacherId;
                    }),
                  );
                },
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: LinearProgressIndicator(),
                ),
                error: (e, _) => Text('Erreur matières : $e'),
              ),
              const SizedBox(height: 12),

              // Enseignant (miroir desktop « Enseignant * »).
              _TeacherField(
                selectedId: _teacherId,
                onChanged: (id) => setState(() => _teacherId = id),
              ),
              const SizedBox(height: 12),

              // Créneau (grille horaire) — miroir desktop « Créneau * ».
              _SlotPicker(
                selection: _slot,
                onChanged: (s) => setState(() => _slot = s),
              ),
              const SizedBox(height: 12),

              // Semaine.
              _WeekTypeField(
                value: _weekType,
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
                onPressed: _saving ? null : _submit,
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
  int? _teacherId;
  _SlotSelection? _slot;
  String? _weekType;
  final _roomCtrl = TextEditingController();
  bool _saving = false;
  bool _deleting = false;

  WeeklyScheduleDto get e => widget.entry;

  @override
  void initState() {
    super.initState();
    _teacherId = e.teacherId;
    _slot = _SlotSelection(
      slotId: e.timeSlotId,
      dayOfWeek: e.dayOfWeek,
      startTime: e.startTime,
      endTime: e.endTime,
    );
    _weekType = e.isAllWeeks ? null : (e.weekType == WeekType.b ? 'B' : 'A');
    _roomCtrl.text = e.room ?? '';
  }

  @override
  void dispose() {
    _roomCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final slot = _slot;
    if (slot == null) return;
    if (!slot.isValid) {
      _showError('L\'heure de fin doit être après l\'heure de début.');
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(scheduleEditControllerProvider).updateEntry(
            e.id,
            ScheduleEntryUpdateRequest(
              timeSlotId: slot.slotId,
              dayOfWeek: slot.dayOfWeek,
              startTime: slot.startTime,
              endTime: slot.endTime,
              weekType: _weekType,
              room: _roomCtrl.text.trim(),
              // [Fix-EDT-FORM-DESKTOP] enseignant affecté à la matière.
              teacherId: _teacherId,
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
              if (e.teacherName != null) 'Ens. ${e.teacherName}',
            ].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),

          // Enseignant (miroir desktop).
          _TeacherField(
            selectedId: _teacherId,
            onChanged: (id) => setState(() => _teacherId = id),
          ),
          const SizedBox(height: 12),

          // Créneau (grille horaire ; l'entrée courante est
          // présélectionnée via son timeSlotId).
          _SlotPicker(
            selection: _slot ??
                _SlotSelection(
                    dayOfWeek: e.dayOfWeek,
                    startTime: e.startTime,
                    endTime: e.endTime),
            onChanged: (s) => setState(() => _slot = s),
          ),
          const SizedBox(height: 12),

          _WeekTypeField(
            value: _weekType,
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
