/// Page de scan QR code pour l'appairage (module Connexions).
///
/// Utilise `mobile_scanner` pour scanner un QR code généré par le desktop.
/// Le contenu attendu est un JSON décodable en [PairingPayload] :
/// `{ip, port, establishment_code, pairing_token}`.
///
/// En cas de succès, la page renvoie le [PairingPayload] au [DevicePairingPage]
/// via `Navigator.pop`. En cas d'erreur (QR invalide, permission caméra
/// refusée), un SnackBar informe l'utilisateur et un bouton de saisie manuelle
/// est proposé en repli.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../shared/models/auth_dto.dart';
import '../../shared/widgets/app_loading.dart';

/// Page plein écran de scan QR.
class QrScannerPage extends ConsumerStatefulWidget {
  const QrScannerPage({super.key});

  @override
  ConsumerState<QrScannerPage> createState() => _QrScannerPageState();

  /// Tente de parser le payload. Supporte :
  /// 1. URI : getech://pair?ip=...&port=8000&token=...&code=...
  /// 2. JSON : {"ip": "...", "port": 8000, "token": "...", "establishment_code": "..."}
  /// 3. JWT : décodage des claims pour extraire IP/port/code
  /// 4. Base64 : JSON encodé
  /// 5. Délimité : ip:port|code|token
  /// 6. Token brut : fallback si format non reconnu
  static PairingPayload? tryParsePayload(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    // 1. URI (getech://pair ou http://.../pair)
    if (trimmed.startsWith('getech://') || trimmed.startsWith('http')) {
      try {
        // Normalisation pour Uri.parse si c'est getech://
        final uri = Uri.parse(
          trimmed.startsWith('getech://')
              ? trimmed.replaceFirst('getech://pair', 'http://getech-app/pair')
              : trimmed,
        );

        final ip = uri.queryParameters['ip'] ??
            uri.queryParameters['host'] ??
            (uri.host == 'getech-app' ? '' : uri.host);
        final port =
            int.tryParse(uri.queryParameters['port'] ?? uri.port.toString()) ??
                8000;
        final code = uri.queryParameters['code'] ??
            uri.queryParameters['establishment_code'] ??
            uri.queryParameters['est_code'] ??
            '';
        final token = uri.queryParameters['token'] ??
            uri.queryParameters['pairing_token'] ??
            '';

        if (token.isNotEmpty) {
          return PairingPayload(
            ip: ip,
            port: port,
            establishmentCode: code,
            pairingToken: token,
          );
        }
      } catch (_) {}
    }

    // 2. JSON ou Base64 JSON
    try {
      String jsonStr = trimmed;
      if (!trimmed.startsWith('{') && !trimmed.contains(' ')) {
        // Tentative Base64
        try {
          jsonStr = utf8.decode(base64.decode(base64.normalize(trimmed)));
        } catch (_) {}
      }

      if (jsonStr.startsWith('{')) {
        final decoded = jsonDecode(jsonStr);
        if (decoded is Map) {
          final data =
              decoded['pairing'] is Map ? decoded['pairing'] as Map : decoded;
          return PairingPayload(
            ip: data['ip']?.toString() ?? data['host']?.toString() ?? '',
            port: int.tryParse(data['port']?.toString() ?? '8000') ?? 8000,
            establishmentCode: data['establishment_code']?.toString() ??
                data['code']?.toString() ??
                '',
            pairingToken: data['pairing_token']?.toString() ??
                data['token']?.toString() ??
                '',
          );
        }
      }
    } catch (_) {}

    // 3. JWT (3 segments)
    if (trimmed.contains('.') && trimmed.split('.').length == 3) {
      try {
        final payloadPart = trimmed.split('.')[1];
        final normalized = base64.normalize(payloadPart);
        final payloadJson = utf8.decode(base64.decode(normalized));
        final payload = jsonDecode(payloadJson);
        if (payload is Map) {
          return PairingPayload(
            ip: payload['ip']?.toString() ?? payload['host']?.toString() ?? '',
            port: int.tryParse(payload['port']?.toString() ?? '8000') ?? 8000,
            establishmentCode: payload['establishment_code']?.toString() ??
                payload['code']?.toString() ??
                '',
            pairingToken: trimmed,
          );
        }
      } catch (_) {}
    }

    // 4. Délimité (ip:port|code|token)
    if (trimmed.contains('|')) {
      final parts = trimmed.split('|');
      if (parts.length >= 2) {
        String ip = '';
        int port = 8000;
        if (parts[0].contains(':')) {
          final hostParts = parts[0].split(':');
          ip = hostParts[0];
          port = int.tryParse(hostParts[1]) ?? 8000;
        } else {
          ip = parts[0];
        }
        return PairingPayload(
          ip: ip,
          port: port,
          establishmentCode: parts.length > 2 ? parts[1] : '',
          pairingToken: parts.last,
        );
      }
    }

    // 5. Token brut (dernier recours)
    if (trimmed.length >= 6 && !trimmed.contains(' ')) {
      return PairingPayload(
        ip: '',
        port: 8000,
        establishmentCode: '',
        pairingToken: trimmed,
      );
    }

    return null;
  }
}

