/// Page d'onboarding d'appairage (module Connexions) — atteinte tant que
/// l'appareil n'est pas encore appairé à un serveur desktop.
///
/// Trois méthodes d'appairage, sélectionnables via un TabBar :
///  1. **Découverte automatique (mDNS)** : liste les serveurs détectés sur le
///     réseau local via [mdnsDiscoveryProvider]. Tap → pré-remplit le formulaire
///     manuel.
///  2. **Appairage manuel** : saisie de l'IP:port, du code établissement et du
///     token d'appairage, puis appel `POST /devices/pair`.
///  3. **Scan QR code** : ouvre [QrScannerPage] qui renvoie un [PairingPayload]
///     parsé depuis le QR affiché côté desktop.
///
/// Sur succès, [ConnectionNotifier.configure] est appelé par le contrôleur et
/// le routeur redirige automatiquement vers `/login` (ou `/dashboard` si déjà
/// authentifié).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_state.dart';
import '../../shared/models/auth_dto.dart';
import '../../shared/widgets/app_error_widget.dart';
import '../../shared/widgets/app_loading.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/section_header.dart';
import 'connection_state.dart';
import 'connections_controller.dart';

/// Page d'appairage.
class DevicePairingPage extends ConsumerStatefulWidget {
  const DevicePairingPage({super.key});

  @override
  ConsumerState<DevicePairingPage> createState() => _DevicePairingPageState();
}

