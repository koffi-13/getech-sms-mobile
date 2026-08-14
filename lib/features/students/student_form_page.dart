/// Page "Formulaire élève" : création (id null) ou édition (id non null).
///
/// Champs : identité + lieu de naissance, contact, médical, scolarité, parents
/// (père/mère), tuteur, photo (image_picker). Validation : matricule + nom
/// requis. Sauvegarde via [studentRepositoryProvider] (POST ou PATCH en ligne,
/// outbox hors-ligne).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/config/constants.dart';
import '../../core/utils/formatters.dart';
import '../../shared/models/student_dto.dart';
import '../../shared/widgets/widgets.dart';
import 'student_controller.dart';

class StudentFormPage extends ConsumerStatefulWidget {
  const StudentFormPage({super.key, this.id});

  final int? id;

  @override
  ConsumerState<StudentFormPage> createState() => _StudentFormPageState();
}

class _StudentFormPageState extends ConsumerState<StudentFormPage> {
  final _formKey = GlobalKey<FormState>();
  bool _isSaving = false;
  bool _isPopulated = false;

  // Contrôleurs Identité.
  late final TextEditingController _matricule;
  late final TextEditingController _nom;
  late final TextEditingController _prenoms;
  late final TextEditingController _birthPlace;
  late final TextEditingController _birthPrefecture;
  late final TextEditingController _birthRegion;
  late final TextEditingController _birthCountry;
  late final TextEditingController _groupe;
  DateTime? _dob;
  Sexe? _sexe;

  // Contact.
  late final TextEditingController _phone;
  late final TextEditingController _email;
  late final TextEditingController _address;
  late final TextEditingController _city;

  // Médical.
  BloodType? _bloodType;
  late final TextEditingController _allergies;
  late final TextEditingController _doctor;

  // Scolarité.
  late final TextEditingController _previousSchool;
  late final TextEditingController _transport;

  // Père.
  late final TextEditingController _pereNom;
  late final TextEditingController _perePrenoms;
  late final TextEditingController _perePhone;
  late final TextEditingController _pereProfession;

  // Mère.
  late final TextEditingController _mereNom;
  late final TextEditingController _merePrenoms;
  late final TextEditingController _merePhone;
  late final TextEditingController _mereProfession;

  // Tuteur.
  late final TextEditingController _tuteurNom;
  late final TextEditingController _tuteurPrenoms;
  late final TextEditingController _tuteurPhone;
  late final TextEditingController _tuteurRelation;

  // Photo.
  String? _photoPath;

  // Données existantes (edit mode).
  StudentDto? _existing;

  @override
  void initState() {
    super.initState();
    _matricule = TextEditingController();
    _nom = TextEditingController();
    _prenoms = TextEditingController();
    _birthPlace = TextEditingController();
    _birthPrefecture = TextEditingController();
    _birthRegion = TextEditingController();
    _birthCountry = TextEditingController();
    _groupe = TextEditingController();
    _phone = TextEditingController();
    _email = TextEditingController();
    _address = TextEditingController();
    _city = TextEditingController();
    _allergies = TextEditingController();
    _doctor = TextEditingController();
    _previousSchool = TextEditingController();
    _transport = TextEditingController();
    _pereNom = TextEditingController();
    _perePrenoms = TextEditingController();
    _perePhone = TextEditingController();
    _pereProfession = TextEditingController();
    _mereNom = TextEditingController();
    _merePrenoms = TextEditingController();
    _merePhone = TextEditingController();
    _mereProfession = TextEditingController();
    _tuteurNom = TextEditingController();
    _tuteurPrenoms = TextEditingController();
    _tuteurPhone = TextEditingController();
    _tuteurRelation = TextEditingController();
  }

