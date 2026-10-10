/// DTOs Élèves — alignés sur les schémas Pydantic du desktop.
///
/// `StudentResponse` serveur : {id, public_id, matricule, nom, prenoms,
/// establishment_id, dob, sexe, classroom_name, inscription_type_label,
/// student_status_label, age, photo_path}.
///
/// Les satellites (contact, médical, scolarité, parents, tuteur) ne sont PAS
/// inclus dans la réponse liste ; ils proviennent d'endpoints dédiés ou d'un
/// enrichissement futur de /students/{id}.
library;

import '../../core/config/constants.dart';
import '../../core/utils/formatters.dart';

/// Élève (StudentResponse côté serveur).
class StudentDto {
  final int id;
  final String publicId;
  final String matricule;
  final String? nom;
  final String? prenoms;
  final int? establishmentId;
  final DateTime? dob;
  final Sexe? sexe;
  // Champs enrichis (desktop-app parity)
  final String? classroomName;
  final String? inscriptionTypeLabel;
  final String? studentStatusLabel;
  final int? age;
  final String? photoPath;
  // Champs satellites (non dans la réponse liste, mais utilisés en détail/form)
  final String? birthPlace;
  final String? birthPrefecture;
  final String? birthRegion;
  final String? birthCountry;
  final String? groupe;
  final int? classroomId;
  final StudentStatus? status;
  final InscriptionType? inscriptionType;
  final StudentContactDto? contact;
  final StudentMedicalDto? medical;
  final StudentScholasticDto? scholastic;
  final List<StudentParentDto> parents;
  final List<GuardianDto> guardians;

  const StudentDto({
    required this.id,
    this.publicId = '',
    required this.matricule,
    this.nom,
    this.prenoms,
    this.establishmentId,
    this.dob,
    this.sexe,
    this.classroomName,
    this.inscriptionTypeLabel,
    this.studentStatusLabel,
    this.age,
    this.photoPath,
    this.birthPlace,
    this.birthPrefecture,
    this.birthRegion,
    this.birthCountry,
    this.groupe,
    this.classroomId,
    this.status,
    this.inscriptionType,
    this.contact,
    this.medical,
    this.scholastic,
    this.parents = const [],
    this.guardians = const [],
  });

  /// Nom complet au format « NOM Prénoms » (convention scolaire : le nom de
  /// famille d'abord, comme dans la version desktop).
  String get fullName =>
      [nom, prenoms].whereType<String>().where((s) => s.isNotEmpty).join(' ');

  String get displayInitials {
    final n = (nom?.isNotEmpty == true) ? nom![0] : '';
    final p = prenoms?.isNotEmpty == true ? prenoms![0] : '';
    return '$n$p'.toUpperCase();
  }

