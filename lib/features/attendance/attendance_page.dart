/// Page « Présence » : sélection classe + date + cours (issu de l'emploi du
/// temps du jour), démarrage d'une session de cours, saisie des absences
/// (case Absent + motif + justifié) et cahier de texte (contenu + devoirs).
///
/// Le cours est dérivé de l'emploi du temps hebdomadaire de la classe pour
/// le jour sélectionné (filtrage par `dayOfWeek`).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/constants.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/utils/formatters.dart';
import '../../features/connections/connection_state.dart';
import '../../features/schedule/schedule_controller.dart';
import '../../shared/models/attendance_dto.dart';
import '../../shared/models/classroom_dto.dart';
import '../../shared/models/student_dto.dart';
import '../../shared/widgets/widgets.dart';
import 'attendance_controller.dart';

class AttendancePage extends ConsumerStatefulWidget {
  const AttendancePage({super.key});

  @override
  ConsumerState<AttendancePage> createState() => _AttendancePageState();
}

class _AttendancePageState extends ConsumerState<AttendancePage> {
  int? _classroomId;
  WeekType _weekType = WeekType.a;
  DateTime _date = DateTime.now();

  WeeklyScheduleDto? _selectedCourse;
  CourseSessionDto? _activeSession;

  /// Brouillons d'absences indexés par `studentId`. Seuls les élèves absents
  /// sont présents dans cette map (présent = absent de la map).
  final Map<int, StudentAbsenceDto> _absencesDrafts = {};

  final TextEditingController _lessonContentCtrl = TextEditingController();
  final TextEditingController _lessonHomeworkCtrl = TextEditingController();
  int? _lessonRecordId;
  bool _lessonLoaded = false;

  bool _saving = false;

  @override
  void dispose() {
    _lessonContentCtrl.dispose();
    _lessonHomeworkCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(connectionProvider);
    final classrooms = ref.watch(classroomsForScheduleProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Présence'),
        actions: [
          if (!conn.canReachServer)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: StatusBadge.offline(),
            ),
        ],
      ),
      body: !conn.canReachServer
          ? const EmptyState(
              title: 'Hors-ligne',
              message: 'La saisie des présences nécessite une connexion au serveur.',
              icon: Icons.cloud_off,
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // --- Sélecteurs ---
                SectionHeader(
                  title: 'Sélection',
                  icon: Icons.filter_list,
                  subtitle: _activeSession == null
                      ? 'Choisissez une classe, une date puis un cours.'
                      : 'Session active — modifications limitées.',
                ),
                const SizedBox(height: 8),
                classrooms.when(
                  data: (list) {
                    if (list.isEmpty) {
                      return const _DisabledField(
                          label: 'Classe', hint: 'Aucune classe');
                    }
                    if (_classroomId == null ||
                        !list.any((c) => c.id == _classroomId)) {
                      _classroomId = list.first.id;
                    }
                    return DropdownButtonFormField<ClassroomDto>(
                      value: list.firstWhere((c) => c.id == _classroomId),
                      decoration: const InputDecoration(
                        labelText: 'Classe',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: list
                          .map((c) => DropdownMenuItem(
                                value: c,
                                child: Text(c.name),
                              ))
                          .toList(),
                      onChanged: _activeSession == null
                          ? (c) => setState(() {
                                _classroomId = c?.id;
                                _selectedCourse = null;
                              })
                          : null,
                    );
                  },
                  loading: () => const LinearProgressIndicator(minHeight: 56),
                  error: (e, _) => _DisabledField(
                      label: 'Classe', hint: 'Erreur : $e'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: _activeSession == null
                            ? () async {
                                final picked = await showDatePicker(
                                  context: context,
                                  initialDate: _date,
                                  firstDate:
                                      DateTime(DateTime.now().year - 1, 1, 1),
                                  lastDate:
                                      DateTime(DateTime.now().year + 1, 12, 31),
                                );
                                if (picked != null) {
                                  setState(() {
                                    _date = picked;
                                    _selectedCourse = null;
                                  });
                                }
                              }
                            : null,
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Date',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.calendar_today, size: 16),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '${DateFormatter.date(_date)} (${_weekdayLabel(_date)})',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SegmentedButton<WeekType>(
                      segments: const [
                        ButtonSegment(value: WeekType.a, label: Text('A')),
                        ButtonSegment(value: WeekType.b, label: Text('B')),
                      ],
                      selected: {_weekType},
                      onSelectionChanged: _activeSession == null
                          ? (s) => setState(() {
                                _weekType = s.first;
                                _selectedCourse = null;
                              })
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                if (_activeSession == null) ...[
                  _courseSelector(context),
                ] else ...[
                  _activeSessionView(context),
                ],
              ],
            ),
    );
  }