  @override
  void dispose() {
    for (final c in [
      _matricule, _nom, _prenoms, _birthPlace, _birthPrefecture,
      _birthRegion, _birthCountry, _groupe, _phone, _email, _address, _city,
      _allergies, _doctor, _previousSchool, _transport, _pereNom, _perePrenoms,
      _perePhone, _pereProfession, _mereNom, _merePrenoms, _merePhone,
      _mereProfession, _tuteurNom, _tuteurPrenoms, _tuteurPhone, _tuteurRelation,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _populateFromDto(StudentDto dto) {
    if (_isPopulated) return;
    _isPopulated = true;
    _existing = dto;

    _matricule.text = dto.matricule;
    _nom.text = dto.nom;
    _prenoms.text = dto.prenoms ?? '';
    _dob = dto.dob;
    _sexe = dto.sexe;
    _birthPlace.text = dto.birthPlace ?? '';
    _birthPrefecture.text = dto.birthPrefecture ?? '';
    _birthRegion.text = dto.birthRegion ?? '';
    _birthCountry.text = dto.birthCountry ?? '';
    _groupe.text = dto.groupe ?? '';
    _photoPath = dto.photoPath;

    final c = dto.contact;
    _phone.text = c?.phone ?? '';
    _email.text = c?.email ?? '';
    _address.text = c?.address ?? '';
    _city.text = c?.city ?? '';

    final m = dto.medical;
    _bloodType = m?.bloodType;
    _allergies.text = m?.allergies ?? '';
    _doctor.text = m?.doctor ?? '';

    final s = dto.scholastic;
    _previousSchool.text = s?.previousSchool ?? '';
    _transport.text = s?.transport ?? '';

    for (final p in dto.parents) {
      if (p.role == 'MERE') {
        _mereNom.text = p.nom ?? '';
        _merePrenoms.text = p.prenoms ?? '';
        _merePhone.text = p.phone ?? '';
        _mereProfession.text = p.profession ?? '';
      } else {
        _pereNom.text = p.nom ?? '';
        _perePrenoms.text = p.prenoms ?? '';
        _perePhone.text = p.phone ?? '';
        _pereProfession.text = p.profession ?? '';
      }
    }

    if (dto.guardians.isNotEmpty) {
      final g = dto.guardians.first;
      _tuteurNom.text = g.nom ?? '';
      _tuteurPrenoms.text = g.prenoms ?? '';
      _tuteurPhone.text = g.phone ?? '';
      _tuteurRelation.text = g.relation ?? '';
    }
  }

  StudentDto _buildDto() {
    final isEdit = widget.id != null && widget.id! > 0;
    final id = isEdit ? widget.id! : 0;

    final parents = <StudentParentDto>[];
    if (_pereNom.text.isNotEmpty || _perePhone.text.isNotEmpty) {
      parents.add(StudentParentDto(
        role: 'PERE',
        nom: _pereNom.text.trim().isEmpty ? null : _pereNom.text.trim(),
        prenoms: _perePrenoms.text.trim().isEmpty ? null : _perePrenoms.text.trim(),
        phone: _perePhone.text.trim().isEmpty ? null : _perePhone.text.trim(),
        profession: _pereProfession.text.trim().isEmpty
            ? null
            : _pereProfession.text.trim(),
      ));
    }
    if (_mereNom.text.isNotEmpty || _merePhone.text.isNotEmpty) {
      parents.add(StudentParentDto(
        role: 'MERE',
        nom: _mereNom.text.trim().isEmpty ? null : _mereNom.text.trim(),
        prenoms: _merePrenoms.text.trim().isEmpty ? null : _merePrenoms.text.trim(),
        phone: _merePhone.text.trim().isEmpty ? null : _merePhone.text.trim(),
        profession: _mereProfession.text.trim().isEmpty
            ? null
            : _mereProfession.text.trim(),
      ));
    }

    final guardians = <GuardianDto>[];
    if (_tuteurNom.text.isNotEmpty || _tuteurPhone.text.isNotEmpty) {
      guardians.add(GuardianDto(
        nom: _tuteurNom.text.trim().isEmpty ? null : _tuteurNom.text.trim(),
        prenoms:
            _tuteurPrenoms.text.trim().isEmpty ? null : _tuteurPrenoms.text.trim(),
        phone: _tuteurPhone.text.trim().isEmpty ? null : _tuteurPhone.text.trim(),
        relation:
            _tuteurRelation.text.trim().isEmpty ? null : _tuteurRelation.text.trim(),
      ));
    }

    // Satellites : on les inclut seulement si au moins un champ est renseigné.
    final hasContact = _phone.text.isNotEmpty ||
        _email.text.isNotEmpty ||
        _address.text.isNotEmpty ||
        _city.text.isNotEmpty;
    final hasMedical = _bloodType != null ||
        _allergies.text.isNotEmpty ||
        _doctor.text.isNotEmpty;
    final hasScholastic =
        _previousSchool.text.isNotEmpty || _transport.text.isNotEmpty;

    // Préserve les IDs satellites existants lors d'une édition.
    final existing = _existing;
    final existingContactId = existing?.contact?.id;
    final existingMedicalId = existing?.medical?.id;
    final existingScholasticId = existing?.scholastic?.id;

    return StudentDto(
      id: id,
      matricule: _matricule.text.trim(),
      nom: _nom.text.trim(),
      prenoms: _prenoms.text.trim().isEmpty ? null : _prenoms.text.trim(),
      dob: _dob,
      sexe: _sexe,
      birthPlace:
          _birthPlace.text.trim().isEmpty ? null : _birthPlace.text.trim(),
      birthPrefecture: _birthPrefecture.text.trim().isEmpty
          ? null
          : _birthPrefecture.text.trim(),
      birthRegion:
          _birthRegion.text.trim().isEmpty ? null : _birthRegion.text.trim(),
      birthCountry:
          _birthCountry.text.trim().isEmpty ? null : _birthCountry.text.trim(),
      photoPath: _photoPath,
      groupe: _groupe.text.trim().isEmpty ? null : _groupe.text.trim(),
      contact: hasContact
          ? StudentContactDto(
              id: existingContactId,
              phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
              email: _email.text.trim().isEmpty ? null : _email.text.trim(),
              address: _address.text.trim().isEmpty ? null : _address.text.trim(),
              city: _city.text.trim().isEmpty ? null : _city.text.trim(),
            )
          : null,
      medical: hasMedical
          ? StudentMedicalDto(
              id: existingMedicalId,
              bloodType: _bloodType,
              allergies:
                  _allergies.text.trim().isEmpty ? null : _allergies.text.trim(),
              doctor: _doctor.text.trim().isEmpty ? null : _doctor.text.trim(),
            )
          : null,
      scholastic: hasScholastic
          ? StudentScholasticDto(
              id: existingScholasticId,
              previousSchool: _previousSchool.text.trim().isEmpty
                  ? null
                  : _previousSchool.text.trim(),
              transport:
                  _transport.text.trim().isEmpty ? null : _transport.text.trim(),
            )
          : null,
      parents: parents,
      guardians: guardians,
      classroomId: existing?.classroomId,
      classroomName: existing?.classroomName,
      status: existing?.status,
      inscriptionType: existing?.inscriptionType,
    );
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(now.year - 15),
      firstDate: DateTime(1950),
      lastDate: now,
      locale: const Locale('fr'),
    );
    if (picked != null) {
      setState(() => _dob = picked);
    }
  }

  Future<void> _pickPhoto(ImageSource source) async {
    try {
      final picker = ImagePicker();
      final xFile = await picker.pickImage(
        source: source,
        imageQuality: 80,
        maxWidth: 600,
        maxHeight: 600,
      );
      if (xFile != null) {
        setState(() => _photoPath = xFile.path);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Photo indisponible : $e')),
        );
      }
    }
  }

  void _showPhotoSourcePicker() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Caméra'),
              onTap: () {
                Navigator.pop(ctx);
                _pickPhoto(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Galerie'),
              onTap: () {
                Navigator.pop(ctx);
                _pickPhoto(ImageSource.gallery);
              },
            ),
            if (_photoPath != null)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('Retirer la photo'),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() => _photoPath = null);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);
    final dto = _buildDto();
    try {
      final repo = ref.read(studentRepositoryProvider);
      final saved = await repo.save(dto);
      // Invalide le cache de la liste et du détail pour la prochaine visite.
      ref.invalidate(studentsListProvider);
      ref.invalidate(studentDetailProvider(saved.id));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Élève enregistré avec succès.')),
        );
        context.pop();
      }
    } on StudentRepositoryException catch (e) {
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
    final isEdit = widget.id != null;

    // En mode édition : pré-chargement via studentDetailProvider.
    if (isEdit) {
      final async = ref.watch(studentDetailProvider(widget.id!));
      return async.when(
        data: (dto) {
          _populateFromDto(dto);
          return _buildScaffold(isEdit: true);
        },
        loading: () => Scaffold(
          appBar: AppBar(title: const Text('Modifier l\'élève')),
          body: const AppLoading(label: 'Chargement…'),
        ),
        error: (e, _) => Scaffold(
          appBar: AppBar(title: const Text('Modifier l\'élève')),
          body: AppErrorWidget(
            message: e.toString(),
            onRetry: () => ref.invalidate(studentDetailProvider(widget.id!)),
          ),
        ),
      );
    }

    return _buildScaffold(isEdit: false);
  }

  Widget _buildScaffold({required bool isEdit}) {
    return Scaffold(
      appBar: AppBar(
        title: Text(isEdit ? 'Modifier l\'élève' : 'Nouvel élève'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Photo.
            _PhotoPicker(
              photoPath: _photoPath,
              initials: _buildInitialsPreview(),
              onPick: _showPhotoSourcePicker,
              sexe: _sexe,
            ),
            const SizedBox(height: 16),

            // Identité.
            _Section(
              title: 'Identité',
              icon: Icons.person_outline,
              children: [
                _TextFormField(
                  controller: _matricule,
                  label: 'Matricule *',
                  hint: 'Ex : ELV-2025-001',
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Matricule requis.' : null,
                ),
                _TextFormField(
                  controller: _nom,
                  label: 'Nom *',
                  hint: 'Ex : Koffi',
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Nom requis.' : null,
                ),
                _TextFormField(
                  controller: _prenoms,
                  label: 'Prénoms',
                  hint: 'Ex : Jean Marc',
                ),
                _DateField(
                  label: 'Date de naissance',
                  value: _dob,
                  onTap: _pickDate,
                ),
                DropdownButtonFormField<Sexe>(
                  value: _sexe,
                  decoration: const InputDecoration(
                    labelText: 'Sexe',
                    prefixIcon: Icon(Icons.wc_outlined),
                  ),
                  items: Sexe.values
                      .map((s) => DropdownMenuItem(
                            value: s,
                            child: Text(s.label),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() => _sexe = v),
                ),
                _TextFormField(
                  controller: _birthPlace,
                  label: 'Lieu de naissance',
                ),
                _TextFormField(
                  controller: _birthPrefecture,
                  label: 'Préfecture',
                ),
                _TextFormField(
                  controller: _birthRegion,
                  label: 'Région',
                ),
                _TextFormField(
                  controller: _birthCountry,
                  label: 'Pays',
                ),
                _TextFormField(
                  controller: _groupe,
                  label: 'Groupe',
                  hint: 'Ex : A',
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Contact.
            _Section(
              title: 'Contact',
              icon: Icons.contact_phone_outlined,
              children: [
                _TextFormField(
                  controller: _phone,
                  label: 'Téléphone',
                  hint: 'Ex : +225 07 00 00 00 00',
                  keyboardType: TextInputType.phone,
                ),
                _TextFormField(
                  controller: _email,
                  label: 'Email',
                  keyboardType: TextInputType.emailAddress,
                ),
                _TextFormField(controller: _address, label: 'Adresse'),
                _TextFormField(controller: _city, label: 'Ville'),
              ],
            ),
            const SizedBox(height: 16),

            // Médical.
            _Section(
              title: 'Médical',
              icon: Icons.medical_services_outlined,
              children: [
                DropdownButtonFormField<BloodType>(
                  value: _bloodType,
                  decoration: const InputDecoration(
                    labelText: 'Groupe sanguin',
                    prefixIcon: Icon(Icons.bloodtype_outlined),
                  ),
                  items: BloodType.values
                      .map((b) => DropdownMenuItem(
                            value: b,
                            child: Text(_bloodLabel(b)),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() => _bloodType = v),
                ),
                _TextFormField(controller: _allergies, label: 'Allergies'),
                _TextFormField(controller: _doctor, label: 'Médecin'),
              ],
            ),
            const SizedBox(height: 16),

            // Scolarité.
            _Section(
              title: 'Scolarité',
              icon: Icons.school_outlined,
              children: [
                _TextFormField(
                  controller: _previousSchool,
                  label: 'Établissement précédent',
                ),
                _TextFormField(controller: _transport, label: 'Transport'),
              ],
            ),
            const SizedBox(height: 16),

            // Père.
            _Section(
              title: 'Père',
              icon: Icons.male,
              children: [
                _TextFormField(controller: _pereNom, label: 'Nom'),
                _TextFormField(controller: _perePrenoms, label: 'Prénoms'),
                _TextFormField(
                  controller: _perePhone,
                  label: 'Téléphone',
                  keyboardType: TextInputType.phone,
                ),
                _TextFormField(controller: _pereProfession, label: 'Profession'),
              ],
            ),
            const SizedBox(height: 16),

            // Mère.
            _Section(
              title: 'Mère',
              icon: Icons.female,
              children: [
                _TextFormField(controller: _mereNom, label: 'Nom'),
                _TextFormField(controller: _merePrenoms, label: 'Prénoms'),
                _TextFormField(
                  controller: _merePhone,
                  label: 'Téléphone',
                  keyboardType: TextInputType.phone,
                ),
                _TextFormField(controller: _mereProfession, label: 'Profession'),
              ],
            ),
            const SizedBox(height: 16),

            // Tuteur.
            _Section(
              title: 'Tuteur',
              icon: Icons.supervisor_account_outlined,
              children: [
                _TextFormField(controller: _tuteurNom, label: 'Nom'),
                _TextFormField(controller: _tuteurPrenoms, label: 'Prénoms'),
                _TextFormField(
                  controller: _tuteurPhone,
                  label: 'Téléphone',
                  keyboardType: TextInputType.phone,
                ),
                _TextFormField(controller: _tuteurRelation, label: 'Relation'),
              ],
            ),
            const SizedBox(height: 24),

            // Bouton de sauvegarde.
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

  String _buildInitialsPreview() {
    final p = _prenoms.text.isNotEmpty ? _prenoms.text[0] : '';
    final n = _nom.text.isNotEmpty ? _nom.text[0] : '';
    return '$p$n'.toUpperCase();
  }

  static String _bloodLabel(BloodType b) {
    const labels = {
      BloodType.aPlus: 'A+',
      BloodType.aMoins: 'A−',
      BloodType.bPlus: 'B+',
      BloodType.bMoins: 'B−',
      BloodType.abPlus: 'AB+',
      BloodType.abMoins: 'AB−',
      BloodType.oPlus: 'O+',
      BloodType.oMoins: 'O−',
      BloodType.inconnu: 'Inconnu',
    };
    return labels[b] ?? b.name;
  }
}

// ---------------------------------------------------------------------------
// Sous-widgets
// ---------------------------------------------------------------------------

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.icon,
    required this.children,
  });
  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(title: title, icon: icon),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _TextFormField extends StatelessWidget {
  const _TextFormField({
    required this.controller,
    required this.label,
    this.hint,
    this.keyboardType,
    this.validator,
  });
  final TextEditingController controller;
  final String label;
  final String? hint;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextFormField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
        keyboardType: keyboardType,
        validator: validator,
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onTap,
  });
  final String label;
  final DateTime? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        onTap: onTap,
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            prefixIcon: const Icon(Icons.calendar_today_outlined),
            border: const OutlineInputBorder(),
          ),
          child: Text(
            DateFormatter.date(value),
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      ),
    );
  }
}

class _PhotoPicker extends StatelessWidget {
  const _PhotoPicker({
    required this.photoPath,
    required this.initials,
    required this.onPick,
    required this.sexe,
  });
  final String? photoPath;
  final String initials;
  final VoidCallback onPick;
  final Sexe? sexe;

  @override
  Widget build(BuildContext context) {
    final color = sexe == Sexe.feminin
        ? Colors.pink.shade300
        : (sexe == Sexe.masculin ? Colors.blue.shade300 : Colors.teal);
    final hasPhoto = photoPath != null && photoPath!.isNotEmpty;

    return Center(
      child: Column(
        children: [
          GestureDetector(
            onTap: onPick,
            child: CircleAvatar(
              radius: 56,
              backgroundColor: color,
              child: hasPhoto
                  ? ClipOval(
                      child: Image.network(
                        photoPath!,
                        fit: BoxFit.cover,
                        width: 112,
                        height: 112,
                        errorBuilder: (_, __, ___) => Text(
                          initials,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 28),
                        ),
                      ),
                    )
                  : Text(
                      initials,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 28),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: onPick,
            icon: const Icon(Icons.photo_camera_outlined),
            label: Text(hasPhoto ? 'Changer la photo' : 'Photo'),
          ),
        ],
      ),
    );
  }
}
