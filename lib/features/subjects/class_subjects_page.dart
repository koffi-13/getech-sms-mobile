/// Page "Affectations par classe" : gestion des matières enseignées dans une
/// classe (coefficient + enseignant).
///
/// Si [classroomId] est fourni, la classe est présélectionnée. Sinon,
/// l'utilisateur choisit une classe dans un dropdown (alimenté par
/// [classroomsListProvider]).
///
/// Pour la classe sélectionnée :
/// - Liste des [ClassSubjectDto] (matière, coefficient, enseignant) avec
///   édition inline du coefficient et bouton de suppression.
/// - FAB "Affecter une matière" → dialogue (matière non affectée + coefficient
///   + enseignant optionnel) via [SubjectRepository.assignSubjectToClass].
///
/// RBAC : SUBJECT_MANAGE requis. Sans cette permission, écran « Permission
/// insuffisante ».
library;

import 'package:collection/collection.dart'; // firstOrNull
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_state.dart';
import '../../core/config/constants.dart';
import '../../core/utils/permissions.dart';
import '../../shared/models/auth_dto.dart';
import '../../shared/models/classroom_dto.dart';
import '../../shared/widgets/widgets.dart';
import '../classrooms/classroom_controller.dart' show classroomsListProvider;
import '../connections/connection_state.dart';
import '../users/user_controller.dart';
import 'subject_controller.dart';

class ClassSubjectsPage extends ConsumerStatefulWidget {
  const ClassSubjectsPage({super.key, this.classroomId});

  /// ID de la classe présélectionnée. Si null, l'utilisateur choisira une
  /// classe dans le dropdown.
  final int? classroomId;

  @override
  ConsumerState<ClassSubjectsPage> createState() => _ClassSubjectsPageState();
}

class _ClassSubjectsPageState extends ConsumerState<ClassSubjectsPage> {
  int? _selectedClassroomId;
  bool _init = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_init) {
      _init = true;
      _selectedClassroomId = widget.classroomId;
    }
  }

  Future<void> _refresh() async {
    final id = _selectedClassroomId;
    if (id != null) {
      ref.invalidate(classSubjectsForClassroomProvider(id));
    }
    ref.invalidate(classroomsListProvider);
    ref.invalidate(subjectsListProvider);
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final canManage =
        hasPermission(auth.permissions, RbacPermissions.subjectManage);
    if (!canManage) {
      return Scaffold(
        appBar: AppBar(title: const Text('Affectations par classe')),
        body: const EmptyState(
          icon: Icons.lock_outline,
          title: 'Permission insuffisante',
          message:
              'Vous n\'avez pas la permission SUBJECT_MANAGE requise pour gérer les affectations classe↔matière.',
        ),
      );
    }

    final classroomsAsync = ref.watch(classroomsListProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Affectations par classe'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Rafraîchir',
            onPressed: _refresh,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          slivers: [
            const SliverToBoxAdapter(child: _OfflineBanner()),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: classroomsAsync.when(
                  data: (classrooms) => _ClassroomSelector(
                    classrooms: classrooms,
                    selectedId: _selectedClassroomId,
                    onChanged: (id) =>
                        setState(() => _selectedClassroomId = id),
                  ),
                  loading: () => const SizedBox(
                    height: 56,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (e, _) => AppErrorWidget(
                    message: e.toString(),
                    onRetry: _refresh,
                    compact: true,
                  ),
                ),
              ),
            ),
            if (_selectedClassroomId != null)
              _ClassSubjectsBody(classroomId: _selectedClassroomId!)
            else
              const SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Icons.class_outlined,
                  title: 'Sélectionnez une classe',
                  message:
                      'Choisissez une classe dans la liste déroulante ci-dessus pour gérer ses matières.',
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 88)),
          ],
        ),
      ),
      floatingActionButton: _selectedClassroomId == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _showAssignDialog(_selectedClassroomId!),
              icon: const Icon(Icons.add),
              label: const Text('Affecter une matière'),
            ),
    );
  }

  // -------------------------------------------------------------------------
  // Dialogue d'affectation d'une matière à la classe courante.
  // -------------------------------------------------------------------------
  Future<void> _showAssignDialog(int classroomId) async {
    // On a besoin des matières (pour exclure celles déjà affectées) et des
    // utilisateurs (pour le sélecteur d'enseignant).
    final subjectsAsync = ref.read(subjectsListProvider(''));
    final usersAsync = ref.read(usersListProvider(''));
    final assignedAsync = ref.read(classSubjectsForClassroomProvider(classroomId));

    final subjects = subjectsAsync.maybeWhen(
      data: (s) => s,
      orElse: () => const <SubjectDto>[],
    );
    final users = usersAsync.maybeWhen(
      data: (u) => u,
      orElse: () => const <UserDto>[],
    );
    final assigned = assignedAsync.maybeWhen(
      data: (a) => a,
      orElse: () => const <ClassSubjectDto>[],
    );

    final assignedSubjectIds = assigned.map((a) => a.subjectId).toSet();
    final candidates = subjects
        .where((s) => !assignedSubjectIds.contains(s.id))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    if (candidates.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Toutes les matières existantes sont déjà affectées à cette classe.'),
          ),
        );
      }
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _AssignSubjectSheet(
        classroomId: classroomId,
        candidates: candidates,
        users: users,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bannière hors-ligne
// ---------------------------------------------------------------------------

class _OfflineBanner extends ConsumerWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider);
    if (conn.canReachServer) return const SizedBox.shrink();
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.cloud_off,
                size: 18,
                color: Theme.of(context).colorScheme.onSecondaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Mode hors-ligne — les affectations seront synchronisées ultérieurement.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sélecteur de classe
