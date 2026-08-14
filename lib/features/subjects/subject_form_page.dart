/// Page "Formulaire matière" : création (id null) ou édition (id non null).
///
/// Champs : name (requis), code (optionnel). Sauvegarde via
/// [subjectRepositoryProvider] (POST ou PATCH en ligne, outbox hors-ligne).
library;

import 'package:collection/collection.dart'; // firstOrNull (extension Iterable)
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_state.dart';
import '../../core/config/constants.dart';
import '../../core/utils/permissions.dart';
import '../../shared/models/classroom_dto.dart';
import '../../shared/widgets/widgets.dart';
import 'subject_controller.dart';

class SubjectFormPage extends ConsumerStatefulWidget {
  const SubjectFormPage({super.key, this.id});

  final int? id;

  @override
  ConsumerState<SubjectFormPage> createState() => _SubjectFormPageState();
}

class _SubjectFormPageState extends ConsumerState<SubjectFormPage> {
  final _formKey = GlobalKey<FormState>();
  bool _isSaving = false;
  bool _isPopulated = false;

  late final TextEditingController _name;
  late final TextEditingController _code;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController();
    _code = TextEditingController();
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  void _populateFromDto(SubjectDto dto) {
    if (_isPopulated) return;
    _isPopulated = true;
    _name.text = dto.name;
    _code.text = dto.code ?? '';
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);
    final name = _name.text.trim();
    final code = _code.text.trim().isEmpty ? null : _code.text.trim();
    try {
      final repo = ref.read(subjectRepositoryProvider);
      final isEdit = widget.id != null && widget.id! > 0;
      if (isEdit) {
        await repo.updateSubject(widget.id!, name: name, code: code);
      } else {
        await repo.createSubject(name: name, code: code);
      }
      ref.invalidate(subjectsListProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isEdit
                ? 'Matière mise à jour avec succès.'
                : 'Matière créée avec succès.'),
          ),
        );
        context.pop();
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
          SnackBar(content: Text('Échec de l\'enregistrement : $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final canManage =
        hasPermission(auth.permissions, RbacPermissions.subjectManage);
    if (!canManage) {
      return Scaffold(
        appBar: AppBar(title: const Text('Matière')),
        body: const EmptyState(
          icon: Icons.lock_outline,
          title: 'Permission insuffisante',
          message:
              'Vous n\'avez pas la permission SUBJECT_MANAGE requise pour créer ou modifier une matière.',
        ),
      );
    }

    final isEdit = widget.id != null;
    if (isEdit) {
      // En mode édition, on recherche la matière dans la liste (la liste est
      // déjà chargée par SubjectsListPage) ; sinon on sollicite la liste
      // sans filtre puis on extrait l'élément.
      final async = ref.watch(subjectsListProvider(''));
      return async.when(
        data: (subjects) {
          final dto = subjects.where((s) => s.id == widget.id).firstOrNull;
          if (dto == null) {
            return Scaffold(
              appBar: AppBar(title: const Text('Modifier la matière')),
              body: AppErrorWidget(
                message: 'Matière introuvable.',
                onRetry: () => ref.invalidate(subjectsListProvider),
              ),
            );
          }
          _populateFromDto(dto);
          return _buildScaffold(isEdit: true);
        },
        loading: () => Scaffold(
          appBar: AppBar(title: const Text('Modifier la matière')),
          body: const AppLoading(label: 'Chargement…'),
        ),
        error: (e, _) => Scaffold(
          appBar: AppBar(title: const Text('Modifier la matière')),
          body: AppErrorWidget(
            message: e.toString(),
            onRetry: () => ref.invalidate(subjectsListProvider),
          ),
        ),
      );
    }
    return _buildScaffold(isEdit: false);
  }

  Widget _buildScaffold({required bool isEdit}) {
    return Scaffold(
      appBar: AppBar(
        title: Text(isEdit ? 'Modifier la matière' : 'Nouvelle matière'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionHeader(
                      title: 'Identification',
                      icon: Icons.menu_book_outlined,
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _name,
                      decoration: const InputDecoration(
                        labelText: 'Nom de la matière *',
                        hintText: 'Ex : Mathématiques',
                        prefixIcon: Icon(Icons.label_outline),
                        border: OutlineInputBorder(),
                      ),
                      textCapitalization: TextCapitalization.sentences,
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? 'Nom de la matière requis.'
                          : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _code,
                      decoration: const InputDecoration(
                        labelText: 'Code',
                        hintText: 'Ex : MATH',
                        prefixIcon: Icon(Icons.tag),
                        border: OutlineInputBorder(),
                      ),
                      textCapitalization: TextCapitalization.characters,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Le code est optionnel mais recommandé pour identifier rapidement la matière (recherche, bulletins).',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _isSaving ? null : _save,
              icon: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(_isSaving ? 'Enregistrement…' : 'Enregistrer'),
            ),
          ],
        ),
      ),
    );
  }
}