  factory StudentDto.fromJson(Map<String, dynamic> j) => StudentDto(
        id: (j['id'] as num).toInt(),
        publicId: j['public_id'] as String? ?? '',
        matricule: j['matricule'] as String? ?? '',
        nom: j['nom'] as String?,
        prenoms: j['prenoms'] as String?,
        establishmentId: (j['establishment_id'] as num?)?.toInt(),
        dob: DateFormatter.parse(j['dob'] as String?),
        sexe: Sexe.fromCode(j['sexe'] as String?),
        classroomName: j['classroom_name'] as String?,
        inscriptionTypeLabel: j['inscription_type_label'] as String?,
        studentStatusLabel: j['student_status_label'] as String?,
        age: (j['age'] as num?)?.toInt(),
        photoPath: j['photo_path'] as String?,
        // Satellites (présents seulement en détail enrichi)
        birthPlace: j['birth_place'] as String?,
        birthPrefecture: j['birth_prefecture'] as String?,
        birthRegion: j['birth_region'] as String?,
        birthCountry: j['birth_country'] as String?,
        groupe: j['groupe'] as String?,
        classroomId: (j['classroom_id'] as num?)?.toInt(),
        // Le serveur ne renvoie que les labels (« Nouveau », « Ancien »…).
        // On tente d'abord les codes (patch serveur / détail enrichi), puis
        // on résout par label — enfin on retombe sur student_status_label /
        // inscription_type_label si présents.
        status: StudentStatus.fromCode(j['status'] as String?) ??
            StudentStatus.fromCode(j['student_status'] as String?) ??
            StudentStatus.fromLabel(j['student_status_label'] as String?),
        inscriptionType: InscriptionType.fromCode(
                j['inscription_type'] as String?) ??
            InscriptionType.fromLabel(
                j['inscription_type_label'] as String?),
        contact: j['contact'] == null
            ? null
            : StudentContactDto.fromJson(j['contact'] as Map<String, dynamic>),
        medical: j['medical'] == null
            ? null
            : StudentMedicalDto.fromJson(j['medical'] as Map<String, dynamic>),
        scholastic: j['scholastic'] == null
            ? null
            : StudentScholasticDto.fromJson(
                j['scholastic'] as Map<String, dynamic>),
        parents: (j['parents'] as List?)
                ?.map((e) => StudentParentDto.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        guardians: (j['guardians'] as List?)
                ?.map((e) => GuardianDto.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'public_id': publicId,
        'matricule': matricule,
        'nom': nom,
        'prenoms': prenoms,
        'establishment_id': establishmentId,
        'dob': DateFormatter.toIso(dob),
        'sexe': sexe?.code,
        'classroom_name': classroomName,
        'inscription_type_label': inscriptionTypeLabel,
        'student_status_label': studentStatusLabel,
        'age': age,
        'photo_path': photoPath,
        'birth_place': birthPlace,
        'birth_prefecture': birthPrefecture,
        'birth_region': birthRegion,
        'birth_country': birthCountry,
        'groupe': groupe,
        'classroom_id': classroomId,
        'status': status?.code,
        'inscription_type': inscriptionType?.code,
        'contact': contact?.toJson(),
        'medical': medical?.toJson(),
        'scholastic': scholastic?.toJson(),
        'parents': parents.map((e) => e.toJson()).toList(),
        'guardians': guardians.map((e) => e.toJson()).toList(),
      };
}

/// Réponse paginée de liste d'élèves (StudentListResponse).
class StudentListResponse {
  final List<StudentDto> items;
  final int total;

  const StudentListResponse({this.items = const [], this.total = 0});

  factory StudentListResponse.fromJson(Map<String, dynamic> j) =>
      StudentListResponse(
        items: (j['items'] as List?)
                ?.map((e) => StudentDto.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        total: (j['total'] as num?)?.toInt() ?? 0,
      );
}

class StudentContactDto {
  final int? id;
  final String? phone;
  final String? email;
  final String? address;
  final String? city;

  const StudentContactDto({this.id, this.phone, this.email, this.address, this.city});

  factory StudentContactDto.fromJson(Map<String, dynamic> j) => StudentContactDto(
        id: (j['id'] as num?)?.toInt(),
        phone: j['phone'] as String?,
        email: j['email'] as String?,
        address: j['address'] as String?,
        city: j['city'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'phone': phone,
        'email': email,
        'address': address,
        'city': city,
      };
}

class StudentMedicalDto {
  final int? id;
  final BloodType? bloodType;
  final String? allergies;
  final String? doctor;

  const StudentMedicalDto({this.id, this.bloodType, this.allergies, this.doctor});

  factory StudentMedicalDto.fromJson(Map<String, dynamic> j) => StudentMedicalDto(
        id: (j['id'] as num?)?.toInt(),
        // [Fix-BLOODTYPE] Le serveur stocke le CODE ('A+', 'O-'…) et non le
        // nom d'enum Dart ('aPlus'). L'ancien matching par nom ne matchait
        // JAMAIS → fallback BloodType.inconnu → assertion DropdownButton
        // « There should be exactly one item with value: BloodType.inconnu »
        // à l'ouverture du formulaire de modification.
        bloodType: j['blood_type'] == null
            ? null
            : bloodTypeFromCode(j['blood_type'] as String?),
        allergies: j['allergies'] as String?,
        doctor: j['doctor'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        // [Fix-BLOODTYPE] Round-trip symétrique par code.
        'blood_type': bloodTypeToCode(bloodType),
        'allergies': allergies,
        'doctor': doctor,
      };
}

/// Parse un groupe sanguin serveur ('A+', 'AB-'…) ou historique ('aPlus').
/// Retourne null si inconnu/vide — JAMAIS BloodType.inconnu (qui n'existe
/// pas dans les items du dropdown du formulaire).
BloodType? bloodTypeFromCode(String? raw) {
  final v = raw?.trim();
  if (v == null || v.isEmpty) return null;
  const byCode = {
    'A+': BloodType.aPlus,
    'A-': BloodType.aMoins,
    'B+': BloodType.bPlus,
    'B-': BloodType.bMoins,
    'AB+': BloodType.abPlus,
    'AB-': BloodType.abMoins,
    'O+': BloodType.oPlus,
    'O-': BloodType.oMoins,
  };
  final code = byCode[v.toUpperCase()];
  if (code != null) return code;
  // Compat : anciens enregistrements locaux stockés par nom d'enum.
  for (final b in BloodType.values) {
    if (b.name.toLowerCase() == v.toLowerCase()) {
      return b == BloodType.inconnu ? null : b;
    }
  }
  return null;
}

/// Sérialise un groupe sanguin en code serveur ('A+'…), null si inconnu.
String? bloodTypeToCode(BloodType? t) {
  if (t == null || t == BloodType.inconnu) return null;
  const map = {
    BloodType.aPlus: 'A+',
    BloodType.aMoins: 'A-',
    BloodType.bPlus: 'B+',
    BloodType.bMoins: 'B-',
    BloodType.abPlus: 'AB+',
    BloodType.abMoins: 'AB-',
    BloodType.oPlus: 'O+',
    BloodType.oMoins: 'O-',
  };
  return map[t];
}

class StudentScholasticDto {
  final int? id;
  final String? previousSchool;
  final String? transport;

  const StudentScholasticDto({this.id, this.previousSchool, this.transport});

  factory StudentScholasticDto.fromJson(Map<String, dynamic> j) =>
      StudentScholasticDto(
        id: (j['id'] as num?)?.toInt(),
        previousSchool: j['previous_school'] as String?,
        transport: j['transport'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'previous_school': previousSchool,
        'transport': transport,
      };
}

class StudentParentDto {
  final int? id;
  final String role; // 'PERE' | 'MERE'
  final String? nom;
  final String? prenoms;
  final String? phone;
  final String? profession;

  const StudentParentDto({
    this.id,
    required this.role,
    this.nom,
    this.prenoms,
    this.phone,
    this.profession,
  });

  /// Nom complet au format « NOM Prénoms » (convention scolaire : le nom de
  /// famille d'abord, comme dans la version desktop).
  String get fullName =>
      [nom, prenoms].whereType<String>().where((s) => s.isNotEmpty).join(' ');

  factory StudentParentDto.fromJson(Map<String, dynamic> j) => StudentParentDto(
        id: (j['id'] as num?)?.toInt(),
        role: j['role'] as String? ?? 'PERE',
        nom: j['nom'] as String?,
        prenoms: j['prenoms'] as String?,
        phone: j['phone'] as String?,
        profession: j['profession'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role,
        'nom': nom,
        'prenoms': prenoms,
        'phone': phone,
        'profession': profession,
      };
}

class GuardianDto {
  final int? id;
  final String? nom;
  final String? prenoms;
  final String? phone;
  final String? email;
  final String? relation;

  const GuardianDto({
    this.id,
    this.nom,
    this.prenoms,
    this.phone,
    this.email,
    this.relation,
  });

  /// Nom complet au format « NOM Prénoms » (convention scolaire : le nom de
  /// famille d'abord, comme dans la version desktop).
  String get fullName =>
      [nom, prenoms].whereType<String>().where((s) => s.isNotEmpty).join(' ');

  factory GuardianDto.fromJson(Map<String, dynamic> j) => GuardianDto(
        id: (j['id'] as num?)?.toInt(),
        nom: j['nom'] as String?,
        prenoms: j['prenoms'] as String?,
        phone: j['phone'] as String?,
        email: j['email'] as String?,
        relation: j['relation'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'nom': nom,
        'prenoms': prenoms,
        'phone': phone,
        'email': email,
        'relation': relation,
      };
}
