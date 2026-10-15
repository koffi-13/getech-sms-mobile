/// Page « Présence » : cours déterminé par l'emploi du temps de
/// l'UTILISATEUR et par « l'heure qui sonne », démarrage de session(s),
/// saisie des absences (case Absent + motif) et cahier de texte.
///
/// [Présence-V10] Trois évolutions majeures (retour utilisateur : « les
/// cours qui n'appartiennent pas à l'utilisateur s'affichent ») :
/// - **Cours de l'utilisateur uniquement** : l'enseignant voit SES cours
///   (`GET /schedule/my` via [TeacherScope]) — plus les cours des autres
///   enseignants de la classe.
/// - **L'heure qui sonne** : le créneau affiché est celui dont l'intervalle
///   CONTIENT l'heure courante (sinon le prochain créneau du jour). La
///   classe où l'enseignant doit se trouver et le cours qui doit tenir en
///   découlent automatiquement.
/// - **Chevauchements = classes jumelées** : deux cours qui se
///   chevauchent forment UN groupe (l'enseignant a jumelé les classes) ;
///   une session est ouverte par classe et l'appel présente la liste
///   FUSIONNÉE des élèves (badges de classe).
/// - **Sélection verrouillée** : pour l'enseignant, classe/date/semaine/
///   cours ne sont plus choisissables — ils suivent l'emploi du temps et
///   l'heure courante (horloge 30 s). L'administration conserve le flux
///   manuel historique.
///
/// [Présence-V9] conservé :
/// - **Deux temps de saisie** : l'APPEL se fait au DÉBUT du cours (liste
///   des élèves d'emblée visible) ; le CAHIER DE TEXTE se remplit à la
///   FIN du cours (section repliée tant que le créneau n'est pas terminé,
///   mais ouvrable à tout moment — rattrapage).
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
  // ── Sélection (flux manuel — administration) ──────────────────────────
  int? _classroomId;
  WeekType _weekType = WeekType.a;
  DateTime _date = DateTime.now();

  WeeklyScheduleDto? _selectedCourse;

  /// [Présence-V10] Session(s) active(s) : UNE par classe du groupe de
  /// cours (classes jumelées → plusieurs sessions ouvertes d'un coup).
  List<CourseSessionDto> _activeSessions = const [];
  smart.CourseGroup? _activeGroup;

  /// [Présence-V10] élève → session de SA classe (sauvegarde des absences
  /// vers la bonne session quand les classes sont jumelées).
  Map<int, int> _sessionByStudent = const {};

  /// [Présence-V10] Cahier de texte partagé : id de fiche existante PAR
  /// session (les classes jumelées partagent le même contenu).
  Map<int, int> _lessonRecordIds = {};

  /// [Présence-V9] L'utilisateur a-t-il choisi MANUELLEMENT la semaine A/B ?
  /// Sinon la semaine calculée (`currentWeekTypeProvider`) fait foi.
  bool _userPickedWeek = false;

  /// [Présence-V9] L'utilisateur a-t-il replié/déplié manuellement le
  /// cahier de texte ? Sinon : replié avant la fin du cours, déplié après.
  bool _cahierUserToggled = false;
  bool _cahierExpanded = false;

  /// [Présence-V9/V10] Horloge : rafraîchit l'UI toutes les 30 s pour que
  /// le créneau « heure qui sonne » suive l'heure courante et que la
  /// section cahier de texte se DÉPLIE automatiquement quand l'heure de
  /// fin du cours est atteinte.
  Timer? _clockTimer;

  /// Brouillons d'absences indexés par `studentId`. Seuls les élèves absents
  /// sont présents dans cette map (présent = absent de la map).
  final Map<int, StudentAbsenceDto> _absencesDrafts = {};

  final TextEditingController _lessonContentCtrl = TextEditingController();
  final TextEditingController _lessonHomeworkCtrl = TextEditingController();
  bool _lessonLoaded = false;

  bool _saving = false;

  /// Session « principale » (première du groupe) — rétrocompatibilité
  /// d'affichage (badge d'état, horaires).
  CourseSessionDto? get _activeSession =>
      _activeSessions.isEmpty ? null : _activeSessions.first;

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

  bool get _hasActiveSession => _activeSessions.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(connectionProvider);
    final classrooms = ref.watch(classroomsForScheduleProvider);
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
                // --- Sélection ---
                SectionHeader(
                  title: 'Sélection',
                  icon: Icons.filter_list,
                  subtitle: _hasActiveSession
                      ? 'Session active — modifications limitées.'
                      : restricted
                          // [Présence-V10] Sélection verrouillée : tout est
                          // déterminé par l'emploi du temps + l'heure.
                          ? 'Cours déterminé par votre emploi du temps et '
                              'l\'heure courante.'
                          : 'Choisissez une classe, une date puis un cours.',
                ),
                const SizedBox(height: 8),

                // [Présence-V10] ENSEIGNANT : panneau automatique verrouillé.
                // ADMINISTRATION : sélecteurs interactifs (flux historique).
                if (restricted)
                  _teacherSelectionPanel(context, scope, effectiveWeek)
                else
                  _adminSelectors(context, classrooms, effectiveWeek),
                const SizedBox(height: 24),

                if (!_hasActiveSession) ...[
                  if (restricted)
                    _teacherCoursePanel(context, scope, effectiveWeek)
                  else
                    _courseSelector(context, effectiveWeek),
                ] else ...[
                  _activeSessionView(context, effectiveWeek),
                ],
              ],
            )
          : _offlinePlaceholder(conn),
    );
  }

  // ---------------------------------------------------------------------------
  // [Présence-V10] PANneau ENSEIGNANT : champs verrouillés (heure qui sonne)
  // ---------------------------------------------------------------------------

  /// Ligne d'information verrouillée (classe / date / semaine / cours) :
  /// la sélection manuelle est DÉSACTIVÉE — ces valeurs suivent l'emploi
  /// du temps de l'enseignant et l'heure courante.
  Widget _teacherSelectionPanel(
    BuildContext context,
    TeacherScope scope,
    WeekType effectiveWeek,
  ) {
    final now = DateTime.now();
    final groups = smart.groupOverlappingCourses(
        scope.coursesForDate(now, currentWeek: effectiveWeek));
    final current = smart.autoCourseGroup(groups, now: now);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _LockedField(
                label: 'Date',
                value:
                    '${DateFormatter.date(now)} (${_weekdayLabel(now)})',
                icon: Icons.calendar_today,
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 110,
              child: _LockedField(
                label: 'Semaine',
                value: effectiveWeek == WeekType.a ? 'A' : 'B',
                icon: Icons.view_week,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _LockedField(
          label: 'Classe',
          value: current?.classroomLabel ?? '—',
          icon: Icons.school_outlined,
        ),
        const SizedBox(height: 12),
        _LockedField(
          label: 'Cours (heure courante)',
          value: current == null
              ? 'Aucun cours aujourd\'hui'
              : '${_fmtMinutes(current.startMinutes)} – '
                  '${_fmtMinutes(current.endMinutes)} • ${current.subjectLabel}'
                  '${current.isMerged ? ' (classes jumelées)' : ''}',
          icon: Icons.schedule,
        ),
      ],
    );
  }

  /// Panneau « heure qui sonne » de l'enseignant : carte du créneau
  /// courant + déroulé de la journée (lecture seule) + démarrage.
  Widget _teacherCoursePanel(
      BuildContext context, TeacherScope scope, WeekType effectiveWeek) {
    final now = DateTime.now();

    // Dimanche : pas de cours.
    if (now.weekday == DateTime.sunday) {
      return const EmptyState(
        title: 'Pas de cours le dimanche',
        message: 'La reprise des cours est prévue lundi.',
        icon: Icons.weekend,
      );
    }

    final groups = smart.groupOverlappingCourses(
        scope.coursesForDate(now, currentWeek: effectiveWeek));
    if (groups.isEmpty) {
      return EmptyState(
        title: 'Aucun cours aujourd\'hui',
        message:
            'Votre emploi du temps ne comporte aucun cours aujourd\'hui '
            '(semaine ${effectiveWeek == WeekType.a ? 'A' : 'B'}).',
        icon: Icons.event_busy,
      );
    }
    final current = smart.autoCourseGroup(groups, now: now);
    if (current == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Carte du créneau « heure qui sonne » ──
        Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.schedule,
                        color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _groupStateLabel(current, now),
                        style:
                            Theme.of(context).textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '${_fmtMinutes(current.startMinutes)} – '
                  '${_fmtMinutes(current.endMinutes)} • '
                  '${current.subjectLabel}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        current.classroomLabel +
                            (current.isMerged
                                ? '  (classes jumelées)'
                                : ''),
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (current.isMerged) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Un seul appel pour l\'ensemble des classes jumelées : '
                    'les élèves des deux classes sont listés ensemble.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant,
                        ),
                  ),
                ],
              ],
            ),
          ),
        ),

        // ── Déroulé de la journée (lecture seule) ──
        ...groups.map((g) {
          final isCurrent = identical(g, current);
          final nowMin = now.hour * 60 + now.minute;
          final isPast = nowMin >= g.endMinutes;
          return Card(
            margin: const EdgeInsets.only(bottom: 6),
            color: isCurrent
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    isCurrent
                        ? Icons.play_circle_fill
                        : (isPast ? Icons.check_circle_outline : Icons.circle_outlined),
                    size: 18,
                    color: isCurrent
                        ? Theme.of(context).colorScheme.primary
                        : (isPast
                            ? Colors.green
                            : Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${_fmtMinutes(g.startMinutes)} – '
                      '${_fmtMinutes(g.endMinutes)} • ${g.subjectLabel} • '
                      '${g.classroomLabel}'
                      '${g.isMerged ? ' (jumelées)' : ''}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontWeight: isCurrent ? FontWeight.bold : null,
                          ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 2,
                    ),
                  ),
                ],
              ),
            ),
          );
        }),

        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _saving ? null : () => _startSessionGroup(current),
          icon: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow),
          label: Text(current.isMerged
              ? 'Démarrer les sessions (classes jumelées)'
              : 'Démarrer la session'),
        ),
      ],
    );
  }

  String _groupStateLabel(smart.CourseGroup g, DateTime now) {
    final nowMin = now.hour * 60 + now.minute;
    if (nowMin >= g.startMinutes && nowMin < g.endMinutes) {
      return 'Cours en cours';
    }
    if (nowMin < g.startMinutes) return 'Prochain cours';
    return 'Dernier cours de la journée';
  }

  static String _fmtMinutes(int m) =>
      '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';

  // ---------------------------------------------------------------------------
  // Sélecteurs ADMINISTRATION (flux historique interactif)
  // ---------------------------------------------------------------------------

  Widget _adminSelectors(
      BuildContext context,
      AsyncValue<List<ClassroomDto>> classrooms,
      WeekType effectiveWeek) {
    final scopeAsync = ref.watch(teacherScopeProvider);
    final scope = scopeAsync.valueOrNull;
    final restricted =
        scope != null && scope.isTeacher && !scope.isAdminOrHeadmaster;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        classrooms.when(
          data: (list) {
            var classList = list;
            if (restricted) {
              final myIds = scope.myClassroomIds;
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
              _classroomId = smart.defaultClassroomId(
                      classList, scope, DateTime.now(),
                      effectiveWeek: effectiveWeek) ??
                  classList.first.id;
            }
            return DropdownButtonFormField<ClassroomDto>(
              value: classList.firstWhere((c) => c.id == _classroomId,
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
                            overflow: TextOverflow.ellipsis, maxLines: 1),
                      ))
                  .toList(),
              onChanged: _hasActiveSession
                  ? null
                  : (c) => setState(() {
                        _classroomId = c?.id;
                        _selectedCourse = null;
                      }),
            );
          },
          loading: () => const LinearProgressIndicator(minHeight: 56),
          error: (e, _) =>
              _DisabledField(label: 'Classe', hint: 'Erreur : $e'),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: _hasActiveSession
                    ? null
                    : () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _date,
                          firstDate: DateTime(DateTime.now().year - 1, 1, 1),
                          lastDate: DateTime(DateTime.now().year + 1, 12, 31),
                        );
                        if (picked != null) {
                          setState(() {
                            _date = picked;
                            _selectedCourse = null;
                          });
                        }
                      },
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
              onSelectionChanged: _hasActiveSession
                  ? null
                  : (s) => setState(() {
                        // [Présence-V9] Choix MANUEL : il prend le
                        // dessus sur la semaine calculée.
                        _userPickedWeek = true;
                        _weekType = s.first;
                        _selectedCourse = null;
                      }),
            ),
          ],
        ),
      ],
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

  /// Sélecteur de cours (flux ADMIN) : dérivé de l'emploi du temps du jour
  /// de la classe sélectionnée + bouton « Démarrer la session ».
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
            // sinon 1er cours de la journée.
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
                    onPressed: _saving
                        ? null
                        : () {
                            // admin : groupe simple d'un cours.
                            final course = _selectedCourse;
                            if (course != null) {
                              _startSessionGroup(smart.CourseGroup([course]));
                            }
                          },
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow),
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

  // ---------------------------------------------------------------------------
  // Démarrage de session(s) — [Présence-V10] groupe (classes jumelées)
  // ---------------------------------------------------------------------------

  /// Démarre UNE session par classe du groupe (chevauchement = classes
  /// jumelées : l'appel couvre l'ensemble des élèves des deux classes).
  Future<void> _startSessionGroup(smart.CourseGroup group) async {
    setState(() => _saving = true);
    try {
      final controller = ref.read(attendanceControllerProvider);
      final sessions = <CourseSessionDto>[];
      for (final course in group.courses) {
        final cid = course.classroomId;
        if (cid == null) continue;
        sessions.add(await controller.startSession(
          classroomId: cid,
          weeklyScheduleId: course.id,
          subjectId: course.subjectId,
          teacherId: course.teacherId,
          // [Présence-V10] Flux enseignant : _date = aujourd'hui (jamais
          // modifiable). Flux admin : date choisie (rattrapage possible).
          date: _date,
          startTime: course.startTime,
          endTime: course.endTime,
        ));
      }
      if (sessions.isEmpty) {
        throw const ApiException(
            'Impossible de démarrer : aucune classe associée à ce cours.');
      }
      setState(() {
        _activeSessions = sessions;
        _activeGroup = group;
        _absencesDrafts.clear();
        _lessonLoaded = false;
        _lessonRecordIds = {};
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

  /// [Présence-V9] Heure de fin du cours actif (null si inconnue) :
  /// celle du créneau du groupe actif, sinon celle renvoyée par la session.
  /// La date de référence est celle de la saisie ([_date] : aujourd'hui en
  /// flux enseignant, date choisie en flux admin).
  DateTime? _courseEndDateTime() {
    final group = _activeGroup;
    if (group != null && group.courses.isNotEmpty) {
      final end = smart.parseHm(group.courses
          .map((c) => c.endTime)
          .reduce((a, b) => a.compareTo(b) > 0 ? a : b));
      if (end != null) {
        return DateTime(
            _date.year, _date.month, _date.day, end.$1, end.$2);
      }
    }
    final end = _activeSession?.endTime;
    final hm = smart.parseHm(end);
    if (hm == null) return null;
    return DateTime(_date.year, _date.month, _date.day, hm.$1, hm.$2);
  }

  // ---------------------------------------------------------------------------
  // Vue session active (appel + cahier de texte)
  // ---------------------------------------------------------------------------

  Widget _activeSessionView(BuildContext context, WeekType effectiveWeek) {
    final session = _activeSession!;
    final group = _activeGroup;
    final merged = group != null && group.isMerged;

    // [Présence-V10] Élèves FUSIONNÉS des classes du groupe (jumelées).
    final classroomIds = (group?.courses
            .map((c) => c.classroomId)
            .whereType<int>()
            .toSet()
            .toList() ??
        [session.classroomId ?? _classroomId!])
      ..sort();
    final studentsAsync =
        ref.watch(mergedClassStudentsProvider(MergedStudentsQuery(classroomIds)));

    // Cahier de texte : la fiche de la session principale pré-remplit le
    // formulaire (les classes jumelées partagent le même contenu).
    final lessonAsync = ref.watch(lessonRecordProvider(session.id));
    // Absences déjà enregistrées : sessions du groupe.
    final absencesAsync = _activeSessions.length == 1
        ? ref.watch(sessionAbsencesProvider(session.id))
        : null;

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
          _lessonRecordIds[session.id] = record.id ?? 0;
        }
      });
    }

    // Initialisation paresseuse des brouillons d'absences (idempotent) :
    // pour un groupe jumelé, on fusionne les absences des sessions.
    if (absencesAsync != null &&
        absencesAsync is AsyncData<List<StudentAbsenceDto>>) {
      for (final a in absencesAsync.value) {
        _absencesDrafts.putIfAbsent(a.studentId, () => a);
      }
    } else {
      for (final s in _activeSessions) {
        final async = ref.read(sessionAbsencesProvider(s.id)).valueOrNull;
        if (async == null) continue;
        for (final a in async) {
          _absencesDrafts.putIfAbsent(a.studentId, () => a);
        }
      }
    }

    // [Présence-V9] Deux temps de saisie :
    // - appel : DÉBUT du cours (visible d'emblée) ;
    // - cahier de texte : FIN du cours — replié tant que le créneau
    //   dure, déplié automatiquement à/après l'heure de fin.
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
                        group?.subjectLabel ??
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
                  '${group != null ? '${_fmtMinutes(group.startMinutes)} – ${_fmtMinutes(group.endMinutes)}' : (session.startTime ?? '')}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (merged) ...[
                  const SizedBox(height: 2),
                  Text(
                    '${group.classroomLabel} — classes jumelées (un appel '
                    'pour l\'ensemble)',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
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
            // [Présence-V10] Association élève → session de sa classe
            // (sauvegarde des absences vers la bonne session).
            final classByStudent = <int, String>{};
            for (final course in group?.courses ?? const <WeeklyScheduleDto>[]) {
              final cid = course.classroomId;
              if (cid == null) continue;
              final label = course.classroomName ?? 'Classe $cid';
              final inClass = ref
                  .read(classStudentsProvider(cid))
                  .valueOrNull;
              for (final s in inClass ?? const <StudentDto>[]) {
                classByStudent[s.id] = label;
              }
            }
            final sessionByStudent = <int, int>{};
            for (final s in _activeSessions) {
              final cid = s.classroomId;
              if (cid == null) continue;
              final inClass = ref.read(classStudentsProvider(cid)).valueOrNull;
              for (final st in inClass ?? const <StudentDto>[]) {
                sessionByStudent[st.id] = s.id;
              }
            }
            _sessionByStudent = sessionByStudent;

            return Column(
              children: [
                // En-tête résumé
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      Text(
                        '${students.length} élève(s)'
                        '${merged ? ' · ${classroomIds.length} classes' : ''}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const Spacer(),
                      Text(
                        '${_absencesDrafts.length} absent(s)',
                        style:
                            Theme.of(context).textTheme.bodySmall?.copyWith(
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
                      classLabel: merged ? classByStudent[s.id] : null,
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
                mergedClassStudentsProvider(MergedStudentsQuery(classroomIds))),
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
            label: Text(_activeSessions.length > 1
                ? 'Marquer les sessions comme terminées'
                : 'Marquer la session comme terminée'),
          ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _saving
              ? null
              : () => setState(() {
                    _activeSessions = const [];
                    _activeGroup = null;
                    _selectedCourse = null;
                    _absencesDrafts.clear();
                    _lessonContentCtrl.clear();
                    _lessonHomeworkCtrl.clear();
                    _lessonRecordIds = {};
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
    if (!_hasActiveSession) return;
    setState(() => _saving = true);
    try {
      // 1) Cahier de texte (si contenu non vide) — [Présence-V10] le même
      // contenu est enregistré sur CHAQUE session du groupe (classes
      // jumelées : un seul cours, un seul cahier de texte).
      final content = _lessonContentCtrl.text.trim();
      if (content.isNotEmpty) {
        for (final session in _activeSessions) {
          final saved = await ref
              .read(attendanceControllerProvider)
              .saveLessonRecord(
                sessionId: session.id,
                content: content,
                homework: _lessonHomeworkCtrl.text.trim().isEmpty
                    ? null
                    : _lessonHomeworkCtrl.text.trim(),
                recordId: _lessonRecordIds[session.id],
              );
          _lessonRecordIds[session.id] = saved.id ?? 0;
        }
      }
      // 2) Absences — [Présence-V10] réparties par session : chaque élève
      // est enregistré sur la session de SA classe (groupes jumelés).
      // [Présence-V9] L'enseignant MARQUE l'absence (absent + motif) ; le
      // statut « Justifié » envoyé tel quel est IGNORÉ par le serveur pour
      // un non-admin ([Fix-JUSTIFY-ADMIN]) : l'état serveur fait foi.
      final bySession = <int, List<StudentAbsenceDto>>{};
      for (final a in _absencesDrafts.values) {
        final sessionId =
            _sessionByStudent[a.studentId] ?? _activeSessions.first.id;
        bySession.putIfAbsent(sessionId, () => []).add(StudentAbsenceDto(
              id: a.id,
              courseSessionId: sessionId,
              studentId: a.studentId,
              studentName: a.studentName,
              matricule: a.matricule,
              isJustified: a.isJustified,
              reason: a.reason,
            ));
      }
      for (final session in _activeSessions) {
        // Chaque session reçoit SA liste (vide = tous présents), comme
        // dans le flux historique mono-classe.
        await ref.read(attendanceControllerProvider).saveAbsences(
              session.id,
              bySession[session.id] ?? const <StudentAbsenceDto>[],
            );
      }
      if (mounted) {
        final total = _absencesDrafts.length;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Enregistré : $total absent(s), cahier de texte ${content.isEmpty ? 'ignoré' : 'mis à jour'}.'),
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
    if (!_hasActiveSession) return;
    setState(() => _saving = true);
    try {
      // [Présence-V10] Toutes les sessions du groupe passent à TERMINÉE.
      final updated = <CourseSessionDto>[];
      for (final session in _activeSessions) {
        if (session.state != CourseSessionState.pending) {
          updated.add(session);
          continue;
        }
        updated.add(await ref
            .read(attendanceControllerProvider)
            .markSessionState(session.id, CourseSessionState.completed.code));
      }
      setState(() => _activeSessions = updated);
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

/// [Présence-V10] Champ verrouillé en lecture seule : la valeur suit
/// l'emploi du temps et l'heure courante — aucun choix manuel.
class _LockedField extends StatelessWidget {
  const _LockedField({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
        // [Fix-OVERFLOW] valeur contrainte à la largeur du champ.
        suffixIcon: Icon(icon,
            size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      child: Text(
        value,
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
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
/// [Présence-V10] [classLabel] : badge de classe (groupes jumelés).
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
    this.classLabel,
  });

  final StudentDto student;
  final StudentAbsenceDto? absence;

  /// Vrai pour un admin (superuser / ADMIN / HEADMASTER) : seule personne
  /// autorisée à justifier une absence.
  final bool canJustify;

  /// [Présence-V10] Badge « 6A » quand plusieurs classes sont jumelées.
  final String? classLabel;

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
                      Row(
                        children: [
                          if (widget.classLabel != null) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .secondaryContainer,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                widget.classLabel!,
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSecondaryContainer,
                                    ),
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                          if (widget.student.matricule.isNotEmpty)
                            Flexible(
                              child: Text(
                                widget.student.matricule,
                                style: Theme.of(context).textTheme.bodySmall,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
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
