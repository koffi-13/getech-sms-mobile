/// Tests du parsing du classement — [Fix-RANK-PARSE].
///
/// Le serveur renvoie `rank` comme une CHAÎNE ("1", "3 B" avec ex-æquo) et,
/// depuis le patch serveur, `rank_number` (int dédié). L'ancien code mobile
/// faisait `(j['rank'] as num?)` qui plantait en type cast sur "3 B".
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:getech_sms_mobile/shared/models/grade_dto.dart';

void main() {
  group('RankingRowDto.fromJson — parsing du rang', () {
    test('rank_number (int) est utilisé en priorité', () {
      final row = RankingRowDto.fromJson({
        'rank': '3 B',
        'rank_number': 3,
        'student_id': 12,
        'nom': 'DUPONT',
        'prenoms': 'Jean',
      });
      expect(row.rank, 3);
    });

    test('rank en chaîne simple ("1") est toléré', () {
      final row = RankingRowDto.fromJson({
        'rank': '1',
        'student_id': 12,
        'nom': 'DUPONT',
        'prenoms': 'Jean',
      });
      expect(row.rank, 1);
    });

    test('rank en chaîne avec ex-æquo ("3 B") est toléré', () {
      final row = RankingRowDto.fromJson({
        'rank': '3 B',
        'student_id': 12,
        'nom': 'DUPONT',
        'prenoms': 'Jean',
      });
      expect(row.rank, 3);
    });

    test('rank numérique (ancien format) reste supporté', () {
      final row = RankingRowDto.fromJson({
        'rank': 7,
        'student_id': 12,
        'nom': 'DUPONT',
        'prenoms': 'Jean',
      });
      expect(row.rank, 7);
    });

    test('rank absent ou nul → 0 (aucun crash)', () {
      final row = RankingRowDto.fromJson({
        'student_id': 12,
        'nom': 'DUPONT',
        'prenoms': 'Jean',
      });
      expect(row.rank, 0);

      final rowNull = RankingRowDto.fromJson({
        'rank': null,
        'student_id': 12,
        'nom': 'DUPONT',
        'prenoms': 'Jean',
      });
      expect(rowNull.rank, 0);
    });

    test('rank_number nul + rank chaîne → repli sur la chaîne', () {
      final row = RankingRowDto.fromJson({
        'rank': '2',
        'rank_number': null,
        'student_id': 12,
        'nom': 'DUPONT',
        'prenoms': 'Jean',
      });
      expect(row.rank, 2);
    });
  });
}
