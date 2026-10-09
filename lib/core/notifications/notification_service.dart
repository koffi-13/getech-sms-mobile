/// Service de notifications locales — GeTech-SMS Mobile.
///
/// Deux familles de notifications :
///
/// 1. **Rappels de cours (enseignants)** — programmés chaque jour depuis le
///    cache local de l'emploi du temps (`/schedule/my` répliqué, donc
///    utilisable hors-ligne) :
///      - 2 minutes avant le début : rappel du cours + « pensez à vérifier
///        la présence des élèves » ;
///      - à l'heure de début : le cours commence, vérifier la présence ;
///      - 5 minutes avant la fin : le créneau se termine.
///    Programmation système (zonedSchedule) : survit à la fermeture de l'app.
///
/// 2. **Suivi de la validation des notes** — après chaque synchronisation,
///    `GET /grades/modifications` est comparé à l'instantané précédent :
///      - enseignant : « votre modification a été validée / rejetée » ;
///      - admin : « N modification(s) en attente de validation ».
library;

import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../features/connections/connection_state.dart';
import '../../features/connections/server_profiles.dart';
import '../auth/auth_state.dart';
import '../auth/teacher_scope.dart';
import '../network/api_endpoints.dart';
import '../network/api_exceptions.dart';
import '../network/dio_client.dart';
import '../sync/sync_engine.dart' show SyncResult;
import '../../shared/models/grade_dto.dart';

/// Intervalle minimal entre deux vérifications de modifications (5 min).
const Duration _modsCheckThrottle = Duration(minutes: 5);

/// Réglages de notifications (persistés dans SharedPreferences).
///
/// [Fix-NOTIFS] Les notifications « utiles et nécessaires » seulement :
/// chaque famille peut être désactivée depuis Paramètres.
class NotificationSettings {
  NotificationSettings._({
    required this.courseReminders,
    required this.gradesValidation,
    required this.syncUpdates,
  });

  /// Rappels de cours (enseignants) : 2 min avant, début, fin de créneau.
  final bool courseReminders;

  /// Suivi de la validation des notes (admin : nouvelles propositions ;
  /// enseignant : décisions reçues).
  final bool gradesValidation;

  /// Résultat des synchronisations (éléments reçus/envoyés, envoi de
  /// l'outbox après une période hors-ligne).
  final bool syncUpdates;

  static const _kCourse = 'getech.notif.course_reminders';
  static const _kGrades = 'getech.notif.grades_validation';
  static const _kSync = 'getech.notif.sync_updates';

  static Future<NotificationSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return NotificationSettings._(
      courseReminders: prefs.getBool(_kCourse) ?? true,
      gradesValidation: prefs.getBool(_kGrades) ?? true,
      syncUpdates: prefs.getBool(_kSync) ?? true,
    );
  }

  Future<void> save({
    bool? courseReminders,
    bool? gradesValidation,
    bool? syncUpdates,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (courseReminders != null) {
      await prefs.setBool(_kCourse, courseReminders);
    }
    if (gradesValidation != null) {
      await prefs.setBool(_kGrades, gradesValidation);
    }
    if (syncUpdates != null) {
      await prefs.setBool(_kSync, syncUpdates);
    }
  }
}

/// Provider des réglages de notifications.
final notificationSettingsProvider =
    FutureProvider<NotificationSettings>((ref) => NotificationSettings.load());

class NotificationService {
  NotificationService(this._ref);

  final Ref _ref;

  FlutterLocalNotificationsPlugin? _plugin;
  bool _timezoneReady = false;
  bool _initialized = false;

  /// Initialise le plugin, les fuseaux horaires et les permissions.
  Future<bool> init() async {
    if (_initialized) return _plugin != null;
    _initialized = true;

    if (!_timezoneReady) {
      tzdata.initializeTimeZones();
      try {
        tz.setLocalLocation(tz.getLocation('Africa/Lome'));
      } catch (_) {
        // Fuseau par défaut — les rappels restent corrects à ~1h près.
      }
      _timezoneReady = true;
    }

    final plugin = FlutterLocalNotificationsPlugin();
    const androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const settings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    );
    final ok = await plugin.initialize(settings);
    if (ok != true) {
      _plugin = null;
      return false;
    }
    _plugin = plugin;

