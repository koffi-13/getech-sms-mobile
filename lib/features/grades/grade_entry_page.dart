/// Page « Saisie des notes » : sélection classe → période → matière (cascade),
/// liste des évaluations, création d'évaluation (GRADE_EDIT), saisie des notes
/// par élève (GradeEntryDto) avec champ absent + commentaire.
///
/// Aligné sur le contrat desktop :
/// - Évaluations : `GET /grades/assessments?class_subject_id=&period_id=`
/// - Notes : `GET /grades/assessments/{id}/grades` → list[GradeEntryResponse]
/// - Sauvegarde : `POST /grades/assessments/{id}/grades` {grades: list[dict]}
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

    final query = (_classSubjectId != null && _periodId != null)
        ? AssessmentsQuery(
            classSubjectId: _classSubjectId!,
            periodId: _periodId!,
          )
        : null;

    return Scaffold(
      floatingActionButton: (canEdit && query != null)
          ? FloatingActionButton.extended(
              onPressed: () => _showCreateAssessmentSheet(),
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
            subtitle: query == null
                ? 'Sélectionnez une matière et une période pour lister les évaluations.'
                : null,
          ),
          const SizedBox(height: 8),
          if (query == null)
            const EmptyState(
              title: 'Aucune matière ou période sélectionnée',
              icon: Icons.book_outlined,
            )
          else
            ref.watch(assessmentsProvider(query)).when(
                  data: (list) {
                    if (list.isEmpty) {
                      return EmptyState(
                        title: 'Aucune évaluation',
                        message: canEdit
                            ? 'Créez une évaluation avec le bouton « + Nouvelle évaluation ».'
                            : 'Aucune évaluation pour cette matière/période.',
                        icon: Icons.assignment_late_outlined,
                      );
                    }
                    return Column(
                      children: list
                          .map((a) => _AssessmentCard(
                                assessment: a,
                                canEdit: canEdit,
                                onTap: () => _openGradeEntry(a),
                                onDelete: canEdit
                                    ? () => _confirmDelete(a)
                                    : null,
                              ))
                          .toList(),
                    );
                  },
                  loading: () =>
                      const AppLoading(label: 'Chargement des évaluations…'),
                  error: (e, _) => AppErrorWidget(
                    message: e.toString(),
                    onRetry: () => ref.invalidate(assessmentsProvider(query)),
                  ),
                ),
        ],
      ),
    );
  }

  void _showCreateAssessmentSheet() {
    if (_classSubjectId == null || _periodId == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CreateAssessmentSheet(
        classSubjectId: _classSubjectId!,
        periodId: _periodId!,
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

  Future<void> _confirmDelete(AssessmentDto assessment) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer l\'évaluation'),
        content: Text(
            'Supprimer « ${assessment.name} » ? Les notes saisies seront perdues.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
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
    try {
      await ref.read(gradeControllerProvider).deleteAssessment(assessment.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Évaluation supprimée.')),
        );
      }
    } on ApiException catch (e) {
      _showError(e.message);
    } catch (e) {
      _showError('Erreur : $e');
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red.shade700),
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
                      '${c.subjectName} (coef. ${c.coefficient})',
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
  const _AssessmentCard({
    required this.assessment,
    required this.onTap,
    required this.canEdit,
    this.onDelete,
  });
  final AssessmentDto assessment;
  final VoidCallback onTap;
  final bool canEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = assessment.totalStudents == 0
        ? null
        : assessment.gradesEnteredCount / assessment.totalStudents;
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
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.assignment_outlined,
                  color: theme.colorScheme.onPrimaryContainer,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      assessment.name.isEmpty
                          ? '(sans nom)'
                          : assessment.name,
                      style: theme.textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: 8,
                      runSpacing: 2,
                      children: [
                        if (assessment.assessmentTypeName.isNotEmpty)
                          _Chip(assessment.assessmentTypeName),
                        _Chip('Max ${assessment.maxScore.toStringAsFixed(0)}'),
                        if (assessment.dateTaken != null &&
                            assessment.dateTaken!.isNotEmpty)
                          _Chip(DateFormatter.date(
                              DateFormatter.parse(assessment.dateTaken))),
                        _Chip(
                          '${assessment.gradesEnteredCount}/${assessment.totalStudents} saisies',
                        ),
                      ],
                    ),
                    if (progress != null) ...[
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: progress.clamp(0.0, 1.0),
                          minHeight: 4,
                          backgroundColor:
                              theme.colorScheme.surfaceContainerHighest,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
              if (canEdit && onDelete != null)
                IconButton(
                  tooltip: 'Supprimer',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.delete_outline,
                      size: 20, color: Colors.red.shade400),
                  onPressed: onDelete,
                ),
              Icon(Icons.chevron_right,
                  color: theme.colorScheme.onSurfaceVariant),
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
///
/// Champs serveur (AssessmentCreateRequest) : {class_subject_id, period_id,
/// name, assessment_type_id, max_score, date_taken}.
class _CreateAssessmentSheet extends ConsumerStatefulWidget {
  const _CreateAssessmentSheet({
    required this.classSubjectId,
    required this.periodId,
  });

  final int classSubjectId;
  final int periodId;

  @override
  ConsumerState<_CreateAssessmentSheet> createState() =>
      _CreateAssessmentSheetState();
}

class _CreateAssessmentSheetState extends ConsumerState<_CreateAssessmentSheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _typeIdCtrl = TextEditingController(text: '1');
  DateTime? _date = DateTime.now();
  double _maxScore = defaultMaxScore;
  bool _saving = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _typeIdCtrl.dispose();
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
              const SizedBox(height: 4),
              Text(
                'class_subject #${widget.classSubjectId} • période #${widget.periodId}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Nom *',
                  hintText: 'ex : Devoir 1',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                textCapitalization: TextCapitalization.sentences,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Nom requis' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _typeIdCtrl,
                decoration: const InputDecoration(
                  labelText: 'Type d\'évaluation (ID) *',
                  hintText: 'ex : 1',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                keyboardType: TextInputType.number,
                validator: (v) {
                  final n = int.tryParse(v ?? '');
                  if (n == null || n <= 0) return 'ID type invalide';
                  return null;
                },
              ),
              const SizedBox(height: 8),
              Text(
                'Astuce : Devoir=1, Composition=2, Interrogation=3, TP=4 (selon le référentiel serveur).',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
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
                    labelText: 'Date de l\'évaluation',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  child: Text(DateFormatter.date(_date)),
                ),
              ),
              const SizedBox(height: 12),
              _NumberStepper(
                label: 'Note maximale',
                value: _maxScore,
                min: 1,
                max: 100,
                step: 1,
                onChanged: (v) => setState(() => _maxScore = v),
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
            AssessmentCreateRequest(
              classSubjectId: widget.classSubjectId,
              periodId: widget.periodId,
              name: _nameCtrl.text.trim(),
              assessmentTypeId: int.parse(_typeIdCtrl.text.trim()),
              maxScore: _maxScore,
              dateTaken: DateFormatter.toIso(_date),
            ),
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
///
/// Utilise [GradeEntryDto] (aligné sur GradeEntryResponse serveur) :
/// {student_id, student_name, student_matricule, grade_id, value, is_absent,
/// comment, is_locked}.
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
  final Map<int, GradeEntryDto> _drafts = {};
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
                    widget.assessment.name.isEmpty
                        ? '(sans nom)'
                        : widget.assessment.name,
                    style: Theme.of(context).textTheme.titleLarge,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              [
                if (widget.assessment.assessmentTypeName.isNotEmpty)
                  widget.assessment.assessmentTypeName,
                'Max ${widget.assessment.maxScore.toStringAsFixed(0)}',
              ].join(' • '),
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
      final resp = await ref
          .read(gradeControllerProvider)
          .saveGrades(widget.assessment.id, grades);
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              resp.skippedCount > 0
                  ? '${resp.savedCount} note(s) enregistrée(s), ${resp.skippedCount} ignorée(s).'
                  : '${resp.savedCount} note(s) enregistrée(s).',
            ),
          ),
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
/// (0–maxScore, snap au pas 0.5), case « Absent » qui désactive le champ,
/// et champ commentaire. Badge « verrouillé » si `is_locked`.
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

  final GradeEntryDto grade;
  final double maxScore;
  final ValueChanged<GradeEntryDto> onChanged;

  @override
  State<_GradeRow> createState() => _GradeRowState();
}

