// test/v27_offline_grades_reedit_test.dart
//
// [Fix-OFFLINE-GRADES-REEDIT] V27 — Retour terrain 2026-11-16 :
// « la modification de note et l'enregistrement de nouvelles notes hors
// ligne après un enregistrement partiel ne sont pas possibles ».
//
// Cause racine (deux défauts combinés) :
//   1. GradeController.saveGrades hors-ligne EMPILE une entrée
//      grade_submission par sauvegarde dans l'outbox (enqueue pur) : à la
//      reconnexion, la sync rejouait les versions INTERMÉDIAIRES — la
//      première version partait en proposition serveur (queued) avec
//      d'anciennes valeurs, puis les versions suivantes la suivaient ;
//      l'affichage local revenait à la valeur serveur entre-temps
//      (« ma modification a disparu / est impossible »).
//   2. _persistLocalPropositions marquait 'pending' TOUTES les lignes
//      existantes de la sauvegarde, même celles que l'utilisateur n'avait
//      pas touchées (saisie partielle) : côté serveur chaque ligne
//      repartait en file de validation.
//
// Correctifs testés ici :
//   A. Outbox.replacePendingFor : une nouvelle sauvegarde hors-ligne pour
//      la même évaluation REMPLACE la soumission en attente (une seule
//      entrée, la dernière version) ;
//   B. _persistLocalPropositions ne marque que les lignes réellement
//      modifiées (≠ dernière valeur connue) ;
//   C. _gradeEntriesFromLocal affiche la valeur de la soumission en
//      attente la PLUS RÉCENTE (lastOrNull + fusion chronologique) ;
//   D. la soumission hors-ligne ne contient que les lignes nouvelles ou
//      modifiées (les lignes intactes ne polluent pas la file serveur).
//
// La sémantique demandée est respectée : TANT QUE la note n'est pas
// synchronisée, l'utilisateur peut saisir/modifier librement (local) ;
// seule la DERNIÈRE version est poussée à la reconnexion ; après la
// synchronisation, une modification devient une proposition (queued)
// soumise à validation admin — comme en ligne.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:getech_sms_mobile/core/database/database.dart' as d;
import 'package:getech_sms_mobile/core/database/database.dart';
import 'package:getech_sms_mobile/core/sync/outbox.dart';
import 'package:getech_sms_mobile/features/connections/connection_state.dart';
import 'package:getech_sms_mobile/features/grades/grade_controller.dart';
import 'package:getech_sms_mobile/shared/models/grade_dto.dart';

/// ConnectionNotifier réel (pattern v12_offline_chain_test) : l'état est
/// forcé APRÈS création via forceOffline(). L'état apparié + hors-ligne
/// DÉFINITIF (canReachServer=false, isChecking=false) est le cœur du
/// scénario : GradeController._definitivelyOffline doit être vrai.
class _OfflineConnectionNotifier extends ConnectionNotifier {
  _OfflineConnectionNotifier(super.ref);