    // Android 13+ : permission POST_NOTIFICATIONS.
    try {
      await plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (_) {}
    return true;
  }

  // ---------------------------------------------------------------------------
  // 1. Rappels de cours (enseignants)
  // ---------------------------------------------------------------------------

  /// (Re)programme les rappels du jour pour l'enseignant connecté.
  ///
  /// Idempotent : annule toutes les notifications « cours » puis ne
  /// reprogramme que les créneaux à venir (dans plus de 60 s).
  /// Retourne le nombre de notifications programmées.
  Future<int> scheduleTodayCourseReminders() async {
    final auth = _ref.read(authProvider);
    if (!auth.isAuthenticated) return 0;
    // [Fix-NOTIFS] respecte le réglage utilisateur.
    final settings = await NotificationSettings.load();
    if (!settings.courseReminders) return 0;
    final scope = _ref.read(teacherScopeProvider).valueOrNull;
    final isTeacher =
        auth.hasDeclaredTeacherRole || (scope != null && scope.isTeacher);
    if (!isTeacher || scope == null) return 0;

    final ready = await init();
    if (!ready || _plugin == null) return 0;
    await _plugin!.cancelAll();

    final now = DateTime.now();
    final today = now.weekday; // 1 = lundi … 7 = dimanche
    if (today > 6) return 0; // dimanche : pas de cours

    final weekType = await WeekTypeHelper.currentWeekType(_ref);

    final scheduled = <_CourseReminder>[];
    for (final course in scope.mySchedule) {
      if (course.dayOfWeek != today) continue;
      // Semaines alternées : « toutes semaines » (week_type null) a toujours
      // lieu ; sinon uniquement si la semaine du jour correspond.
      if (!course.isAllWeeks &&
          weekType != null &&
          course.weekType != weekType) {
        continue;
      }

      final start = _parseHm(course.startTime);
      final end = _parseHm(course.endTime);
      if (start == null) continue;

      final startDt = DateTime(now.year, now.month, now.day, start.$1, start.$2);
      DateTime? endDt;
      if (end != null) {
        endDt = DateTime(now.year, now.month, now.day, end.$1, end.$2);
      }

      final subject = course.subjectName ?? 'Cours';
      final classroom = course.classroomName ?? '';
      final room = course.room;

      // a) 2 min avant le début.
      final t2 = startDt.subtract(const Duration(minutes: 2));
      if (t2.isAfter(now.add(const Duration(seconds: 60)))) {
        scheduled.add(_CourseReminder(
          t2,
          'Cours dans 2 minutes',
          '$subject — $classroom'
          '${room != null && room.isNotEmpty ? ' (salle $room)' : ''}. '
          'Au démarrage, pensez à vérifier la présence des élèves.',
        ));
      }

      // b) à l'heure : vérifier la présence.
      if (startDt.isAfter(now.add(const Duration(seconds: 60)))) {
        scheduled.add(_CourseReminder(
          startDt,
          'Le cours commence',
          '$subject ($classroom) : vérifiez la présence des élèves avant '
          'de démarrer.',
        ));
      }

      // c) 5 min avant la fin.
      if (endDt != null) {
        final tEnd = endDt.subtract(const Duration(minutes: 5));
        if (tEnd.isAfter(now.add(const Duration(seconds: 60)))) {
          scheduled.add(_CourseReminder(
            tEnd,
            'Créneau bientôt terminé',
            'Votre créneau de $subject ($classroom) se termine dans 5 minutes.',
          ));
        }
      }
    }

    for (final r in scheduled) {
      await _zonedSchedule(
        id: _stableId(r.when, r.title),
        title: r.title,
        body: r.body,
        when: r.when,
      );
    }
    return scheduled.length;
  }