// ---------------------------------------------------------------------------

class _ClassroomSelector extends StatelessWidget {
  const _ClassroomSelector({
    required this.classrooms,
    required this.selectedId,
    required this.onChanged,
  });

  final List<ClassroomDto> classrooms;
  final int? selectedId;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    if (classrooms.isEmpty) {
      return const AppErrorWidget(
        message: 'Aucune classe disponible. Créez d\'abord une classe.',
        compact: true,
      );
    }
    final selected = classrooms.where((c) => c.id == selectedId).firstOrNull;
    // Auto-sélection de la première classe si rien n'est sélectionné.
    if (selected == null && selectedId == null && classrooms.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onChanged(classrooms.first.id);
      });
    }
    return DropdownButtonFormField<int>(
      value: selected?.id ?? selectedId,
      decoration: const InputDecoration(
        labelText: 'Classe',
        prefixIcon: Icon(Icons.class_outlined),
        border: OutlineInputBorder(),
      ),
      items: classrooms
          .map((c) => DropdownMenuItem(
                value: c.id,
                child: Text(
                  c.name,
                  overflow: TextOverflow.ellipsis,
                ),
              ))
          .toList(),
      onChanged: onChanged,
    );
  }
}

// ---------------------------------------------------------------------------
// Corps : liste des matières affectées à la classe sélectionnée
// ---------------------------------------------------------------------------

class _ClassSubjectsBody extends ConsumerWidget {
  const _ClassSubjectsBody({required this.classroomId});

