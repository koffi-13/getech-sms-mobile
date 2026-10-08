/// Page "Formulaire utilisateur" : création (id null) ou édition (id non null).
///
/// Champs : username, firstName, lastName, email, phone, sexe, password
/// (requis en création, optionnel en édition), isActive (switch),
/// isSuperuser (switch, admin uniquement).
///
/// Sauvegarde via [userRepositoryProvider] (POST ou PATCH en ligne, outbox
/// hors-ligne). Validation : username + password (création) requis.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_state.dart';
import '../../core/config/constants.dart';
import '../../core/utils/permissions.dart';
import '../../shared/models/auth_dto.dart';
import '../../shared/widgets/widgets.dart';
import 'user_controller.dart';

class UserFormPage extends ConsumerStatefulWidget {
  const UserFormPage({super.key, this.id});

  final int? id;

  @override
  ConsumerState<UserFormPage> createState() => _UserFormPageState();
}

class _UserFormPageState extends ConsumerState<UserFormPage> {
  final _formKey = GlobalKey<FormState>();
  bool _isSaving = false;
  bool _isPopulated = false;
  bool _obscurePassword = true;

  late final TextEditingController _username;
  late final TextEditingController _firstName;
  late final TextEditingController _lastName;
  late final TextEditingController _email;
  late final TextEditingController _phone;
  late final TextEditingController _password;

  Sexe? _sexe;
  bool _isActive = true;
  bool _isSuperuser = false;

  @override
  void initState() {
    super.initState();
    _username = TextEditingController();
    _firstName = TextEditingController();
    _lastName = TextEditingController();
    _email = TextEditingController();
    _phone = TextEditingController();
    _password = TextEditingController();
  }

  @override
  void dispose() {
    for (final c in [
      _username,
      _firstName,
      _lastName,
      _email,
      _phone,
      _password,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _populateFromDto(UserDto dto) {
    if (_isPopulated) return;
    _isPopulated = true;
    _username.text = dto.username;
    _firstName.text = dto.firstName ?? '';
    _lastName.text = dto.lastName ?? '';
    _email.text = dto.email ?? '';
    _phone.text = dto.phone ?? '';
    _sexe = dto.sexe;
    _isActive = dto.isActive;
    _isSuperuser = dto.isSuperuser;
  }

  UserWriteRequest _buildRequest() {
    final pwd = _password.text.trim();
    return UserWriteRequest(
      username: _username.text.trim(),
      firstName: _firstName.text.trim().isEmpty ? null : _firstName.text.trim(),
      lastName: _lastName.text.trim().isEmpty ? null : _lastName.text.trim(),
      email: _email.text.trim().isEmpty ? null : _email.text.trim(),
      phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
      sexe: _sexe,
      password: pwd.isEmpty ? null : pwd,
      isActive: _isActive,
      isSuperuser: _isSuperuser,
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);
    final req = _buildRequest();
    try {
      final repo = ref.read(userRepositoryProvider);
      final isEdit = widget.id != null && widget.id! > 0;
      if (isEdit) {
        await repo.updateUser(widget.id!, req);
      } else {
        await repo.createUser(req);
      }
      ref.invalidate(usersListProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isEdit
                ? 'Utilisateur mis à jour avec succès.'
                : 'Utilisateur créé avec succès.'),
          ),
        );
        context.pop();
      }
    } on UserRepositoryException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Échec de l\'enregistrement : $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    // RBAC : USER_MANAGE requis. Seul un superuser peut définir isSuperuser.
    final canManage = hasPermission(auth.permissions, RbacPermissions.userManage);
    if (!canManage) {
      return Scaffold(
        appBar: AppBar(title: const Text('Utilisateur')),
        body: const EmptyState(
          icon: Icons.lock_outline,
          title: 'Permission insuffisante',
          message:
              'Vous n\'avez pas la permission USER_MANAGE requise pour créer ou modifier un utilisateur.',
        ),
      );
    }
    final isAdmin = auth.isSuperuser;

    final isEdit = widget.id != null;
    if (isEdit) {
      final async = ref.watch(userDetailProvider(widget.id!));
      return async.when(
        data: (dto) {
          _populateFromDto(dto);
          return _buildScaffold(isEdit: true, isAdmin: isAdmin);
        },
        loading: () => Scaffold(
          appBar: AppBar(title: const Text('Modifier l\'utilisateur')),
          body: const AppLoading(label: 'Chargement…'),
        ),
        error: (e, _) => Scaffold(
          appBar: AppBar(title: const Text('Modifier l\'utilisateur')),
          body: AppErrorWidget(
            message: e.toString(),
            onRetry: () => ref.invalidate(userDetailProvider(widget.id!)),
          ),
        ),
      );
    }
    return _buildScaffold(isEdit: false, isAdmin: isAdmin);
  }

