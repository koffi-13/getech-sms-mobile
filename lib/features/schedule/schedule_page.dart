/// Page « Emploi du temps » — RBAC complet (miroir du desktop).
///
/// - **Admin / headmaster / superuser** : vue « Par classe » (dropdown) et
///   « Par enseignant » (dropdown), édition complète (ajout / modification /
///   suppression de cours) si le patch serveur est appliqué.
/// - **Enseignant** : onglets « Mes cours » (grille de tous ses cours,
///   `GET /schedule/my`) et « Mes classes » (EDT complet des classes où il
///   enseigne ou dont il est titulaire) — strictement lecture seule.
/// - **Autres profils** : vue par classe en lecture seule.
///
/// Semaines alternées : filtre « Toutes / A / B » (l'alternance vient de
/// `school_years.alternating_week_start_date` via [currentWeekTypeProvider]).
library;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_state.dart';
import '../../core/auth/teacher_scope.dart';
import '../../core/config/constants.dart';
import '../../features/connections/connection_state.dart';
import '../../shared/models/attendance_dto.dart';
import '../../shared/models/classroom_dto.dart';
import '../../shared/widgets/widgets.dart';
import '../users/user_controller.dart';
import 'schedule_controller.dart';
import 'schedule_editor.dart';
import 'schedule_grid.dart';

class SchedulePage extends ConsumerStatefulWidget {
  const SchedulePage({super.key});

  @override
  ConsumerState<SchedulePage> createState() => _SchedulePageState();
}

/// Filtre de semaine pour la grille.
enum _WeekFilter { all, a, b }

enum _AdminViewMode { classroom, teacher }

class _SchedulePageState extends ConsumerState<SchedulePage> {
  _WeekFilter _weekFilter = _WeekFilter.all;
  WeekType? _currentWeek;

  // Sélections admin.
  _AdminViewMode _adminMode = _AdminViewMode.classroom;
  int? _classroomId;
  int? _teacherId;