  static (int, int)? _parseHm(String? s) {
    if (s == null) return null;
    final parts = s.split(':');
    if (parts.length < 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return (h, m);
  }

  /// Id stable (année, jour de l'année, heure, type) : permet
  /// d'annuler/reprogrammer sans fuite ni collision.
  int _stableId(DateTime when, String title) {
    final dayOfYear = when.difference(DateTime(when.year)).inDays;
    final timeHash = when.hour * 60 + when.minute;
    final titleHash = title.length;
    return (when.year % 100) * 10000000 +
        dayOfYear * 10000 +
        timeHash * 10 +
        (titleHash % 10);
  }

  Future<void> _zonedSchedule({
    required int id,
    required String title,
    required String body,
    required DateTime when,
  }) async {
    final plugin = _plugin;
    if (plugin == null) return;
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'getech_sms_cours',
        'Rappels de cours',
        channelDescription: 'Rappels avant le début et la fin de vos cours',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );
    final tzWhen = tz.TZDateTime.from(when, tz.local);

    // Exact si possible (Android 12+ SCHEDULE_EXACT_ALARM) ; repli inexact.
    try {
      await plugin.zonedSchedule(
        id,
        title,
        body,
        tzWhen,
        details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (_) {
      try {
        await plugin.zonedSchedule(
          id,
          title,
          body,
          tzWhen,
          details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
        );
      } catch (_) {
        // Silencieux : les rappels sont un confort, jamais bloquants.
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 2. Suivi de la validation des notes (après synchro)
  // ---------------------------------------------------------------------------

  /// Vérifie les modifications de notes et notifie les changements.
  ///
  /// [Fix-NOTIFS] Plus de répétition : l'admin n'est notifié que quand le
  /// nombre de propositions en attente AUGMENTE (nouvelles propositions) —
  /// l'ancienne version notifiait « N en attente » à chaque synchro tant
  /// qu'il restait des propositions non traitées (spam ressenti comme des
  /// « notifications de développement »). L'enseignant est notifié des
  /// décisions (validée/rejetée) sur ses propositions.
  Future<void> maybeCheckGradeModifications({bool force = false}) async {
    final auth = _ref.read(authProvider);
    final conn = _ref.read(connectionProvider);
    if (!auth.isAuthenticated || conn.serverUrl == null) return;
    if (!conn.canReachServer && !conn.isChecking) return;

    // [Fix-NOTIFS] respecte le réglage utilisateur.
    final settings = await NotificationSettings.load();
    if (!settings.gradesValidation) return;

    final prefs = await SharedPreferences.getInstance();
    final pid = _ref.read(activeProfileIdProvider) ?? conn.profileId;
    final snapshotKey = 'getech.grade_mods_snapshot.${pid ?? 'default'}';
    final throttleKey = 'getech.grade_mods_lastcheck.${pid ?? 'default'}';
    final pendingCountKey =
        'getech.grade_mods_pending_count.${pid ?? 'default'}';
    if (!force) {
      final last = DateTime.tryParse(prefs.getString(throttleKey) ?? '');
      if (last != null &&
          DateTime.now().difference(last) < _modsCheckThrottle) {
        return;
      }
    }
    await prefs.setString(throttleKey, DateTime.now().toIso8601String());

    try {
      final dio = _ref.read(dioProvider);
      final isAdmin = auth.isAdminOrHeadmaster;
      final resp = await dio.get(
        buildUrl(conn.serverUrl!, ApiEndpoints.gradesModifications),
        queryParameters: {
          if (!isAdmin) 'mine': 'true',
          'limit': 200,
        },
      );
      final rows = ((resp.data as List?) ?? const [])
          .whereType<Map>()
          .map((e) => GradeModificationListDto.fromJson(
              Map<String, dynamic>.from(e)))
          .toList();

      // Instantané précédent {id: status}.
      final raw = prefs.getString(snapshotKey);
      final previous = <int, String>{};
      if (raw != null) {
        try {
          final m = jsonDecode(raw) as Map;
          m.forEach((k, v) {
            previous[int.tryParse(k.toString()) ?? -1] = v.toString();
          });
        } catch (_) {}
      }

      var approved = 0;
      var rejected = 0;
      final next = <int, String>{};
      for (final m in rows) {
        next[m.id] = m.status;
        final before = previous[m.id];
        if (before == m.status) continue;
        if (m.status == 'APPROVED' && before != null) approved++;
        if (m.status == 'REJECTED' && before != null) rejected++;
      }
      await prefs.setString(
          snapshotKey, jsonEncode(next.map((k, v) => MapEntry('$k', v))));

      if (isAdmin) {
        final pending = rows.where((m) => m.status == 'PENDING').length;
        // [Fix-NOTIFS] notification sur TRANSITION uniquement : notifier
        // seulement si le nombre d'attentes AUGMENTE (nouvelles
        // propositions). Une baisse (décisions traitées) ou une stabilité
        // ne notifie plus.
        final previousPending = prefs.getInt(pendingCountKey) ?? 0;
        await prefs.setInt(pendingCountKey, pending);
        if (pending > previousPending) {
          final newOnes = pending - previousPending;
          await showNow(
            'modifications-pending',
            'Nouvelles modifications de notes',
            '$newOnes nouvelle(s) proposition(s) de note(s) à valider '
            '($pending au total). Ouvrez le module Notes du serveur pour '
            'les accorder ou les rejeter.',
          );
        }
      } else if (approved > 0 || rejected > 0) {
        final parts = <String>[
          if (approved > 0) '$approved validée(s)',
          if (rejected > 0) '$rejected rejetée(s)',
        ];
        await showNow(
          'modifications-decided',
          'Vos modifications de notes',
          'Mise à jour : ${parts.join(' et ')}. '
          'Consultez le module Notes pour le détail.',
        );
      }
    } on ApiException catch (_) {
      // Serveur sans patch : silencieux.
    } catch (_) {
      // Best-effort.
    }
  }

  // ---------------------------------------------------------------------------
  // 3. Résultat de synchronisation (notification utile)
  // ---------------------------------------------------------------------------

  /// Notifie le résultat d'une synchronisation — uniquement quand quelque
  /// chose a réellement bougé (éléments reçus, envoyés, ou erreurs).
  ///
  /// [Fix-NOTIFS] Remplace les messages répétitifs par une information
  /// actionnable : « X élément(s) reçu(s), Y envoyé(s) » ou, en cas
  /// d'échec, le nombre d'erreurs avec invitation à réessayer.
  Future<void> notifySyncResult(SyncResult result) async {
    // Respecte le réglage utilisateur.
    final settings = await NotificationSettings.load();
    if (!settings.syncUpdates) return;

    if (!result.isSuccess) {
      await showNow(
        'sync-failed',
        'Synchronisation incomplète',
        '${result.errors.length} erreur(s) pendant la synchronisation. '
        'Vos modifications locales sont conservées et seront renvoyées '
        'à la prochaine tentative.',
      );
      return;
    }
    if (result.pulled > 0 || result.pushed > 0) {
      final parts = <String>[
        if (result.pulled > 0) '${result.pulled} reçu(s)',
        if (result.pushed > 0) '${result.pushed} envoyé(s)',
      ];
      await showNow(
        'sync-done',
        'Synchronisation terminée',
        'Vos données sont à jour (${parts.join(' · ')}).',
      );
    }
  }

  /// Affiche une notification immédiate (hors rappels programmés).
  Future<void> showNow(String tag, String title, String body) async {
    final ready = await init();
    if (!ready || _plugin == null) return;
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'getech_sms_general',
        'Informations GeTech-SMS',
        channelDescription: 'Validation des notes et informations',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );
    try {
      await _plugin!.show(tag.hashCode, title, body, details);
    } catch (_) {}
  }
}

class _CourseReminder {
  const _CourseReminder(this.when, this.title, this.body);
  final DateTime when;
  final String title;
  final String body;
}

/// Provider du service de notifications.
final notificationServiceProvider = Provider<NotificationService>(
  (ref) => NotificationService(ref),
);

/// Programme les rappels du jour dès que le scope enseignant est résolu
/// (données de l'emploi du temps disponibles, y compris hors-ligne).
final courseRemindersSchedulerProvider = FutureProvider<int>((ref) async {
  final auth = ref.watch(authProvider);
  if (!auth.isAuthenticated) return 0;
  final scopeAsync = ref.watch(teacherScopeProvider);
  // Attend que le scope ait tranché (enseignant ou non) avant de programmer.
  return scopeAsync.maybeWhen(
    data: (scope) => ref
        .read(notificationServiceProvider)
        .scheduleTodayCourseReminders(),
    orElse: () => 0,
  );
});
