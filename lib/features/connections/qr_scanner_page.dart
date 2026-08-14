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

import 'dart:convert' show jsonDecode;

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
    try {
      final hasTorch = await _controller.hasTorch;
      if (!mounted) return;
      setState(() => _hasTorch = hasTorch);
    } catch (_) {
      // hasTorch peut échouer sur certains émulateurs : on ignore.
    }
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
    final payload = _tryParse(raw);
    if (payload == null) {
      _toast('QR code invalide');
      return;
    }
    // Évite les déclenchements multiples.
    _controller.stop();
    Navigator.of(context).pop<PairingPayload>(payload);
  }

  /// Tente de parser le payload. Accepte soit un JSON objet direct, soit un
  /// JSON enveloppé `{ "pairing": { ... } }` pour robustesse.
  static PairingPayload? _tryParse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      Map<String, dynamic> data;
      if (decoded['pairing'] is Map) {
        data = Map<String, dynamic>.from(decoded['pairing'] as Map);
      } else {
        data = Map<String, dynamic>.from(decoded);
      }
      final payload = PairingPayload.fromJson(data);
      if (payload.ip.isEmpty ||
          payload.establishmentCode.isEmpty ||
          payload.pairingToken.isEmpty) {
        return null;
      }
      return payload;
    } catch (_) {
      return null;
    }
  }

  void _onPermissionSet(bool granted) {
    if (!granted) {
      setState(() => _permissionDenied = true);
    } else if (_permissionDenied) {
      setState(() => _permissionDenied = false);
    }
  }

  void _onError(Object error) {
    setState(() => _startError = 'Erreur caméra : $error');
  }

  Future<void> _toggleTorch() async {
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
          onPermissionSet: (_, granted) => _onPermissionSet(granted),
          errorBuilder: (context, error, child) => _CameraError(
            message: error.toString(),
            onManual: _enterManually,
          ),
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