  String _weekdayLabel(DateTime d) {
    const names = {
      DateTime.monday: 'Lundi',
      DateTime.tuesday: 'Mardi',
      DateTime.wednesday: 'Mercredi',
      DateTime.thursday: 'Jeudi',
      DateTime.friday: 'Vendredi',
      DateTime.saturday: 'Samedi',
      DateTime.sunday: 'Dimanche',
    };
    return names[d.weekday] ?? '—';
  }

  /// Sélecteur de cours (dérivé de l'emploi du temps du jour) + bouton
  /// « Démarrer la session ».
  Widget _courseSelector(BuildContext context) {
    if (_classroomId == null) {
      return const EmptyState(
        title: 'Sélectionnez une classe',
        icon: Icons.school_outlined,
      );
    }
    // Pas de cours le dimanche (semaine scolaire Lundi..Samedi).
    if (_date.weekday == DateTime.sunday) {
      return const EmptyState(
        title: 'Pas de cours le dimanche',
        message: 'Sélectionnez un jour de semaine (Lundi..Samedi).',
        icon: Icons.weekend,
      );
    }
    return ref
        .watch(weeklyScheduleProvider(ScheduleQuery(
          classroomId: _classroomId!,
          weekType: _weekType,
        )))
        .when(
          data: (list) {
            final dayCourses = list
                .where((s) => s.dayOfWeek == _date.weekday)
                .toList()
              ..sort((a, b) => a.startTime.compareTo(b.startTime));
            if (dayCourses.isEmpty) {
              return EmptyState(
                title: 'Aucun cours ce jour',
                message:
                    'Aucun cours programmé le ${_weekdayLabel(_date)} (semaine ${_weekType == WeekType.a ? 'A' : 'B'}).',
                icon: Icons.event_busy,
              );
            }
            // Auto-sélection du 1er cours si vide ou invalide.
            if (_selectedCourse == null ||
                !dayCourses.any((c) => c.id == _selectedCourse!.id)) {
              _selectedCourse = dayCourses.first;
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<WeeklyScheduleDto>(
                  value: _selectedCourse,
                  decoration: const InputDecoration(
                    labelText: 'Cours',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: dayCourses
                      .map((c) => DropdownMenuItem(
                            value: c,
                            child: Text(
                              '${c.startTime} – ${c.subjectName ?? 'Cours'}'
                              '${c.teacherName != null ? ' (${c.teacherName})' : ''}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ))
                      .toList(),
                  onChanged: (c) => setState(() => _selectedCourse = c),
                ),
                const SizedBox(height: 16),
                if (_selectedCourse != null)
                  FilledButton.icon(
                    onPressed: _startSession,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Démarrer la session'),
                  ),
              ],
            );
          },
          loading: () =>
              const AppLoading(label: 'Chargement de l\'emploi du temps…'),
          error: (e, _) => AppErrorWidget(
            message: e.toString(),
            onRetry: () => ref.invalidate(weeklyScheduleProvider(ScheduleQuery(
              classroomId: _classroomId!,
              weekType: _weekType,
            ))),
          ),
        );
  }

  Future<void> _startSession() async {
    if (_classroomId == null || _selectedCourse == null) return;
    final course = _selectedCourse!;
    setState(() => _saving = true);
    try {
      final session = await ref.read(attendanceControllerProvider).startSession(
            classroomId: _classroomId!,
            weeklyScheduleId: course.id,
            subjectId: course.subjectId,
            teacherId: course.teacherId,
            date: _date,
            startTime: course.startTime,
            endTime: course.endTime,
          );
      setState(() {
        _activeSession = session;
        _absencesDrafts.clear();
        _lessonLoaded = false;
      });
    } on ApiException catch (e) {
      _showError(e.message);
    } catch (e) {
      _showError('Erreur : $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Vue active une fois la session démarrée : badge d'état, liste des
  /// élèves avec case « Absent », cahier de texte, bouton « Enregistrer ».
  Widget _activeSessionView(BuildContext context) {
    final session = _activeSession!;
    final studentsAsync =
        ref.watch(classStudentsProvider(session.classroomId ?? _classroomId!));
    final absencesAsync = ref.watch(sessionAbsencesProvider(session.id));
    final lessonAsync = ref.watch(lessonRecordProvider(session.id));

    // Initialisation paresseuse du cahier de texte (une seule fois).
    if (lessonAsync is AsyncData<LessonRecordDto?> && !_lessonLoaded) {
      _lessonLoaded = true;
      final record = lessonAsync.value;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (record != null) {
          _lessonContentCtrl.text = record.content;
          _lessonHomeworkCtrl.text = record.homework ?? '';
          _lessonRecordId = record.id;
        }
      });
    }

    // Initialisation paresseuse des brouillons d'absences (idempotent).
    if (absencesAsync is AsyncData<List<StudentAbsenceDto>>) {
      for (final a in absencesAsync.value) {
        _absencesDrafts.putIfAbsent(a.studentId, () => a);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // --- En-tête session + badge état ---
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _selectedCourse?.subjectName ??
                            session.subjectName ??
                            'Cours',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    _StateBadge(state: session.state),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${_weekdayLabel(_date)} ${DateFormatter.date(_date)} • '
                  '${session.startTime ?? _selectedCourse?.startTime ?? ''}'
                  '${(session.endTime ?? _selectedCourse?.endTime) != null ? ' – ${session.endTime ?? _selectedCourse?.endTime}' : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (_selectedCourse?.teacherName != null) ...[
                  const SizedBox(height: 2),
                  Text('Ens. ${_selectedCourse!.teacherName}',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // --- Liste des élèves ---
        SectionHeader(
          title: 'Élèves',
          icon: Icons.group,
          subtitle:
              'Cochez les absents. Par défaut, tous les élèves sont présents.',
        ),
        const SizedBox(height: 8),
        studentsAsync.when(
          data: (students) {
            if (students.isEmpty) {
              return const EmptyState(
                title: 'Aucun élève',
                message: 'Aucun élève inscrit dans cette classe.',
                icon: Icons.group_off,
              );
            }
            return Column(
              children: [
                // En-tête résumé
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      Text(
                        '${students.length} élève(s)',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const Spacer(),
                      Text(
                        '${_absencesDrafts.length} absent(s)',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: _absencesDrafts.isEmpty
                                  ? Colors.green
                                  : Colors.red.shade400,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                ...students.map((s) => _StudentAbsenceRow(
                      student: s,
                      absence: _absencesDrafts[s.id],
                      onChanged: (absent, draft) {
                        setState(() {
                          if (absent && draft != null) {
                            _absencesDrafts[s.id] = draft;
                          } else {
                            _absencesDrafts.remove(s.id);
                          }
                        });
                      },
                    )),
              ],
            );
          },
          loading: () => const AppLoading(label: 'Chargement des élèves…'),
          error: (e, _) => AppErrorWidget(
            message: e.toString(),
            onRetry: () => ref.invalidate(
                classStudentsProvider(session.classroomId ?? _classroomId!)),
          ),
        ),
        const SizedBox(height: 16),

        // --- Cahier de texte ---
        SectionHeader(
          title: 'Cahier de texte',
          icon: Icons.menu_book_outlined,
          subtitle: 'Contenu du cours et devoirs à faire.',
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _lessonContentCtrl,
          decoration: const InputDecoration(
            labelText: 'Contenu du cours',
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
          minLines: 3,
          maxLines: 5,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _lessonHomeworkCtrl,
          decoration: const InputDecoration(
            labelText: 'Devoirs',
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
          minLines: 2,
          maxLines: 4,
        ),
        const SizedBox(height: 24),

        // --- Actions ---
        FilledButton.icon(
          onPressed: _saving ? null : _saveAll,
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
        if (session.state == CourseSessionState.pending)
          OutlinedButton.icon(
            onPressed: _saving ? null : _markCompleted,
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('Marquer la session comme terminée'),
          ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _saving
              ? null
              : () => setState(() {
                    _activeSession = null;
                    _selectedCourse = null;
                    _absencesDrafts.clear();
                    _lessonContentCtrl.clear();
                    _lessonHomeworkCtrl.clear();
                    _lessonRecordId = null;
                    _lessonLoaded = false;
                  }),
          icon: const Icon(Icons.close),
          label: const Text('Fermer la session (sans enregistrer)'),
        ),
      ],
    );
  }

  Future<void> _saveAll() async {
    final session = _activeSession;
    if (session == null) return;
    setState(() => _saving = true);
    try {
      // 1) Cahier de texte (si contenu non vide).
      final content = _lessonContentCtrl.text.trim();
      if (content.isNotEmpty) {
        await ref.read(attendanceControllerProvider).saveLessonRecord(
              sessionId: session.id,
              content: content,
              homework: _lessonHomeworkCtrl.text.trim().isEmpty
                  ? null
                  : _lessonHomeworkCtrl.text.trim(),
              recordId: _lessonRecordId,
            );
      }
      // 2) Absences.
      final absences = _absencesDrafts.values
          .map((a) => StudentAbsenceDto(
                id: a.id,
                courseSessionId: session.id,
                studentId: a.studentId,
                studentName: a.studentName,
                matricule: a.matricule,
                isJustified: a.isJustified,
                reason: a.reason,
              ))
          .toList();
      await ref.read(attendanceControllerProvider).saveAbsences(
            session.id,
            absences,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Enregistré : ${absences.length} absent(s), cahier de texte ${content.isEmpty ? 'ignoré' : 'mis à jour'}.'),
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

  Future<void> _markCompleted() async {
    final session = _activeSession;
    if (session == null) return;
    setState(() => _saving = true);
    try {
      final updated = await ref
          .read(attendanceControllerProvider)
          .markSessionState(session.id, CourseSessionState.completed.code);
      setState(() => _activeSession = updated);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Session marquée comme terminée.')),
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

class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.state});
  final CourseSessionState state;

  @override
  Widget build(BuildContext context) {
    Color color;
    IconData icon;
    switch (state) {
      case CourseSessionState.pending:
        color = Colors.orange;
        icon = Icons.hourglass_top;
        break;
      case CourseSessionState.completed:
        color = Colors.green;
        icon = Icons.check_circle;
        break;
      case CourseSessionState.cancelled:
        color = Colors.red;
        icon = Icons.cancel;
        break;
    }
    return StatusBadge(label: state.label, color: color, icon: icon);
  }
}

/// Ligne d'un élève avec case « Absent » et, si cochée, champ « Motif » +
/// interrupteur « Justifié ».
///
/// Le [TextEditingController] du motif est géré dans un [State] dédié pour
/// conserver la position du curseur entre les rebuilds et nettoyer le champ
/// quand l'élève repasse à « présent ».
class _StudentAbsenceRow extends StatefulWidget {
  const _StudentAbsenceRow({
    required this.student,
    required this.absence,
    required this.onChanged,
  });

  final StudentDto student;
  final StudentAbsenceDto? absence;
  final void Function(bool absent, StudentAbsenceDto? draft) onChanged;

  @override
  State<_StudentAbsenceRow> createState() => _StudentAbsenceRowState();
}

class _StudentAbsenceRowState extends State<_StudentAbsenceRow> {
  late final TextEditingController _reasonCtrl;

  @override
  void initState() {
    super.initState();
    _reasonCtrl = TextEditingController(text: widget.absence?.reason ?? '');
    _reasonCtrl.addListener(_onReasonChanged);
  }

  void _onReasonChanged() {
    final a = widget.absence;
    if (a == null) return;
    final text = _reasonCtrl.text;
    if (text != (a.reason ?? '')) {
      widget.onChanged(
        true,
        StudentAbsenceDto(
          id: a.id,
          courseSessionId: a.courseSessionId,
          studentId: a.studentId,
          studentName: a.studentName,
          matricule: a.matricule,
          isJustified: a.isJustified,
          reason: text.isEmpty ? null : text,
        ),
      );
    }
  }

  @override
  void didUpdateWidget(covariant _StudentAbsenceRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Quand l'élève repasse à « présent », on nettoie le motif pour la
    // prochaine fois. On ne touche jamais au texte pendant la frappe pour
    // préserver le curseur.
    if (oldWidget.absence != null && widget.absence == null) {
      _reasonCtrl.clear();
    }
  }

  @override
  void dispose() {
    _reasonCtrl.removeListener(_onReasonChanged);
    _reasonCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAbsent = widget.absence != null;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.student.fullName,
                          style: Theme.of(context).textTheme.titleSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      if (widget.student.matricule.isNotEmpty)
                        Text(widget.student.matricule,
                            style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Checkbox(
                  value: isAbsent,
                  onChanged: (v) {
                    final absent = v ?? false;
                    if (absent) {
                      widget.onChanged(
                        true,
                        StudentAbsenceDto(
                          courseSessionId: 0, // Rempli à la sauvegarde.
                          studentId: widget.student.id,
                          studentName: widget.student.fullName,
                          matricule: widget.student.matricule,
                          isJustified: false,
                          reason: null,
                        ),
                      );
                    } else {
                      widget.onChanged(false, null);
                    }
                  },
                ),
                const SizedBox(width: 4),
                Text('Absent',
                    style: Theme.of(context).textTheme.labelMedium),
              ],
            ),
            if (isAbsent) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _reasonCtrl,
                decoration: const InputDecoration(
                  labelText: 'Motif',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Justifié'),
                value: widget.absence!.isJustified,
                onChanged: (v) {
                  final a = widget.absence!;
                  widget.onChanged(
                    true,
                    StudentAbsenceDto(
                      id: a.id,
                      courseSessionId: a.courseSessionId,
                      studentId: a.studentId,
                      studentName: a.studentName,
                      matricule: a.matricule,
                      isJustified: v,
                      reason: a.reason,
                    ),
                  );
                },
              ),
            ],
          ],
        ),
      ),
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
