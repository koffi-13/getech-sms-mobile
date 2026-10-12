/// Page "Élèves" : liste filtrée (recherche + classe + sexe + statut + type
/// d'inscription) avec pull-to-refresh, support offline-first et FAB d'ajout
/// (RBAC). Les noms sont affichés au format « NOM Prénoms ».
///
/// La liste rendue consomme [studentsListProvider] avec le filtre courant —
/// la recherche et tous les chips filtrent réellement les données.
///
/// [Fix-TEACHER-STUDENTS-SCOPE] Un enseignant (non-admin) ne voit que les
/// élèves des classes dans lesquelles il intervient (périmètre
/// [TeacherScope]), combinés ou filtrés par les filtres du haut — mêmes
/// contraintes que la page Classes. Les détails d'un élève ne sont
/// accessibles que dans sa classe de titulariat (prof. principal).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_state.dart';
import '../../core/auth/teacher_scope.dart';
import '../../core/config/constants.dart';
import '../../core/utils/permissions.dart';
import '../../shared/models/classroom_dto.dart';
import '../../shared/models/student_dto.dart';
import '../../shared/widgets/widgets.dart';
import '../classrooms/classroom_controller.dart';
import '../connections/connection_state.dart';
import 'student_controller.dart';
import 'student_photos.dart';

class StudentsListPage extends ConsumerStatefulWidget {
  const StudentsListPage({super.key});

  @override
  ConsumerState<StudentsListPage> createState() => _StudentsListPageState();
}

class _StudentsListPageState extends ConsumerState<StudentsListPage> {
  StudentFilter _filter = StudentFilter.empty;

  // Recherche debouncée (léger délai pour limiter les requêtes).
  DateTime? _lastSearchAt;

  void _onSearchChanged(String value) {
    final now = DateTime.now();
    _lastSearchAt = now;
    Future.delayed(const Duration(milliseconds: 350), () {
      if (_lastSearchAt == now) {
        setState(() => _filter = _filter.copyWith(search: value.trim()));
      }
    });
  }

