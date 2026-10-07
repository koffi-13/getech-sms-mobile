/// Formulaire de création / édition d'un élève — sections complètes :
/// - Identité (matricule, nom, prénoms, sexe, date de naissance, groupe) ;
/// - Naissance (lieu, préfecture, région, pays) ;
/// - Classe & scolarité (classe, statut, type d'inscription, école
///   précédente, transport) ;
/// - Contact (téléphone, email, adresse, ville) ;
/// - Médical (groupe sanguin, allergies, médecin) ;
/// - Père / Mère (nom, prénoms, téléphone, profession) ;
/// - Tuteur (nom, prénoms, téléphone, email, relation).
///
/// Le matricule est optionnel à la création (auto-généré par le serveur si
/// vide). Le nom complet est saisi et affiché « NOM Prénoms ».
library;

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/constants.dart';
import '../../core/utils/formatters.dart';
import '../../shared/models/student_dto.dart';
import '../../shared/widgets/widgets.dart';
import '../classrooms/classroom_controller.dart';
import 'student_controller.dart';

class StudentFormPage extends ConsumerStatefulWidget {
  final int? id;
  const StudentFormPage({super.key, this.id});

  @override
  ConsumerState<StudentFormPage> createState() => _StudentFormPageState();
}

class _StudentFormPageState extends ConsumerState<StudentFormPage> {
  final _formKey = GlobalKey<FormState>();

  // Identité.
  final _nom = TextEditingController();
  final _prenoms = TextEditingController();
  final _matricule = TextEditingController();
  final _groupe = TextEditingController();
  DateTime? _dob;
  Sexe? _sexe;

  // Naissance.
  final _birthPlace = TextEditingController();
  final _birthPrefecture = TextEditingController();
  final _birthRegion = TextEditingController();
  final _birthCountry = TextEditingController();

  // Classe & scolarité.
  int? _classroomId;
  StudentStatus? _status;
  InscriptionType? _inscriptionType;
  final _previousSchool = TextEditingController();
  final _transport = TextEditingController();

  // Contact.
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _address = TextEditingController();
  final _city = TextEditingController();

  // Médical.
  BloodType? _bloodType;
  final _allergies = TextEditingController();
  final _doctor = TextEditingController();

  // Père.
  final _pereNom = TextEditingController();
  final _perePrenoms = TextEditingController();
  final _perePhone = TextEditingController();
  final _pereProfession = TextEditingController();

  // Mère.
  final _mereNom = TextEditingController();
  final _merePrenoms = TextEditingController();
  final _merePhone = TextEditingController();
  final _mereProfession = TextEditingController();

  // Tuteur.
  final _tuteurNom = TextEditingController();
  final _tuteurPrenoms = TextEditingController();
  final _tuteurPhone = TextEditingController();
  final _tuteurEmail = TextEditingController();
  final _tuteurRelation = TextEditingController();

  bool _loading = false;
  bool _loaded = false;

  bool get _isEdit => widget.id != null;

  @override
  void initState() {
    super.initState();
    if (_isEdit) {
      _loadStudent();
    } else {
      _loaded = true;
    }
  }

