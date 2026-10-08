/// Page « Saisie des notes » : sélection classe → période → matière (cascade),
/// liste des évaluations (avec progress + maxScore), création d'évaluation
/// (GRADE_EDIT, type via [CommonAssessmentTypes.defaults]), saisie des notes
/// par élève ([GradeEntryDto]) avec champ absent + commentaire + **verrouillage**
/// (is_locked) : si la note est verrouillée, l'input et la case « Absent » sont
/// désactivés et un badge « Verrouillée » s'affiche. Le serveur ignore les
/// notes verrouillées dans le bulk_save (skipped_count).
///
/// RBAC :
/// - GRADE_READ  → lecture seule (sheet ouverte en consultation, bouton
///   « Enregistrer » masqué).
/// - GRADE_EDIT  → création / suppression d'évaluations + saisie des notes.
///
/// Aligné sur le contrat desktop :
/// - Évaluations : `GET /grades/assessments?class_subject_id=&period_id=`
/// - Notes : `GET /grades/assessments/{id}/grades` → list[GradeEntryResponse]
/// - Sauvegarde : `POST /grades/assessments/{id}/grades` {grades: list[dict]}
library;

import 'package:collection/collection.dart'; // firstOrNull
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
import 'grade_utils.dart';

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
          // [Fix-OFFLINE] Plus de garde hors-ligne bloquante : la saisie
          // est TOUJOURS possible. Hors-ligne, la page lit le cache Drift
          // (+ soumissions en attente) et l'enregistrement part dans
          // l'outbox — synchronisé à la prochaine connexion.
          : const _GradeEntryBody(),
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
    // Les admins (superuser / ADMIN / HEADMASTER) ne sont PAS soumis au
    // verrouillage des notes déjà saisies (is_locked) — ils peuvent corriger
    // une note existante (miroir de l'upsert admin du desktop).
    final isAdmin = auth.isAdminOrHeadmaster;

    final classrooms = ref.watch(classroomsForGradesProvider);

    // Auto-sélection de la première classe (miroir Ranking/Bulletin).
    final classroomList = classrooms.valueOrNull ?? const <ClassroomDto>[];
    if (_classroomId == null && classroomList.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _classroomId == null) {
          setState(() => _classroomId = classroomList.first.id);
        }
      });
    }

    // Périodes filtrées par le CYCLE de la classe sélectionnée — corrige le
    // mélange lycée/collège dans le champ « Période ».
    final periods = _classroomId == null
        ? const AsyncValue<List<PeriodDto>>.data(const [])
        : ref.watch(periodsForClassroomProvider(_classroomId!));

    // Auto-sélection de la période ACTIVE du jour (miroir
    // GradeService.get_active_period), sinon la première.
    final periodList = periods.valueOrNull ?? const <PeriodDto>[];
    if (_classroomId != null &&
        _periodId == null &&
        periodList.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _periodId == null) {
          final active = activePeriodOf(periodList);
          if (active != null) setState(() => _periodId = active.id);
        }
      });
    }

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
          // [Fix-OFFLINE] Bandeau d'information (jamais bloquant) : la
          // saisie reste possible, l'enregistrement part dans l'outbox.
          Consumer(builder: (context, ref, _) {
            final conn = ref.watch(connectionProvider);
            final offline = !conn.canReachServer && !conn.isChecking;
            if (!offline) return const SizedBox.shrink();
            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.cloud_off_outlined,
                      size: 18,
                      color: Theme.of(context).colorScheme.onTertiaryContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Mode hors-ligne : consultation et saisie sur le cache '
                      'local. L\'enregistrement sera synchronisé à la prochaine '
                      'connexion.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onTertiaryContainer),
                    ),
                  ),
                ],
              ),
            );
          }),
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
                // Reset de la période : elle sera re-filtrée par le cycle de
                // la nouvelle classe puis auto-sélectionnée (période active).
                _periodId = null;
              });
            },
            labelOf: (c) => c.name,
          ),
          const SizedBox(height: 12),
          _DropdownField<PeriodDto>(
            label: 'Période',
            value: periods.maybeWhen(
              data: (list) {
                // [Fix-PERIOD-CYCLE] Filtrer les périodes par cycle de la classe sélectionnée.
                final filtered = _filterPeriodsByCycle(list, _classroomId, classrooms);
                return filtered.where((p) => p.id == _periodId).firstOrNull ??
                    (filtered.isEmpty ? null : filtered.first);
              },
              orElse: () => null,
            ),
            items: periods.maybeWhen(
              data: (list) => _filterPeriodsByCycle(list, _classroomId, classrooms),
              orElse: () => const [],
            ),
            enabled: periods is AsyncData && _classroomId != null,
            onChanged: (p) => setState(() => _periodId = p?.id),
            labelOf: (p) => p.cycleName == null
                ? p.name
                : '${p.name} (${p.cycleName})',
            hint: _classroomId == null
                ? 'Sélectionnez une classe d\'abord'
                : null,
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
                                onTap: () =>
                                    _openGradeEntry(a, canEdit, isAdmin),
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

  /// [Fix-PERIOD-CYCLE] Filtre les périodes par cycle de la classe sélectionnée.
  /// Si la classe a un cycleId, on ne garde que les périodes du même cycle.
  /// Si pas de classe sélectionnée ou pas de cycleId, on garde tout.
  List<PeriodDto> _filterPeriodsByCycle(
    List<PeriodDto> allPeriods,
    int? classroomId,
    AsyncValue<List<ClassroomDto>> classroomsAsync,
  ) {
    if (classroomId == null) return allPeriods;
    final classrooms = classroomsAsync.valueOrNull ?? [];
    final classroom = classrooms.where((c) => c.id == classroomId).firstOrNull;
    if (classroom == null) return allPeriods;

    // Le ClassroomDto a cycleName (ex: "Collège", "Lycée").
    // Le PeriodDto a maintenant cycleId et cycleName.
    // Si les périodes n'ont pas de cycleId (ancien serveur), on ne filtre pas.
    final hasCycleInfo = allPeriods.any((p) => p.cycleId != null);
    if (!hasCycleInfo) return allPeriods;

    // Filtrer par cycleId si disponible, sinon par cycleName.
    final filtered = allPeriods.where((p) {
      // Si la période n'a pas de cycleId, on la garde (rétrocompatible).
      if (p.cycleId == null) return true;
      // Si la classroom a un cycleId et la période aussi, on compare.
      if (classroom.cycleId != null) {
        return p.cycleId == classroom.cycleId;
      }
      // Sinon, comparer par nom.
      if (p.cycleName != null && classroom.cycleName != null) {
        return p.cycleName!.toLowerCase() == classroom.cycleName!.toLowerCase();
      }
      return true;
    }).toList();

    return filtered;
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

  void _openGradeEntry(AssessmentDto assessment, bool canEdit, bool isAdmin) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _GradeEntrySheet(
        assessment: assessment,
        canEdit: canEdit,
        // Admin : le verrouillage is_locked est ignoré (notes modifiables).
        isAdmin: isAdmin,
      ),
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
    this.hint,
  });

  final String label;
  final T? value;
  final List<T> items;
  final ValueChanged<T?> onChanged;
  final String Function(T) labelOf;
  final bool enabled;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    // Garantit que la valeur actuelle est dans la liste des items.
    final effectiveValue =
        (value != null && items.any((e) => e == value)) ? value : null;
    return DropdownButtonFormField<T>(
      value: effectiveValue,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
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
      return const _DisabledField(
          label: 'Matière', hint: 'Sélectionnez une classe d\'abord.');
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
///
/// Le type d'évaluation est choisi parmi [CommonAssessmentTypes.defaults]
/// (aucun endpoint REST ne liste les types pour le moment — réf. serveur).
/// La note maximale est pré-remplie avec `type.defaultMaxScore`.
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
  AssessmentTypeInfo? _type;
  DateTime? _date = DateTime.now();
  double _maxScore = 20;
  bool _saving = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _onTypeChanged(AssessmentTypeInfo? t) {
    if (t == null) return;
    setState(() {
      _type = t;
      // Pré-remplit la note maximale avec le défaut du type sélectionné
      // si l'utilisateur n'a pas encore personnalisé la valeur.
      _maxScore = t.defaultMaxScore.toDouble();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Types d'évaluation : endpoint dédié (patch serveur) avec replis —
    // 1) GET /grades/assessment-types ; 2) types déduits des évaluations
    // existantes de la matière (assessment_type_id/name dénormalisés) ;
    // 3) valeurs par défaut.
    final typesAsync = ref.watch(assessmentTypesProvider);
    final existingAsync = ref.watch(assessmentsProvider(AssessmentsQuery(
      classSubjectId: widget.classSubjectId,
      periodId: widget.periodId,
    )));

    final serverTypes = typesAsync.value ?? CommonAssessmentTypes.defaults;
    var types = serverTypes;
    if (identical(types, CommonAssessmentTypes.defaults)) {
      final derived = <int, AssessmentTypeInfo>{};
      for (final a in existingAsync.valueOrNull ?? const <AssessmentDto>[]) {
        if (a.assessmentTypeId > 0 && a.assessmentTypeName.isNotEmpty) {
          derived.putIfAbsent(
              a.assessmentTypeId,
              () => AssessmentTypeInfo(
                    id: a.assessmentTypeId,
                    name: a.assessmentTypeName,
                    code: a.assessmentTypeName.toUpperCase(),
                    category: a.assessmentTypeCategory.toUpperCase() == 'EXAM'
                        ? AssessmentCategory.examen
                        : AssessmentCategory.classe,
                  ));
        }
      }
      if (derived.isNotEmpty) types = derived.values.toList();
    }

    // Auto-sélection du premier type.
    if (_type == null || !types.any((t) => t.id == _type!.id)) {
      if (types.isNotEmpty) {
        _type = types.first;
        _maxScore = types.first.defaultMaxScore.toDouble();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() {});
        });
      }
    }

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
              if (types.isEmpty)
                const Text(
                  'Aucun type d\'évaluation connu pour ce serveur. Créez-en '
                  'un côté desktop ou appliquez le patch serveur '
                  '(assessment-types).',
                  style: TextStyle(fontStyle: FontStyle.italic),
                )
              else
                DropdownButtonFormField<AssessmentTypeInfo>(
                  value: _type,
                  decoration: const InputDecoration(
                    labelText: 'Type d\'évaluation *',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: types
                      .map((t) => DropdownMenuItem(
                            value: t,
                            child: Text(
                              '${t.name} (${t.category.label})',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ))
                      .toList(),
                  onChanged: _onTypeChanged,
                ),
              const SizedBox(height: 8),
              if (identical(types, CommonAssessmentTypes.defaults))
                Text(
                  'Astuce : les types sont chargés depuis le serveur si le patch '
                  'GeTech-SMS est appliqué ; sinon ce sont les évaluations '
                  'existantes de la matière qui servent de référence.',
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
                    firstDate: DateTime(DateTime.now().year - 2, 1, 1),
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
    if (_type == null) return;
    setState(() => _saving = true);
    try {
      await ref.read(gradeControllerProvider).createAssessment(
            AssessmentCreateRequest(
              classSubjectId: widget.classSubjectId,
              periodId: widget.periodId,
              name: _nameCtrl.text.trim(),
              assessmentTypeId: _type!.id,
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
/// **Verrouillage** : si `grade.isLocked == true`, l'input de note, la case
/// « Absent » et le commentaire sont désactivés, et un badge « Verrouillée »
/// s'affiche. Le serveur ignore les notes verrouillées dans le bulk_save
/// (skipped_count) — le résultat renvoyé l'indique explicitement.
///
/// **Lecture seule** : si [canEdit] est `false` (GRADE_READ uniquement), le
/// bouton « Enregistrer » est masqué et un bandeau « Lecture seule » s'affiche.
///
/// Utilise [GradeEntryDto] (aligné sur GradeEntryResponse serveur) :
/// {student_id, student_name, student_matricule, grade_id, value, is_absent,
/// comment, is_locked}.
class _GradeEntrySheet extends ConsumerStatefulWidget {
  const _GradeEntrySheet({
    required this.assessment,
    required this.canEdit,
    this.isAdmin = false,
  });

  final AssessmentDto assessment;
  final bool canEdit;

  /// Vrai pour les admins (superuser / ADMIN / HEADMASTER) : le verrouillage
  /// `is_locked` est ignoré — les notes déjà saisies restent modifiables
  /// (miroir de l'upsert admin du desktop ; nécessite le patch serveur pour
  /// persister côté API, sinon le serveur compte les existantes en `skipped`).
  final bool isAdmin;

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
            if (!widget.canEdit) ...[
              const SizedBox(height: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.blueGrey.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.visibility_outlined,
                        size: 14, color: Colors.blueGrey.shade700),
                    const SizedBox(width: 6),
                    Text(
                      'Lecture seule (GRADE_READ)',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: Colors.blueGrey.shade700,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ],
                ),
              ),
            ],
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
                        editable: widget.canEdit,
                        isAdmin: widget.isAdmin,
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
            if (widget.canEdit) ...[
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
        String msg;
        if (resp.offlineQueued) {
          msg = 'Enregistré hors-ligne — la synchronisation aura lieu à la '
              'prochaine connexion au serveur.';
        } else if (resp.queuedCount > 0) {
          msg = '${resp.savedCount} note(s) enregistrée(s) ; '
              '${resp.queuedCount} modification(s) en attente de validation '
              'admin.';
        } else if (resp.skippedCount > 0) {
          msg = '${resp.savedCount} note(s) enregistrée(s), '
              '${resp.skippedCount} inchangée(s).';
        } else {
          msg = '${resp.savedCount} note(s) enregistrée(s).';
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 4)),
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
/// et champ commentaire.
///
/// **Verrouillage** : si `grade.isLocked == true`, badge « Verrouillée »,
/// tous les champs désactivés.
///
/// **Lecture seule** : si [editable] est `false`, idem (champs désactivés),
/// sans le badge de verrouillage.
class _GradeRow extends StatefulWidget {
  const _GradeRow({
    required this.grade,
    required this.maxScore,
    required this.editable,
    required this.onChanged,
    this.isAdmin = false,
  });

  final GradeEntryDto grade;
  final double maxScore;
  final bool editable;

  /// Admin : le verrou `is_locked` n'est pas appliqué (notes modifiables).
  final bool isAdmin;
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
      widget.grade.copyWith(
        value: value,
        isAbsent: isAbsent,
        comment: comment,
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
    // [Grade-Validation] Fin du verrouillage des notes existantes : les
    // champs restent éditables (enseignant : la modification devient une
    // proposition à valider/rejeter par un admin ; admin : application
    // directe). La ligne porte une MARQUE de statut (voir _GradeMarkChip).
    final readOnly = !widget.editable;
    final disabled = readOnly;
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
                          // [Grade-Validation] Marque de statut de la note
                          // (proposition en attente / validée / rejetée /
                          // synchronisation différée) au lieu de l'ancien
                          // badge « Verrouillée ».
                          _GradeMarkChip(grade: widget.grade),
                          if (readOnly)
                            Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: Icon(Icons.visibility_outlined,
                                  size: 14,
                                  color: theme.colorScheme.onSurfaceVariant),
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
                    enabled: !widget.grade.isAbsent && !disabled,
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
                      onChanged: disabled
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
              enabled: !disabled,
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

/// [Grade-Validation] Badge de marque d'une note :
///   - 'pending_sync' (saisie hors-ligne) : « Sera synchronisée » ;
///   - 'PENDING' (serveur) : « X → Y · en attente de validation » ;
///   - 'APPROVED' : « Modification validée » ;
///   - 'REJECTED' : « Modifiée — rejetée (valeur actuelle conservée) » ;
///   - sinon : pas de badge (note ordinaire).
class _GradeMarkChip extends StatelessWidget {
  const _GradeMarkChip({required this.grade});

  final GradeEntryDto grade;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = grade.modificationStatus ??
        (grade.localSyncMark == 'pending_sync' ? 'pending_sync' : null);
    if (status == null) return const SizedBox.shrink();

    String label;
    Color fg;
    Color bg;
    IconData icon;
    switch (status) {
      case 'pending_sync':
        label = 'Sera synchronisée';
        fg = Colors.blue.shade800;
        bg = Colors.blue.shade50;
        icon = Icons.sync_outlined;
        break;
      case 'PENDING':
        final oldV = grade.modification?.oldValue;
        final newV = grade.modification?.newValue ??
            grade.value; // hors-ligne : valeur proposée affichée
        label = oldV != null
            ? 'En attente de validation (${oldV.toStringAsFixed(oldV.truncateToDouble() == oldV ? 0 : 1)} → ${newV?.toStringAsFixed(newV!.truncateToDouble() == newV ? 0 : 1) ?? '?'})'
            : 'En attente de validation';
        fg = Colors.orange.shade800;
        bg = Colors.orange.shade50;
        icon = Icons.hourglass_top_outlined;
        break;
      case 'APPROVED':
        label = 'Modification validée';
        fg = Colors.green.shade800;
        bg = Colors.green.shade50;
        icon = Icons.check_circle_outline;
        break;
      case 'REJECTED':
        label = 'Modifiée — rejetée (ancienne valeur conservée)';
        fg = Colors.red.shade700;
        bg = Colors.red.shade50;
        icon = Icons.block_outlined;
        break;
      default:
        return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: fg),
          const SizedBox(width: 2),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