  Future<void> _refresh() async {
    // [Fix-PHOTO-RETRY] Les mémos négatifs des photos (élève « sans photo »
    // après un échec transitoire ou un 404 serveur) sont purgés : un
    // pull-to-refresh relance les téléchargements.
    resetStudentPhotoCache(ref);
    ref.invalidate(studentControllerProvider);
    ref.invalidate(teacherScopeProvider);
    ref.invalidate(classroomsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final canRead = hasPermission(auth.permissions, RbacPermissions.studentRead);
    final canCreate = hasPermission(auth.permissions, RbacPermissions.studentCreate);

    if (!canRead) {
      return Scaffold(
        appBar: AppBar(title: const Text('Élèves')),
        body: const EmptyState(
          icon: Icons.lock_outline,
          title: 'Permission insuffisante',
          message: 'Vous n\'avez pas la permission STUDENT_READ.',
        ),
      );
    }

    final classroomsAsync = ref.watch(classroomsProvider);
    // ⚠️ La liste est FILTRÉE via studentsListProvider (le bug historique
    // était de consommer la liste brute — recherche et filtres no-ops).
    final studentsAsync = ref.watch(studentsListProvider(_filter));
    // [Fix-TEACHER-STUDENTS-SCOPE] Périmètre enseignant : filtrage des
    // élèves ET du sélecteur de classe aux classes où il intervient.
    final scopeAsync = ref.watch(teacherScopeProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Élèves'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Rafraîchir',
            onPressed: _refresh,
          ),
          // [Fix-ELEVES-EXPORT] Bouton « Export / Import » retiré sur demande
          // utilisateur (retour V9) : l'import/export en masse reste
          // disponible côté serveur desktop.
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          slivers: _buildSlivers(studentsAsync, classroomsAsync, scopeAsync),
        ),
      ),
      floatingActionButton: canCreate
          ? FloatingActionButton.extended(
              onPressed: () => context.push('/students/new'),
              icon: const Icon(Icons.add),
              label: const Text('Nouvel élève'),
            )
          : null,
    );
  }

  List<Widget> _buildSlivers(
    AsyncValue<List<StudentDto>> studentsAsync,
    AsyncValue<List<ClassroomDto>> classroomsAsync,
    AsyncValue<TeacherScope> scopeAsync,
  ) {
    // [Fix-TEACHER-STUDENTS-SCOPE] Un enseignant attend le verdict du scope
    // avant d'afficher (sinon les élèves de TOUTES les classes seraient
    // visibles une fraction de seconde avant filtrage).
    final scope = scopeAsync.valueOrNull;
    final auth = ref.read(authProvider);
    final restricted =
        scope != null && scope.isTeacher && !scope.isAdminOrHeadmaster;
    final scopeReady = auth.isAdminOrHeadmaster || scopeAsync.hasValue;

    final slivers = <Widget>[
      const SliverToBoxAdapter(child: _OfflineBanner()),
      // Barre de recherche.
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: AppSearchBar(
            hint: 'Nom, prénoms ou matricule…',
            onChanged: _onSearchChanged,
          ),
        ),
      ),
      // Filtres horizontaux.
      SliverToBoxAdapter(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              _FilterChip(
                label: _classroomLabel(classroomsAsync, scope),
                icon: Icons.school_outlined,
                selected: _filter.classroomId != null,
                onTap: () =>
                    _openClassroomPicker(context, classroomsAsync, scope),
              ),
              const SizedBox(width: 8),
              _FilterChip(
                label: _filter.sexe?.label ?? 'Sexe',
                icon: Icons.people_outline,
                selected: _filter.sexe != null,
                onTap: () => _openSexePicker(context),
              ),
              const SizedBox(width: 8),
              _FilterChip(
                label: _filter.status?.label ?? 'Statut',
                icon: Icons.new_releases_outlined,
                selected: _filter.status != null,
                onTap: () => _openStatusPicker(context),
              ),
              const SizedBox(width: 8),
              _FilterChip(
                label: _filter.inscriptionType?.label ?? 'Inscription',
                icon: Icons.how_to_reg_outlined,
                selected: _filter.inscriptionType != null,
                onTap: () => _openInscriptionPicker(context),
              ),
              if (_filter != StudentFilter.empty && _filter.search.isEmpty) ...[
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: () => setState(() => _filter = StudentFilter.empty),
                  icon: const Icon(Icons.clear, size: 16),
                  label: const Text('Reset'),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 8)),
    ];

    if (!scopeReady || studentsAsync.isLoading) {
      slivers.add(const SliverFillRemaining(
        hasScrollBody: false,
        child: AppLoading(label: 'Chargement des élèves…'),
      ));
      return slivers;
    }

    if (studentsAsync.hasError) {
      slivers.add(SliverFillRemaining(
        hasScrollBody: false,
        child: AppErrorWidget(
          message: studentsAsync.error.toString(),
          onRetry: _refresh,
        ),
      ));
      return slivers;
    }

    final allStudents = studentsAsync.value ?? [];
    // [Fix-FILTER] Appliquer le filtre côté client (recherche + classe + sexe + statut).
    //
    // [Fix-TEACHER-STUDENTS-SCOPE] Enseignant : seuls les élèves de SES
    // classes (enseignement ∪ titulariat) sont visibles, combinés ou
    // filtrés par le filtre de classe (restreint à ses classes).
    final myClassroomIds = restricted ? scope!.myClassroomIds : null;
    final students = allStudents.where((s) {
      if (myClassroomIds != null) {
        final cid = s.classroomId;
        if (cid == null || !myClassroomIds.contains(cid)) return false;
      }
      if (_filter.search.isNotEmpty) {
        final q = _filter.search.toLowerCase();
        final fullName = s.fullName.toLowerCase();
        final matricule = (s.matricule ?? '').toLowerCase();
        if (!fullName.contains(q) && !matricule.contains(q)) {
          return false;
        }
      }
      if (_filter.classroomId != null && s.classroomId != _filter.classroomId) {
        return false;
      }
      if (_filter.sexe != null && s.sexe != _filter.sexe) {
        return false;
      }
      if (_filter.status != null && s.status != _filter.status) {
        return false;
      }
      return true;
    }).toList();
    if (students.isEmpty) {
      slivers.add(SliverFillRemaining(
        hasScrollBody: false,
        child: EmptyState(
          icon: Icons.person_search,
          title: 'Aucun élève trouvé',
          message: _filter == StudentFilter.empty
              ? (restricted
                  ? 'Aucun élève dans vos classes. Synchronisez ou contactez '
                      'l\'administration.'
                  : 'Aucun élève synchronisé. Tirez pour rafraîchir.')
              : 'Essayez d\'ajuster vos filtres ou votre recherche.',
        ),
      ));
      return slivers;
    }

    slivers.add(SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      sliver: SliverList.separated(
        itemCount: students.length,
        separatorBuilder: (_, __) => const SizedBox(height: 4),
        itemBuilder: (context, i) => _StudentTile(
          student: students[i],
          canOpenDetails: !restricted ||
              scope!.headClassrooms
                  .any((c) => c.id == students[i].classroomId),
        ),
      ),
    ));

    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 80)));
    return slivers;
  }

  String _classroomLabel(AsyncValue<List<ClassroomDto>> async,
      TeacherScope? scope) {
    if (_filter.classroomId == null) {
      final restricted =
          scope != null && scope.isTeacher && !scope.isAdminOrHeadmaster;
      return restricted ? 'Mes classes' : 'Classe';
    }
    return async.maybeWhen(
      data: (list) =>
          list.where((c) => c.id == _filter.classroomId).firstOrNullName,
      orElse: () => 'Classe #${_filter.classroomId}',
    );
  }

  void _openClassroomPicker(BuildContext context,
      AsyncValue<List<ClassroomDto>> async, TeacherScope? scope) {
    // [Fix-TEACHER-CLASSES-SCOPE-V9] Un enseignant ne filtre que parmi SES
    // classes — l'ancien code partait de TOUTES les classes puis y AJOUTAIT
    // celles du périmètre (union) : le filtre « Mes classes » listait donc
    // toutes les classes de l'établissement. On fait maintenant une
    // INTERSECTION : cartes riches de /classrooms limitées au périmètre,
    // complétées par les cartes du scope (classes absentes du serveur).
    final restricted =
        scope != null && scope.isTeacher && !scope.isAdminOrHeadmaster;
    var list = async.value ?? [];
    if (restricted) {
      final myIds = scope!.myClassroomIds;
      final byId = <int, ClassroomDto>{
        for (final c in list)
          if (myIds.contains(c.id)) c.id: c,
      };
      for (final c in scope.myClassrooms) {
        byId.putIfAbsent(c.id, () => c);
      }
      list = byId.values.toList()..sort((a, b) => a.name.compareTo(b.name));
    }
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(
                  restricted ? 'Toutes mes classes' : 'Toutes les classes'),
              onTap: () {
                setState(() => _filter = _filter.copyWith(clearClassroom: true));
                Navigator.pop(ctx);
              },
            ),
            ...list.map((c) => ListTile(
                  title: Text(c.name),
                  subtitle: c.levelLabel.isEmpty ? null : Text(c.levelLabel),
                  trailing: _filter.classroomId == c.id ? const Icon(Icons.check) : null,
                  onTap: () {
                    setState(() => _filter = _filter.copyWith(classroomId: c.id));
                    Navigator.pop(ctx);
                  },
                )),
          ],
        ),
      ),
    );
  }

  void _openSexePicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Tous les sexes'),
              onTap: () {
                setState(() => _filter = _filter.copyWith(clearSexe: true));
                Navigator.pop(ctx);
              },
            ),
            ...Sexe.values.map((v) => ListTile(
                  title: Text(v.label),
                  onTap: () {
                    setState(() => _filter = _filter.copyWith(sexe: v));
                    Navigator.pop(ctx);
                  },
                )),
          ],
        ),
      ),
    );
  }

  void _openStatusPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Tous les statuts'),
              onTap: () {
                setState(() => _filter = _filter.copyWith(clearStatus: true));
                Navigator.pop(ctx);
              },
            ),
            ...StudentStatus.values.map((v) => ListTile(
                  title: Text(v.label),
                  onTap: () {
                    setState(() => _filter = _filter.copyWith(status: v));
                    Navigator.pop(ctx);
                  },
                )),
          ],
        ),
      ),
    );
  }

  void _openInscriptionPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Tous les types d\'inscription'),
              onTap: () {
                setState(() =>
                    _filter = _filter.copyWith(clearInscriptionType: true));
                Navigator.pop(ctx);
              },
            ),
            ...InscriptionType.values.map((v) => ListTile(
                  title: Text(v.label),
                  onTap: () {
                    setState(() =>
                        _filter = _filter.copyWith(inscriptionType: v));
                    Navigator.pop(ctx);
                  },
                )),
          ],
        ),
      ),
    );
  }
}