  // Sélection enseignant (onglet « Mes classes »).
  int? _teacherClassroomId;

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(connectionProvider);
    final auth = ref.watch(authProvider);
    final scopeAsync = ref.watch(teacherScopeProvider);
    final currentWeekAsync = ref.watch(currentWeekTypeProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Emploi du temps'), actions: [
        if (!conn.canReachServer)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: StatusBadge.offline(),
          ),
      ]),
      body: Column(
        children: [
          if (!conn.canReachServer) const ScheduleOfflineBanner(),
          Expanded(
            child: !conn.canReachServer
                ? const EmptyState(
                    title: 'Hors-ligne',
                    message:
                        'Connectez-vous au serveur pour charger l\'emploi du temps.',
                    icon: Icons.cloud_off,
                  )
                : scopeAsync.when(
                    data: (scope) {
                      // Semaine alternée courante (auto-détection).
                      _currentWeek = currentWeekAsync.value;
                      if (auth.isAdminOrHeadmaster) {
                        return _AdminScheduleView(
                          mode: _adminMode,
                          onModeChanged: (m) =>
                              setState(() => _adminMode = m),
                          classroomId: _classroomId,
                          onClassroomChanged: (id) =>
                              setState(() => _classroomId = id),
                          teacherId: _teacherId,
                          onTeacherChanged: (id) =>
                              setState(() => _teacherId = id),
                          weekFilter: _weekFilter,
                          currentWeek: _currentWeek,
                          onWeekFilterChanged: (f) =>
                              setState(() => _weekFilter = f),
                        );
                      }
                      if (scope.isTeacher) {
                        return _TeacherScheduleView(
                          scope: scope,
                          selectedClassroomId: _teacherClassroomId,
                          onClassroomChanged: (id) =>
                              setState(() => _teacherClassroomId = id),
                          weekFilter: _weekFilter,
                          currentWeek: _currentWeek,
                          onWeekFilterChanged: (f) =>
                              setState(() => _weekFilter = f),
                        );
                      }
                      // Autres profils : vue classe lecture seule.
                      return _ReadOnlyClassroomView(
                        weekFilter: _weekFilter,
                        currentWeek: _currentWeek,
                        onWeekFilterChanged: (f) =>
                            setState(() => _weekFilter = f),
                      );
                    },
                    loading: () =>
                        const AppLoading(label: 'Chargement…'),
                    error: (e, _) => AppErrorWidget(
                      message: e.toString(),
                      onRetry: () => ref.invalidate(teacherScopeProvider),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Segmented control du filtre de semaine
// ---------------------------------------------------------------------------

class _WeekFilterToggle extends StatelessWidget {
  const _WeekFilterToggle({
    required this.value,
    required this.onChanged,
    required this.hasAlternatingWeeks,
  });

  final _WeekFilter value;
  final ValueChanged<_WeekFilter> onChanged;
  final bool hasAlternatingWeeks;

  @override
  Widget build(BuildContext context) {
    // Pas de semaines alternées → masque le filtre (tout = toutes les semaines).
    if (!hasAlternatingWeeks) return const SizedBox.shrink();
    return SegmentedButton<_WeekFilter>(
      segments: const [
        ButtonSegment(value: _WeekFilter.all, label: Text('Toutes')),
        ButtonSegment(value: _WeekFilter.a, label: Text('A')),
        ButtonSegment(value: _WeekFilter.b, label: Text('B')),
      ],
      selected: {value},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}

/// Filtre une liste d'entrées selon le filtre de semaine.
List<WeeklyScheduleDto> _applyWeekFilter(
    List<WeeklyScheduleDto> list, _WeekFilter filter) {
  switch (filter) {
    case _WeekFilter.all:
      return list;
    case _WeekFilter.a:
      return list.where((s) => s.matchesWeek(WeekType.a)).toList();
    case _WeekFilter.b:
      return list.where((s) => s.matchesWeek(WeekType.b)).toList();
  }
}

// ---------------------------------------------------------------------------
// Vue ADMIN : mode Classe / Enseignant + édition
// ---------------------------------------------------------------------------

class _AdminScheduleView extends ConsumerWidget {
  const _AdminScheduleView({
    required this.mode,
    required this.onModeChanged,
    required this.classroomId,
    required this.onClassroomChanged,
    required this.teacherId,
    required this.onTeacherChanged,
    required this.weekFilter,
    required this.currentWeek,
    required this.onWeekFilterChanged,
  });

  final _AdminViewMode mode;
  final ValueChanged<_AdminViewMode> onModeChanged;
  final int? classroomId;
  final ValueChanged<int?> onClassroomChanged;
  final int? teacherId;
  final ValueChanged<int?> onTeacherChanged;
  final _WeekFilter weekFilter;
  final WeekType? currentWeek;
  final ValueChanged<_WeekFilter> onWeekFilterChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final classrooms = ref.watch(classroomsForScheduleProvider);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Column(
            children: [
              SegmentedButton<_AdminViewMode>(
                segments: const [
                  ButtonSegment(
                      value: _AdminViewMode.classroom,
                      icon: Icon(Icons.school_outlined),
                      label: Text('Par classe')),
                  ButtonSegment(
                      value: _AdminViewMode.teacher,
                      icon: Icon(Icons.person_outline),
                      label: Text('Par enseignant')),
                ],
                selected: {mode},
                onSelectionChanged: (s) => onModeChanged(s.first),
              ),
              const SizedBox(height: 12),
              if (mode == _AdminViewMode.classroom)
                _ClassroomDropdown(
                  classroomsAsync: classrooms,
                  selectedId: classroomId,
                  onChanged: onClassroomChanged,
                )
              else
                _TeacherDropdown(
                  selectedId: teacherId,
                  onChanged: onTeacherChanged,
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _WeekFilterToggle(
                      value: weekFilter,
                      onChanged: onWeekFilterChanged,
                      hasAlternatingWeeks: true,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: mode == _AdminViewMode.classroom
              ? _AdminClassroomGrid(
                  classroomId: classroomId,
                  weekFilter: weekFilter,
                )
              : _AdminTeacherGrid(
                  teacherId: teacherId,
                  weekFilter: weekFilter,
                ),
        ),
      ],
    );
  }
}

class _ClassroomDropdown extends StatelessWidget {
  const _ClassroomDropdown({
    required this.classroomsAsync,
    required this.selectedId,
    required this.onChanged,
  });

  final AsyncValue<List<ClassroomDto>> classroomsAsync;
  final int? selectedId;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return classroomsAsync.when(
      data: (list) {
        if (list.isEmpty) {
          return const Text('Aucune classe disponible.');
        }
        var effective = selectedId;
        if (effective == null || !list.any((c) => c.id == effective)) {
          effective = list.first.id;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (effective != null) onChanged(effective);
          });
        }
        return DropdownButtonFormField<int>(
          value: effective,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Classe',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: list
              .map((c) => DropdownMenuItem(
                    value: c.id,
                    child: Text(c.name, overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
          onChanged: (v) => onChanged(v),
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: LinearProgressIndicator(),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('Erreur : $e',
            style:
                TextStyle(color: Theme.of(context).colorScheme.error)),
      ),
    );
  }
}

class _TeacherDropdown extends ConsumerWidget {
  const _TeacherDropdown({
    required this.selectedId,
    required this.onChanged,
  });

  final int? selectedId;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Liste des enseignants : GET /users (permission USER_READ).
    final usersAsync = ref.watch(usersListProvider(''));
    return usersAsync.when(
      data: (users) {
        final teachers = users
            .where((u) =>
                u.isActive &&
                ((u.role ?? '').toLowerCase().contains('teacher') ||
                    (u.role ?? '').toLowerCase().contains('enseignant')))
            .toList()
          ..sort((a, b) => a.fullName.compareTo(b.fullName));
        if (teachers.isEmpty) {
          return const Text(
              'Aucun enseignant trouvé (permission USER_READ requise).');
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
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Enseignant',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: teachers
              .map((t) => DropdownMenuItem(
                    value: t.id,
                    child: Text(
                      t.fullName.isEmpty ? t.username : t.fullName,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ))
              .toList(),
          onChanged: (v) => onChanged(v),
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: LinearProgressIndicator(),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('Erreur : $e',
            style:
                TextStyle(color: Theme.of(context).colorScheme.error)),
      ),
    );
  }
}

/// Grille EDT d'une classe (mode admin, éditable).
class _AdminClassroomGrid extends ConsumerWidget {
  const _AdminClassroomGrid({
    required this.classroomId,
    required this.weekFilter,
  });

  final int? classroomId;
  final _WeekFilter weekFilter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(canEditScheduleProvider);
    if (classroomId == null) {
      return const EmptyState(
        title: 'Sélectionnez une classe',
        message: 'Choisissez une classe pour afficher son emploi du temps.',
        icon: Icons.school_outlined,
      );
    }
    final async = ref.watch(classroomScheduleProvider(classroomId!));
    return async.when(
      data: (list) {
        final filtered = _applyWeekFilter(list, weekFilter);
        return ScheduleGridScreen(
          entries: filtered,
          mode: ScheduleDisplayMode.classroom,
          classroomId: classroomId,
          canEdit: canEdit,
          showAddButton: canEdit,
        );
      },
      loading: () =>
          const AppLoading(label: 'Chargement de l\'emploi du temps…'),
      error: (e, _) => AppErrorWidget(
        message: e.toString(),
        onRetry: () => ref.invalidate(classroomScheduleProvider(classroomId!)),
      ),
    );
  }
}

/// Grille EDT d'un enseignant (mode admin, éditable).
class _AdminTeacherGrid extends ConsumerWidget {
  const _AdminTeacherGrid({
    required this.teacherId,
    required this.weekFilter,
  });

  final int? teacherId;
  final _WeekFilter weekFilter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (teacherId == null) {
      return const EmptyState(
        title: 'Sélectionnez un enseignant',
        message:
            'Choisissez un enseignant pour afficher son emploi du temps.',
        icon: Icons.person_outline,
      );
    }
    final async = ref.watch(teacherScheduleByIdProvider(teacherId!));
    return async.when(
      data: (list) {
        final filtered = _applyWeekFilter(list, weekFilter);
        return ScheduleGridScreen(
          entries: filtered,
          mode: ScheduleDisplayMode.teacher,
          canEdit: false, // L'édition se fait par classe (besoin des matières).
          showAddButton: false,
          emptyMessage: 'Aucun cours planifié pour cet enseignant.',
        );
      },
      loading: () =>
          const AppLoading(label: 'Chargement de l\'emploi du temps…'),
      error: (e, _) => AppErrorWidget(
        message: e.toString(),
        onRetry: () =>
            ref.invalidate(teacherScheduleByIdProvider(teacherId!)),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Vue ENSEIGNANT : Mes cours + Mes classes
// ---------------------------------------------------------------------------

class _TeacherScheduleView extends ConsumerWidget {
  const _TeacherScheduleView({
    required this.scope,
    required this.selectedClassroomId,
    required this.onClassroomChanged,
    required this.weekFilter,
    required this.currentWeek,
    required this.onWeekFilterChanged,
  });

  final TeacherScope scope;
  final int? selectedClassroomId;
  final ValueChanged<int?> onClassroomChanged;
  final _WeekFilter weekFilter;
  final WeekType? currentWeek;
  final ValueChanged<_WeekFilter> onWeekFilterChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasAlternating = currentWeek != null ||
        scope.mySchedule.any((s) => !s.isAllWeeks);

    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: 'Mes cours'),
              Tab(text: 'Mes classes'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                // --- Onglet « Mes cours » : tous ses cours, toutes classes ---
                ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _WeekFilterToggle(
                            value: weekFilter,
                            onChanged: onWeekFilterChanged,
                            hasAlternatingWeeks: hasAlternating,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _MyCoursesSection(
                      scope: scope,
                      weekFilter: weekFilter,
                      currentWeek: currentWeek,
                    ),
                  ],
                ),
                // --- Onglet « Mes classes » : EDT complet par classe ---
                _TeacherClassroomsTab(
                  scope: scope,
                  selectedClassroomId: selectedClassroomId,
                  onClassroomChanged: onClassroomChanged,
                  weekFilter: weekFilter,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MyCoursesSection extends StatelessWidget {
  const _MyCoursesSection({
    required this.scope,
    required this.weekFilter,
    required this.currentWeek,
  });

  final TeacherScope scope;
  final _WeekFilter weekFilter;
  final WeekType? currentWeek;

  @override
  Widget build(BuildContext context) {
    if (scope.mySchedule.isEmpty) {
      return const EmptyState(
        title: 'Aucun cours planifié',
        message:
            'Vous n\'avez aucun cours dans l\'emploi du temps. Contactez '
            'l\'administration de l\'établissement.',
        icon: Icons.event_busy,
      );
    }
    final filtered = _applyWeekFilter(scope.mySchedule, weekFilter);
    if (filtered.isEmpty) {
      return EmptyState(
        title: 'Aucun cours cette semaine',
        message:
            'Aucun cours pour la semaine ${weekFilter == _WeekFilter.a ? 'A' : 'B'}.',
        icon: Icons.event_busy,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ScheduleGridView(
          schedule: filtered,
          mode: ScheduleDisplayMode.teacher,
          onEntryTap: (e) => showScheduleEntryDetails(
            context,
            e,
            mode: ScheduleDisplayMode.teacher,
          ),
        ),
      ],
    );
  }
}

class _TeacherClassroomsTab extends StatelessWidget {
  const _TeacherClassroomsTab({
    required this.scope,
    required this.selectedClassroomId,
    required this.onClassroomChanged,
    required this.weekFilter,
  });

  final TeacherScope scope;
  final int? selectedClassroomId;
  final ValueChanged<int?> onClassroomChanged;
  final _WeekFilter weekFilter;

  @override
  Widget build(BuildContext context) {
    final classrooms = scope.myClassrooms;
    if (classrooms.isEmpty) {
      return const EmptyState(
        title: 'Aucune classe liée',
        message:
            'Vous n\'êtes ni titulaire ni enseignant dans une classe.',
        icon: Icons.school_outlined,
      );
    }
    var effective = selectedClassroomId;
    if (effective == null || !classrooms.any((c) => c.id == effective)) {
      effective = classrooms.first.id;
    }
    final selected =
        classrooms.firstWhereOrNull((c) => c.id == effective) ??
            classrooms.first;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Column(
            children: [
              DropdownButtonFormField<int>(
                value: effective,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'Classe',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: scope.headClassrooms.any((c) => c.id == effective)
                      ? const Tooltip(
                          message: 'Vous êtes titulaire de cette classe',
                          child: Icon(Icons.star, size: 18),
                        )
                      : null,
                ),
                items: classrooms
                    .map((c) => DropdownMenuItem(
                          value: c.id,
                          child: Text(
                            c.name +
                                (scope.headClassrooms.any((h) => h.id == c.id)
                                    ? '  (titulaire)'
                                    : ''),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ))
                    .toList(),
                onChanged: (v) => onClassroomChanged(v),
              ),
              const SizedBox(height: 8),
              _ClassroomEdtReader(
                classroomId: selected.id,
                weekFilter: weekFilter,
                compact: true,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Vue par classe lecture seule (autres profils)
// ---------------------------------------------------------------------------

class _ReadOnlyClassroomView extends StatelessWidget {
  const _ReadOnlyClassroomView({
    required this.weekFilter,
    required this.currentWeek,
    required this.onWeekFilterChanged,
  });

  final _WeekFilter weekFilter;
  final WeekType? currentWeek;
  final ValueChanged<_WeekFilter> onWeekFilterChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: _ClassroomPickeredReader(
            weekFilter: weekFilter,
            onWeekFilterChanged: onWeekFilterChanged,
          ),
        ),
      ],
    );
  }
}

class _ClassroomPickeredReader extends ConsumerStatefulWidget {
  const _ClassroomPickeredReader({
    required this.weekFilter,
    required this.onWeekFilterChanged,
  });

  final _WeekFilter weekFilter;
  final ValueChanged<_WeekFilter> onWeekFilterChanged;

  @override
  ConsumerState<_ClassroomPickeredReader> createState() =>
      _ClassroomPickeredReaderState();
}

class _ClassroomPickeredReaderState
    extends ConsumerState<_ClassroomPickeredReader> {
  int? _classroomId;

  @override
  Widget build(BuildContext context) {
    final classrooms = ref.watch(classroomsForScheduleProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: _ClassroomDropdown(
            classroomsAsync: classrooms,
            selectedId: _classroomId,
            onChanged: (id) => setState(() => _classroomId = id),
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: _ClassroomEdtReader(
            classroomId: _classroomId,
            weekFilter: widget.weekFilter,
          ),
        ),
      ],
    );
  }
}

/// Lecteur d'EDT d'une classe (lecture seule — enseignants et autres profils).
class _ClassroomEdtReader extends ConsumerWidget {
  const _ClassroomEdtReader({
    required this.classroomId,
    required this.weekFilter,
    this.compact = false,
  });

  final int? classroomId;
  final _WeekFilter weekFilter;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (classroomId == null) {
      return const EmptyState(
        title: 'Sélectionnez une classe',
        message: 'Choisissez une classe pour afficher son emploi du temps.',
        icon: Icons.school_outlined,
      );
    }
    final async = ref.watch(classroomScheduleProvider(classroomId!));
    return async.when(
      data: (list) {
        final filtered = _applyWeekFilter(list, weekFilter);
        if (filtered.isEmpty) {
          return const EmptyState(
            title: 'Aucun cours programmé',
            message: 'L\'emploi du temps de cette classe est vide.',
            icon: Icons.event_busy,
          );
        }
        return ScheduleGridView(
          schedule: filtered,
          mode: ScheduleDisplayMode.classroom,
          compact: compact,
          onEntryTap: (e) =>
              showScheduleEntryDetails(context, e),
        );
      },
      loading: () =>
          const AppLoading(label: 'Chargement de l\'emploi du temps…'),
      error: (e, _) => AppErrorWidget(
        message: e.toString(),
        onRetry: () => ref.invalidate(classroomScheduleProvider(classroomId!)),
      ),
    );
  }
}