class _QrScannerPageState extends ConsumerState<QrScannerPage> {
  late final MobileScannerController _controller;
  bool _torchOn = false;
  bool _hasTorch = false;
  bool _permissionDenied = false;
  bool _starting = true;
  String? _startError;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      returnImage: false,
    );
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // hasTorch n'est plus disponible dans la nouvelle API mobile_scanner
    // On assume la torche disponible par défaut
    setState(() => _hasTorch = true);
    if (!mounted) return;
    setState(() => _starting = false);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;
    final raw = barcodes.first.rawValue;
    if (raw == null || raw.isEmpty) {
      _toast('QR code vide ou illisible');
      return;
    }
    final payload = QrScannerPage.tryParsePayload(raw);
    if (payload == null) {
      _toast('QR code invalide');
      return;
    }
    // Évite les déclenchements multiples.
    _controller.stop();
    Navigator.of(context).pop<PairingPayload>(payload);
  }

  /// Tente de parser le payload. Supporte :
  /// 1. URI : getech://pair?ip=...&port=8000&token=...&code=...
  /// 2. JSON : {"ip": "...", "port": 8000, "token": "...", "establishment_code": "..."}
  /// 3. JWT : décodage des claims pour extraire IP/port/code
  /// 4. Base64 : JSON encodé
  /// 5. Délimité : ip:port|code|token
  static PairingPayload? tryParsePayload(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    // 1. URI (getech://pair ou http://.../pair)
    if (trimmed.startsWith('getech://') || trimmed.startsWith('http')) {
      try {
        // Normalisation pour Uri.parse si c'est getech://
        final uri = Uri.parse(
          trimmed.startsWith('getech://')
              ? trimmed.replaceFirst('getech://pair', 'http://getech-app/pair')
              : trimmed,
        );
        
        final ip = uri.queryParameters['ip'] ?? uri.queryParameters['host'] ?? 
                  (uri.host == 'getech-app' ? '' : uri.host);
        final port = int.tryParse(uri.queryParameters['port'] ?? uri.port.toString()) ?? 8000;
        final code = uri.queryParameters['code'] ?? uri.queryParameters['establishment_code'] ?? uri.queryParameters['est_code'] ?? '';
        final token = uri.queryParameters['token'] ?? uri.queryParameters['pairing_token'] ?? '';

        if (token.isNotEmpty) {
          return PairingPayload(
            ip: ip,
            port: port,
            establishmentCode: code,
            pairingToken: token,
          );
        }
      } catch (_) {}
    }

    // 2. JSON ou Base64 JSON
    try {
      String jsonStr = trimmed;
      if (!trimmed.startsWith('{') && !trimmed.contains(' ')) {
        // Tentative Base64
        try {
          jsonStr = utf8.decode(base64.decode(base64.normalize(trimmed)));
        } catch (_) {}
      }

      if (jsonStr.startsWith('{')) {
        final decoded = jsonDecode(jsonStr);
        if (decoded is Map) {
          final data = decoded['pairing'] is Map ? decoded['pairing'] as Map : decoded;
          return PairingPayload(
            ip: data['ip']?.toString() ?? data['host']?.toString() ?? '',
            port: int.tryParse(data['port']?.toString() ?? '8000') ?? 8000,
            establishmentCode: data['establishment_code']?.toString() ?? data['code']?.toString() ?? '',
            pairingToken: data['pairing_token']?.toString() ?? data['token']?.toString() ?? '',
          );
        }
      }
    } catch (_) {}

    // 3. JWT (3 segments)
    if (trimmed.contains('.') && trimmed.split('.').length == 3) {
      try {
        final payloadPart = trimmed.split('.')[1];
        final normalized = base64.normalize(payloadPart);
        final payloadJson = utf8.decode(base64.decode(normalized));
        final payload = jsonDecode(payloadJson);
        if (payload is Map) {
          return PairingPayload(
            ip: payload['ip']?.toString() ?? payload['host']?.toString() ?? '',
            port: int.tryParse(payload['port']?.toString() ?? '8000') ?? 8000,
            establishmentCode: payload['establishment_code']?.toString() ?? payload['code']?.toString() ?? '',
            pairingToken: trimmed,
          );
        }
      } catch (_) {}
    }

    // 4. Délimité (ip:port|code|token)
    if (trimmed.contains('|')) {
      final parts = trimmed.split('|');
      if (parts.length >= 2) {
        String ip = '';
        int port = 8000;
        if (parts[0].contains(':')) {
          final hostParts = parts[0].split(':');
          ip = hostParts[0];
          port = int.tryParse(hostParts[1]) ?? 8000;
        } else {
          ip = parts[0];
        }
        return PairingPayload(
          ip: ip,
          port: port,
          establishmentCode: parts.length > 2 ? parts[1] : '',
          pairingToken: parts.last,
        );
      }
    }

    // 5. Token brut (dernier recours)
    if (trimmed.length >= 6 && !trimmed.contains(' ')) {
      return PairingPayload(
        ip: '',
        port: 8000,
        establishmentCode: '',
        pairingToken: trimmed,
      );
    }

    return null;
  }

  void _toggleTorch() async {
    try {
      await _controller.toggleTorch();
      if (!mounted) return;
      setState(() => _torchOn = !_torchOn);
    } catch (_) {
      _toast('Torche indisponible');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
      ));
  }

  void _enterManually() {
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      // Revient à la page d'appairage (push) sans résultat : l'utilisateur
      // saisira les champs manuellement dans l'onglet « Manuel ».
      nav.pop<PairingPayload?>(null);
    } else {
      // Accès direct (deep-link) : remplace la route courante.
      context.go('/pairing');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scanner un QR code'),
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          if (_hasTorch)
            IconButton(
              onPressed: _toggleTorch,
              icon: Icon(_torchOn ? Icons.flash_on : Icons.flash_off),
              tooltip: _torchOn ? 'Désactiver la lampe' : 'Activer la lampe',
            ),
        ],
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_permissionDenied) {
      return _PermissionDenied(
        onRetry: () {
          setState(() => _permissionDenied = false);
          _controller.start();
        },
        onManual: _enterManually,
      );
    }
    if (_startError != null && _starting) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off, size: 48, color: Colors.white70),
              const SizedBox(height: 16),
              Text(
                _startError!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: _enterManually,
                icon: const Icon(Icons.edit),
                label: const Text('Saisir manuellement'),
              ),
            ],
          ),
        ),
      );
    }
    return Stack(
      children: [
        MobileScanner(
          controller: _controller,
          onDetect: _onDetect,
        ),
        // Viseur carré centré
        _ScannerOverlay(colorScheme: theme.colorScheme),
        // Bandeau d'aide en bas
        Positioned(
          left: 16,
          right: 16,
          bottom: MediaQuery.of(context).padding.bottom + 16,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Pointez la caméra vers le QR code affiché sur le terminal desktop',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 13),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white70),
                      ),
                      onPressed: _enterManually,
                      icon: const Icon(Icons.edit),
                      label: const Text('Saisir manuellement'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_starting)
          const Center(
            child: AppLoading(label: 'Initialisation de la caméra…'),
          ),
      ],
    );
  }
}

