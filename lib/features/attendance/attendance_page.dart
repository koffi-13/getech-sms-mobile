/// Page « Présence » : sélection classe + date + cours (issu de l'emploi du
/// temps du jour), démarrage d'une session de cours, saisie des absences
/// (case Absent + motif) et cahier de texte (contenu + devoirs).
///
/// Le cours est dérivé de l'emploi du temps hebdomadaire de la classe pour
/// le jour sélectionné (filtrage par `dayOfWeek`).
///
/// [Présence-V9] Deux évolutions majeures :
/// - **Sélection intelligente** : classe, date (aujourd'hui), semaine A/B
///   (calculée) et cours (créneau en cours ou à venir) sont pré-sélectionnés
///   d'après l'emploi du temps enseignant et l'heure courante — plus besoin
///   de choisir manuellement au quotidien.
/// - **Deux temps de saisie** : l'APPEL se fait au DÉBUT du cours (liste des
///   élèves d'emblée visible) ; le CAHIER DE TEXTE se remplit à la FIN du
///   cours (section repliée tant que le créneau n'est pas terminé, mais
///   ouvrable à tout moment — rattrapage).
/// - **Justification réservée à l'administration** : l'enseignant MARQUE
///   l'absence (absent + motif) ; le statut « Justifié » n'est modifiable
///   que par un admin (le serveur le garantit aussi — [Fix-JUSTIFY-ADMIN]).
library;

