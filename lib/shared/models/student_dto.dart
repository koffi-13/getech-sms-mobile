/// DTOs Élèves (identité + satellites : contact, médical, scolarité, parents, tuteur).
library;

import '../../core/config/constants.dart';
import '../../core/utils/formatters.dart';

class StudentDto {
  final int id;
  final String matricule;
  final String nom;
  final String? prenoms;
  final DateTime? dob;
  final Sexe? sexe;
  final String? birthPlace;
  final String? birthPrefecture;
  final String? birthRegion;
  final String? birthCountry;
  final String? photoPath;
  final String? groupe;
  final StudentContactDto? contact;
  final StudentMedicalDto? medical;
  final StudentScholasticDto? scholastic;
  final List<StudentParentDto> parents;
  final List<GuardianDto> guardians;
  final int? classroomId;
  final String? classroomName;
  final StudentStatus? status;
  final InscriptionType? inscriptionType;

  const StudentDto({
    required this.id,
    required this.matricule,
    required this.nom,
    this.prenoms,
    this.dob,
    this.sexe,
    this.birthPlace,
    this.birthPrefecture,
    this.birthRegion,
    this.birthCountry,
    this.photoPath,
    this.groupe,
    this.contact,
    this.medical,
    this.scholastic,
    this.parents = const [],
    this.guardians = const [],
    this.classroomId,
    this.classroomName,
    this.status,
    this.inscriptionType,
  });

  String get fullName =>
      [prenoms, nom].whereType<String>().where((s) => s.isNotEmpty).join(' ');

  String get displayInitials {
    final p = prenoms?.isNotEmpty == true ? prenoms![0] : '';
    final n = nom.isNotEmpty ? nom[0] : '';
    return '$p$n'.toUpperCase();
  }

  factory StudentDto.fromJson(Map<String, dynamic> j) => StudentDto(
        id: (j['id'] as num).toInt(),
        matricule: j['matricule'] as String? ?? '',
        nom: j['nom'] as String? ?? '',
        prenoms: j['prenoms'] as String?,
        dob: DateFormatter.parse(j['dob'] as String?),
        sexe: Sexe.fromCode(j['sexe'] as String?),
        birthPlace: j['birth_place'] as String?,
        birthPrefecture: j['birth_prefecture'] as String?,
        birthRegion: j['birth_region'] as String?,
        birthCountry: j['birth_country'] as String?,
        photoPath: j['photo_path'] as String?,
        groupe: j['groupe'] as String?,
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
        classroomId: (j['classroom_id'] as num?)?.toInt(),
        classroomName: j['classroom_name'] as String?,
        status: StudentStatus.fromCode(j['status'] as String?),
        inscriptionType: InscriptionType.fromCode(j['inscription_type'] as String?),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'matricule': matricule,
        'nom': nom,
        'prenoms': prenoms,
        'dob': DateFormatter.toIso(dob),
        'sexe': sexe?.code,
        'birth_place': birthPlace,
        'birth_prefecture': birthPrefecture,
        'birth_region': birthRegion,
        'birth_country': birthCountry,
        'photo_path': photoPath,
        'groupe': groupe,
        'contact': contact?.toJson(),
        'medical': medical?.toJson(),
        'scholastic': scholastic?.toJson(),
        'parents': parents.map((e) => e.toJson()).toList(),
        'guardians': guardians.map((e) => e.toJson()).toList(),
        'classroom_id': classroomId,
        'classroom_name': classroomName,
        'status': status?.code,
        'inscription_type': inscriptionType?.code,
      };
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
        bloodType: j['blood_type'] == null
            ? null
            : BloodType.values.firstWhere(
                (b) => b.name == j['blood_type'],
                orElse: () => BloodType.inconnu,
              ),
        allergies: j['allergies'] as String?,
        doctor: j['doctor'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'blood_type': bloodType?.name,
        'allergies': allergies,
        'doctor': doctor,
      };
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

/// Parent d'un élève (père ou mère).
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

  String get fullName =>
      [prenoms, nom].whereType<String>().where((s) => s.isNotEmpty).join(' ');

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

/// Tuteur légal (relation N-N via student_guardians).
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

  String get fullName =>
      [prenoms, nom].whereType<String>().where((s) => s.isNotEmpty).join(' ');

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
