// test/blood_type_test.dart
//
// [Fix-BLOODTYPE] Tests du round-trip groupe sanguin.
//
// Contexte : le serveur stocke le CODE ('A+', 'O-'…) mais le DTO mobile
// matchait le NOM d'enum Dart ('aPlus') → aucun match → fallback
// BloodType.inconnu → assertion DropdownButton « There should be exactly
// one item with [DropdownButton]'s value: BloodType.inconnu » à chaque
// ouverture du formulaire de modification d'un élève ayant un groupe
// sanguin renseigné.

import 'package:flutter_test/flutter_test.dart';
import 'package:getech_sms_mobile/core/config/constants.dart';
import 'package:getech_sms_mobile/shared/models/classroom_dto.dart';
import 'package:getech_sms_mobile/shared/models/student_dto.dart';

void main() {
  group('bloodTypeFromCode / bloodTypeToCode', () {
    test('round-trip des 8 groupes par code serveur', () {
      const codes = {
        'A+': BloodType.aPlus,
        'A-': BloodType.aMoins,
        'B+': BloodType.bPlus,
        'B-': BloodType.bMoins,
        'AB+': BloodType.abPlus,
        'AB-': BloodType.abMoins,
        'O+': BloodType.oPlus,
        'O-': BloodType.oMoins,
      };
      codes.forEach((code, expected) {
        expect(bloodTypeFromCode(code), expected, reason: code);
        expect(bloodTypeToCode(expected), code, reason: code);
      });
    });

    test('null / vide / code inconnu → null (JAMAIS BloodType.inconnu)', () {
      expect(bloodTypeFromCode(null), isNull);
      expect(bloodTypeFromCode(''), isNull);
      expect(bloodTypeFromCode('   '), isNull);
      expect(bloodTypeFromCode('XY?'), isNull);
      // L'enum inconnu ne doit jamais être produit.
      expect(bloodTypeFromCode('inconnu'), isNull);
    });

    test('compat anciens enregistrements par nom d\'enum', () {
      expect(bloodTypeFromCode('aPlus'), BloodType.aPlus);
      expect(bloodTypeFromCode('oMoins'), BloodType.oMoins);
    });

    test('bloodTypeToCode(null / inconnu) → null', () {
      expect(bloodTypeToCode(null), isNull);
      expect(bloodTypeToCode(BloodType.inconnu), isNull);
    });
  });

  group('StudentMedicalDto round-trip', () {
    test('fromJson avec code serveur « A+ » → aPlus (pas inconnu)', () {
      final dto = StudentMedicalDto.fromJson({
        'id': 5,
        'blood_type': 'A+',
        'allergies': 'Pollens',
        'doctor': 'Dr Houénou',
      });
      expect(dto.bloodType, BloodType.aPlus);
      expect(dto.allergies, 'Pollens');

      // toJson renvoie le code — symétrique avec le serveur.
      expect(dto.toJson()['blood_type'], 'A+');
    });

    test('fromJson avec groupe inconnu du serveur → null (dropdown sûr)', () {
      final dto = StudentMedicalDto.fromJson({'blood_type': 'ZZ'});
      expect(dto.bloodType, isNull);
      expect(dto.toJson()['blood_type'], isNull);
    });

    test('fromJson sans groupe sanguin → null', () {
      final dto = StudentMedicalDto.fromJson({});
      expect(dto.bloodType, isNull);
    });
  });

  group('ClassroomDto ids tolérants', () {
    test('fromJson avec ids en chaînes numériques', () {
      final dto = ClassroomDto.fromJson({
        'id': '42',
        'name': '2nde A',
        'head_teacher_id': '7',
        'cycle_id': '3',
        'max_students': '40',
        'current_students_count': '12',
      });
      expect(dto.id, 42);
      expect(dto.headTeacherId, 7);
      expect(dto.cycleId, 3);
      expect(dto.maxStudents, 40);
      expect(dto.currentStudentsCount, 12);
    });

    test('fromJson avec ids numériques (contrat nominal)', () {
      final dto = ClassroomDto.fromJson({
        'id': 42,
        'name': '2nde A',
      });
      expect(dto.id, 42);
      expect(dto.headTeacherId, isNull);
    });
  });
}
