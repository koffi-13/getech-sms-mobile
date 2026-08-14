/// Page Profil : affiche les informations de l'utilisateur courant et permet
/// de modifier le profil (PATCH /auth/update-profile) ainsi que de changer le
/// mot de passe (POST /auth/change-password via [AuthNotifier]).
///
/// Après une mise à jour réussie du profil, [AuthNotifier.fetchMe] est appelé
/// pour rafraîchir l'état global (et l'en-tête du drawer).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_state.dart';
import '../../core/config/constants.dart';
import '../../core/network/api_exceptions.dart';
import '../../shared/models/auth_dto.dart';
import '../../shared/widgets/widgets.dart';
import 'settings_controller.dart';

/// Page Profil (lecteur + éditeur).
class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  late final TextEditingController _firstNameCtrl;
  late final TextEditingController _lastNameCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _oldPasswordCtrl;
  late final TextEditingController _newPasswordCtrl;
  late final TextEditingController _confirmPasswordCtrl;

  final _profileFormKey = GlobalKey<FormState>();
  final _passwordFormKey = GlobalKey<FormState>();

  Sexe? _sexe;
  bool _obscureOld = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;

  bool _savingProfile = false;
  bool _savingPassword = false;
  String? _profileError;
  String? _profileSuccess;
  String? _passwordError;
  String? _passwordSuccess;

  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    // Les contrôleurs sont initialisés à vide dès le initState pour pouvoir
    // être disposés sans risque même si l'utilisateur n'est pas encore chargé.
    _firstNameCtrl = TextEditingController();
    _lastNameCtrl = TextEditingController();
    _emailCtrl = TextEditingController();
    _phoneCtrl = TextEditingController();
    _oldPasswordCtrl = TextEditingController();
    _newPasswordCtrl = TextEditingController();
    _confirmPasswordCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _oldPasswordCtrl.dispose();
    _newPasswordCtrl.dispose();
    _confirmPasswordCtrl.dispose();
    super.dispose();
  }

  /// Pré-remplit les contrôleurs (une fois) à partir de l'utilisateur courant.
  void _ensureInitialized(UserDto? user) {
    if (_initialized || user == null) return;
    _firstNameCtrl.text = user.firstName ?? '';
    _lastNameCtrl.text = user.lastName ?? '';
    _emailCtrl.text = user.email ?? '';
    _phoneCtrl.text = user.phone ?? '';
    _sexe = user.sexe;
    _initialized = true;
  }

  Future<void> _saveProfile() async {
    if (!_profileFormKey.currentState!.validate()) return;
    setState(() {
      _savingProfile = true;
      _profileError = null;
      _profileSuccess = null;
    });
    FocusScope.of(context).unfocus();
    try {
      await ref.read(settingsControllerProvider).updateProfile(
            firstName: _firstNameCtrl.text.trim(),
            lastName: _lastNameCtrl.text.trim(),
            email: _emailCtrl.text.trim(),
            phone: _phoneCtrl.text.trim(),
            sexe: _sexe,
          );
      // Rafraîchit l'état global (user, permissions).
      await ref.read(authProvider.notifier).fetchMe();
      if (mounted) {
        setState(() {
          _savingProfile = false;
          _profileSuccess = 'Profil mis à jour avec succès.';
        });
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Profil mis à jour.')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _savingProfile = false;
          _profileError = e is ApiException ? e.message : e.toString();
        });
      }
    }
  }

  Future<void> _changePassword() async {
    if (!_passwordFormKey.currentState!.validate()) return;
    setState(() {
      _savingPassword = true;
      _passwordError = null;
      _passwordSuccess = null;
    });
    FocusScope.of(context).unfocus();
    final ok = await ref.read(authProvider.notifier).changePassword(
          oldPassword: _oldPasswordCtrl.text,
          newPassword: _newPasswordCtrl.text,
        );
    if (!mounted) return;
    if (ok) {
      _oldPasswordCtrl.clear();
      _newPasswordCtrl.clear();
      _confirmPasswordCtrl.clear();
      setState(() {
        _savingPassword = false;
        _passwordSuccess = 'Mot de passe modifié avec succès.';
        _passwordError = null;
      });
    } else {
      setState(() {
        _savingPassword = false;
        _passwordError =
            ref.read(authProvider).error ?? 'Échec du changement de mot de passe.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final user = auth.user;
    _ensureInitialized(user);

    final theme = Theme.of(context);

    // Si l'utilisateur n'est pas encore chargé (rare sur /settings/profile
    // car le routeur exige auth), on affiche un loader.
    if (!_initialized || user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Profil')),
        body: const AppLoading(label: 'Chargement du profil…'),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Profil')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _ProfileHeader(user: user),
          const SizedBox(height: 16),
          _buildProfileForm(theme),
          const SizedBox(height: 16),
          _buildPasswordForm(theme),
        ],
      ),
    );
  }

  // --- En-tête : avatar + nom + username ---
  Widget _buildProfileForm(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _profileFormKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionHeader(
                title: 'Modifier le profil',
                icon: Icons.edit_outlined,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _firstNameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Prénom',
                        border: OutlineInputBorder(),
                      ),
                      textCapitalization: TextCapitalization.words,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _lastNameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Nom',
                        border: OutlineInputBorder(),
                      ),
                      textCapitalization: TextCapitalization.words,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Adresse e-mail',
                  prefixIcon: Icon(Icons.mail_outline),
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  final s = v?.trim() ?? '';
                  if (s.isEmpty) return null; // e-mail optionnel
                  final regex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
                  if (!regex.hasMatch(s)) {
                    return 'Adresse e-mail invalide.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Téléphone',
                  prefixIcon: Icon(Icons.phone_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<Sexe?>(
                value: _sexe,
                decoration: const InputDecoration(
                  labelText: 'Sexe',
                  prefixIcon: Icon(Icons.wc_outlined),
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem<Sexe?>(
                    value: null,
                    child: Text('Non renseigné'),
                  ),
                  ...Sexe.values.map(
                    (s) => DropdownMenuItem<Sexe?>(value: s, child: Text(s.label)),
                  ),
                ],
                onChanged: (v) => setState(() => _sexe = v),
              ),
              if (_profileError != null) ...[
                const SizedBox(height: 12),
                _InlineMessage(message: _profileError!, isError: true),
              ],
              if (_profileSuccess != null) ...[
                const SizedBox(height: 12),
                _InlineMessage(message: _profileSuccess!, isError: false),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _savingProfile ? null : _saveProfile,
                icon: _savingProfile
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(
                  _savingProfile ? 'Enregistrement…' : 'Enregistrer',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Formulaire changement de mot de passe ---
  Widget _buildPasswordForm(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _passwordFormKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionHeader(
                title: 'Changer le mot de passe',
                icon: Icons.lock_outline,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _oldPasswordCtrl,
                obscureText: _obscureOld,
                decoration: InputDecoration(
                  labelText: 'Mot de passe actuel',
                  prefixIcon: const Icon(Icons.lock_outline),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(_obscureOld
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                    onPressed: () =>
                        setState(() => _obscureOld = !_obscureOld),
                  ),
                ),
                validator: (v) => (v == null || v.isEmpty)
                    ? 'Veuillez saisir votre mot de passe actuel.'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _newPasswordCtrl,
                obscureText: _obscureNew,
                decoration: InputDecoration(
                  labelText: 'Nouveau mot de passe',
                  prefixIcon: const Icon(Icons.lock_outline),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(_obscureNew
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                    onPressed: () =>
                        setState(() => _obscureNew = !_obscureNew),
                  ),
                ),
                validator: (v) {
                  if (v == null || v.isEmpty) {
                    return 'Veuillez saisir un nouveau mot de passe.';
                  }
                  if (v.length < 8) {
                    return 'Le mot de passe doit comporter au moins 8 caractères.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _confirmPasswordCtrl,
                obscureText: _obscureConfirm,
                decoration: InputDecoration(
                  labelText: 'Confirmer le nouveau mot de passe',
                  prefixIcon: const Icon(Icons.lock_outline),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(_obscureConfirm
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                    onPressed: () =>
                        setState(() => _obscureConfirm = !_obscureConfirm),
                  ),
                ),
                validator: (v) {
                  if (v == null || v.isEmpty) {
                    return 'Veuillez confirmer le nouveau mot de passe.';
                  }
                  if (v != _newPasswordCtrl.text) {
                    return 'Les mots de passe ne correspondent pas.';
                  }
                  return null;
                },
              ),
              if (_passwordError != null) ...[
                const SizedBox(height: 12),
                _InlineMessage(message: _passwordError!, isError: true),
              ],
              if (_passwordSuccess != null) ...[
                const SizedBox(height: 12),
                _InlineMessage(message: _passwordSuccess!, isError: false),
              ],
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: _savingPassword ? null : _changePassword,
                icon: _savingPassword
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      )
                    : const Icon(Icons.vpn_key_outlined),
                label: Text(
                  _savingPassword ? 'Modification…' : 'Modifier le mot de passe',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// En-tête du profil : avatar (initiales), nom, username, email, téléphone, sexe.
class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.user});
  final UserDto user;

  String _initials(String? fullName) {
    final name = (fullName ?? '').trim();
    if (name.isEmpty) return 'U';
    final parts = name.split(RegExp(r'\s+'));
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            CircleAvatar(
              radius: 44,
              backgroundColor: theme.colorScheme.primary,
              child: Text(
                _initials(user.fullName),
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onPrimary,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              user.fullName.isNotEmpty ? user.fullName : user.username,
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              '@${user.username}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: [
                if (user.email != null)
                  _Chip(icon: Icons.mail_outline, label: user.email!),
                if (user.phone != null)
                  _Chip(icon: Icons.phone_outlined, label: user.phone!),
                if (user.sexe != null)
                  _Chip(icon: Icons.wc_outlined, label: user.sexe!.label),
                _Chip(
                  icon: user.isSuperuser
                      ? Icons.verified
                      : Icons.shield_outlined,
                  label: user.isSuperuser ? 'Superutilisateur' : 'Utilisateur',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Message inline (succès ou erreur) affiché sous les formulaires.
class _InlineMessage extends StatelessWidget {
  const _InlineMessage({required this.message, required this.isError});
  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isError ? theme.colorScheme.error : Colors.green;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            color: color,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}
