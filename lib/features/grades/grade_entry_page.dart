/// Page « Saisie des notes » : sélection classe → période → matière (cascade),
/// liste des évaluations, création d'évaluation (GRADE_EDIT), saisie des notes
/// par élève avec champ absent + commentaire.
///
/// RBAC : si l'utilisateur n'a pas la permission GRADE_READ, affiche un
/// message « Permission insuffisante ».
library;

import 'package:collection/collection.dart'; // firstOrNull (extension Iterable)
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_state.dart';
import '../../core/config/constants.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/permissions.dart';
import '../../features/connections/connection_state.dart';
import '../../shared/models/classroom_dto.dart';
import '../../shared/models/grade_dto.dart';
import '../../shared/widgets/widgets.dart';
import 'grade_controller.dart';

class GradeEntryPage extends ConsumerWidget {
  const GradeEntryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final perms = auth.permissions;
    final conn = ref.watch(connectionProvider);

    final canRead = hasPermission(perms, RbacPermissions.gradeRead);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notes & Bulletins'),
        actions: [
          IconButton(
            tooltip: 'Classement',
            icon: const Icon(Icons.leaderboard_outlined),
            onPressed: canRead
                ? () => context.push('/grades/ranking')
                : null,
          ),
        ],
      ),
      body: !canRead
          ? const EmptyState(
              title: 'Permission insuffisante',
              message: 'Vous n\'avez pas accès à la saisie des notes (GRADE_READ).',
              icon: Icons.lock_outline,
            )
          : (!conn.canReachServer
              ? const EmptyState(
                  title: 'Hors-ligne',
                  message: 'La saisie des notes nécessite une connexion au serveur.',
                  icon: Icons.cloud_off,
                )
              : const _GradeEntryBody()),
    );
  }
}

class _GradeEntryBody extends ConsumerStatefulWidget {
  const _GradeEntryBody();

  @override
  ConsumerState<_GradeEntryBody> createState() => _GradeEntryBodyState();
}

class _GradeEntryBodyState extends ConsumerState<_GradeEntryBody> {
  int? _classroomId;
  int? _periodId;
  int? _classSubjectId;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final canEdit = hasPermission(auth.permissions, RbacPermissions.gradeEdit);

    final classrooms = ref.watch(classroomsForGradesProvider);
    final periods = ref.watch(periodsProvider);

    return Scaffold(
      floatingActionButton: (canEdit && _classSubjectId != null)
          ? FloatingActionButton.extended(
              onPressed: _showCreateAssessmentSheet,
              icon: const Icon(Icons.add),
              label: const Text('Nouvelle évaluation'),
            )
          : null,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // --- Sélecteurs en cascade ---
          SectionHeader(
            title: 'Filtres',
            icon: Icons.filter_list,
            subtitle: 'Sélectionnez une classe, une période et une matière.',
          ),
          const SizedBox(height: 8),
          _DropdownField<ClassroomDto>(
            label: 'Classe',
            value: classrooms.maybeWhen(
              data: (list) =>
                  list.where((c) => c.id == _classroomId).firstOrNull ??
                  (list.isEmpty ? null : list.first),
              orElse: () => null,
            ),
            items: classrooms.maybeWhen(
              data: (list) => list,
              orElse: () => const [],
            ),
            enabled: classrooms is AsyncData,
            onChanged: (c) {
              setState(() {
                _classroomId = c?.id;
                _classSubjectId = null;
              });
            },
            labelOf: (c) => c.name,
          ),
          const SizedBox(height: 12),
          _DropdownField<PeriodDto>(
            label: 'Période',
            value: periods.maybeWhen(
              data: (list) =>
                  list.where((p) => p.id == _periodId).firstOrNull ??
                  (list.isEmpty ? null : list.first),
              orElse: () => null,
            ),
            items: periods.maybeWhen(
              data: (list) => list,
              orElse: () => const [],
            ),
            enabled: periods is AsyncData,
            onChanged: (p) => setState(() => _periodId = p?.id),
            labelOf: (p) => p.name,
          ),
          const SizedBox(height: 12),
          _ClassSubjectField(
            classroomId: _classroomId,
            selectedId: _classSubjectId,
            onChanged: (id) => setState(() => _classSubjectId = id),
          ),
          const SizedBox(height: 24),

          // --- Liste des évaluations ---
          SectionHeader(
            title: 'Évaluations',
            icon: Icons.assignment_outlined,
            subtitle: _classSubjectId == null
                ? 'Sélectionnez une matière pour lister ses évaluations.'
                : null,
          ),
          const SizedBox(height: 8),
          if (_classSubjectId == null)
            const EmptyState(
              title: 'Aucune matière sélectionnée',
              icon: Icons.book_outlined,
            )
          else
            ref.watch(assessmentsProvider(_classSubjectId!)).when(
                  data: (list) {
                    if (list.isEmpty) {
                      return EmptyState(
                        title: 'Aucune évaluation',
                        message: canEdit
                            ? 'Créez une évaluation avec le bouton « + Nouvelle évaluation ».'
                            : 'Aucune évaluation pour cette matière.',
                        icon: Icons.assignment_late_outlined,
                      );
                    }
                    return Column(
                      children: list
                          .map((a) => _AssessmentCard(
                                assessment: a,
                                onTap: () => _openGradeEntry(a),
                              ))
                          .toList(),
                    );
                  },
                  loading: () =>
                      const AppLoading(label: 'Chargement des évaluations…'),
                  error: (e, _) => AppErrorWidget(
                    message: e.toString(),
                    onRetry: () =>
                        ref.invalidate(assessmentsProvider(_classSubjectId!)),
                  ),
                ),
        ],
      ),
    );
  }

  void _showCreateAssessmentSheet() {
    if (_classSubjectId == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CreateAssessmentSheet(
        classSubjectId: _classSubjectId!,
        defaultPeriodId: _periodId,
      ),
    );
  }

  void _openGradeEntry(AssessmentDto assessment) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _GradeEntrySheet(assessment: assessment),
    );
  }
}

