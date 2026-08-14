/// Page de connexion : 3 champs (nom d'utilisateur, mot de passe, code
/// établissement) + bouton "Se connecter".
///
/// Le code établissement est pré-rempli depuis [connectionProvider] (modifiable).
/// La soumission appelle [AuthNotifier.login]. En cas de serveur injoignable,
/// un bandeau invite l'utilisateur à vérifier le module Connexions. En cas de
/// succès, le garde du routeur redirige automatiquement vers `/dashboard`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_state.dart';
import '../../core/config/app_config.dart';
import '../connections/connection_state.dart';

/// Écran de connexion (formulaire centré sur carte).
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _establishmentCodeCtrl = TextEditingController();

  bool _obscurePassword = true;

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _establishmentCodeCtrl.dispose();
    super.dispose();
  }

  /// Pré-remplit le code établissement à partir de l'état de connexion tant
  /// que l'utilisateur n'a pas saisi de valeur lui-même. Comme
  /// [ConnectionNotifier] charge son état de manière asynchrone, on ré-essaie
  /// à chaque build jusqu'à obtenir un code non vide.
  void _ensurePrefilledCode() {
    if (_establishmentCodeCtrl.text.isNotEmpty) return;
    final conn = ref.read(connectionProvider);
    if (conn.establishmentCode != null &&
        conn.establishmentCode!.isNotEmpty) {
      _establishmentCodeCtrl.text = conn.establishmentCode!;
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    // Masque le clavier avant la requête.
    FocusScope.of(context).unfocus();

    final ok = await ref.read(authProvider.notifier).login(
          username: _usernameCtrl.text.trim(),
          password: _passwordCtrl.text,
          establishmentCode: _establishmentCodeCtrl.text.trim(),
        );
    if (!mounted) return;
    if (ok) {
      context.go('/dashboard');
    }
    // En cas d'échec, l'erreur est exposée via authProvider.error et affichée
    // en dessous du formulaire (pas besoin de SnackBar).
  }

  @override
  Widget build(BuildContext context) {
    _ensurePrefilledCode();

    final auth = ref.watch(authProvider);
    final conn = ref.watch(connectionProvider);
    final theme = Theme.of(context);

    final serverUnreachable =
        conn.status == ServerStatus.offline ||
            conn.status == ServerStatus.unpaired ||
            conn.forceOffline;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // En-tête : logo + nom + sous-titre.
                    Container(
                      width: 84,
                      height: 84,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.school,
                        size: 44,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      AppConfig.appName,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Gestion scolaire — espace enseignant',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Bandeau serveur injoignable.
                    if (serverUnreachable) ...[
                      _UnreachableBanner(
                        onManageConnections: () => context.push('/connections'),
                      ),
                      const SizedBox(height: 16),
                    ],

                    Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextFormField(
                              controller: _usernameCtrl,
                              autofillHints: const ['username'],
                              textInputAction: TextInputAction.next,
                              textCapitalization: TextCapitalization.none,
                              decoration: const InputDecoration(
                                labelText: 'Nom d\'utilisateur',
                                prefixIcon: Icon(Icons.person_outline),
                                border: OutlineInputBorder(),
                              ),
                              validator: (v) => (v == null || v.trim().isEmpty)
                                  ? 'Veuillez saisir votre nom d\'utilisateur.'
                                  : null,
                            ),
                            const SizedBox(height: 14),
                            TextFormField(
                              controller: _passwordCtrl,
                              autofillHints: const ['password'],
                              obscureText: _obscurePassword,
                              textInputAction: TextInputAction.next,
                              decoration: InputDecoration(
                                labelText: 'Mot de passe',
                                prefixIcon:
                                    const Icon(Icons.lock_outline),
                                border: const OutlineInputBorder(),
                                suffixIcon: IconButton(
                                  tooltip: _obscurePassword
                                      ? 'Afficher le mot de passe'
                                      : 'Masquer le mot de passe',
                                  icon: Icon(
                                    _obscurePassword
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                  ),
                                  onPressed: () => setState(() =>
                                      _obscurePassword = !_obscurePassword),
                                ),
                              ),
                              validator: (v) => (v == null || v.isEmpty)
                                  ? 'Veuillez saisir votre mot de passe.'
                                  : null,
                            ),
                            const SizedBox(height: 14),
                            TextFormField(
                              controller: _establishmentCodeCtrl,
                              textCapitalization:
                                  TextCapitalization.characters,
                              textInputAction: TextInputAction.done,
                              decoration: const InputDecoration(
                                labelText: 'Code établissement',
                                prefixIcon: Icon(Icons.domain_outlined),
                                helperText:
                                    'Code fourni par votre établissement.',
                                border: OutlineInputBorder(),
                              ),
                              validator: (v) => (v == null || v.trim().isEmpty)
                                  ? 'Le code établissement est requis.'
                                  : null,
                            ),
                            const SizedBox(height: 20),
                            FilledButton.icon(
                              onPressed: auth.isLoading ? null : _submit,
                              icon: auth.isLoading
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.4,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.login),
                              label: Text(
                                auth.isLoading ? 'Connexion…' : 'Se connecter',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (auth.error != null && !auth.isLoading) ...[
                      const SizedBox(height: 14),
                      _ErrorBanner(message: auth.error!),
                    ],
                    const SizedBox(height: 20),
                    TextButton.icon(
                      onPressed: () => context.push('/connections'),
                      icon: const Icon(Icons.link, size: 18),
                      label: const Text('Gérer les connexions serveur'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bandeau "Serveur injoignable" affiché en haut du formulaire.
class _UnreachableBanner extends StatelessWidget {
  const _UnreachableBanner({required this.onManageConnections});
  final VoidCallback onManageConnections;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off, color: Colors.orange, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Serveur injoignable — vérifiez le module Connexions.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.orange.shade800,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          TextButton(onPressed: onManageConnections, child: const Text('Ouvrir')),
        ],
      ),
    );
  }
}

/// Bandeau d'erreur de connexion (identifiants invalides, etc.).
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: theme.colorScheme.error, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
