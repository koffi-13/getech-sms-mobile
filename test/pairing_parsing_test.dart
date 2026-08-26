import 'package:flutter_test/flutter_test.dart';
import 'package:getech_sms_mobile/features/connections/qr_scanner_page.dart';
import 'package:getech_sms_mobile/shared/models/auth_dto.dart';
import 'dart:convert';

void main() {
  group('PairingPayload Parsing Tests', () {
    test('Should parse getech:// URI format', () {
      const input = 'getech://pair?ip=192.168.1.50&port=8080&code=EST001&token=abc-123';
      final payload = QrScannerPage.tryParsePayload(input);
      
      expect(payload, isNotNull);
      expect(payload!.ip, '192.168.1.50');
      expect(payload.port, 8080);
      expect(payload.establishmentCode, 'EST001');
      expect(payload.pairingToken, 'abc-123');
    });

    test('Should parse JSON format', () {
      final input = jsonEncode({
        'ip': '192.168.1.100',
        'port': 8000,
        'establishment_code': 'EST-LOM',
        'pairing_token': 'token-secret'
      });
      final payload = QrScannerPage.tryParsePayload(input);
      
      expect(payload, isNotNull);
      expect(payload!.ip, '192.168.1.100');
      expect(payload.port, 8000);
      expect(payload.pairingToken, 'token-secret');
    });

    test('Should parse delimited format', () {
      const input = '192.168.1.10:8000|EST-CODE|TOKEN-XYZ';
      final payload = QrScannerPage.tryParsePayload(input);
      
      expect(payload, isNotNull);
      expect(payload!.ip, '192.168.1.10');
      expect(payload.port, 8000);
      expect(payload.establishmentCode, 'EST-CODE');
      expect(payload.pairingToken, 'TOKEN-XYZ');
    });

    test('Should parse raw token format', () {
      const input = '63CD91E9';
      final payload = QrScannerPage.tryParsePayload(input);
      
      expect(payload, isNotNull);
      expect(payload!.pairingToken, '63CD91E9');
      expect(payload.ip, isEmpty);
    });

    test('Should return null for invalid format', () {
      const input = 'invalid random string';
      final payload = QrScannerPage.tryParsePayload(input);
      expect(payload, isNull);
    });
  });
}