/// Champ de sélection générique (DropdownButtonFormField avec AsyncData).
class _DropdownField<T> extends StatelessWidget {
  const _DropdownField({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    required this.labelOf,
    this.enabled = true,
  });

  final String label;
  final T? value;
  final List<T> items;
  final ValueChanged<T?> onChanged;
  final String Function(T) labelOf;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    // Garantit que la valeur actuelle est dans la liste des items.
    final effectiveValue =
        (value != null && items.any((e) => e == value)) ? value : null;
    return DropdownButtonFormField<T>(
      value: effectiveValue,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      items: items
          .map((e) => DropdownMenuItem<T>(
                value: e,
                child: Text(labelOf(e), overflow: TextOverflow.ellipsis),
              ))
          .toList(),
      onChanged: enabled ? onChanged : null,
    );
  }
}

/// Champ matière (dépend de la classe sélectionnée).
class _ClassSubjectField extends ConsumerWidget {
  const _ClassSubjectField({
    required this.classroomId,
    required this.selectedId,
    required this.onChanged,
  });

  final int? classroomId;
  final int? selectedId;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (classroomId == null) {
      return _DisabledField(label: 'Matière', hint: 'Sélectionnez une classe d\'abord.');
    }
    final async = ref.watch(classSubjectsProvider(classroomId!));
    return async.when(
      data: (list) {
        final selected = list.where((c) => c.id == selectedId).firstOrNull ??
            (list.isEmpty ? null : list.first);
        // Auto-sélection de la première matière.
        if (selected != null && selectedId != selected.id) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            onChanged(selected.id);
          });
        }
        return DropdownButtonFormField<ClassSubjectDto>(
          value: selected,
          decoration: const InputDecoration(
            labelText: 'Matière',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: list
              .map((c) => DropdownMenuItem(
                    value: c,
                    child: Text(
                      '${c.subjectName} (coef. ${c.coefficient.toStringAsFixed(1)})',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ))
              .toList(),
          onChanged: (c) => onChanged(c?.id),
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: LinearProgressIndicator(),
      ),
      error: (e, _) => _DisabledField(label: 'Matière', hint: 'Erreur : $e'),
    );
  }
}

class _DisabledField extends StatelessWidget {
  const _DisabledField({required this.label, required this.hint});
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return TextField(
      enabled: false,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }
}

class _AssessmentCard extends StatelessWidget {
  const _AssessmentCard({required this.assessment, required this.onTap});
  final AssessmentDto assessment;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.assignment_outlined,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      assessment.title,
                      style: Theme.of(context).textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: 8,
                      children: [
                        _Chip('${assessment.type.label}'),
                        _Chip(
                            'Max ${assessment.maxScore.toStringAsFixed(0)}'),
                        _Chip(
                            'Coef. ${assessment.coefficient.toStringAsFixed(1)}'),
                        if (assessment.date != null)
                          _Chip(DateFormatter.date(assessment.date!)),
                      ],
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}

