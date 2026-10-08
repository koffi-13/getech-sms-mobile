// test/sync_idempotency_test.dart
//
// [Fix-SYNC-IDEMPOTENCE] Tests unitaires pour l'architecture de synchronisation
// offline-first avec idempotency_key + device_uuid.
//
// Adapté au contrat RÉEL de POST /sync/push [Fix-SYNC-PUSH] :
// `{device_token?, lines: [{line_id?, op, table, data}]}` —
// l'enrichissement d'idempotence se fait dans le `data` de chaque ligne.
//
// Couverture :
//   - SyncPushRequest.withIdempotency() enrichit chaque ligne correctement.
//   - Les clés générées sont au format UUID v4 canonique.
//   - Le device_uuid est propagé dans chaque ligne.
//   - Les lignes qui ont déjà une idempotency_key ne sont pas écrasées.
//   - Les lignes sans `data` (Map) sont laissées intactes.
//   - Le fallback sans device_uuid reste rétrocompatible.

import 'package:flutter_test/flutter_test.dart';
import 'package:getech_sms_mobile/shared/models/sync_dto.dart';
import 'package:uuid/uuid.dart';

void main() {
  group('SyncPushRequest.withIdempotency', () {
    test('enrichit chaque ligne avec idempotency_key et device_uuid', () {
      final lines = <Map<String, dynamic>>[
        {
          'line_id': 'l1',
          'op': 'upsert',
          'table': 'grades',
          'data': {'id': 1, 'value': 15.5},
        },
        {
          'line_id': 'l2',
          'op': 'upsert',
          'table': 'grades',
          'data': {'id': 2, 'value': 12.0},
        },
        {
          'line_id': 'l3',
          'op': 'upsert',
          'table': 'student_absences',
          'data': {'id': 1, 'is_justified': true},
        },
      ];

      final request = SyncPushRequest.withIdempotency(
        lines: lines,
        deviceUuid: 'a3f2c1d0-4e5b-4f6a-8c7d-9e0f1a2b3c4d',
        generateIdempotencyKey: _realIdempotencyKey,
      );

      // Vérifier que chaque ligne a reçu idempotency_key + device_uuid
      for (final line in request.lines) {
        final data = line['data'] as Map<String, dynamic>;
        expect(data['idempotency_key'], isNotNull,
            reason: 'idempotency_key manquante dans ${line['table']}');
        expect(data['device_uuid'], 'a3f2c1d0-4e5b-4f6a-8c7d-9e0f1a2b3c4d',
            reason: 'device_uuid manquant dans ${line['table']}');
      }
    });

    test('les idempotency_key générées sont au format UUID v4', () {
      final lines = <Map<String, dynamic>>[
        {
          'line_id': 'l1',
          'op': 'upsert',
          'table': 'grades',
          'data': {'id': 1, 'value': 10.0},
        },
      ];

      final request = SyncPushRequest.withIdempotency(
        lines: lines,
        deviceUuid: 'a3f2c1d0-4e5b-4f6a-8c7d-9e0f1a2b3c4d',
        generateIdempotencyKey: _realIdempotencyKey,
      );

      final data = request.lines.first['data'] as Map<String, dynamic>;
      final key = data['idempotency_key'] as String;
      // Format UUID v4 : 8-4-4-4-12 hex digits, version 4, variant 8/9/a/b.
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(key),
        isTrue,
        reason: 'idempotency_key doit être un UUID v4 canonique, got: $key',
      );
    });

    test('n\'écrase pas une idempotency_key déjà présente', () {
      final existingKey = '11111111-2222-4333-8444-555555555555';
      final lines = <Map<String, dynamic>>[
        {
          'line_id': 'l1',
          'op': 'upsert',
          'table': 'grades',
          'data': {
            'id': 1,
            'value': 10.0,
            'idempotency_key': existingKey,
          },
        },
      ];

      final request = SyncPushRequest.withIdempotency(
        lines: lines,
        deviceUuid: 'a3f2c1d0-4e5b-4f6a-8c7d-9e0f1a2b3c4d',
        generateIdempotencyKey: _realIdempotencyKey,
      );

      final data = request.lines.first['data'] as Map<String, dynamic>;
      expect(data['idempotency_key'], existingKey,
          reason: 'Une idempotency_key déjà présente ne doit pas être écrasée.');
    });

    test('propage le device_uuid dans toutes les tables', () {
      final lines = <Map<String, dynamic>>[
        {
          'op': 'upsert',
          'table': 'grades',
          'data': {'id': 1},
        },
        {
          'op': 'upsert',
          'table': 'student_absences',
          'data': {'id': 1},
        },
        {
          'op': 'upsert',
          'table': 'students',
          'data': {'id': 1},
        },
      ];

      final request = SyncPushRequest.withIdempotency(
        lines: lines,
        deviceUuid: 'test-device-uuid-v4',
        generateIdempotencyKey: _realIdempotencyKey,
      );

      for (final line in request.lines) {
        final data = line['data'] as Map<String, dynamic>;
        expect(data['device_uuid'], 'test-device-uuid-v4',
            reason: 'device_uuid manquant dans la table ${line['table']}');
      }
    });

    test('préserve les autres champs du payload', () {
      final lines = <Map<String, dynamic>>[
        {
          'line_id': 'l1',
          'op': 'upsert',
          'table': 'grades',
          'data': {
            'id': 1,
            'assessment_id': 5,
            'student_id': 10,
            'value': 14.5,
            'is_absent': false,
            'comments': 'Bien',
          },
        },
      ];

      final request = SyncPushRequest.withIdempotency(
        lines: lines,
        deviceUuid: 'dev-uuid',
        generateIdempotencyKey: _realIdempotencyKey,
      );

      final line = request.lines.first;
      expect(line['line_id'], 'l1');
      expect(line['op'], 'upsert');
      expect(line['table'], 'grades');
      final data = line['data'] as Map<String, dynamic>;
      expect(data['id'], 1);
      expect(data['assessment_id'], 5);
      expect(data['student_id'], 10);
      expect(data['value'], 14.5);
      expect(data['is_absent'], false);
      expect(data['comments'], 'Bien');
    });

    test('laisse intactes les lignes sans data (Map)', () {
      final lines = <Map<String, dynamic>>[
        {'line_id': 'l1', 'op': 'delete', 'table': 'grades'}, // pas de data
        {'line_id': 'l2', 'op': 'upsert', 'table': 'grades', 'data': null},
      ];

      final request = SyncPushRequest.withIdempotency(
        lines: lines,
        deviceUuid: 'dev-uuid',
        generateIdempotencyKey: _realIdempotencyKey,
      );

      expect(request.lines.first.containsKey('data'), isFalse);
      expect(request.lines.last['data'], isNull);
    });

    test('toJson produit la structure attendue par le serveur', () {
      final lines = <Map<String, dynamic>>[
        {
          'line_id': 'l1',
          'op': 'upsert',
          'table': 'grades',
          'data': {
            'id': 1,
            'idempotency_key': 'key-1',
            'device_uuid': 'dev-1',
          },
        },
      ];

      final request = SyncPushRequest(lines: lines, deviceToken: 'tok-1');
      final json = request.toJson();

      // Contrat RÉEL du serveur : {device_token?, lines: [...]}.
      expect(json['device_token'], 'tok-1');
      expect(json['lines'], isA<List>());
      expect(json['lines'].length, 1);
      final jsonData = json['lines'].first['data'] as Map<String, dynamic>;
      expect(jsonData['idempotency_key'], 'key-1');
      expect(jsonData['device_uuid'], 'dev-1');
    });
  });

  group('SyncPushRequest rétrocompatible', () {
    test('constructeur simple sans idempotence fonctionne', () {
      final lines = <Map<String, dynamic>>[
        {
          'line_id': 'l1',
          'op': 'upsert',
          'table': 'grades',
          'data': {'id': 1, 'value': 10.0},
        },
      ];

      final request = SyncPushRequest(lines: lines);

      // Pas d'idempotency_key injectée -> rétrocompatible avec l'ancien
      // comportement (le serveur applique LWW classique).
      final data = request.lines.first['data'] as Map<String, dynamic>;
      expect(data.containsKey('idempotency_key'), isFalse);
    });
  });
}

/// Génère un vrai UUID v4 via le package uuid (même que la production).
String _realIdempotencyKey() {
  return const Uuid().v4();
}