  final int classroomId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(classSubjectsForClassroomProvider(classroomId));
    return async.when(
      data: (items) {
        if (items.isEmpty) {
          return const SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: Icons.assignment_ind_outlined,
              title: 'Aucune matière affectée',
              message:
                  'Utilisez le bouton « Affecter une matière » pour ajouter des matières à cette classe.',
            ),
          );
        }
        return SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          sliver: SliverList.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 4),
            itemBuilder: (context, i) => _ClassSubjectCard(
              item: items[i],
              classroomId: classroomId,
            ),
          ),
        );
      },
      loading: () => const SliverFillRemaining(
        hasScrollBody: false,
        child: AppLoading(label: 'Chargement des affectations…'),
      ),
      error: (e, _) => SliverFillRemaining(
        hasScrollBody: false,
        child: AppErrorWidget(
          message: e.toString(),
          onRetry: () => ref.invalidate(
            classSubjectsForClassroomProvider(classroomId),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Carte d'une affectation classe↔matière (édition coefficient + suppression)
// ---------------------------------------------------------------------------

class _ClassSubjectCard extends ConsumerStatefulWidget {
  const _ClassSubjectCard({required this.item, required this.classroomId});

  final ClassSubjectDto item;
  final int classroomId;

  @override
  ConsumerState<_ClassSubjectCard> createState() => _ClassSubjectCardState();
}

class _ClassSubjectCardState extends ConsumerState<_ClassSubjectCard> {
  late final TextEditingController _coefCtrl;
  bool _isSaving = false;
  bool _isRemoving = false;

  @override
  void initState() {
    super.initState();
    _coefCtrl = TextEditingController(
      text: widget.item.coefficient.toString(),
    );
  }

  @override
  void dispose() {
    _coefCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveCoefficient() async {
    final raw = _coefCtrl.text.trim().replaceAll(',', '.');
    final value = double.tryParse(raw);
    if (value == null || value <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Coefficient invalide (doit être > 0).')),
        );
      }
      // Restaure la valeur initiale.
      _coefCtrl.text = widget.item.coefficient.toString();
      return;
    }
    if ((value - widget.item.coefficient.toDouble()).abs() < 0.5) return; // Inchangé.
    setState(() => _isSaving = true);
    try {
      await ref.read(subjectRepositoryProvider).updateClassSubject(
            widget.item.id,
            classroomId: widget.classroomId,
            coefficient: value,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Coefficient mis à jour.')),
        );
      }
    } on SubjectRepositoryException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Échec : $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _remove() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Retirer la matière ?'),
        content: Text(
            'Voulez-vous vraiment retirer « ${widget.item.subjectName} » de cette classe ? '
            'Les évaluations et notes associées ne seront pas supprimées.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.errorContainer,
              foregroundColor: Theme.of(ctx).colorScheme.onErrorContainer,
            ),
            child: const Text('Retirer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _isRemoving = true);
    try {
      await ref.read(subjectRepositoryProvider).removeClassSubject(
            widget.item.id,
            classroomId: widget.classroomId,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('« ${widget.item.subjectName} » retirée.')),
        );
      }
    } on SubjectRepositoryException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Échec : $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isRemoving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.menu_book_outlined,
                    size: 20,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.item.subjectName,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (widget.item.teacherName != null &&
                          widget.item.teacherName!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          'Ens. : ${widget.item.teacherName}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ] else ...[
                        const SizedBox(height: 2),
                        Text(
                          'Aucun enseignant',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Retirer la matière',
                  onPressed: _isRemoving ? null : _remove,
                  icon: _isRemoving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.delete_outline, color: theme.colorScheme.error),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  'Coefficient :',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 80,
                  child: TextField(
                    controller: _coefCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _saveCoefficient(),
                  ),
                ),
                const SizedBox(width: 8),
                if (_isSaving)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  TextButton.icon(
                    onPressed: _saveCoefficient,
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('OK'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Dialogue d'affectation d'une matière (matière + coefficient + enseignant)
// ---------------------------------------------------------------------------

class _AssignSubjectSheet extends ConsumerStatefulWidget {
  const _AssignSubjectSheet({
    required this.classroomId,
    required this.candidates,
    required this.users,
  });

  final int classroomId;
  final List<SubjectDto> candidates;
  final List<UserDto> users;

  @override
  ConsumerState<_AssignSubjectSheet> createState() => _AssignSubjectSheetState();
}

class _AssignSubjectSheetState extends ConsumerState<_AssignSubjectSheet> {
  final _formKey = GlobalKey<FormState>();
  int? _subjectId;
  final _coefCtrl = TextEditingController(text: '1.0');
  int? _teacherId;
  bool _isSaving = false;

  @override
  void dispose() {
    _coefCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);
    final coefRaw = _coefCtrl.text.trim().replaceAll(',', '.');
    final coef = double.tryParse(coefRaw) ?? 1.0;
    try {
      await ref.read(subjectRepositoryProvider).assignSubjectToClass(
            classroomId: widget.classroomId,
            subjectId: _subjectId!,
            coefficient: coef,
            teacherId: _teacherId,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Matière affectée avec succès.')),
        );
        Navigator.pop(context);
      }
    } on SubjectRepositoryException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Échec : $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Auto-sélection de la première matière candidate.
    if (_subjectId == null && widget.candidates.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _subjectId = widget.candidates.first.id);
      });
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              title: 'Affecter une matière',
              icon: Icons.assignment_add,
              subtitle: widget.candidates.isEmpty
                  ? null
                  : '${widget.candidates.length} matière(s) disponible(s)',
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              value: _subjectId,
              decoration: const InputDecoration(
                labelText: 'Matière *',
                prefixIcon: Icon(Icons.menu_book_outlined),
                border: OutlineInputBorder(),
              ),
              items: widget.candidates
                  .map((s) => DropdownMenuItem(
                        value: s.id,
                        child: Text(
                          s.code != null && s.code!.isNotEmpty
                              ? '${s.name} (${s.code})'
                              : s.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _subjectId = v),
              validator: (v) => v == null ? 'Sélectionnez une matière.' : null,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _coefCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Coefficient *',
                      prefixIcon: Icon(Icons.scale_outlined),
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) {
                      final raw = v?.trim().replaceAll(',', '.') ?? '';
                      final value = double.tryParse(raw);
                      if (value == null || value <= 0) {
                        return 'Coefficient invalide (doit être > 0).';
                      }
                      return null;
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              value: _teacherId,
              decoration: const InputDecoration(
                labelText: 'Enseignant (optionnel)',
                prefixIcon: Icon(Icons.person_outline),
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem<int>(
                  value: null,
                  child: Text('— Aucun —'),
                ),
                ...widget.users.map(
                  (u) => DropdownMenuItem<int>(
                    value: u.id,
                    child: Text(
                      u.fullName.isEmpty
                          ? '@${u.username}'
                          : '${u.fullName} (@${u.username})',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
              onChanged: (v) => setState(() => _teacherId = v),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _isSaving ? null : _submit,
              icon: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check),
              label: Text(_isSaving ? 'Affectation…' : 'Affecter'),
            ),
          ],
        ),
      ),
    );
  }
}
