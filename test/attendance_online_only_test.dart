// test/attendance_online_only_test.dart
//
// [Fix-PRESENCE-ONLINE] Règle métier : la présence n'est saisie qu'en
// connexion au serveur. Toute mutation du module Présence doit être refusée
// (ApiException explicite, aucune mise en file d'attente hors-ligne) tant
// que [ConnectionState.canReachServer] est faux — y compris pendant le
// heartbeat initial (« checking »), qui est un état indéterminé.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:getech_sms_mobile/core/network/api_exceptions.dart';
import 'package:getech_sms_mobile/features/attendance/attendance_controller.dart';
import 'package:getech_sms_mobile/features/connections/connection_state.dart';
import 'package:getech_sms_mobile/shared/models/attendance_dto.dart';

/// État appairé (serveur configuré + token) avec le statut demandé.
ConnectionState _paired(ServerStatus status, {bool forceOffline = false}) =>
    ConnectionState(
      status: status,
      profileId: 'p-test',
      serverUrlOverride: 'http://192.168.1.10:8000/api/v1',
      establishmentCode: 'EST-TEST',
      pairingToken: 'token-test',
      forceOffline: forceOffline,
    );

const _absence = StudentAbsenceDto(
  courseSessionId: 1,
  studentId: 42,
  studentName: 'DUPONT Jean',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // ConnectionNotifier._init() lit SharedPreferences au démarrage :
    // mock requis pour un test hors plateforme.
    SharedPreferences.setMockInitialValues({});
  });

  final cases = <String, ConnectionState>{
    'non appairé': const ConnectionState(),
    'heartbeat en cours (checking)': _paired(ServerStatus.checking),
    'serveur injoignable (offline)': _paired(ServerStatus.offline),
    'mode hors-ligne forcé': _paired(ServerStatus.online, forceOffline: true),
  };

  for (final entry in cases.entries) {
    group('connexion non établie — ${entry.key}', () {
      late ProviderContainer container;
      late AttendanceController controller;

      setUp(() {
        container = ProviderContainer();
        addTearDown(container.dispose);
        // Force l'état de connexion SANS passer par applyProfile (qui
        // lancerait un heartbeat réel).
        container.read(connectionProvider.notifier).state = entry.value;
        controller = container.read(attendanceControllerProvider);
      });

      test('démarrage de session refusé', () {
        expect(
          () => controller.startSession(
            classroomId: 1,
            date: DateTime(2026, 10, 10),
          ),
          throwsA(
            isA<ApiException>().having(
              (e) => e.message,
              'message',
              contains('connexion au serveur'),
            ),
          ),
        );
      });

      test('enregistrement des absences refusé', () {
        expect(
          () => controller.saveAbsences(1, const [_absence]),
          throwsA(
            isA<ApiException>().having(
              (e) => e.message,
              'message',
              contains('connexion au serveur'),
            ),
          ),
        );
      });

      test('changement d\'état de session refusé', () {
        expect(
          () => controller.markSessionState(1, 'completed'),
          throwsA(
            isA<ApiException>().having(
              (e) => e.message,
              'message',
              contains('connexion au serveur'),
            ),
          ),
        );
      });

      test('cahier de texte refusé', () {
        expect(
          () => controller.saveLessonRecord(
            sessionId: 1,
            content: 'Chapitre 3 — exercices 1 à 5',
          ),
          throwsA(
            isA<ApiException>().having(
              (e) => e.message,
              'message',
              contains('connexion au serveur'),
            ),
          ),
        );
      });
    });
  }
}