class _GradeRowState extends State<_GradeRow> {
  late final TextEditingController _valueCtrl;
  late final TextEditingController _commentCtrl;

  @override
  void initState() {
    super.initState();
    _valueCtrl = TextEditingController(text: _formattedValue);
    _commentCtrl = TextEditingController(text: widget.grade.comment ?? '');
    _valueCtrl.addListener(_onValueCtrlChanged);
    _commentCtrl.addListener(_onCommentCtrlChanged);
  }

  String get _formattedValue =>
      widget.grade.isAbsent || widget.grade.value == null
          ? ''
          : widget.grade.value!.toStringAsFixed(2);

  void _onValueCtrlChanged() {
    if (widget.grade.isAbsent) return; // Champ désactivé.
    final v = _valueCtrl.text;
    final parsed = double.tryParse(v.replaceAll(',', '.'));
    final snapped = parsed == null
        ? null
        : GradeFormatter.snap(parsed.clamp(0.0, widget.maxScore));
    if (snapped != widget.grade.value) {
      widget.onChanged(_copyWith(value: snapped, isAbsent: false));
    }
  }

  void _onCommentCtrlChanged() {
    if (widget.grade.comment != _commentCtrl.text) {
      widget.onChanged(_copyWith(comment: _commentCtrl.text));
    }
  }