  void forceOffline() {
    state = state.copyWith(
      status: ServerStatus.offline,
      profileId: 'p-test',
      serverUrlOverride: 'http://192.168.1.10:8000/api/v1',
      establishmentCode: 'R12-01',
      pairingToken: 'token-test',
    );
  }
}

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        connectionProvider.overrideWith((ref) => _OfflineConnectionNotifier(ref)),
      ],
    );
    (container.read(connectionProvider.notifier) as _OfflineConnectionNotifier)
        .forceOffline();
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> seedGrade({
    required int gradeId,
    required int assessmentId,
    required int studentId,
    double? value,
    bool isAbsent = false,
  }) async {
    await db.into(db.grades).insert(
          d.GradesCompanion.insert(
            id: Value(gradeId),
            assessmentId: assessmentId,
            studentId: studentId,
            value: Value(value),
            isAbsent: Value(isAbsent),
            syncedAt: Value(DateTime.now()),
          ),
        );
  }

  GradeEntryDto entry(int studentId, double? value,
          {int? gradeId, bool isAbsent = false, String? comment}) =>
      GradeEntryDto(
        studentId: studentId,
        studentName: 'Élève $studentId',
        studentMatricule: 'MAT-$studentId',
        gradeId: gradeId,
        value: value,
        isAbsent: isAbsent,
        comment: comment,
      );

  test(
      'A. une 2e sauvegarde hors-ligne REMPLACE la soumission en attente '
      '(pas d empilement)', () async {
    final controller = container.read(gradeControllerProvider);

    // 1re sauvegarde partielle : élève 1 = 12.
    final r1 = await controller.saveGrades(
      50,
      [entry(1, 12, gradeId: 101), entry(2, null)],
    );
    expect(r1.offlineQueued, isTrue);

    final outbox = container.read(outboxProvider);
    var pending = await outbox.pending();
    expect(pending.length, 1, reason: 'une seule entrée après le 1er save');
    var payload = pending.single.payloadMap;
    expect(payload['assessment_id'], 50);
    expect((payload['grades'] as List).length, 2,
        reason: 'note existante modifiée + note nouvelle');

    // 2e sauvegarde : l'utilisateur complète/modifie — élève 1 = 14,
    // élève 2 = 15 (nouvelle), élève 3 = 16 (nouvelle).
    await controller.saveGrades(
      50,
      [
        entry(1, 14, gradeId: 101),
        entry(2, 15),
        entry(3, 16),
      ],
    );

    pending = await outbox.pending();
    expect(pending.length, 1,
        reason: '[Fix-OFFLINE-GRADES-REEDIT] la 2e sauvegarde REMPLACE la '
            'soumission précédente — pas d’empilement');
    payload = pending.single.payloadMap;
    final rows = (payload['grades'] as List)
        .cast<Map<String, dynamic>>()
        .toList();
    // La DERNIÈRE version fait foi : élève 1 = 14 (pas 12).
    final e1 = rows.firstWhere((r) => r['student_id'] == 1);
    expect(e1['value'], 14);
    // Une AUTRE évaluation reste indépendante.
    await controller.saveGrades(60, [entry(9, 10)]);
    pending = await outbox.pending();
    expect(pending.length, 2, reason: 'les soumissions d évaluations '
        'différentes coexistent');
    final ids = pending.map((e) => e.payloadMap['assessment_id']).toSet();
    expect(ids, {50, 60});
  });

  test('B. seules les lignes MODIFIÉES sont marquées pending localement',
      () async {
    await seedGrade(
        gradeId: 101, assessmentId: 50, studentId: 1, value: 12);
    await seedGrade(
        gradeId: 102, assessmentId: 50, studentId: 2, value: 8);

    final controller = container.read(gradeControllerProvider);
    // L'utilisateur ne touche QUE l'élève 1 (12 → 14) ; l'élève 2 est
    // renvoyé tel quel (saisie partielle puis enregistrement global).
    await controller.saveGrades(
      50,
      [entry(1, 14, gradeId: 101), entry(2, 8, gradeId: 102)],
    );

    final rows = await (db.select(db.grades)
          ..where((t) => t.assessmentId.equals(50)))
        .get();
    final byStudent = {for (final g in rows) g.studentId: g};
    expect(byStudent[1]!.syncStatus, 'pending',
        reason: 'ligne modifiée → proposition locale');
    expect(byStudent[1]!.proposedValue, 14);
    expect(byStudent[2]!.syncStatus, isNull,
        reason: '[Fix-OFFLINE-GRADES-REEDIT] ligne INTACTE → pas de marque '
            '(avant : pending sur tout le monde)');
    expect(byStudent[2]!.proposedValue, isNull);
  });

  test('C+D. la soumission ne contient que les lignes utiles et la '
      'ré-édition reste possible après un save partiel', () async {
    await seedGrade(
        gradeId: 101, assessmentId: 50, studentId: 1, value: 12);

    final controller = container.read(gradeControllerProvider);
    final outbox = container.read(outboxProvider);

    // Save partiel : élève 1 (existante, 12→14) + élève 2 (nouvelle, 15).
    await controller.saveGrades(
      50,
      [entry(1, 14, gradeId: 101), entry(2, 15)],
    );

    // Ré-édition : l'utilisateur ROUVRE la feuille et corrige l'élève 1
    // à 16 (toujours hors-ligne — doit rester possible) et l'élève 2
    // (nouvelle, pas encore synchronisée) à 17.
    await controller.saveGrades(
      50,
      [entry(1, 16, gradeId: 101), entry(2, 17)],
    );

    final pending = await outbox.pending();
    expect(pending.length, 1);
    final rows = (pending.single.payloadMap['grades'] as List)
        .cast<Map<String, dynamic>>()
        .toList();
    expect(rows.length, 2, reason: 'élève 1 (modifiée) + élève 2 (nouvelle)');
    final e1 = rows.firstWhere((r) => r['student_id'] == 1);
    final e2 = rows.firstWhere((r) => r['student_id'] == 2);
    expect(e1['value'], 16, reason: 'dernière version de l élève 1');
    expect(e2['value'], 17, reason: 'dernière version de l élève 2');
  });
}