extension on Iterable<ClassroomDto> {
  String get firstOrNullName => isEmpty ? '' : first.name;
}

// ---------------------------------------------------------------------------
// Composants internes
// ---------------------------------------------------------------------------

class _OfflineBanner extends ConsumerWidget {
  const _OfflineBanner();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider);
    if (conn.canReachServer) return const SizedBox.shrink();
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.cloud_off, size: 16),
            SizedBox(width: 8),
            Text('Mode hors-ligne — accès SQLite uniquement',
                style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FilterChip(
      avatar: Icon(icon, size: 16),
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
      selectedColor: theme.colorScheme.primaryContainer,
      labelStyle: TextStyle(
        color: selected ? theme.colorScheme.onPrimaryContainer : null,
      ),
    );
  }
}

class _StudentTile extends StatelessWidget {
  const _StudentTile({required this.student, this.canOpenDetails = true});
  final StudentDto student;

  /// [Fix-TEACHER-STUDENTS-SCOPE] Faux pour un enseignant simple : la fiche
  /// détaillée est réservée au professeur principal de la classe.
  final bool canOpenDetails;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        // Photo de l'élève via l'endpoint dédié (cache disque), initiales
        // en fallback — `photo_path` n'est pas une URL utilisable.
        leading: StudentAvatar(
          studentId: student.id,
          initials: student.displayInitials,
        ),
        title: Text(
          student.fullName,
          // NOM en majuscules + prénoms — convention scolaire.
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          [
            if (student.matricule.isNotEmpty) student.matricule,
            if (student.classroomName != null) student.classroomName!,
            if (student.status != null) student.status!.label,
          ].join(' • '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: canOpenDetails
            ? const Icon(Icons.chevron_right)
            : const Icon(Icons.lock_outline, size: 18),
        onTap: () {
          if (!canOpenDetails) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                    'Les détails des élèves sont réservés au professeur '
                    'principal de la classe.'),
                duration: Duration(seconds: 3),
              ),
            );
            return;
          }
          context.push('/students/${student.id}');
        },
      ),
    );
  }
}
