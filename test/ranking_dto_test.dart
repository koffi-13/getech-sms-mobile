// test/ranking_dto_test.dart
//
// [Fix-RANK-CAST] Tests du parsing tolérant des DTOs de notes/classement.
//
// Contexte : le serveur sérialise le rang en CHAÎNE (« 1 », « 3 B » pour les
// ex-æquo) et certaines moyennes (Decimal SQL) peuvent arriver en chaînes.
// L'ancien code castait `as num?` et plantait avec
// « type 'String' is not a subtype of type 'num?' in type cast » pour
// certaines classes seulement (celles avec des notes).

import 'package:flutter_test/flutter_test.dart';
import 'package:getech_sms_mobile/shared/models/grade_dto.dart';

void main() {
  group('RankingRowDto.fromJson', () {
    test('rang chaîne simple (« 1 ») et moyenne numérique', () {
      final row = RankingRowDto.fromJson({
        'rank': '1',
        'student_id': 7,
        'nom': 'ADJE',
        'prenoms': 'Prénom',
        'matricule': 'EST1-2026-0001',
        'average': 14.5,
        'annual_average': 13.0,
      });
      expect(row.rank, 1);
      expect(row.rankLabel, '1');
      expect(row.average, 14.5);
      expect(row.annualAverage, 13.0);
      expect(row.studentId, 7);
    });

    test('rang ex-æquo (« 3 B ») → rang numérique 3 + libellé conservé', () {
      final row = RankingRowDto.fromJson({
        'rank': '3 B',
        'student_id': 8,
        'nom': 'KOFFI',
        'prenoms': '',
        'average': 11.25,
      });
      expect(row.rank, 3);
      expect(row.rankLabel, '3 B');
    });

    test('rank_number (serveur ≥ V5) prioritaire', () {
      final row = RankingRowDto.fromJson({
        'rank': '2',
        'rank_number': 2,
        'student_id': 9,
        'nom': 'DOSSOU',
        'average': 12.75,
      });
      expect(row.rank, 2);
      expect(row.rankLabel, '2');
    });

    test('moyennes en chaînes (Decimal SQL) parsées sans crash', () {
      final row = RankingRowDto.fromJson({
        'rank': '1',
        'student_id': 10,
        'nom': 'AMOUSSOU',
        'average': '12.5000',
        'class_avg': '10.2500',
        'exam_avg': '14.0000',
        'weighted_period_avg': '25.0000',
        'weighted_max_score': '40.0000',
        'annual_average': '12.5000',
      });
      expect(row.average, 12.5);
      expect(row.classAvg, 10.25);
      expect(row.examAvg, 14.0);
      expect(row.weightedPeriodAvg, 25.0);
      expect(row.weightedMaxScore, 40.0);
      expect(row.annualAverage, 12.5);
    });

    test('élève sans note : rangs null → 0 sans crash', () {
      final row = RankingRowDto.fromJson({
        'rank': null,
        'rank_number': null,
        'student_id': 11,
        'nom': 'SANTOS',
        'average': null,
      });
      expect(row.rank, 0);
      expect(row.rankLabel, isNull);
      expect(row.average, isNull);
    });

    test('ids en chaînes tolérés', () {
      final row = RankingRowDto.fromJson({
        'rank': 1,
        'student_id': '12',
        'subject_id': '3',
        'inscription_type_id': '1',
        'nom': 'ZANOU',
      });
      expect(row.studentId, 12);
      expect(row.subjectId, 3);
      expect(row.inscriptionTypeId, 1);
    });

    test('previous_period_averages en Map {id: moyenne}', () {
      final row = RankingRowDto.fromJson({
        'rank': '1',
        'student_id': 13,
        'nom': 'AGBO',
        'average': 15.0,
        'previous_period_averages': {'3': 13.0, '4': 14.5},
      });
      expect(row.previousPeriodAverages[3], 13.0);
      expect(row.previousPeriodAverages[4], 14.5);
    });
  });

  group('Autres DTOs de notes — parsing tolérant', () {
    test('GradeEntryDto.value en chaîne', () {
      final g = GradeEntryDto.fromJson({
        'student_id': 1,
        'student_name': 'Élève',
        'value': '15.5',
        'is_absent': false,
      });
      expect(g.value, 15.5);
    });

    test('AssessmentDto.maxScore en chaîne', () {
      final a = AssessmentDto.fromJson({
        'id': 1,
        'name': 'Devoir',
        'max_score': '20',
      });
      expect(a.maxScore, 20.0);
    });
  });
}