/// Bottom sheet de création d'évaluation (RBAC GRADE_EDIT).
class _CreateAssessmentSheet extends ConsumerStatefulWidget {
  const _CreateAssessmentSheet({
    required this.classSubjectId,
    this.defaultPeriodId,
  });

  final int classSubjectId;
  final int? defaultPeriodId;

  @override
  ConsumerState<_CreateAssessmentSheet> createState() =>
      _CreateAssessmentSheetState();
}

class _CreateAssessmentSheetState extends ConsumerState<_CreateAssessmentSheet> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  AssessmentType _type = AssessmentType.devoir;
  DateTime? _date = DateTime.now();
  double _maxScore = defaultMaxScore;
  double _coefficient = 1.0;
  bool _saving = false;

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        8,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Nouvelle évaluation',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              TextFormField(
                controller: _titleCtrl,
                decoration: const InputDecoration(
                  labelText: 'Titre *',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                textCapitalization: TextCapitalization.sentences,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Titre requis' : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<AssessmentType>(
                value: _type,
                decoration: const InputDecoration(
                  labelText: 'Type',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: AssessmentType.values
                    .map((t) => DropdownMenuItem(
                          value: t,
                          child: Text(t.label),
                        ))
                    .toList(),
                onChanged: (t) => setState(() => _type = t ?? _type),
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _date ?? DateTime.now(),
                    firstDate:
                        DateTime(DateTime.now().year - 2, 1, 1),
                    lastDate: DateTime(DateTime.now().year + 2, 12, 31),
                  );
                  if (picked != null) setState(() => _date = picked);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Date',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  child: Text(DateFormatter.date(_date)),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _NumberStepper(
                      label: 'Note maximale',
                      value: _maxScore,
                      min: 1,
                      max: 100,
                      step: 1,
                      onChanged: (v) => setState(() => _maxScore = v),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _NumberStepper(
                      label: 'Coefficient',
                      value: _coefficient,
                      min: 0.5,
                      max: 20,
                      step: gradeStep,
                      onChanged: (v) => setState(() => _coefficient = v),
                    ),
                  ),
                ],
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
                label: const Text('Créer'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      await ref.read(gradeControllerProvider).createAssessment(
            classSubjectId: widget.classSubjectId,
            title: _titleCtrl.text.trim(),
            type: _type,
            date: _date,
            maxScore: _maxScore,
            coefficient: _coefficient,
            periodId: widget.defaultPeriodId,
          );
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Évaluation créée.')),
        );
      }
    } on ApiException catch (e) {
      _showError(e.message);
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
}

