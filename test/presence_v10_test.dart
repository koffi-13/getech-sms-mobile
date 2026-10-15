/// [Présence-V10] Tests unitaires de la logique pure de la page Présence :
/// - regroupement des cours JUMELÉS (chevauchement d'intervalles) ;
/// - sélection du créneau « heure qui sonne » (intervalle contenant l'heure
///   courante, sinon prochain créneau, sinon rattrapage).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:getech_sms_mobile/core/config/constants.dart';
import 'package:getech_sms_mobile/features/attendance/course_selection.dart' as smart;
import 'package:getech_sms_mobile/shared/models/attendance_dto.dart';

WeeklyScheduleDto _course(
  int id, {
  required int dayOfWeek,
  required String start,
  required String end,
  int? classroomId,
  String? classroomName,
  String? subjectName,
}) =>
    WeeklyScheduleDto(
      id: id,
      classroomId: classroomId,
      classroomName: classroomName,
      subjectName: subjectName,
      timeSlotId: id * 10,
      dayOfWeek: dayOfWeek,
      startTime: start,
      endTime: end,
    );

void main() {
  group('[Présence-V10] classes jumelées (chevauchements)', () {
    test('groupOverlappingCourses : cours disjoints → groupes séparés', () {
      final groups = smart.groupOverlappingCourses([
        _course(1, dayOfWeek: 1, start: '08:00', end: '10:00'),
        _course(2, dayOfWeek: 1, start: '10:00', end: '12:00'),
        _course(3, dayOfWeek: 1, start: '15:00', end: '17:00'),
      ]);
      expect(groups.length, 3);
      expect(groups.every((g) => !g.isMerged), isTrue);
    });

    test('groupOverlappingCourses : chevauchement → UN groupe jumelé', () {
      // L'enseignant a 6A ET 6B sur le même créneau → classes jumelées.
      final groups = smart.groupOverlappingCourses([
        _course(1, dayOfWeek: 1, start: '08:00', end: '10:00',
            classroomId: 11, classroomName: '6A', subjectName: 'Maths'),
        _course(2, dayOfWeek: 1, start: '08:00', end: '10:00',
            classroomId: 12, classroomName: '6B', subjectName: 'Maths'),
      ]);
      expect(groups.length, 1);
      expect(groups.first.isMerged, isTrue);
      expect(groups.first.classroomLabel, '6A + 6B');
      expect(groups.first.subjectLabel, 'Maths');
      expect(groups.first.startMinutes, 8 * 60);
      expect(groups.first.endMinutes, 10 * 60);
    });

    test('groupOverlappingCourses : chevauchement partiel transitif', () {
      // 08-10 et 09-12 se chevauchent ; 12-14 touche à peine (fin=début
      // strictement → PAS de chevauchement).
      final groups = smart.groupOverlappingCourses([
        _course(1, dayOfWeek: 2, start: '08:00', end: '10:00'),
        _course(2, dayOfWeek: 2, start: '09:00', end: '12:00'),
        _course(3, dayOfWeek: 2, start: '12:00', end: '14:00'),
      ]);
      expect(groups.length, 2);
      expect(groups.first.isMerged, isTrue); // 1 + 2
      expect(groups.first.endMinutes, 12 * 60); // max des fins.
      expect(groups.last.courses.length, 1); // 3 seul.
    });

    test('groupOverlappingCourses : tri par heure de début', () {
      final groups = smart.groupOverlappingCourses([
        _course(2, dayOfWeek: 3, start: '14:00', end: '16:00'),
        _course(1, dayOfWeek: 3, start: '08:00', end: '10:00'),
      ]);
      expect(groups.first.startMinutes, 8 * 60);
      expect(groups.last.startMinutes, 14 * 60);
    });
  });

  group('[Présence-V10] heure qui sonne (autoCourseGroup)', () {
    final groups = smart.groupOverlappingCourses([
      _course(1, dayOfWeek: 1, start: '08:00', end: '10:00'),
      _course(2, dayOfWeek: 1, start: '10:00', end: '12:00'),
      _course(3, dayOfWeek: 1, start: '15:00', end: '17:00'),
    ]);

    test("l'heure courante DANS le créneau 10-12 → ce créneau", () {
      final now = DateTime(2026, 10, 12, 11, 0);
      final g = smart.autoCourseGroup(groups, now: now);
      expect(g, isNotNull);
      expect(g!.startMinutes, 10 * 60);
    });

    test("l'heure courante ENTRE deux créneaux → le prochain (15-17)", () {
      final now = DateTime(2026, 10, 12, 13, 30);
      final g = smart.autoCourseGroup(groups, now: now);
      expect(g, isNotNull);
      expect(g!.startMinutes, 15 * 60);
    });

    test('journée finie → dernier créneau (rattrapage)', () {
      final now = DateTime(2026, 10, 12, 18, 0);
      final g = smart.autoCourseGroup(groups, now: now);
      expect(g, isNotNull);
      expect(g!.endMinutes, 17 * 60);
    });

    test('avant les cours → premier créneau', () {
      final now = DateTime(2026, 10, 12, 7, 0);
      final g = smart.autoCourseGroup(groups, now: now);
      expect(g, isNotNull);
      expect(g!.startMinutes, 8 * 60);
    });

    test('aucun groupe → null', () {
      expect(smart.autoCourseGroup(const [], now: DateTime.now()), isNull);
    });
  });

  group('[Présence-V10] libellés de groupe', () {
    test('matières distinctes séparées par « / »', () {
      final groups = smart.groupOverlappingCourses([
        _course(1, dayOfWeek: 1, start: '08:00', end: '10:00',
            classroomId: 11, classroomName: '6A', subjectName: 'Maths'),
        _course(2, dayOfWeek: 1, start: '08:00', end: '10:00',
            classroomId: 12, classroomName: '6B', subjectName: 'PC'),
      ]);
      expect(groups.first.subjectLabel, 'Maths / PC');
    });

    test('cours toutes semaines (weekTypeRaw null) parsable', () {
      // Les cours « toutes semaines » (week_type NULL serveur) doivent
      // passer dans le regroupement sans erreur.
      final course = WeeklyScheduleDto(
        id: 1,
        classroomId: 11,
        classroomName: '6A',
        subjectName: 'Maths',
        timeSlotId: 10,
        dayOfWeek: 1,
        startTime: '08:00',
        endTime: '10:00',
        weekTypeRaw: null,
      );
      final groups = smart.groupOverlappingCourses([course]);
      expect(groups.length, 1);
      expect(groups.first.classroomLabel, '6A');
    });
  });
}
