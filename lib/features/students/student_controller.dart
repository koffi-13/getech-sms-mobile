/// Contrôleur du module Élèves : liste filtrée, détail complet (satellites)
/// et repository (création/édition/suppression) offline-first.
///
/// Améliorations V2 :
/// - filtres complets (classe, sexe, statut, type d'inscription, recherche)
///   appliqués via [studentsListProvider] ;
/// - `GET /students` paginé (per_page=200, toutes les pages) ;
/// - persistance locale **complète** : identité étendue (lieu de naissance,
///   préfecture, région, pays, groupe) + satellites (contact, médical,
///   scolarité, parents, tuteurs) + assignations avec **codes** (plus de
///   labels : `fromLabel` corrigeait le round-trip « Nouveau » → null) ;
/// - création/édition avec satellites (le payload complet est envoyé à
///   `POST/PATCH /students` — endpoints fournis par le patch serveur
///   GeTech-SMS ; en attendant, repli outbox) ;
/// - noms affichés au format « NOM Prénoms » (voir [StudentDto.fullName]).
library;

import 'package:drift/drift.dart' as d;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart' as log_pkg;

import '../../core/config/constants.dart' as cfg;
import '../../core/database/database.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/dio_client.dart';
import '../../core/sync/outbox.dart';
import '../../features/connections/connection_state.dart';
import '../../shared/models/student_dto.dart';

final log_pkg.Logger _log = log_pkg.Logger(
  printer: log_pkg.PrettyPrinter(noBoxingByDefault: true),
  level: log_pkg.Level.off,
);

// ---------------------------------------------------------------------------
// StudentFilter
// ---------------------------------------------------------------------------

class StudentFilter {
  final int? classroomId;
  final String search;
  final cfg.Sexe? sexe;
  final cfg.StudentStatus? status;
  final cfg.InscriptionType? inscriptionType;

  const StudentFilter({
    this.classroomId,
    this.search = '',
    this.sexe,
    this.status,
    this.inscriptionType,
  });

  static const empty = StudentFilter();

  bool get isEmpty =>
      classroomId == null &&
      search.isEmpty &&
      sexe == null &&
      status == null &&
      inscriptionType == null;