  @override
  void dispose() {
    for (final c in [
      _nom, _prenoms, _matricule, _groupe,
      _birthPlace, _birthPrefecture, _birthRegion, _birthCountry,
      _previousSchool, _transport,
      _phone, _email, _address, _city,
      _allergies, _doctor,
      _pereNom, _perePrenoms, _perePhone, _pereProfession,
      _mereNom, _merePrenoms, _merePhone, _mereProfession,
      _tuteurNom, _tuteurPrenoms, _tuteurPhone, _tuteurEmail,
      _tuteurRelation,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadStudent() async {
    try {
      final s = await ref.read(studentDetailProvider(widget.id!).future);
      if (!mounted) return;
      _nom.text = s.nom ?? '';
      _prenoms.text = s.prenoms ?? '';
      _matricule.text = s.matricule;
      _groupe.text = s.groupe ?? '';
      _dob = s.dob;
      _sexe = s.sexe;
      _birthPlace.text = s.birthPlace ?? '';
      _birthPrefecture.text = s.birthPrefecture ?? '';
      _birthRegion.text = s.birthRegion ?? '';
      _birthCountry.text = s.birthCountry ?? '';
      _classroomId = s.classroomId;
      _status = s.status;
      _inscriptionType = s.inscriptionType;
      if (s.scholastic != null) {
        _previousSchool.text = s.scholastic!.previousSchool ?? '';
        _transport.text = s.scholastic!.transport ?? '';
      }
      if (s.contact != null) {
        _phone.text = s.contact!.phone ?? '';
        _email.text = s.contact!.email ?? '';
        _address.text = s.contact!.address ?? '';
        _city.text = s.contact!.city ?? '';
      }
      if (s.medical != null) {
        _bloodType = s.medical!.bloodType;
        _allergies.text = s.medical!.allergies ?? '';
        _doctor.text = s.medical!.doctor ?? '';
      }
      for (final p in s.parents) {
        if (p.role == 'PERE') {
          _pereNom.text = p.nom ?? '';
          _perePrenoms.text = p.prenoms ?? '';
          _perePhone.text = p.phone ?? '';
          _pereProfession.text = p.profession ?? '';
        } else if (p.role == 'MERE') {
          _mereNom.text = p.nom ?? '';
          _merePrenoms.text = p.prenoms ?? '';
          _merePhone.text = p.phone ?? '';
          _mereProfession.text = p.profession ?? '';
        }
      }
      if (s.guardians.isNotEmpty) {
        final g = s.guardians.first;
        _tuteurNom.text = g.nom ?? '';
        _tuteurPrenoms.text = g.prenoms ?? '';
        _tuteurPhone.text = g.phone ?? '';
        _tuteurEmail.text = g.email ?? '';
        _tuteurRelation.text = g.relation ?? '';
      }
      setState(() => _loaded = true);
    } catch (e) {
      if (mounted) {
        setState(() => _loaded = true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Impossible de charger l\'élève : $e'),
              backgroundColor: Colors.red.shade700),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final classroomsAsync = ref.watch(classroomsProvider);

    return Scaffold(
      appBar: AppBar(
          title: Text(_isEdit ? 'Modifier l\'élève' : 'Nouvel élève')),
      body: !_loaded
          ? const AppLoading()
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _section(context, 'Identité', Icons.badge_outlined, [
                    TextFormField(
                      controller: _nom,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: 'Nom *',
                        hintText: 'Nom de famille',
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Champ requis' : null,
                    ),
                    TextFormField(
                      controller: _prenoms,
                      decoration: const InputDecoration(
                        labelText: 'Prénoms',
                        hintText: 'Prénoms de l\'élève',
                      ),
                    ),
                    TextFormField(
                      controller: _matricule,
                      decoration: InputDecoration(
                        labelText: _isEdit ? 'Matricule' : 'Matricule',
                        helperText: _isEdit
                            ? null
                            : 'Laissez vide pour auto-générer',
                      ),
                    ),
                    DropdownButtonFormField<Sexe>(
                      value: _sexe,
                      items: Sexe.values
                          .map((s) => DropdownMenuItem(
                              value: s, child: Text(s.label)))
                          .toList(),
                      onChanged: (v) => setState(() => _sexe = v),
                      decoration: const InputDecoration(labelText: 'Sexe'),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Date de naissance'),
                      subtitle: Text(
                          _dob == null ? 'Non définie' : DateFormatter.date(_dob!)),
                      trailing: const Icon(Icons.calendar_today),
                      onTap: _pickDob,
                    ),
                    TextFormField(
                      controller: _groupe,
                      decoration: const InputDecoration(
                          labelText: 'Groupe (optionnel)'),
                    ),
                  ]),
                  _section(context, 'Lieu de naissance',
                      Icons.place_outlined, [
                    TextFormField(
                      controller: _birthPlace,
                      decoration:
                          const InputDecoration(labelText: 'Lieu de naissance'),
                    ),
                    TextFormField(
                      controller: _birthPrefecture,
                      decoration: const InputDecoration(labelText: 'Préfecture'),
                    ),
                    TextFormField(
                      controller: _birthRegion,
                      decoration: const InputDecoration(labelText: 'Région'),
                    ),
                    TextFormField(
                      controller: _birthCountry,
                      decoration: const InputDecoration(labelText: 'Pays'),
                    ),
                  ]),
                  _section(
                      context, 'Classe & scolarité', Icons.school_outlined, [
                    classroomsAsync.when(
                      data: (list) {
                        // Garde : la valeur doit exister dans les items.
                        final effectiveValue = (list.any((c) => c.id == _classroomId))
                            ? _classroomId
                            : null;
                        return DropdownButtonFormField<int>(
                          value: effectiveValue,
                          items: [
                            const DropdownMenuItem(
                                value: null, child: Text('Non classé')),
                            ...list.map((c) => DropdownMenuItem(
                                value: c.id, child: Text(c.name))),
                          ],
                          onChanged: (v) => setState(() => _classroomId = v),
                          decoration:
                              const InputDecoration(labelText: 'Classe'),
                        );
                      },
                      loading: () => const LinearProgressIndicator(),
                      error: (e, st) => Text('Erreur classes : $e'),
                    ),
                    DropdownButtonFormField<StudentStatus>(
                      value: _status,
                      items: StudentStatus.values
                          .map((s) => DropdownMenuItem(
                              value: s, child: Text(s.label)))
                          .toList(),
                      onChanged: (v) => setState(() => _status = v),
                      decoration:
                          const InputDecoration(labelText: 'Statut'),
                    ),
                    DropdownButtonFormField<InscriptionType>(
                      value: _inscriptionType,
                      items: InscriptionType.values
                          .map((s) => DropdownMenuItem(
                              value: s, child: Text(s.label)))
                          .toList(),
                      onChanged: (v) => setState(() => _inscriptionType = v),
                      decoration: const InputDecoration(
                          labelText: 'Type d\'inscription'),
                    ),
                    TextFormField(
                      controller: _previousSchool,
                      decoration: const InputDecoration(
                          labelText: 'École précédente'),
                    ),
                    TextFormField(
                      controller: _transport,
                      decoration: const InputDecoration(
                          labelText: 'Transport'),
                    ),
                  ]),
                  _section(
                      context, 'Contact', Icons.contact_phone_outlined, [
                    TextFormField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                          labelText: 'Téléphone'),
                    ),
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(labelText: 'Email'),
                    ),
                    TextFormField(
                      controller: _address,
                      decoration: const InputDecoration(labelText: 'Adresse'),
                    ),
                    TextFormField(
                      controller: _city,
                      decoration: const InputDecoration(labelText: 'Ville'),
                    ),
                  ]),
                  _section(context, 'Médical', Icons.medical_services_outlined,
                      [
                    DropdownButtonFormField<BloodType>(
                      value: _bloodType,
                      items: const [
                        DropdownMenuItem(value: null, child: Text('Inconnu')),
                        DropdownMenuItem(
                            value: BloodType.aPlus, child: Text('A+')),
                        DropdownMenuItem(
                            value: BloodType.aMoins, child: Text('A-')),
                        DropdownMenuItem(
                            value: BloodType.bPlus, child: Text('B+')),
                        DropdownMenuItem(
                            value: BloodType.bMoins, child: Text('B-')),
                        DropdownMenuItem(
                            value: BloodType.abPlus, child: Text('AB+')),
                        DropdownMenuItem(
                            value: BloodType.abMoins, child: Text('AB-')),
                        DropdownMenuItem(
                            value: BloodType.oPlus, child: Text('O+')),
                        DropdownMenuItem(
                            value: BloodType.oMoins, child: Text('O-')),
                      ],
                      onChanged: (v) => setState(() => _bloodType = v),
                      decoration: const InputDecoration(
                          labelText: 'Groupe sanguin'),
                    ),
                    TextFormField(
                      controller: _allergies,
                      decoration: const InputDecoration(
                          labelText: 'Allergies'),
                    ),
                    TextFormField(
                      controller: _doctor,
                      decoration: const InputDecoration(
                          labelText: 'Médecin traitant'),
                    ),
                  ]),
                  _section(context, 'Père', Icons.man_outlined, [
                    TextFormField(
                      controller: _pereNom,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(labelText: 'Nom'),
                    ),
                    TextFormField(
                      controller: _perePrenoms,
                      decoration: const InputDecoration(labelText: 'Prénoms'),
                    ),
                    TextFormField(
                      controller: _perePhone,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(labelText: 'Téléphone'),
                    ),
                    TextFormField(
                      controller: _pereProfession,
                      decoration: const InputDecoration(labelText: 'Profession'),
                    ),
                  ]),
                  _section(context, 'Mère', Icons.woman_outlined, [
                    TextFormField(
                      controller: _mereNom,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(labelText: 'Nom'),
                    ),
                    TextFormField(
                      controller: _merePrenoms,
                      decoration: const InputDecoration(labelText: 'Prénoms'),
                    ),
                    TextFormField(
                      controller: _merePhone,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(labelText: 'Téléphone'),
                    ),
                    TextFormField(
                      controller: _mereProfession,
                      decoration: const InputDecoration(labelText: 'Profession'),
                    ),
                  ]),
                  _section(context, 'Tuteur', Icons.supervisor_account_outlined,
                      [
                    TextFormField(
                      controller: _tuteurNom,
                      textCapitalization: TextCapitalization.characters,
                      decoration:
                          const InputDecoration(labelText: 'Nom du tuteur'),
                    ),
                    TextFormField(
                      controller: _tuteurPrenoms,
                      decoration: const InputDecoration(labelText: 'Prénoms'),
                    ),
                    TextFormField(
                      controller: _tuteurPhone,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(labelText: 'Téléphone'),
                    ),
                    TextFormField(
                      controller: _tuteurEmail,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(labelText: 'Email'),
                    ),
                    TextFormField(
                      controller: _tuteurRelation,
                      decoration: const InputDecoration(
                          labelText: 'Relation (ex. oncle, tuteur légal)'),
                    ),
                  ]),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _loading ? null : _submit,
                    icon: _loading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: const Text('Enregistrer'),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
    );
  }

  Widget _section(
      BuildContext context, String title, IconData icon, List<Widget> fields) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Icon(icon, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 4),
              ...fields
                  .expand((f) => [f, const SizedBox(height: 12)])
                  .toList()
                ..removeLast(),
            ],
          ),
        ),
      ),
    );
  }

  void _pickDob() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(2010),
      firstDate: DateTime(1990),
      lastDate: DateTime.now(),
    );
    if (d != null) setState(() => _dob = d);
  }

  StudentDto _buildDto() {
    final parents = <StudentParentDto>[];
    if (_pereNom.text.trim().isNotEmpty || _perePhone.text.trim().isNotEmpty) {
      parents.add(StudentParentDto(
        role: 'PERE',
        nom: _pereNom.text.trim(),
        prenoms: _perePrenoms.text.trim(),
        phone: _perePhone.text.trim(),
        profession: _pereProfession.text.trim(),
      ));
    }
    if (_mereNom.text.trim().isNotEmpty || _merePhone.text.trim().isNotEmpty) {
      parents.add(StudentParentDto(
        role: 'MERE',
        nom: _mereNom.text.trim(),
        prenoms: _merePrenoms.text.trim(),
        phone: _merePhone.text.trim(),
        profession: _mereProfession.text.trim(),
      ));
    }
    final guardians = <GuardianDto>[];
    if (_tuteurNom.text.trim().isNotEmpty ||
        _tuteurPhone.text.trim().isNotEmpty) {
      guardians.add(GuardianDto(
        nom: _tuteurNom.text.trim(),
        prenoms: _tuteurPrenoms.text.trim(),
        phone: _tuteurPhone.text.trim(),
        email: _tuteurEmail.text.trim(),
        relation: _tuteurRelation.text.trim(),
      ));
    }

    return StudentDto(
      id: widget.id ?? 0,
      nom: _nom.text.trim(),
      prenoms: _prenoms.text.trim(),
      matricule: _matricule.text.trim(),
      dob: _dob,
      sexe: _sexe,
      birthPlace: _birthPlace.text.trim(),
      birthPrefecture: _birthPrefecture.text.trim(),
      birthRegion: _birthRegion.text.trim(),
      birthCountry: _birthCountry.text.trim(),
      groupe: _groupe.text.trim(),
      classroomId: _classroomId,
      status: _status,
      inscriptionType: _inscriptionType,
      contact: StudentContactDto(
        phone: _phone.text.trim(),
        email: _email.text.trim(),
        address: _address.text.trim(),
        city: _city.text.trim(),
      ),
      medical: StudentMedicalDto(
        bloodType: _bloodType,
        allergies: _allergies.text.trim(),
        doctor: _doctor.text.trim(),
      ),
      scholastic: StudentScholasticDto(
        previousSchool: _previousSchool.text.trim(),
        transport: _transport.text.trim(),
      ),
      parents: parents,
      guardians: guardians,
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      await ref.read(studentRepositoryProvider).save(_buildDto());
      ref.invalidate(studentControllerProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_isEdit
                ? 'Élève modifié.'
                : 'Élève enregistré (synchronisation serveur en arrière-plan).'),
          ),
        );
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Erreur : $e'),
              backgroundColor: Colors.red.shade700),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}