  Widget _buildScaffold({required bool isEdit, required bool isAdmin}) {
    return Scaffold(
      appBar: AppBar(
        title: Text(isEdit ? 'Modifier l\'utilisateur' : 'Nouvel utilisateur'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionHeader(
                      title: 'Identité',
                      icon: Icons.person_outline,
                    ),
                    const SizedBox(height: 8),
                    _TextFormField(
                      controller: _username,
                      label: 'Identifiant *',
                      hint: 'Ex : jkoffi',
                      prefixIcon: const Icon(Icons.alternate_email),
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? 'Identifiant requis.'
                          : null,
                    ),
                    _TextFormField(
                      controller: _firstName,
                      label: 'Prénom',
                      hint: 'Ex : Jean',
                      prefixIcon: const Icon(Icons.person_outline),
                    ),
                    _TextFormField(
                      controller: _lastName,
                      label: 'Nom',
                      hint: 'Ex : Koffi',
                      prefixIcon: const Icon(Icons.person_outline),
                    ),
                    DropdownButtonFormField<Sexe>(
                      value: _sexe,
                      decoration: const InputDecoration(
                        labelText: 'Sexe',
                        prefixIcon: Icon(Icons.wc_outlined),
                        border: OutlineInputBorder(),
                      ),
                      items: Sexe.values
                          .map((s) => DropdownMenuItem(
                                value: s,
                                child: Text(s.label),
                              ))
                          .toList(),
                      onChanged: (v) => setState(() => _sexe = v),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionHeader(
                      title: 'Contact',
                      icon: Icons.contact_phone_outlined,
                    ),
                    const SizedBox(height: 8),
                    _TextFormField(
                      controller: _email,
                      label: 'Email',
                      hint: 'exemple@établissement.org',
                      keyboardType: TextInputType.emailAddress,
                      prefixIcon: const Icon(Icons.mail_outline),
                      validator: (v) {
                        final s = v?.trim() ?? '';
                        if (s.isEmpty) return null;
                        final re = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
                        return re.hasMatch(s)
                            ? null
                            : 'Adresse email invalide.';
                      },
                    ),
                    _TextFormField(
                      controller: _phone,
                      label: 'Téléphone',
                      hint: 'Ex : +225 07 00 00 00 00',
                      keyboardType: TextInputType.phone,
                      prefixIcon: const Icon(Icons.phone_outlined),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SectionHeader(
                      title: 'Sécurité',
                      icon: Icons.lock_outline,
                      subtitle: isEdit
                          ? 'Laisser vide pour conserver le mot de passe actuel.'
                          : 'Mot de passe initial requis (modifiable par l\'utilisateur).',
                    ),
                    const SizedBox(height: 8),
                    _TextFormField(
                      controller: _password,
                      label: isEdit ? 'Nouveau mot de passe' : 'Mot de passe *',
                      hint: '••••••••',
                      obscureText: _obscurePassword,
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(_obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined),
                        onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword),
                      ),
                      validator: (v) {
                        if (isEdit) {
                          // Optionnel en édition : si renseigné, min 6 caractères.
                          final s = v?.trim() ?? '';
                          if (s.isEmpty) return null;
                          if (s.length < 6) {
                            return 'Au moins 6 caractères.';
                          }
                          return null;
                        }
                        // Création : requis.
                        if (v == null || v.trim().isEmpty) {
                          return 'Mot de passe requis.';
                        }
                        if (v.trim().length < 6) {
                          return 'Au moins 6 caractères.';
                        }
                        return null;
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionHeader(
                      title: 'Statut & permissions',
                      icon: Icons.admin_panel_settings_outlined,
                    ),
                    const SizedBox(height: 4),
                    SwitchListTile(
                      value: _isActive,
                      onChanged: (v) => setState(() => _isActive = v),
                      title: const Text('Compte actif'),
                      subtitle: const Text(
                          'Un compte inactif ne peut pas se connecter.'),
                      secondary: Icon(
                        _isActive ? Icons.check_circle : Icons.block,
                        color: _isActive ? Colors.green : Colors.grey,
                      ),
                    ),
                    SwitchListTile(
                      value: _isSuperuser,
                      onChanged: isAdmin
                          ? (v) => setState(() => _isSuperuser = v)
                          : null,
                      title: const Text('Superutilisateur'),
                      subtitle: Text(
                        isAdmin
                            ? 'Accorde toutes les permissions (RBAC wildcard).'
                            : 'Réservé aux superutilisateurs.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      secondary: Icon(
                        Icons.shield,
                        color: _isSuperuser
                            ? Theme.of(context).colorScheme.tertiary
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _isSaving ? null : _save,
              icon: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(_isSaving ? 'Enregistrement…' : 'Enregistrer'),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sous-widgets
// ---------------------------------------------------------------------------

class _TextFormField extends StatelessWidget {
  const _TextFormField({
    required this.controller,
    required this.label,
    this.hint,
    this.keyboardType,
    this.validator,
    this.obscureText = false,
    this.prefixIcon,
    this.suffixIcon,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;
  final bool obscureText;
  final Widget? prefixIcon;
  final Widget? suffixIcon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextFormField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: prefixIcon,
          suffixIcon: suffixIcon,
          border: const OutlineInputBorder(),
        ),
        keyboardType: keyboardType,
        obscureText: obscureText,
        validator: validator,
      ),
    );
  }
}
