/// [Présence-V9] Sélection par défaut intelligente de la page Présence :
/// classe, cours (créneau en cours ou à venir) et semaine A/B sont
/// pré-sélectionnés d'après l'emploi du temps enseignant et l'heure
/// courante — l'utilisateur n'a plus à choisir manuellement au quotidien.
///
/// Logique PURE (sans Widget/Ref) : testable unitairement
/// (`test/presence_v9_test.dart`).
library;

import '../../core/auth/teacher_scope.dart';
import '../../core/config/constants.dart' show WeekType;
import '../../shared/models/attendance_dto.dart';
import '../../shared/models/classroom_dto.dart';

/// « HH:mm » → (heure, minute) ; null si non parsable.
(int, int)? parseHm(String? s) {
  if (s == null) return null;
  final parts = s.split(':');
  if (parts.length < 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  return (h, m);
}

/// Cours présélectionné parmi [dayCourses] (triés par heure de début) :
/// - aujourd'hui ([date] = jour de [now]) → 1er créneau NON TERMINÉ
///   (en cours ou à venir) ;
/// - autre date → 1er créneau de la journée ;
/// - journée terminée → dernier créneau (rattrapage).
WeeklyScheduleDto? autoCourseFor(
  List<WeeklyScheduleDto> dayCourses, {
  required DateTime date,
  required DateTime now,
}) {
  if (dayCourses.isEmpty) return null;
  final isToday = date.year == now.year &&
      date.month == now.month &&
      date.day == now.day;
  if (!isToday) return dayCourses.first;

  for (final c in dayCourses) {
    final end = parseHm(c.endTime);
    if (end == null) {
      // Fin inconnue : créneau « à venir » tant qu'il n'a pas commencé.
      final start = parseHm(c.startTime);
      if (start == null) continue;
      final startDt = DateTime(now.year, now.month, now.day, start.$1, start.$2);
      if (!startDt.isBefore(now)) return c;
      continue;
    }
    final endDt = DateTime(now.year, now.month, now.day, end.$1, end.$2);
    if (!endDt.isBefore(now)) return c; // en cours ou à venir.
  }
  return dayCourses.last; // journée finie → dernier créneau.
}

/// Classe présélectionnée : celle du créneau EN COURS ou À VENIR
/// aujourd'hui dans l'emploi du temps ENSEIGNANT ([scope]), parmi les
/// classes disponibles [classList] — null si introuvable (l'appelant
/// prendra la 1re classe de la liste, comportement historique).
int? defaultClassroomId(
  List<ClassroomDto> classList,
  TeacherScope? scope,
  DateTime now, {
  required WeekType effectiveWeek,
}) {
  if (scope == null || !scope.isTeacher || scope.isAdminOrHeadmaster) {
    return null;
  }
  final courses = scope.coursesForDate(now, currentWeek: effectiveWeek);
  final ids = classList.map((c) => c.id).toSet();
  for (final c in courses) {
    final cid = c.classroomId;
    if (cid == null) continue;
    final end = parseHm(c.endTime);
    final start = parseHm(c.startTime);
    if (end != null) {
      final endDt = DateTime(now.year, now.month, now.day, end.$1, end.$2);
      if (endDt.isBefore(now)) continue; // créneau terminé.
    } else if (start != null) {
      final startDt = DateTime(now.year, now.month, now.day, start.$1, start.$2);
      if (startDt.isBefore(now)) continue;
    }
    if (ids.contains(cid)) return cid; // en cours ou à venir.
  }
  return null;
}