class _DevicePairingPageState extends ConsumerState<DevicePairingPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  final _formKey = GlobalKey<FormState>();
  final _serverCtrl = TextEditingController();
  final _establishmentCtrl = TextEditingController();
  final _pairingTokenCtrl = TextEditingController();

  bool _submitting = false;
  String? _submitError;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _serverCtrl.dispose();
    _establishmentCtrl.dispose();
    _pairingTokenCtrl.dispose();
    super.dispose();
  }

  /// Normalise la saisie IP:port en URL serveur `http://<host>:<port>/api/v1`.
  /// Accepte aussi une saisie déjà complète (ex: `http://192.168.1.10:8000/api/v1`).
  String _normalizeServerUrl(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return s;
    final hadHttps = s.startsWith('https://');
    if (s.startsWith('http://') || s.startsWith('https://')) {
      s = s.substring(s.indexOf('://') + 3);
    }
    // Supprime un éventuel suffixe /api/v1 déjà présent.
    final apiSuffix = RegExp(r'/api/v\d+/?$', caseSensitive: false);
    s = s.replaceAll(apiSuffix, '');
    s = s.replaceAll(RegExp(r'/+$'), '');
    final scheme = hadHttps ? 'https' : 'http';
    return '$scheme://$s/api/v1';
  }

  void _prefillFromDiscovered(DiscoveredServer server) {
    _serverCtrl.text = '${server.ip}:${server.port}';
    if (server.establishmentCode != null &&
        server.establishmentCode!.isNotEmpty) {
      _establishmentCtrl.text = server.establishmentCode!;
    }
    _pairingTokenCtrl.clear();
    setState(() => _submitError = null);
    _tabController.animateTo(1); // → onglet manuel
  }

  Future<void> _submitManual() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _submitError = null;
    });

    final serverUrl = _normalizeServerUrl(_serverCtrl.text);
    final establishmentCode = _establishmentCtrl.text.trim();
    final pairingToken = _pairingTokenCtrl.text.trim();

    try {
      await ref.read(connectionsControllerProvider).pairManual(
            serverUrl: serverUrl,
            establishmentCode: establishmentCode,
            pairingToken: pairingToken,
          );
      if (!mounted) return;
      _navigateAfterPairSuccess();
    } on PairingException catch (e) {
      if (!mounted) return;
      setState(() => _submitError = e.message);
      _toast(e.message);
    } catch (e) {
      if (!mounted) return;
      final msg = 'Échec de l\'appairage : $e';
      setState(() => _submitError = msg);
      _toast(msg);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _openQrScanner() async {
    final payload = await context.push<PairingPayload>('/qr-scanner');
    if (!mounted || payload == null) return;
    await _pairWithPayload(payload);
  }

  Future<void> _pairWithPayload(PairingPayload payload) async {
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    try {
      await ref
          .read(connectionsControllerProvider)
          .pairWithPayload(payload);
      if (!mounted) return;
      _navigateAfterPairSuccess();
    } on PairingException catch (e) {
      if (!mounted) return;
      // Pré-remplit le formulaire manuel avec les champs du QR pour re-tentative.
      _serverCtrl.text = '${payload.ip}:${payload.port}';
      _establishmentCtrl.text = payload.establishmentCode;
      _pairingTokenCtrl.text = payload.pairingToken;
      _tabController.animateTo(1);
      setState(() => _submitError = e.message);
      _toast(e.message);
    } catch (e) {
      if (!mounted) return;
      final msg = 'Échec de l\'appairage : $e';
      setState(() => _submitError = msg);
      _toast(msg);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _navigateAfterPairSuccess() {
    final authed = ref.read(authProvider).isAuthenticated;
    if (!mounted) return;
    context.go(authed ? '/dashboard' : '/login');
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Appairage du terminal'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.wifi_find), text: 'Découverte'),
            Tab(icon: Icon(Icons.edit_note), text: 'Manuel'),
            Tab(icon: Icon(Icons.qr_code_scanner), text: 'QR Code'),
          ],
        ),
      ),
      body: Stack(
        children: [
          TabBarView(
            controller: _tabController,
            children: [
              _DiscoveryTab(onSelect: _prefillFromDiscovered),
              _ManualForm(
                formKey: _formKey,
                serverCtrl: _serverCtrl,
                establishmentCtrl: _establishmentCtrl,
                pairingTokenCtrl: _pairingTokenCtrl,
                onSubmit: _submitManual,
                submitting: _submitting,
                error: _submitError,
              ),
              _QrTab(onScan: _openQrScanner),
            ],
          ),
          if (_submitting)
            Container(
              color: Colors.black.withValues(alpha: 0.35),
              alignment: Alignment.center,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('Appairage en cours…'),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Onglet 1 : découverte mDNS
// ---------------------------------------------------------------------------

class _DiscoveryTab extends ConsumerWidget {
  const _DiscoveryTab({required this.onSelect});
  final ValueChanged<DiscoveredServer> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final discovery = ref.watch(mdnsDiscoveryProvider);
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: () async => ref.refresh(mdnsDiscoveryProvider.future),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SectionHeader(
            title: 'Découverte automatique',
            subtitle:
                'Recherche des terminaux GeTech-SMS sur le réseau local (mDNS).',
            icon: Icons.wifi_find,
          ),
          const SizedBox(height: 8),
          discovery.when(
            data: (servers) {
              if (servers.isEmpty) {
                return const EmptyState(
                  icon: Icons.wifi_tethering,
                  title: 'Aucun terminal détecté',
                  message:
                      'Vérifiez que le terminal desktop est démarré et connecté au même réseau Wi-Fi, '
                      'ou utilisez l\'appairage manuel.',
                );
              }
              return Column(
                children: [
                  for (final s in servers)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor:
                              theme.colorScheme.primaryContainer.withValues(alpha: 0.6),
                          child: Icon(Icons.dns,
                              color: theme.colorScheme.onPrimaryContainer),
                        ),
                        title: Text(s.establishmentName ?? s.name),
                        subtitle: Text('${s.ip}:${s.port}'
                            '${s.establishmentCode != null ? '  •  ${s.establishmentCode}' : ''}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => onSelect(s),
                      ),
                    ),
                ],
              );
            },
            loading: () => const AppLoading(label: 'Recherche en cours…'),
            error: (e, _) => AppErrorWidget(
              message: 'Erreur de découverte : $e',
              onRetry: () => ref.invalidate(mdnsDiscoveryProvider),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Astuce : si aucun terminal n\'apparaît, demandez l\'IP du serveur '
            'au responsable et utilisez l\'onglet « Manuel » ou « QR Code ».',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Onglet 2 : saisie manuelle
// ---------------------------------------------------------------------------

class _ManualForm extends StatelessWidget {
  const _ManualForm({
    required this.formKey,
    required this.serverCtrl,
    required this.establishmentCtrl,
    required this.pairingTokenCtrl,
    required this.onSubmit,
    required this.submitting,
    required this.error,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController serverCtrl;
  final TextEditingController establishmentCtrl;
  final TextEditingController pairingTokenCtrl;
  final VoidCallback onSubmit;
  final bool submitting;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Form(
      key: formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SectionHeader(
            title: 'Appairage manuel',
            subtitle: 'Saisissez les informations affichées sur le terminal desktop.',
            icon: Icons.edit_note,
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: serverCtrl,
            decoration: const InputDecoration(
              labelText: 'Adresse du serveur',
              hintText: 'ex : 192.168.1.10:8000',
              prefixIcon: Icon(Icons.dns_outlined),
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.url,
            autocorrect: false,
            textInputAction: TextInputAction.next,
            validator: (v) {
              final s = v?.trim() ?? '';
              if (s.isEmpty) return 'Champ requis';
              if (!RegExp(r'^[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]{2,5}$')
                      .hasMatch(s) &&
                  !s.startsWith('http')) {
                return 'Format attendu : IP:port (ex : 192.168.1.10:8000)';
              }
              return null;
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: establishmentCtrl,
            decoration: const InputDecoration(
              labelText: 'Code établissement',
              hintText: 'ex : EST001',
              prefixIcon: Icon(Icons.school_outlined),
              border: OutlineInputBorder(),
            ),
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            textInputAction: TextInputAction.next,
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Champ requis' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: pairingTokenCtrl,
            decoration: const InputDecoration(
              labelText: 'Token d\'appairage',
              hintText: 'Code à usage unique (ex : 8f3c…)',
              prefixIcon: Icon(Icons.key),
              border: OutlineInputBorder(),
            ),
            autocorrect: false,
            obscureText: true,
            textInputAction: TextInputAction.done,
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Champ requis' : null,
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            AppErrorWidget(message: error!, compact: true),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: submitting ? null : onSubmit,
            icon: submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.link),
            label: const Text('Appairer'),
          ),
          const SizedBox(height: 16),
          Text(
            'Le token d\'appairage est généré par le terminal desktop '
            '(menu « Appairer un mobile ») et expire après 5 minutes.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Onglet 3 : scan QR
// ---------------------------------------------------------------------------

class _QrTab extends StatelessWidget {
  const _QrTab({required this.onScan});
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.qr_code_scanner,
                  size: 48, color: theme.colorScheme.primary),
            ),
            const SizedBox(height: 20),
            Text(
              'Scanner le QR code d\'appairage',
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Sur le terminal desktop, ouvrez le menu « Appairer un mobile » '
              'puis scannez le QR code affiché à l\'écran. L\'adresse, le code '
              'établissement et le token seront configurés automatiquement.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onScan,
              icon: const Icon(Icons.camera_alt),
              label: const Text('Ouvrir le scanner'),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () => context.go('/pairing'),
              icon: const Icon(Icons.edit),
              label: const Text('Saisir manuellement'),
            ),
          ],
        ),
      ),
    );
  }
}