/// Viseur carré centré pour guider l'utilisateur.
class _ScannerOverlay extends StatelessWidget {
  const _ScannerOverlay({required this.colorScheme});
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final side = size.shortestSide * 0.65;
          final left = (size.width - side) / 2;
          final top = (size.height - side) / 2;
          return Stack(
            children: [
              // Voile sombre autour du viseur
              ColorFiltered(
                colorFilter: ColorFilter.mode(
                  Colors.black.withValues(alpha: 0.45),
                  BlendMode.srcOut,
                ),
                child: Stack(
                  children: [
                    Container(
                      decoration: const BoxDecoration(
                        color: Colors.transparent,
                      ),
                    ),
                    Positioned(
                      left: left,
                      top: top,
                      child: Container(
                        width: side,
                        height: side,
                        decoration: BoxDecoration(
                          color: Colors.black,
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Bordure du viseur
              Positioned(
                left: left,
                top: top,
                child: Container(
                  width: side,
                  height: side,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: colorScheme.primary.withValues(alpha: 0.9),
                      width: 3,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PermissionDenied extends StatelessWidget {
  const _PermissionDenied({required this.onRetry, required this.onManual});
  final VoidCallback onRetry;
  final VoidCallback onManual;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography, size: 56, color: Colors.white70),
            const SizedBox(height: 16),
            const Text(
              'Accès caméra refusé',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Autorisez l\'accès à la caméra dans les réglages de l\'application pour scanner un QR code, ou saisissez les informations d\'appairage manuellement.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Réessayer'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onManual,
              icon: const Icon(Icons.edit),
              label: const Text('Saisir manuellement'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CameraError extends StatelessWidget {
  const _CameraError({required this.message, required this.onManual});
  final String message;
  final VoidCallback onManual;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.white70),
            const SizedBox(height: 16),
            Text(
              'Caméra indisponible',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(color: Colors.white),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: onManual,
              icon: const Icon(Icons.edit),
              label: const Text('Saisir manuellement'),
            ),
          ],
        ),
      ),
    );
  }
}