import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_state.dart';
import '../../core/auth/teacher_scope.dart';
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
import 'course_selection.dart' as smart;

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

  /// [Présence-V9] L'utilisateur a-t-il choisi MANUELLEMENT la semaine A/B ?
  /// Sinon la semaine calculée (`currentWeekTypeProvider`) fait foi.
  bool _userPickedWeek = false;

  /// [Présence-V9] L'utilisateur a-t-il replié/déplié manuellement le
  /// cahier de texte ? Sinon : replié avant la fin du cours, déplié après.
  bool _cahierUserToggled = false;
  bool _cahierExpanded = false;

  /// [Présence-V9] Horloge : rafraîchit l'UI toutes les 30 s pour que la
  /// section cahier de texte se DÉPLIE automatiquement quand l'heure de
  /// fin du cours est atteinte (session active) et que la sélection par
  /// défaut du cours suive l'heure courante (sélecteur).
  Timer? _clockTimer;

  /// Brouillons d'absences indexés par `studentId`. Seuls les élèves absents
  /// sont présents dans cette map (présent = absent de la map).
  final Map<int, StudentAbsenceDto> _absencesDrafts = {};

  final TextEditingController _lessonContentCtrl = TextEditingController();
  final TextEditingController _lessonHomeworkCtrl = TextEditingController();
  int? _lessonRecordId;
  bool _lessonLoaded = false;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _clockTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _lessonContentCtrl.dispose();
    _lessonHomeworkCtrl.dispose();
    super.dispose();
  }

  /// [Présence-V9] Semaine effective : choix manuel > semaine calculée > A.
  WeekType _effectiveWeekType(WeekType? autoWeek) =>
      _userPickedWeek ? _weekType : (autoWeek ?? _weekType);

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(connectionProvider);
    final classrooms = ref.watch(classroomsForScheduleProvider);
    // [Présence-V9] Périmètre enseignant + semaine A/B calculée pour la
    // présélection intelligente.
    final auth = ref.watch(authProvider);
    final scopeAsync = ref.watch(teacherScopeProvider);
    final scope = scopeAsync.valueOrNull;
    final autoWeek = ref.watch(currentWeekTypeProvider).valueOrNull;
    final restricted =
        scope != null && scope.isTeacher && !scope.isAdminOrHeadmaster;
    final effectiveWeek = _effectiveWeekType(autoWeek);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Présence'),
        actions: [
          // [Fix-PRESENCE-ONLINE] La saisie n'est proposée QUE lorsque la
          // connexion au serveur est établie (y compris pendant la
          // vérification initiale : état indéterminé = pas de saisie).
          if (!conn.canReachServer)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: conn.isChecking
                  ? const StatusBadge(
                      label: 'Connexion…',
                      color: Colors.orange,
                      icon: Icons.wifi_find,
                    )
                  : StatusBadge.offline(),
            ),
        ],
      ),
      // [Fix-PRESENCE-ONLINE] Garde stricte : contrairement aux autres
      // modules (local-first), la présence n'est JAMAIS saisie hors-ligne —
      // ni en file d'attente ni en cache. L'état « checking » (heartbeat en
      // cours) est traité comme non-connecté : on attend le verdict.
      body: conn.canReachServer
          ? ListView(
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
                    // [Présence-V9] Un enseignant ne choisit que parmi SES
                    // classes (enseignement ∪ titulariat) — pas toutes les
                    // classes de l'établissement (miroir du module Classes).
                    var classList = list;
                    if (restricted) {
                      final myIds = scope!.myClassroomIds;
                      final byId = <int, ClassroomDto>{
                        for (final c in list)
                          if (myIds.contains(c.id)) c.id: c,
                      };
                      for (final c in scope.myClassrooms) {
                        byId.putIfAbsent(c.id, () => c);
                      }
                      classList = byId.values.toList()
                        ..sort((a, b) => a.name.compareTo(b.name));
                    }
                    if (classList.isEmpty) {
                      return const _DisabledField(
                          label: 'Classe', hint: 'Aucune classe');
                    }
                    // [Présence-V9] Présélection intelligente : classe du
                    // créneau EN COURS ou À VENIR aujourd'hui (emploi du
                    // temps enseignant) — sinon 1re classe de la liste.
                    if (_classroomId == null ||
                        !classList.any((c) => c.id == _classroomId)) {
                      _classroomId =
                          smart.defaultClassroomId(
                                  classList, scope, DateTime.now(),
                                  effectiveWeek: effectiveWeek) ??
                              classList.first.id;
                    }
                    return DropdownButtonFormField<ClassroomDto>(
                      value: classList.firstWhere(
                          (c) => c.id == _classroomId,
                          orElse: () => classList.first),
                      // [Fix-OVERFLOW] isExpanded : contraint la valeur
                      // sélectionnée à la largeur du champ.
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Classe',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: classList
                          .map((c) => DropdownMenuItem(
                                value: c,
                                child: Text(c.name,
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 1),
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
                      selected: {effectiveWeek},
                      onSelectionChanged: _activeSession == null
                          ? (s) => setState(() {
                                // [Présence-V9] Choix MANUEL : il prend le
                                // dessus sur la semaine calculée.
                                _userPickedWeek = true;
                                _weekType = s.first;
                                _selectedCourse = null;
                              })
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                if (_activeSession == null) ...[
                  _courseSelector(context, effectiveWeek),
                ] else ...[
                  _activeSessionView(context, effectiveWeek),
                ],
              ],
            )
            : _offlinePlaceholder(conn),
    );
  }

  /// [Fix-PRESENCE-ONLINE] Vue affichée à la place du formulaire tant que la
  /// connexion au serveur n'est pas établie. Trois états :
  /// - non appairé : aucun serveur configuré → proposer l'appairage ;
  /// - vérification en cours (heartbeat) : attendre le verdict ;
  /// - hors-ligne / mode hors-ligne forcé : inviter à se reconnecter.
  Widget _offlinePlaceholder(ConnectionState conn) {
    if (!conn.isPaired) {
      return EmptyState(
        title: 'Aucun serveur',
        message:
            'La présence ne peut être saisie qu\'en connexion au serveur. '
            'Appairez d\'abord un serveur GeTech-SMS.',
        icon: Icons.dns_outlined,
        actionLabel: 'Appairer un serveur',
        onAction: () => context.push('/connections'),
      );
    }
    if (conn.isChecking) {
      return EmptyState(
        title: 'Connexion au serveur…',
        message:
            'Vérification de la liaison en cours. La saisie des présences '
            'sera proposée dès que la connexion sera établie.',
        icon: Icons.wifi_find,
        actionLabel: 'Revérifier',
        onAction: () => ref.read(connectionProvider.notifier).checkStatus(),
      );
    }
    return EmptyState(
      title: 'Hors-ligne',
      message: conn.forceOffline
          ? 'Le mode hors-ligne est activé. La présence ne peut être saisie '
              'qu\'en connexion au serveur — désactivez le mode hors-ligne '
              'pour saisir les absences et le cahier de texte.'
          : 'Serveur injoignable. La présence ne peut être saisie qu\'en '
              'connexion au serveur. Vérifiez que le serveur GeTech-SMS est '
              'démarré et joignable, puis réessayez.',
      icon: Icons.cloud_off,
      actionLabel: 'Réessayer',
      onAction: () => ref.read(connectionProvider.notifier).checkStatus(),
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
  ///
  /// [Présence-V9] [effectiveWeek] est la semaine A/B réellement affichée
  /// (choix manuel ou calculée) — l'ancien code utilisait `_weekType` brut,
  /// qui restait « A » tant que l'utilisateur n'avait pas touché au
  /// segmented button.
  Widget _courseSelector(BuildContext context, WeekType effectiveWeek) {
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
          weekType: effectiveWeek,
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
                    'Aucun cours programmé le ${_weekdayLabel(_date)} (semaine ${effectiveWeek == WeekType.a ? 'A' : 'B'}).',
                icon: Icons.event_busy,
              );
            }
            // [Présence-V9] Auto-sélection intelligente : créneau EN COURS
            // ou À VENIR selon l'heure courante (aujourd'hui seulement) —
            // sinon 1er cours de la journée. L'ancien code prenait
            // systématiquement le 1er créneau, même à 15 h.
            if (_selectedCourse == null ||
                !dayCourses.any((c) => c.id == _selectedCourse!.id)) {
              _selectedCourse = smart.autoCourseFor(dayCourses,
                  date: _date, now: DateTime.now());
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<WeeklyScheduleDto>(
                  value: _selectedCourse,
                  // [Fix-COURSE-OVERFLOW-152] isExpanded : la valeur
                  // sélectionnée est contrainte à la largeur du champ.
                  // L'ancienne version laissait le Text mesurer sa largeur
                  // naturelle (« 08:00 – Mathématiques (M. Konan Yao
                  // Bernard) ») → débordement de 152 px sur la droite.
                  isExpanded: true,
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
                              maxLines: 1,
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
              weekType: effectiveWeek,
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
        // [Présence-V9] Le cahier de texte repart replié (fin de cours)
        // sauf rattrapage : l'état d'expansion suit à nouveau l'heure.
        _cahierUserToggled = false;
        _cahierExpanded = false;
      });
    } on ApiException catch (e) {
      _showError(e.message);
    } catch (e) {
      _showError(AppErrorWidget.humanize(e.toString()));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Vue active une fois la session démarrée : badge d'état, liste des
  /// élèves avec case « Absent », cahier de texte, bouton « Enregistrer ».
  /// [Présence-V9] Heure de fin du cours actif (null si inconnue) :
  /// celle du créneau sélectionné, sinon celle renvoyée par la session.
  DateTime? _courseEndDateTime() {
    final end = _selectedCourse?.endTime ?? _activeSession?.endTime;
    final hm = smart.parseHm(end);
    if (hm == null) return null;
    return DateTime(_date.year, _date.month, _date.day, hm.$1, hm.$2);
  }

  Widget _activeSessionView(BuildContext context, WeekType effectiveWeek) {
    final session = _activeSession!;
    final studentsAsync =
        ref.watch(classStudentsProvider(session.classroomId ?? _classroomId!));
    final absencesAsync = ref.watch(sessionAbsencesProvider(session.id));
    final lessonAsync = ref.watch(lessonRecordProvider(session.id));
    // [Présence-V9] Justification réservée à l'administration.
    final canJustify = ref.watch(authProvider).isAdminOrHeadmaster;

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

    // [Présence-V9] Deux temps de saisie :
    // - appel : DÉBUT du cours (visible d'emblée) ;
    // - cahier de texte : FIN du cours — replié tant que le créneau
    //   dure, déplié automatiquement à/après l'heure de fin ; le
    //   rattrapage reste possible à tout moment (tap sur l'en-tête).
    final courseEnd = _courseEndDateTime();
    final now = DateTime.now();
    final courseEnded = courseEnd != null && now.isAfter(courseEnd);
    final lessonHasContent =
        _lessonContentCtrl.text.trim().isNotEmpty && _lessonLoaded;
    final cahierExpanded = _cahierUserToggled
        ? _cahierExpanded
        : (courseEnded || lessonHasContent);
    final remaining = courseEnd?.difference(now);
    final cahierSubtitle = courseEnd == null
        ? 'À remplir en fin de cours (horaire de fin inconnu).'
        : courseEnded
            ? 'Le cours est terminé — pensez à compléter le cahier de texte.'
            : 'À remplir en fin de cours (fin à ${_fmtHm(courseEnd)}'
                '${remaining != null && remaining.inMinutes < 120 ? ', dans ${remaining.inMinutes} min' : ''})'
                '. Ouvert à tout moment (rattrapage).';

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

        // --- 1er temps : APPEL (début de cours) — liste des élèves ---
        SectionHeader(
          title: 'Appel — début de cours',
          icon: Icons.fact_check_outlined,
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
                      // [Présence-V9] Justification réservée à l'admin.
                      canJustify: canJustify,
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

        // --- 2e temps : CAHIER DE TEXTE (fin de cours) ---
        // [Présence-V9] Section repliable : repliée tant que le créneau
        // dure (l'appel est la priorité), dépliée automatiquement quand
        // l'heure de fin arrive (horloge 30 s) ; l'en-tête reste tappable
        // à tout moment pour anticiper ou rattraper la saisie.
        Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              InkWell(
                onTap: () => setState(() {
                  _cahierUserToggled = true;
                  _cahierExpanded = !cahierExpanded;
                }),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                  child: Row(
                    children: [
                      Icon(Icons.menu_book_outlined,
                          color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Cahier de texte — fin de cours',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleSmall
                                    ?.copyWith(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 2),
                            Text(
                              cahierSubtitle,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        cahierExpanded
                            ? Icons.expand_less
                            : Icons.expand_more,
                      ),
                    ],
                  ),
                ),
              ),
              AnimatedCrossFade(
                duration: const Duration(milliseconds: 200),
                crossFadeState: cahierExpanded
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                firstChild: const SizedBox(width: double.infinity),
                secondChild: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
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
                    ],
                  ),
                ),
              ),
            ],
          ),
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

  /// [Présence-V9] « HH:mm » lisible (DateTime → « 14:30 »).
  static String _fmtHm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

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
      // [Présence-V9] L'enseignant MARQUE l'absence (absent + motif) ; le
      // statut « Justifié » envoyé tel quel est IGNORÉ par le serveur pour
      // un non-admin ([Fix-JUSTIFY-ADMIN]) : l'état serveur fait foi.
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
      _showError(AppErrorWidget.humanize(e.toString()));
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
      _showError(AppErrorWidget.humanize(e.toString()));
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
/// statut de justification.
///
/// [Présence-V9] **Justification réservée à l'administration** : seul un
/// admin ([canJustify]) voit l'interrupteur « Justifié ». L'enseignant
/// MARQUE l'absence (case + motif d'observation) ; le statut de
/// justification vient du serveur (badge lecture seule « Justifiée
/// (administration) » si l'admin l'a posée) et une invite rappelle la
/// règle.
class _StudentAbsenceRow extends StatefulWidget {
  const _StudentAbsenceRow({
    required this.student,
    required this.absence,
    required this.onChanged,
    this.canJustify = false,
  });

  final StudentDto student;
  final StudentAbsenceDto? absence;

  /// Vrai pour un admin (superuser / ADMIN / HEADMASTER) : seule personne
  /// autorisée à justifier une absence.
  final bool canJustify;

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
              // [Présence-V9] Justification : admin → interrupteur ;
              // enseignant → information (le serveur garantit la règle).
              if (widget.canJustify)
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
                )
              else if (widget.absence!.isJustified)
                Row(
                  children: [
                    Icon(Icons.verified,
                        size: 16, color: Colors.green.shade700),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Justifiée (administration) — statut non modifiable '
                        'par un enseignant.',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: Colors.green.shade700),
                      ),
                    ),
                  ],
                )
              else
                Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 16,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'La justification d\'une absence est réservée à '
                        'l\'administration.',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant),
                      ),
                    ),
                  ],
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
