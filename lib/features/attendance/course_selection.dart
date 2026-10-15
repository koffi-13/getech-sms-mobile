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

// ---------------------------------------------------------------------------
// [Présence-V10] Groupes de cours jumelés (chevauchements de créneaux)
// ---------------------------------------------------------------------------

/// Minutes depuis minuit (« HH:mm » → int) ; null si non parsable.
int? _minutes(String? s) {
  final hm = parseHm(s);
  if (hm == null) return null;
  return hm.$1 * 60 + hm.$2;
}

/// Groupe de cours d'un même créneau : 1 cours normal, ou PLUSIEURS cours
/// qui se chevauchent (l'enseignant a JUMELÉ les classes — il fait cours
/// aux deux classes en même temps).
class CourseGroup {
  final List<WeeklyScheduleDto> courses;
  const CourseGroup(this.courses);

  /// Heure de début du groupe (min depuis minuit).
  int get startMinutes =>
      courses.map((c) => _minutes(c.startTime) ?? 0).reduce((a, b) => a < b ? a : b);

  /// Heure de fin du groupe (max des fins).
  int get endMinutes =>
      courses.map((c) => _minutes(c.endTime) ?? 0).reduce((a, b) => a > b ? a : b);

  bool get isMerged => courses.length > 1;

  /// Libellé des classes du groupe : « 6A » ou « 6A + 6B » (jumelées).
  String get classroomLabel {
    final names = courses
        .map((c) => c.classroomName ?? 'Classe ${c.classroomId ?? '?'}')
        .toSet()
        .toList()
      ..sort();
    return names.join(' + ');
  }

  /// Matière(s) du groupe (une en général ; les jumelages croisés gardent
  /// les matières distinctes séparées par « / »).
  String get subjectLabel {
    final names = courses
        .map((c) => c.subjectName ?? 'Cours')
        .toSet()
        .toList();
    return names.join(' / ');
  }
}

/// Regroupe les cours d'une journée par chevauchement d'intervalles.
///
/// Deux cours se chevauchent si `startA < finB` ET `startB < finA`
/// (l'appartenance à un groupe est transitive). Un chevauchement =
/// l'enseignant a JUMELÉ les classes : elles forment UN seul créneau.
List<CourseGroup> groupOverlappingCourses(List<WeeklyScheduleDto> dayCourses) {
  final sorted = [...dayCourses]
    ..sort((a, b) => (_minutes(a.startTime) ?? 0)
        .compareTo(_minutes(b.startTime) ?? 0));
  final groups = <CourseGroup>[];
  final groupEnds = <int>[];

  for (final c in sorted) {
    final start = _minutes(c.startTime);
    final end = _minutes(c.endTime);
    var placed = false;
    for (var i = 0; i < groups.length; i++) {
      // Trié par début : chevauche le groupe s'il commence avant la fin
      // (maximale) du groupe.
      if (start != null && start < groupEnds[i]) {
        groups[i].courses.add(c);
        if (end != null && end > groupEnds[i]) groupEnds[i] = end;
        placed = true;
        break;
      }
    }
    if (!placed) {
      groups.add(CourseGroup([c]));
      groupEnds.add(end ?? start ?? 0);
    }
  }
  return groups;
}

/// Groupe présélectionné selon « l'heure qui sonne » :
/// - le groupe dont le CRÉNEAU CONTIENT l'heure courante ;
/// - sinon le prochain groupe à venir (premier créneau non terminé) ;
/// - sinon le dernier groupe de la journée (rattrapage) ;
/// - null si aucun cours.
CourseGroup? autoCourseGroup(
  List<CourseGroup> groups, {
  required DateTime now,
}) {
  if (groups.isEmpty) return null;
  final nowMinutes = now.hour * 60 + now.minute;
  for (final g in groups) {
    if (nowMinutes >= g.startMinutes && nowMinutes < g.endMinutes) {
      return g; // l'heure qui sonne est DANS ce créneau.
    }
  }
  for (final g in groups) {
    if (nowMinutes < g.startMinutes) return g; // prochain créneau.
  }
  return groups.last; // journée finie → rattrapage.
}
