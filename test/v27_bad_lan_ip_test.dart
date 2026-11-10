// test/v27_bad_lan_ip_test.dart
// Tests [Fix-BAD-LAN-IP] — parsing du QR enrichi (ips[]), ordre des
// candidates, server-info api_urls, et URLs de repli de ConnectionState.
//
// Contexte : le desktop n'envoyait qu'UNE IP (route par défaut = souvent un
// adaptateur virtuel Hyper-V/WSL/VPN) → le mobile timeout 8 s en TCP sur un
// port filtré alors que le serveur répondait très bien. Le QR transporte
// désormais TOUTES les IPs LAN du poste (champ ips, ip conservé pour
// compatibilité) et le mobile essaie chaque candidate.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:getech_sms_mobile/features/connections/connection_state.dart';
import 'package:getech_sms_mobile/shared/models/auth_dto.dart';

void main() {
  group('PairingPayload [Fix-BAD-LAN-IP]', () {
    test('QR moderne : ips[] parsée, ip conservée, ordre respecté', () {
      final payload = PairingPayload.fromJson({
        'ip': '172.20.0.1',
        'ips': ['172.20.0.1', '192.168.1.10', '10.0.0.5'],
        'port': 8001,
        'establishment_code': 'R11-01',
        'pairing_token': 'ABC12345',
      });
      expect(payload.ip, '172.20.0.1');
      expect(payload.ips, ['172.20.0.1', '192.168.1.10', '10.0.0.5']);
      // La première candidate = IP principale (compat ascendante)…
      expect(payload.serverUrls.first, 'http://172.20.0.1:8001/api/v1');
      // …suivie des AUTRES IPs du poste, sans doublon.
      expect(payload.serverUrls, [
        'http://172.20.0.1:8001/api/v1',
        'http://192.168.1.10:8001/api/v1',
        'http://10.0.0.5:8001/api/v1',
      ]);
    });

    test('QR ancien (sans ips) : une seule candidate, rien ne casse', () {
      final payload = PairingPayload.fromJson({
        'ip': '192.168.1.10',
        'port': 8000,
        'establishment_code': 'R11-01',
        'pairing_token': 'ABC12345',
      });
      expect(payload.ips, isEmpty);
      expect(payload.serverUrls, ['http://192.168.1.10:8000/api/v1']);
    });

    test('QR vide (ips nulle ou entrées vides) : robustesse', () {
      final payload = PairingPayload.fromJson({
        'ip': '192.168.1.10',
        'ips': null,
        'port': 8000,
        'establishment_code': 'R11-01',
        'pairing_token': 'ABC12345',
      });
      expect(payload.serverUrls, ['http://192.168.1.10:8000/api/v1']);
    });

    test('round-trip JSON conserve ips[]', () {
      final payload = PairingPayload.fromJson({
        'ip': '172.20.0.1',
        'ips': ['172.20.0.1', '192.168.1.10'],
        'port': 8001,
        'establishment_code': 'R11-01',
        'pairing_token': 'ABC12345',
      });
      final encoded = json.encode(payload.toJson());
      final decoded = PairingPayload.fromJson(
        json.decode(encoded) as Map<String, dynamic>,
      );
      expect(decoded.ips, payload.ips);
      expect(decoded.serverUrls, payload.serverUrls);
    });
  });

  group('ServerInfoDto [Fix-BAD-LAN-IP]', () {
    test('api_urls[] parsée côté server-info', () {
      final dto = ServerInfoDto.fromJson({
        'establishment_code': 'R11-01',
        'establishment_name': 'Lycée Test',
        'server_version': '1.1.0',
        'api_url': 'http://192.168.1.10:8001/api/v1',
        'api_urls': [
          'http://192.168.1.10:8001/api/v1',
          'http://10.0.0.5:8001/api/v1',
        ],
        'lan_ips': ['192.168.1.10', '10.0.0.5'],
      });
      expect(dto.apiUrl, 'http://192.168.1.10:8001/api/v1');
      expect(dto.apiUrls, [
        'http://192.168.1.10:8001/api/v1',
        'http://10.0.0.5:8001/api/v1',
      ]);
    });

    test('serveur ancien sans api_urls : liste vide, pas de crash', () {
      final dto = ServerInfoDto.fromJson({
        'establishment_code': 'R11-01',
        'establishment_name': 'Lycée Test',
        'server_version': '1.0.0',
        'api_url': 'http://192.168.1.10:8000/api/v1',
      });
      expect(dto.apiUrls, isEmpty);
      expect(dto.apiUrl, 'http://192.168.1.10:8000/api/v1');
    });
  });

  group('ConnectionState.alternateServerUrls [Fix-BAD-LAN-IP]', () {
    test('allServerUrls : principale puis replis, sans doublon', () {
      const state = ConnectionState(
        status: ServerStatus.online,
        serverIp: '172.20.0.1',
        serverPort: 8001,
        pairingToken: 'token',
        alternateServerUrls: [
          'http://192.168.1.10:8001/api/v1',
          'http://172.20.0.1:8001/api/v1', // doublon de la primaire
        ],
      );
      expect(state.allServerUrls, [
        'http://172.20.0.1:8001/api/v1',
        'http://192.168.1.10:8001/api/v1',
      ]);
    });

    test('allServerUrls : replis persistés dans l\'ordre de victoire', () {
      // Cas du battement suivant une victoire de repli : la vainqueuse
      // est en TÊTE de alternateServerUrls (promue par checkStatus).
      // allServerUrls garde la primaire du profil en premier (comportement
      // historique) suivie des replis dans leur ordre de victoire.
      const state = ConnectionState(
        status: ServerStatus.online,
        serverIp: '172.20.0.1',
        serverPort: 8001,
        pairingToken: 'token',
        alternateServerUrls: [
          'http://192.168.1.10:8001/api/v1', // gagnante promue en tête
          'http://10.0.0.5:8001/api/v1',
        ],
      );
      expect(state.allServerUrls.first, 'http://172.20.0.1:8001/api/v1');
      // …puis les replis, vainqueuse d'abord (utile dès que la primaire
      // du profil est elle-même réécrite un jour).
      expect(state.allServerUrls, [
        'http://172.20.0.1:8001/api/v1',
        'http://192.168.1.10:8001/api/v1',
        'http://10.0.0.5:8001/api/v1',
      ]);
    });

    test('allServerUrls vide si non appairé', () {
      const state = ConnectionState();
      expect(state.allServerUrls, isEmpty);
    });
  });
}