  StudentFilter copyWith({
    int? classroomId,
    String? search,
    cfg.Sexe? sexe,
    cfg.StudentStatus? status,
    cfg.InscriptionType? inscriptionType,
    bool clearClassroom = false,
    bool clearSexe = false,
    bool clearStatus = false,
    bool clearInscriptionType = false,
  }) =>
      StudentFilter(
        classroomId: clearClassroom ? null : (classroomId ?? this.classroomId),
        search: search ?? this.search,
        sexe: clearSexe ? null : (sexe ?? this.sexe),
        status: clearStatus ? null : (status ?? this.status),
        inscriptionType:
            clearInscriptionType ? null : (inscriptionType ?? this.inscriptionType),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StudentFilter &&
          other.classroomId == classroomId &&
          other.search == search &&
          other.sexe == sexe &&
          other.status == status &&
          other.inscriptionType == inscriptionType;

  @override
  int get hashCode => Object.hash(
      classroomId, search, sexe, status, inscriptionType);
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

final studentControllerProvider =
    StateNotifierProvider.autoDispose<StudentController, AsyncValue<List<StudentDto>>>((ref) {
  return StudentController(ref);
});

final studentFilterProvider = StateProvider<StudentFilter>((ref) => StudentFilter.empty);

/// Liste filtrée : source unique de la page Élèves et de l'onglet Élèves du
/// détail de classe (le filtre par classe est le cas d'usage principal).
final studentsListProvider = Provider.autoDispose
    .family<AsyncValue<List<StudentDto>>, StudentFilter>((ref, filter) {
  final asyncList = ref.watch(studentControllerProvider);
  return asyncList.whenData((list) {
    return _applyFilter(list, filter);
  });
});

List<StudentDto> _applyFilter(List<StudentDto> list, StudentFilter filter) {
  final search = filter.search.trim().toLowerCase();
  return list.where((s) {
    if (filter.classroomId != null && s.classroomId != filter.classroomId) {
      return false;
    }
    if (filter.sexe != null && s.sexe != filter.sexe) return false;
    if (filter.status != null && s.status != filter.status) return false;
    if (filter.inscriptionType != null &&
        s.inscriptionType != filter.inscriptionType) {
      return false;
    }
    if (search.isNotEmpty) {
      final nom = s.nom?.toLowerCase() ?? '';
      final prenoms = s.prenoms?.toLowerCase() ?? '';
      return nom.contains(search) ||
          prenoms.contains(search) ||
          s.matricule.toLowerCase().contains(search);
    }
    return true;
  }).toList()
    ..sort((a, b) {
      final c = (a.nom ?? '').compareTo(b.nom ?? '');
      if (c != 0) return c;
      return (a.prenoms ?? '').compareTo(b.prenoms ?? '');
    });
}

final studentDetailProvider = FutureProvider.autoDispose.family<StudentDto, int>((ref, id) async {
  final repo = ref.read(studentRepositoryProvider);
  return repo.getById(id);
});

// ---------------------------------------------------------------------------
// StudentController
// ---------------------------------------------------------------------------

class StudentController extends StateNotifier<AsyncValue<List<StudentDto>>> {
  final Ref _ref;

  StudentController(this._ref) : super(const AsyncValue.loading()) {
    refresh();
  }

  Future<void> refresh() async {
    // 1. Charger immédiatement les données locales
    final localStudents = await _fetchFromLocal();
    if (localStudents.isNotEmpty) {
      state = AsyncValue.data(localStudents);
    }

    try {
      final canReach = _ref.read(connectionProvider).canReachServer;
      if (!canReach) {
        if (localStudents.isEmpty) {
          state = AsyncValue.data(const []);
        }
        return;
      }

      // 2. Tenter de rafraîchir depuis l'API (toutes les pages)
      final apiStudents = await _fetchFromApi();
      if (apiStudents.isNotEmpty) {
        await _saveToLocal(apiStudents);
      }

      // 3. Re-charger depuis le local (avec satellites et assignations)
      final updatedLocal = await _fetchFromLocal();
      state = AsyncValue.data(updatedLocal);
    } catch (e, st) {
      if (state.hasValue && state.value!.isNotEmpty) {
        _log.w('Erreur rafraîchissement API (utilisation cache) : $e');
      } else {
        state = AsyncValue.error(e, st);
      }
    }
  }

  /// `GET /students` avec pagination complète (per_page=200, toutes pages).
  Future<List<StudentDto>> _fetchFromApi() async {
    final dio = _ref.read(dioProvider);
    final serverUrl = _ref.read(connectionProvider).serverUrl!;
    final result = <StudentDto>[];
    var page = 1;
    const perPage = 200;
    while (page <= 20) {
      final response = await dio.get(
        buildUrl(serverUrl, ApiEndpoints.students),
        queryParameters: {'page': page, 'per_page': perPage},
      );
      final data = response.data;
      List<StudentDto> chunk;
      if (data is List) {
        chunk = data
            .whereType<Map>()
            .map((j) => StudentDto.fromJson(Map<String, dynamic>.from(j)))
            .toList();
      } else if (data is Map && data['items'] is List) {
        chunk = (data['items'] as List)
            .whereType<Map>()
            .map((j) => StudentDto.fromJson(Map<String, dynamic>.from(j)))
            .toList();
      } else {
        chunk = const [];
      }
      result.addAll(chunk);
      if (chunk.length < perPage) break;
      page++;
    }
    return result;
  }

  /// Lecture locale enrichie : élèves + assignation/classe + satellites
  /// (contact, médical, scolarité, parents, tuteurs) en requêtes groupées.
  Future<List<StudentDto>> _fetchFromLocal() async {
    final db = _ref.read(databaseProvider);

    final rows = await (db.select(db.students).join([
      d.leftOuterJoin(
        db.studentClassAssignments,
        db.studentClassAssignments.studentId.equalsExp(db.students.id),
      ),
      d.leftOuterJoin(
        db.classrooms,
        db.classrooms.id.equalsExp(db.studentClassAssignments.classroomId),
      ),
    ])
          ..where(db.students.isDeleted.equals(false)))
        .get();

    if (rows.isEmpty) return const [];

    final studentIds = rows
        .map((r) => r.readTable(db.students).id)
        .toSet();

    // Satellites en bulk (pas de N+1) — requêtes typées.
    final contactRows = await (db.select(db.studentContacts)
          ..where((t) =>
              t.studentId.isIn(studentIds) & t.isDeleted.equals(false)))
        .get();
    final contacts = <int, StudentContact>{
      for (final c in contactRows) c.studentId: c
    };

    final medicalRows = await (db.select(db.studentMedicals)
          ..where((t) =>
              t.studentId.isIn(studentIds) & t.isDeleted.equals(false)))
        .get();
    final medicals = <int, StudentMedical>{
      for (final m in medicalRows) m.studentId: m
    };

    final scholasticRows = await (db.select(db.studentScholastics)
          ..where((t) =>
              t.studentId.isIn(studentIds) & t.isDeleted.equals(false)))
        .get();
    final scholastics = <int, StudentScholastic>{
      for (final sc in scholasticRows) sc.studentId: sc
    };

    final parentsRows = await (db.select(db.studentParents)
          ..where((t) => t.studentId.isIn(studentIds) & t.isDeleted.equals(false)))
        .get();
    final parentsByStudent = <int, List<StudentParentDto>>{};
    for (final p in parentsRows) {
      parentsByStudent.putIfAbsent(p.studentId, () => []).add(
            StudentParentDto(
              id: p.id,
              role: p.role,
              nom: p.nom,
              prenoms: p.prenoms,
              phone: p.phone,
              profession: p.profession,
            ),
          );
    }

    final guardianLinks = await (db.select(db.studentGuardians)
          ..where((t) => t.studentId.isIn(studentIds) & t.isDeleted.equals(false)))
        .get();
    final guardianIds = guardianLinks.map((g) => g.guardianId).toSet();
    final guardiansRows = guardianIds.isEmpty
        ? const <Guardian>[]
        : await (db.select(db.guardians)
              ..where((t) => t.id.isIn(guardianIds) & t.isDeleted.equals(false)))
            .get();
    final guardiansById = {for (final g in guardiansRows) g.id: g};
    final guardiansByStudent = <int, List<GuardianDto>>{};
    for (final link in guardianLinks) {
      final g = guardiansById[link.guardianId];
      if (g == null) continue;
      guardiansByStudent.putIfAbsent(link.studentId, () => []).add(
            GuardianDto(
              id: g.id,
              nom: g.nom,
              prenoms: g.prenoms,
              phone: g.phone,
              email: g.email,
              relation: g.relation,
            ),
          );
    }

    return rows.map<StudentDto>((row) {
      final s = row.readTable(db.students);
      final c = row.readTableOrNull(db.classrooms);
      final assign = row.readTableOrNull(db.studentClassAssignments);

      return StudentDto(
        id: s.id,
        nom: s.nom,
        prenoms: s.prenoms,
        matricule: s.matricule,
        establishmentId: s.establishmentId,
        dob: s.dob,
        sexe: cfg.Sexe.fromCode(s.sexe),
        birthPlace: s.birthPlace,
        birthPrefecture: s.birthPrefecture,
        birthRegion: s.birthRegion,
        birthCountry: s.birthCountry,
        photoPath: s.photoPath,
        groupe: s.groupe,
        classroomName: c?.name,
        classroomId: assign?.classroomId ?? c?.id,
        status: cfg.StudentStatus.fromCode(assign?.status),
        inscriptionType: cfg.InscriptionType.fromCode(assign?.inscriptionType),
        studentStatusLabel: assign?.status != null
            ? cfg.StudentStatus.fromCode(assign?.status)?.label
            : null,
        inscriptionTypeLabel: assign?.inscriptionType != null
            ? cfg.InscriptionType.fromCode(assign?.inscriptionType)?.label
            : null,
        contact: contacts[s.id] == null
            ? null
            : StudentContactDto(
                id: contacts[s.id]!.id,
                phone: contacts[s.id]!.phone,
                email: contacts[s.id]!.email,
                address: contacts[s.id]!.address,
                city: contacts[s.id]!.city,
              ),
        medical: medicals[s.id] == null
            ? null
            : StudentMedicalDto(
                id: medicals[s.id]!.id,
                bloodType: _bloodTypeFromCode(medicals[s.id]!.bloodType),
                allergies: medicals[s.id]!.allergies,
                doctor: medicals[s.id]!.doctor,
              ),
        scholastic: scholastics[s.id] == null
            ? null
            : StudentScholasticDto(
                id: scholastics[s.id]!.id,
                previousSchool: scholastics[s.id]!.previousSchool,
                transport: scholastics[s.id]!.transport,
              ),
        parents: parentsByStudent[s.id] ?? const [],
        guardians: guardiansByStudent[s.id] ?? const [],
      );
    }).toList();
  }

  /// Persiste l'intégralité des données élèves (identité + satellites +
  /// assignations avec codes) en un seul batch atomique. Les assignations
  /// serveur de l'élève sont supprimées avant ré-insertion (pas d'id serveur
  /// dans StudentResponse).
  Future<void> _saveToLocal(List<StudentDto> students) async {
    final db = _ref.read(databaseProvider);
    await db.batch((batch) {
      for (final s in students) {
        batch.insert(
          db.students,
          StudentsCompanion.insert(
            id: d.Value(s.id),
            nom: s.nom ?? '',
            prenoms: d.Value(s.prenoms),
            matricule: s.matricule,
            dob: d.Value(s.dob),
            sexe: d.Value(s.sexe?.code),
            birthPlace: d.Value(s.birthPlace),
            birthPrefecture: d.Value(s.birthPrefecture),
            birthRegion: d.Value(s.birthRegion),
            birthCountry: d.Value(s.birthCountry),
            photoPath: d.Value(s.photoPath),
            groupe: d.Value(s.groupe),
            establishmentId: d.Value(s.establishmentId),
            isDirty: const d.Value(false),
          ),
          mode: d.InsertMode.insertOrReplace,
        );

        // Assignation classe/année avec CODES (fix : les labels ne
        // survivaient pas au round-trip `fromCode`).
        batch.deleteWhere(
            db.studentClassAssignments,
            (t) => t.studentId.equals(s.id) & t.isDirty.equals(false));
        if (s.classroomId != null) {
          batch.insert(
            db.studentClassAssignments,
            StudentClassAssignmentsCompanion.insert(
              studentId: s.id,
              classroomId: s.classroomId!,
              status: d.Value(s.status?.code),
              inscriptionType: d.Value(s.inscriptionType?.code),
            ),
          );
        }

        // Contact (1-1).
        _upsertContact(db, batch, s);

        // Médical (1-1).
        if (s.medical != null) {
          batch.deleteWhere(db.studentMedicals,
              (t) => t.studentId.equals(s.id) & t.isDirty.equals(false));
          batch.insert(
            db.studentMedicals,
            StudentMedicalsCompanion.insert(
              studentId: s.id,
              bloodType: d.Value(_bloodTypeToCode(s.medical!.bloodType)),
              allergies: d.Value(s.medical!.allergies),
              doctor: d.Value(s.medical!.doctor),
            ),
          );
        }

        // Scolarité (1-1).
        if (s.scholastic != null) {
          batch.deleteWhere(db.studentScholastics,
              (t) => t.studentId.equals(s.id) & t.isDirty.equals(false));
          batch.insert(
            db.studentScholastics,
            StudentScholasticsCompanion.insert(
              studentId: s.id,
              previousSchool: d.Value(s.scholastic!.previousSchool),
              transport: d.Value(s.scholastic!.transport),
            ),
          );
        }

        // Parents.
        batch.deleteWhere(db.studentParents,
            (t) => t.studentId.equals(s.id) & t.isDirty.equals(false));
        for (final p in s.parents) {
          batch.insert(
            db.studentParents,
            StudentParentsCompanion.insert(
              studentId: s.id,
              role: p.role,
              nom: d.Value(p.nom),
              prenoms: d.Value(p.prenoms),
              phone: d.Value(p.phone),
              profession: d.Value(p.profession),
            ),
          );
        }

        // Tuteurs (N-N via guardians + student_guardians).
        batch.deleteWhere(db.studentGuardians,
            (t) => t.studentId.equals(s.id) & t.isDirty.equals(false));
        for (final g in s.guardians) {
          if (g.id != null && g.id! > 0) {
            batch.insert(
              db.guardians,
              GuardiansCompanion.insert(
                id: d.Value(g.id!),
                nom: d.Value(g.nom),
                prenoms: d.Value(g.prenoms),
                phone: d.Value(g.phone),
                email: d.Value(g.email),
                relation: d.Value(g.relation),
              ),
              mode: d.InsertMode.insertOrReplace,
            );
            batch.insert(
              db.studentGuardians,
              StudentGuardiansCompanion.insert(
                studentId: s.id,
                guardianId: g.id!,
              ),
            );
          } else {
            // Tuteur créé localement (pas encore d'id serveur).
            final localId = -DateTime.now().millisecondsSinceEpoch;
            batch.insert(
              db.guardians,
              GuardiansCompanion.insert(
                id: d.Value(localId),
                nom: d.Value(g.nom),
                prenoms: d.Value(g.prenoms),
                phone: d.Value(g.phone),
                email: d.Value(g.email),
                relation: d.Value(g.relation),
              ),
              mode: d.InsertMode.insertOrReplace,
            );
            batch.insert(
              db.studentGuardians,
              StudentGuardiansCompanion.insert(
                studentId: s.id,
                guardianId: localId,
              ),
            );
          }
        }
      }
    });
  }

  void _upsertContact(AppDatabase db, d.Batch batch, StudentDto s) {
    final c = s.contact;
    if (c == null) return;
    batch.deleteWhere(db.studentContacts,
        (t) => t.studentId.equals(s.id) & t.isDirty.equals(false));
    batch.insert(
      db.studentContacts,
      StudentContactsCompanion.insert(
        studentId: s.id,
        phone: d.Value(c.phone),
        email: d.Value(c.email),
        address: d.Value(c.address),
        city: d.Value(c.city),
      ),
    );
  }
}

/// Mapping groupe sanguin : la table Drift stocke un code texte
/// (« A+ », « O- », …) alors que le DTO expose l'enum [BloodType].
cfg.BloodType? _bloodTypeFromCode(String? code) {
  if (code == null || code.isEmpty) return null;
  const map = {
    'A+': cfg.BloodType.aPlus,
    'A-': cfg.BloodType.aMoins,
    'B+': cfg.BloodType.bPlus,
    'B-': cfg.BloodType.bMoins,
    'AB+': cfg.BloodType.abPlus,
    'AB-': cfg.BloodType.abMoins,
    'O+': cfg.BloodType.oPlus,
    'O-': cfg.BloodType.oMoins,
  };
  return map[code] ?? cfg.BloodType.inconnu;
}

String? _bloodTypeToCode(cfg.BloodType? t) {
  if (t == null || t == cfg.BloodType.inconnu) return null;
  const map = {
    cfg.BloodType.aPlus: 'A+',
    cfg.BloodType.aMoins: 'A-',
    cfg.BloodType.bPlus: 'B+',
    cfg.BloodType.bMoins: 'B-',
    cfg.BloodType.abPlus: 'AB+',
    cfg.BloodType.abMoins: 'AB-',
    cfg.BloodType.oPlus: 'O+',
    cfg.BloodType.oMoins: 'O-',
  };
  return map[t];
}

// ---------------------------------------------------------------------------
// StudentRepository
// ---------------------------------------------------------------------------

final studentRepositoryProvider = Provider<StudentRepository>((ref) {
  return StudentRepository(ref);
});

class StudentRepository {
  final Ref _ref;
  StudentRepository(this._ref);

  /// Détail complet : `GET /students/{id}` en ligne (les satellites sont
  /// inclus si le patch serveur est appliqué), enrichi/fallback par les
  /// données locales (satellites + assignation).
  Future<StudentDto> getById(int id) async {
    final canReach = _ref.read(connectionProvider).canReachServer;
    StudentDto? remote;
    if (canReach) {
      try {
        final dio = _ref.read(dioProvider);
        final serverUrl = _ref.read(connectionProvider).serverUrl!;
        final response = await dio.get(
          buildUrl(serverUrl, ApiEndpoints.student(id)),
        );
        if (response.data is Map) {
          remote = StudentDto.fromJson(
              Map<String, dynamic>.from(response.data as Map));
        }
      } catch (e) {
        _log.w('getById($id) API échec, repli local : $e');
      }
    }

    // Enrichissement local (satellites/assignation manquants en ligne).
    final local = await _getLocalById(id);
    if (remote == null) {
      if (local == null) {
        throw StateError('Élève #$id introuvable.');
      }
      return local;
    }
    if (local == null) return remote;
    return StudentDto(
      id: remote.id,
      publicId: remote.publicId,
      matricule: remote.matricule,
      nom: remote.nom,
      prenoms: remote.prenoms,
      establishmentId: remote.establishmentId,
      dob: remote.dob ?? local.dob,
      sexe: remote.sexe ?? local.sexe,
      classroomName: remote.classroomName ?? local.classroomName,
      inscriptionTypeLabel:
          remote.inscriptionTypeLabel ?? local.inscriptionTypeLabel,
      studentStatusLabel:
          remote.studentStatusLabel ?? local.studentStatusLabel,
      age: remote.age ?? local.age,
      photoPath: remote.photoPath ?? local.photoPath,
      birthPlace: remote.birthPlace ?? local.birthPlace,
      birthPrefecture: remote.birthPrefecture ?? local.birthPrefecture,
      birthRegion: remote.birthRegion ?? local.birthRegion,
      birthCountry: remote.birthCountry ?? local.birthCountry,
      groupe: remote.groupe ?? local.groupe,
      classroomId: remote.classroomId ?? local.classroomId,
      status: remote.status ?? local.status,
      inscriptionType: remote.inscriptionType ?? local.inscriptionType,
      contact: remote.contact ?? local.contact,
      medical: remote.medical ?? local.medical,
      scholastic: remote.scholastic ?? local.scholastic,
      parents: remote.parents.isNotEmpty ? remote.parents : local.parents,
      guardians:
          remote.guardians.isNotEmpty ? remote.guardians : local.guardians,
    );
  }

  Future<StudentDto?> _getLocalById(int id) async {
    final db = _ref.read(databaseProvider);
    final students = await (db.select(db.students)
          ..where((t) => t.id.equals(id) & t.isDeleted.equals(false)))
        .get();
    if (students.isEmpty) return null;
    final s = students.first;

    // Assignation active la plus récente.
    final assigns = await (db.select(db.studentClassAssignments)
          ..where((t) =>
              t.studentId.equals(id) & t.isDeleted.equals(false))
          ..orderBy([(t) => d.OrderingTerm.desc(t.id)])
          ..limit(1))
        .get();
    final assign = assigns.isEmpty ? null : assigns.first;
    Classroom? classroom;
    if (assign != null) {
      final cls = await (db.select(db.classrooms)
            ..where((t) => t.id.equals(assign.classroomId)))
          .get();
      classroom = cls.isEmpty ? null : cls.first;
    }

    // Satellites.
    final contacts = await (db.select(db.studentContacts)
          ..where((t) => t.studentId.equals(id) & t.isDeleted.equals(false)))
        .get();
    final medicals = await (db.select(db.studentMedicals)
          ..where((t) => t.studentId.equals(id) & t.isDeleted.equals(false)))
        .get();
    final scholastics = await (db.select(db.studentScholastics)
          ..where((t) => t.studentId.equals(id) & t.isDeleted.equals(false)))
        .get();
    final parents = await (db.select(db.studentParents)
          ..where((t) => t.studentId.equals(id) & t.isDeleted.equals(false)))
        .get();
    final links = await (db.select(db.studentGuardians)
          ..where((t) => t.studentId.equals(id) & t.isDeleted.equals(false)))
        .get();
    final guardians = <GuardianDto>[];
    for (final link in links) {
      final g = await (db.select(db.guardians)
            ..where((t) => t.id.equals(link.guardianId)))
          .get();
      if (g.isNotEmpty) {
        final gg = g.first;
        guardians.add(GuardianDto(
          id: gg.id,
          nom: gg.nom,
          prenoms: gg.prenoms,
          phone: gg.phone,
          email: gg.email,
          relation: gg.relation,
        ));
      }
    }

    return StudentDto(
      id: s.id,
      nom: s.nom,
      prenoms: s.prenoms,
      matricule: s.matricule,
      establishmentId: s.establishmentId,
      dob: s.dob,
      sexe: cfg.Sexe.fromCode(s.sexe),
      birthPlace: s.birthPlace,
      birthPrefecture: s.birthPrefecture,
      birthRegion: s.birthRegion,
      birthCountry: s.birthCountry,
      photoPath: s.photoPath,
      groupe: s.groupe,
      classroomName: classroom?.name,
      classroomId: assign?.classroomId,
      status: cfg.StudentStatus.fromCode(assign?.status),
      inscriptionType: cfg.InscriptionType.fromCode(assign?.inscriptionType),
      studentStatusLabel: cfg.StudentStatus.fromCode(assign?.status)?.label,
      inscriptionTypeLabel:
          cfg.InscriptionType.fromCode(assign?.inscriptionType)?.label,
      contact: contacts.isEmpty
          ? null
          : StudentContactDto(
              id: contacts.first.id,
              phone: contacts.first.phone,
              email: contacts.first.email,
              address: contacts.first.address,
              city: contacts.first.city,
            ),
      medical: medicals.isEmpty
          ? null
          : StudentMedicalDto(
              id: medicals.first.id,
              bloodType: _bloodTypeFromCode(medicals.first.bloodType),
              allergies: medicals.first.allergies,
              doctor: medicals.first.doctor,
            ),
      scholastic: scholastics.isEmpty
          ? null
          : StudentScholasticDto(
              id: scholastics.first.id,
              previousSchool: scholastics.first.previousSchool,
              transport: scholastics.first.transport,
            ),
      parents: parents
          .map((p) => StudentParentDto(
                id: p.id,
                role: p.role,
                nom: p.nom,
                prenoms: p.prenoms,
                phone: p.phone,
                profession: p.profession,
              ))
          .toList(),
      guardians: guardians,
    );
  }

  /// Sauvegarde (création si id == 0, édition sinon).
  Future<StudentDto> save(StudentDto student) async {
    if (student.id == 0) {
      return create(StudentCreateRequest.fromDto(student));
    } else {
      await update(student.id, StudentUpdateRequest.fromDto(student));
      return getById(student.id);
    }
  }

  /// Crée un élève : écriture locale complète (identité + satellites +
  /// assignation) puis `POST /students` (payload complet). Si le serveur
  /// ne propose pas encore l'endpoint (404/405 → patch serveur requis),
  /// la création est mise en file outbox pour re-tentative.
  Future<StudentDto> create(StudentCreateRequest req) async {
    final db = _ref.read(databaseProvider);
    final canReach = _ref.read(connectionProvider).canReachServer;

    // ID local temporaire (négatif) pour ne pas entrer en collision avec les
    // IDs serveur ; l'outbox re-jouera le POST plus tard.
    final localId = -DateTime.now().millisecondsSinceEpoch;

    await db.transaction(() async {
      await db.into(db.students).insert(StudentsCompanion.insert(
            id: d.Value(localId),
            nom: req.nom,
            prenoms: d.Value(req.prenoms),
            matricule: req.matricule,
            dob: d.Value(req.dob),
            sexe: d.Value(req.sexe?.code),
            birthPlace: d.Value(req.birthPlace),
            birthPrefecture: d.Value(req.birthPrefecture),
            birthRegion: d.Value(req.birthRegion),
            birthCountry: d.Value(req.birthCountry),
            groupe: d.Value(req.groupe),
            establishmentId: d.Value(req.establishmentId),
            photoPath: d.Value(req.photoPath),
            isDirty: d.Value(!canReach),
          ));

      if (req.classroomId != null) {
        await db.into(db.studentClassAssignments).insert(
              StudentClassAssignmentsCompanion.insert(
                studentId: localId,
                classroomId: req.classroomId!,
                status: d.Value(req.status?.code),
                inscriptionType: d.Value(req.inscriptionType?.code),
                isDirty: const d.Value(true),
              ),
            );
      }

      if (req.contact != null) {
        await db.into(db.studentContacts).insert(
              StudentContactsCompanion.insert(
                studentId: localId,
                phone: d.Value(req.contact!.phone),
                email: d.Value(req.contact!.email),
                address: d.Value(req.contact!.address),
                city: d.Value(req.contact!.city),
                isDirty: const d.Value(true),
              ),
            );
      }
      if (req.medical != null) {
        await db.into(db.studentMedicals).insert(
              StudentMedicalsCompanion.insert(
                studentId: localId,
                bloodType: d.Value(_bloodTypeToCode(req.medical!.bloodType)),
                allergies: d.Value(req.medical!.allergies),
                doctor: d.Value(req.medical!.doctor),
                isDirty: const d.Value(true),
              ),
            );
      }
      if (req.scholastic != null) {
        await db.into(db.studentScholastics).insert(
              StudentScholasticsCompanion.insert(
                studentId: localId,
                previousSchool: d.Value(req.scholastic!.previousSchool),
                transport: d.Value(req.scholastic!.transport),
                isDirty: const d.Value(true),
              ),
            );
      }
      for (final p in req.parents) {
        await db.into(db.studentParents).insert(
              StudentParentsCompanion.insert(
                studentId: localId,
                role: p.role,
                nom: d.Value(p.nom),
                prenoms: d.Value(p.prenoms),
                phone: d.Value(p.phone),
                profession: d.Value(p.profession),
                isDirty: const d.Value(true),
              ),
            );
      }
      for (final g in req.guardians) {
        final guardianLocalId = -DateTime.now().millisecondsSinceEpoch;
        await db.into(db.guardians).insert(GuardiansCompanion.insert(
              id: d.Value(guardianLocalId),
              nom: d.Value(g.nom),
              prenoms: d.Value(g.prenoms),
              phone: d.Value(g.phone),
              email: d.Value(g.email),
              relation: d.Value(g.relation),
              isDirty: const d.Value(true),
            ));
        await db.into(db.studentGuardians).insert(
              StudentGuardiansCompanion.insert(
                studentId: localId,
                guardianId: guardianLocalId,
                isDirty: const d.Value(true),
              ),
            );
      }
    });

    if (canReach) {
      try {
        final dio = _ref.read(dioProvider);
        final serverUrl = _ref.read(connectionProvider).serverUrl!;
        final response = await dio.post(
          buildUrl(serverUrl, ApiEndpoints.students),
          data: req.toJson(),
        );
        if (response.data is Map) {
          return StudentDto.fromJson(
              Map<String, dynamic>.from(response.data as Map));
        }
      } catch (e) {
        // Endpoint absent (patch serveur requis) ou erreur réseau → outbox.
        _log.w('create() POST échoué, mise en file outbox : $e');
        await _queueForSync('POST', localId, req.toJson());
      }
    } else {
      await _queueForSync('POST', localId, req.toJson());
    }

    // Retourne le DTO avec l'id local (les listes se rechargent depuis Drift).
    return StudentDto(
      id: localId,
      nom: req.nom,
      prenoms: req.prenoms,
      matricule: req.matricule,
      dob: req.dob,
      sexe: req.sexe,
      birthPlace: req.birthPlace,
      birthPrefecture: req.birthPrefecture,
      birthRegion: req.birthRegion,
      birthCountry: req.birthCountry,
      groupe: req.groupe,
      classroomId: req.classroomId,
      status: req.status,
      inscriptionType: req.inscriptionType,
      contact: req.contact,
      medical: req.medical,
      scholastic: req.scholastic,
      parents: req.parents,
      guardians: req.guardians,
    );
  }

  /// Modifie un élève : `PATCH /students/{id}` (payload complet, y compris
  /// `classroom_id` pour changer de classe). Repli outbox si indisponible.
  Future<void> update(int id, StudentUpdateRequest req) async {
    final db = _ref.read(databaseProvider);
    final canReach = _ref.read(connectionProvider).canReachServer;

    await (db.update(db.students)..where((t) => t.id.equals(id))).write(
      StudentsCompanion(
        nom: d.Value(req.nom ?? ''),
        prenoms: d.Value(req.prenoms),
        matricule: d.Value(req.matricule ?? ''),
        dob: d.Value(req.dob),
        sexe: d.Value(req.sexe?.code),
        birthPlace: d.Value(req.birthPlace),
        birthPrefecture: d.Value(req.birthPrefecture),
        birthRegion: d.Value(req.birthRegion),
        birthCountry: d.Value(req.birthCountry),
        groupe: d.Value(req.groupe),
        photoPath: d.Value(req.photoPath),
        isDirty: d.Value(!canReach),
      ),
    );

    // Mise à jour de l'assignation si la classe change (upsert : delete
    // non-dirty puis insert — l'update seul serait un no-op sans ligne).
    if (req.classroomId != null) {
      await (db.delete(db.studentClassAssignments)
            ..where((t) => t.studentId.equals(id) & t.isDirty.equals(false)))
          .go();
      await db.into(db.studentClassAssignments).insert(
            StudentClassAssignmentsCompanion.insert(
              studentId: id,
              classroomId: req.classroomId!,
              status: d.Value(req.status?.code),
              inscriptionType: d.Value(req.inscriptionType?.code),
              isDirty: const d.Value(true),
            ),
          );
    }

    // Satellites 1-1 : upsert (delete non-dirty + insert).
    if (req.contact != null) {
      await (db.delete(db.studentContacts)
            ..where((t) => t.studentId.equals(id) & t.isDirty.equals(false)))
          .go();
      await db.into(db.studentContacts).insert(
            StudentContactsCompanion.insert(
              studentId: id,
              phone: d.Value(req.contact!.phone),
              email: d.Value(req.contact!.email),
              address: d.Value(req.contact!.address),
              city: d.Value(req.contact!.city),
              isDirty: const d.Value(true),
            ),
          );
    }
    if (req.medical != null) {
      await (db.delete(db.studentMedicals)
            ..where((t) => t.studentId.equals(id) & t.isDirty.equals(false)))
          .go();
      await db.into(db.studentMedicals).insert(
            StudentMedicalsCompanion.insert(
              studentId: id,
              bloodType: d.Value(_bloodTypeToCode(req.medical!.bloodType)),
              allergies: d.Value(req.medical!.allergies),
              doctor: d.Value(req.medical!.doctor),
              isDirty: const d.Value(true),
            ),
          );
    }
    if (req.scholastic != null) {
      await (db.delete(db.studentScholastics)
            ..where((t) => t.studentId.equals(id) & t.isDirty.equals(false)))
          .go();
      await db.into(db.studentScholastics).insert(
            StudentScholasticsCompanion.insert(
              studentId: id,
              previousSchool: d.Value(req.scholastic!.previousSchool),
              transport: d.Value(req.scholastic!.transport),
              isDirty: const d.Value(true),
            ),
          );
    }
    if (req.parents != null) {
      await (db.delete(db.studentParents)
            ..where((t) => t.studentId.equals(id) & t.isDirty.equals(false)))
          .go();
      for (final p in req.parents!) {
        await db.into(db.studentParents).insert(
              StudentParentsCompanion.insert(
                studentId: id,
                role: p.role,
                nom: d.Value(p.nom),
                prenoms: d.Value(p.prenoms),
                phone: d.Value(p.phone),
                profession: d.Value(p.profession),
                isDirty: const d.Value(true),
              ),
            );
      }
    }
    if (req.guardians != null) {
      await (db.delete(db.studentGuardians)
            ..where((t) => t.studentId.equals(id) & t.isDirty.equals(false)))
          .go();
      for (final g in req.guardians!) {
        final guardianLocalId = g.id ?? -DateTime.now().millisecondsSinceEpoch;
        await db.into(db.guardians).insert(
              GuardiansCompanion.insert(
                id: d.Value(guardianLocalId),
                nom: d.Value(g.nom),
                prenoms: d.Value(g.prenoms),
                phone: d.Value(g.phone),
                email: d.Value(g.email),
                relation: d.Value(g.relation),
                isDirty: const d.Value(true),
              ),
              mode: d.InsertMode.insertOrReplace,
            );
        await db.into(db.studentGuardians).insert(
              StudentGuardiansCompanion.insert(
                studentId: id,
                guardianId: guardianLocalId,
                isDirty: const d.Value(true),
              ),
            );
      }
    }

    if (canReach) {
      try {
        final dio = _ref.read(dioProvider);
        final serverUrl = _ref.read(connectionProvider).serverUrl!;
        await dio.patch(
          buildUrl(serverUrl, ApiEndpoints.student(id)),
          data: req.toJson(),
        );
      } catch (e) {
        _log.w('update($id) PATCH échoué, mise en file outbox : $e');
        await _queueForSync('PATCH', id, req.toJson());
      }
    } else {
      await _queueForSync('PATCH', id, req.toJson());
    }
  }

  Future<void> delete(int id) async {
    final db = _ref.read(databaseProvider);
    final canReach = _ref.read(connectionProvider).canReachServer;

    // Soft-delete local.
    await (db.update(db.students)..where((t) => t.id.equals(id)))
        .write(const StudentsCompanion(isDeleted: d.Value(true)));

    if (canReach) {
      try {
        final dio = _ref.read(dioProvider);
        final serverUrl = _ref.read(connectionProvider).serverUrl!;
        await dio.delete(buildUrl(serverUrl, ApiEndpoints.student(id)));
      } catch (e) {
        _log.w('delete($id) DELETE échoué, mise en file outbox : $e');
        await _queueForSync('DELETE', id, null);
      }
    } else {
      await _queueForSync('DELETE', id, null);
    }
  }

  Future<void> _queueForSync(String method, int entityId, Map<String, dynamic>? data) async {
    await _ref.read(outboxProvider).enqueue(
      table: 'students',
      operation: method,
      recordId: entityId,
      payload: data ?? {},
    );
  }
}

// ---------------------------------------------------------------------------
// Requêtes (payload complet avec satellites)
// ---------------------------------------------------------------------------

/// Requête de création : `POST /students`.
///
/// Le matricule est optionnel (auto-généré côté serveur si vide — patch
/// serveur). Les satellites sont créés dans la même transaction serveur.
class StudentCreateRequest {
  final String nom;
  final String? prenoms;
  final String matricule;
  final DateTime? dob;
  final cfg.Sexe? sexe;
  final String? birthPlace;
  final String? birthPrefecture;
  final String? birthRegion;
  final String? birthCountry;
  final String? groupe;
  final String? photoPath;
  final int? establishmentId;
  final int? classroomId;
  final cfg.StudentStatus? status;
  final cfg.InscriptionType? inscriptionType;
  final StudentContactDto? contact;
  final StudentMedicalDto? medical;
  final StudentScholasticDto? scholastic;
  final List<StudentParentDto> parents;
  final List<GuardianDto> guardians;

  StudentCreateRequest({
    required this.nom,
    this.prenoms,
    this.matricule = '',
    this.dob,
    this.sexe,
    this.birthPlace,
    this.birthPrefecture,
    this.birthRegion,
    this.birthCountry,
    this.groupe,
    this.photoPath,
    this.establishmentId,
    this.classroomId,
    this.status,
    this.inscriptionType,
    this.contact,
    this.medical,
    this.scholastic,
    this.parents = const [],
    this.guardians = const [],
  });

  factory StudentCreateRequest.fromDto(StudentDto s) => StudentCreateRequest(
        nom: s.nom ?? '',
        prenoms: s.prenoms,
        matricule: s.matricule,
        dob: s.dob,
        sexe: s.sexe,
        birthPlace: s.birthPlace,
        birthPrefecture: s.birthPrefecture,
        birthRegion: s.birthRegion,
        birthCountry: s.birthCountry,
        groupe: s.groupe,
        photoPath: s.photoPath,
        establishmentId: s.establishmentId,
        classroomId: s.classroomId,
        status: s.status,
        inscriptionType: s.inscriptionType,
        contact: s.contact,
        medical: s.medical,
        scholastic: s.scholastic,
        parents: s.parents,
        guardians: s.guardians,
      );

  Map<String, dynamic> toJson() => {
        'nom': nom,
        'prenoms': prenoms,
        if (matricule.isNotEmpty) 'matricule': matricule,
        'dob': dob != null
            ? '${dob!.year.toString().padLeft(4, '0')}-'
                '${dob!.month.toString().padLeft(2, '0')}-'
                '${dob!.day.toString().padLeft(2, '0')}'
            : null,
        'sexe': sexe?.code,
        'birth_place': birthPlace,
        'birth_prefecture': birthPrefecture,
        'birth_region': birthRegion,
        'birth_country': birthCountry,
        'groupe': groupe,
        'photo_path': photoPath,
        'establishment_id': establishmentId,
        'classroom_id': classroomId,
        'status': status?.code,
        'inscription_type': inscriptionType?.code,
        'contact': contact?.toJson(),
        'medical': medical == null ? null : {
            'blood_type': _bloodTypeToCode(medical!.bloodType),
            'allergies': medical!.allergies,
            'doctor': medical!.doctor,
          },
        'scholastic': scholastic?.toJson(),
        'parents': parents.map((e) => e.toJson()).toList(),
        'guardians': guardians.map((e) => e.toJson()).toList(),
      };
}

/// Requête de mise à jour : `PATCH /students/{id}` (tous champs optionnels —
/// `classroom_id` est inclus pour permettre le changement de classe).
class StudentUpdateRequest {
  final String? nom;
  final String? prenoms;
  final String? matricule;
  final DateTime? dob;
  final cfg.Sexe? sexe;
  final String? birthPlace;
  final String? birthPrefecture;
  final String? birthRegion;
  final String? birthCountry;
  final String? groupe;
  final String? photoPath;
  final int? classroomId;
  final cfg.StudentStatus? status;
  final cfg.InscriptionType? inscriptionType;
  final StudentContactDto? contact;
  final StudentMedicalDto? medical;
  final StudentScholasticDto? scholastic;
  final List<StudentParentDto>? parents;
  final List<GuardianDto>? guardians;

  StudentUpdateRequest({
    this.nom,
    this.prenoms,
    this.matricule,
    this.dob,
    this.sexe,
    this.birthPlace,
    this.birthPrefecture,
    this.birthRegion,
    this.birthCountry,
    this.groupe,
    this.photoPath,
    this.classroomId,
    this.status,
    this.inscriptionType,
    this.contact,
    this.medical,
    this.scholastic,
    this.parents,
    this.guardians,
  });

  factory StudentUpdateRequest.fromDto(StudentDto s) => StudentUpdateRequest(
        nom: s.nom ?? '',
        prenoms: s.prenoms,
        matricule: s.matricule,
        dob: s.dob,
        sexe: s.sexe,
        birthPlace: s.birthPlace,
        birthPrefecture: s.birthPrefecture,
        birthRegion: s.birthRegion,
        birthCountry: s.birthCountry,
        groupe: s.groupe,
        photoPath: s.photoPath,
        classroomId: s.classroomId,
        status: s.status,
        inscriptionType: s.inscriptionType,
        contact: s.contact,
        medical: s.medical,
        scholastic: s.scholastic,
        parents: s.parents,
        guardians: s.guardians,
      );

  Map<String, dynamic> toJson() => {
        'nom': nom,
        'prenoms': prenoms,
        if (matricule != null && matricule!.isNotEmpty) 'matricule': matricule,
        'dob': dob != null
            ? '${dob!.year.toString().padLeft(4, '0')}-'
                '${dob!.month.toString().padLeft(2, '0')}-'
                '${dob!.day.toString().padLeft(2, '0')}'
            : null,
        'sexe': sexe?.code,
        'birth_place': birthPlace,
        'birth_prefecture': birthPrefecture,
        'birth_region': birthRegion,
        'birth_country': birthCountry,
        'groupe': groupe,
        'photo_path': photoPath,
        'classroom_id': classroomId,
        'status': status?.code,
        'inscription_type': inscriptionType?.code,
        'contact': contact?.toJson(),
        'medical': medical == null ? null : {
            'blood_type': _bloodTypeToCode(medical!.bloodType),
            'allergies': medical!.allergies,
            'doctor': medical!.doctor,
          },
        'scholastic': scholastic?.toJson(),
        'parents': parents?.map((e) => e.toJson()).toList(),
        'guardians': guardians?.map((e) => e.toJson()).toList(),
      };
}

class StudentRepositoryException implements Exception {
  final String message;
  StudentRepositoryException(this.message);
  @override
  String toString() => message;
}