  GradeEntryDto _copyWith({
    double? value,
    bool? isAbsent,
    String? comment,
  }) =>
      GradeEntryDto(
        studentId: widget.grade.studentId,
        studentName: widget.grade.studentName,
        studentMatricule: widget.grade.studentMatricule,
        gradeId: widget.grade.gradeId,
        value: value,
        isAbsent: isAbsent ?? widget.grade.isAbsent,
        comment: comment ?? widget.grade.comment,
        isLocked: widget.grade.isLocked,
      );

  @override
  void didUpdateWidget(covariant _GradeRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Resynchronise le texte uniquement quand l'état « Absent » bascule :
    // on évite ainsi de perturber le curseur pendant la frappe.
    if (oldWidget.grade.isAbsent != widget.grade.isAbsent) {
      _valueCtrl.text = _formattedValue;
    }
  }

  @override
  void dispose() {
    _valueCtrl.removeListener(_onValueCtrlChanged);
    _commentCtrl.removeListener(_onCommentCtrlChanged);
    _valueCtrl.dispose();
    _commentCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locked = widget.grade.isLocked;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              widget.grade.studentName,
                              style: theme.textTheme.titleSmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (locked)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade300,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.lock,
                                      size: 11, color: Colors.grey.shade700),
                                  const SizedBox(width: 2),
                                  Text(
                                    'Verrouillé',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: Colors.grey.shade700,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                      if (widget.grade.studentMatricule.isNotEmpty)
                        Text(widget.grade.studentMatricule,
                            style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 90,
                  child: TextField(
                    controller: _valueCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    enabled: !widget.grade.isAbsent && !locked,
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
                      onChanged: locked
                          ? null
                          : (v) {
                              final absent = v ?? false;
                              // On préserve `value` pour pouvoir revenir en
                              // arrière (décocher « Absent » restaure la note
                              // saisie). Si on coche Absent, value=null côté
                              // serveur.
                              widget.onChanged(_copyWith(
                                  value: absent ? null : widget.grade.value,
                                  isAbsent: absent));
                            },
                    ),
                    const Text('Abs', style: TextStyle(fontSize: 11)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _commentCtrl,
              enabled: !locked,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Commentaire (optionnel)',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.comment_outlined, size: 18),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 10),
              ),
              style: theme.textTheme.bodySmall,
              maxLines: 1,
            ),
          ],
        ),
      ),
    );
  }
}