/// Stepper numérique réutilisable (boutons +/- avec pas configurable).
class _NumberStepper extends StatelessWidget {
  const _NumberStepper({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final double step;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      child: Row(
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: value > min
                ? () => onChanged(
                    GradeFormatter.snap((value - step).clamp(min, max)))
                : null,
          ),
          Expanded(
            child: Text(
              value.toStringAsFixed(value == value.truncate() ? 0 : 1),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add_circle_outline),
            onPressed: value < max
                ? () => onChanged(
                    GradeFormatter.snap((value + step).clamp(min, max)))
                : null,
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet de saisie des notes d'une évaluation : un élève par ligne,
/// champ numérique (0–maxScore, pas 0.5) + case « Absent » + commentaire.
class _GradeEntrySheet extends ConsumerStatefulWidget {
  const _GradeEntrySheet({required this.assessment});
  final AssessmentDto assessment;

  @override
  ConsumerState<_GradeEntrySheet> createState() => _GradeEntrySheetState();
}

class _GradeEntrySheetState extends ConsumerState<_GradeEntrySheet> {
  /// Brouillons de notes indexés par `studentId`. Initialisés paresseusement
  /// à partir de la première réponse de l'API et conservés entre les rebuilds
  /// pour ne pas perdre les saisies en cours.
  final Map<int, GradeDto> _drafts = {};
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(assessmentGradesProvider(widget.assessment.id));
    final maxHeight = MediaQuery.of(context).size.height * 0.85;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          8,
          16,
          16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.assessment.title,
                    style: Theme.of(context).textTheme.titleLarge,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${widget.assessment.type.label} • Max ${widget.assessment.maxScore.toStringAsFixed(0)} • Coef. ${widget.assessment.coefficient.toStringAsFixed(1)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const Divider(height: 24),
            Expanded(
              child: async.when(
                data: (grades) {
                  // Initialise paresseusement les brouillons sans écraser
                  // les modifications déjà effectuées par l'utilisateur.
                  for (final g in grades) {
                    _drafts.putIfAbsent(g.studentId, () => g);
                  }
                  if (grades.isEmpty) {
                    return const EmptyState(
                      title: 'Aucun élève',
                      message: 'Aucun élève à noter pour cette évaluation.',
                      icon: Icons.group_off,
                    );
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: grades.length,
                    itemBuilder: (_, i) {
                      final original = grades[i];
                      final draft = _drafts[original.studentId] ?? original;
                      return _GradeRow(
                        grade: draft,
                        maxScore: widget.assessment.maxScore,
                        onChanged: (g) =>
                            setState(() => _drafts[original.studentId] = g),
                      );
                    },
                  );
                },
                loading: () =>
                    const AppLoading(label: 'Chargement des notes…'),
                error: (e, _) => AppErrorWidget(
                  message: e.toString(),
                  onRetry: () => ref.invalidate(
                      assessmentGradesProvider(widget.assessment.id)),
                ),
              ),
            ),
            const SizedBox(height: 8),
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
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final grades = _drafts.values.toList();
    setState(() => _saving = true);
    try {
      await ref
          .read(gradeControllerProvider)
          .saveGrades(widget.assessment.id, grades);
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('${grades.length} note(s) enregistrée(s).')),
        );
      }
    } on ApiException catch (e) {
      _showError(e.message);
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
}

/// Ligne de saisie d'une note : nom + matricule de l'élève, champ numérique
/// (0–maxScore, snap au pas 0.5) et case « Absent » qui désactive le champ.
///
/// Le [TextEditingController] est géré dans un [State] dédié pour conserver
/// la position du curseur entre les rebuilds et synchroniser le texte quand
/// l'utilisateur bascule la case « Absent ».
class _GradeRow extends StatefulWidget {
  const _GradeRow({
    required this.grade,
    required this.maxScore,
    required this.onChanged,
  });

  final GradeDto grade;
  final double maxScore;
  final ValueChanged<GradeDto> onChanged;

  @override
  State<_GradeRow> createState() => _GradeRowState();
}

class _GradeRowState extends State<_GradeRow> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: _formattedValue);
    _ctrl.addListener(_onCtrlChanged);
  }

  String get _formattedValue => widget.grade.isAbsent || widget.grade.value == null
      ? ''
      : widget.grade.value!.toStringAsFixed(2);

  void _onCtrlChanged() {
    if (widget.grade.isAbsent) return; // Champ désactivé.
    final v = _ctrl.text;
    final parsed = double.tryParse(v.replaceAll(',', '.'));
    final snapped = parsed == null
        ? null
        : GradeFormatter.snap(parsed.clamp(0.0, widget.maxScore));
    if (snapped != widget.grade.value) {
      widget.onChanged(_copyWith(value: snapped, isAbsent: false));
    }
  }

  GradeDto _copyWith({double? value, bool? isAbsent}) => GradeDto(
        id: widget.grade.id,
        assessmentId: widget.grade.assessmentId,
        studentId: widget.grade.studentId,
        studentName: widget.grade.studentName,
        matricule: widget.grade.matricule,
        value: value,
        isAbsent: isAbsent ?? widget.grade.isAbsent,
        comments: widget.grade.comments,
      );

  @override
  void didUpdateWidget(covariant _GradeRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Resynchronise le texte uniquement quand l'état « Absent » bascule :
    // on évite ainsi de perturber le curseur pendant la frappe.
    if (oldWidget.grade.isAbsent != widget.grade.isAbsent) {
      _ctrl.text = _formattedValue;
    }
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onCtrlChanged);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.grade.studentName,
                      style: Theme.of(context).textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  if (widget.grade.matricule != null)
                    Text(widget.grade.matricule!,
                        style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 90,
              child: TextField(
                controller: _ctrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                enabled: !widget.grade.isAbsent,
                decoration: InputDecoration(
                  prefixText: '/ ${widget.maxScore.toStringAsFixed(0)}  ',
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(width: 8),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: widget.grade.isAbsent,
                  onChanged: (v) {
                    final absent = v ?? false;
                    // On préserve `value` pour pouvoir revenir en arrière
                    // (décocher « Absent » restaure la note saisie).
                    widget.onChanged(
                        _copyWith(value: widget.grade.value, isAbsent: absent));
                  },
                ),
                const Text('Abs', style: TextStyle(fontSize: 11)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
