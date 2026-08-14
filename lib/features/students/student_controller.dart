/// Contrôleur du module Élèves : liste filtrée, détail, et repository
/// (création/édition/suppression) offline-first.
///
/// - En ligne (`connection.canReachServer`) : appels REST `/students/*` via
///   [dioProvider] + [buildUrl], et cache Drift upserté en retour.
/// - Hors-ligne : lecture depuis la base Drift locale (`db.students` + tables
///   satellites), avec best-effort sur la classe courante (via
///   `student_class_assignments` + `classrooms`).
///
/// Les écritures (create/update/delete) sont systématiquement persistées
/// localement (Drift) ; si le serveur est injoignable, l'opération est mise en
/// file d'attente via [outboxProvider] pour être poussée ultérieurement par le
/// [SyncEngine].
library;

import 'package:drift/drift.dart' show InsertMode, Value;
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

import '../../core/config/constants.dart';
import '../../core/database/database.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../../core/sync/outbox.dart';
import '../../features/connections/connection_state.dart';
import '../../shared/models/student_dto.dart';

final Logger _log = Logger(
  printer: PrettyPrinter(methodNames: false, noBoxingByDefault: true),
  level: Level.off, // Silence en production — activé via AppConfig.isDebug si besoin.
);

// ---------------------------------------------------------------------------
// StudentFilter
// ---------------------------------------------------------------------------

/// Filtres de la liste des élèves (recherche texte + classe + sexe + statut).
///
/// Utilisé comme clé de `studentsListProvider` (family) — l'égalité structurelle
/// permet à Riverpod de cache-correctement les résultats.
class StudentFilter {
  final String search;
  final int? classroomId;
  final Sexe? sexe;
  final StudentStatus? status;
  final int page;
  final int perPage;

  const StudentFilter({
    this.search = '',
    this.classroomId,
    this.sexe,
    this.status,
    this.page = 1,
    this.perPage = 100,
  });

  static const empty = StudentFilter();

  StudentFilter copyWith({
    String? search,
    int? classroomId,
    Sexe? sexe,
    StudentStatus? status,
    int? page,
    int? perPage,
    bool clearClassroom = false,
    bool clearSexe = false,
    bool clearStatus = false,
  }) =>
      StudentFilter(
        search: search ?? this.search,
        classroomId:
            clearClassroom ? null : (classroomId ?? this.classroomId),
        sexe: clearSexe ? null : (sexe ?? this.sexe),
        status: clearStatus ? null : (status ?? this.status),
        page: page ?? this.page,
        perPage: perPage ?? this.perPage,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StudentFilter &&
          runtimeType == other.runtimeType &&
          search == other.search &&
          classroomId == other.classroomId &&
          sexe == other.sexe &&
          status == other.status &&
          page == other.page &&
          perPage == other.perPage;

  @override
  int get hashCode =>
      Object.hash(search, classroomId, sexe, status, page, perPage);
}

// ---------------------------------------------------------------------------
// Helpers : mapping Drift row → DTO
// ---------------------------------------------------------------------------

/// Reconstruit un [StudentDto] en remplaçant uniquement son `id`. Les DTOs
/// partagés n'exposant pas de `copyWith`, on reconstruit explicitement.
StudentDto _withId(StudentDto dto, int id) => StudentDto(
      id: id,
      matricule: dto.matricule,
      nom: dto.nom,
      prenoms: dto.prenoms,
      dob: dto.dob,
      sexe: dto.sexe,
      birthPlace: dto.birthPlace,
      birthPrefecture: dto.birthPrefecture,
      birthRegion: dto.birthRegion,
      birthCountry: dto.birthCountry,
      photoPath: dto.photoPath,
      groupe: dto.groupe,
      contact: dto.contact,
      medical: dto.medical,
      scholastic: dto.scholastic,
      parents: dto.parents,
      guardians: dto.guardians,
      classroomId: dto.classroomId,
      classroomName: dto.classroomName,
      status: dto.status,
      inscriptionType: dto.inscriptionType,
    );

/// Mappe une ligne Drift `Student` (générée par build_runner) en [StudentDto],
/// en enrichissant avec les satellites (contact/médical/scolarité/parents/
/// tuteurs) et la classe courante lorsque `extras` est fourni.
StudentDto _mapStudentRow(
  Student row, {
  StudentContact? contact,
  StudentMedical? medical,
  StudentScholastic? scholastic,
  List<StudentParent> parents = const [],
  List<Guardian> guardians = const [],
  int? classroomId,
  String? classroomName,
  StudentStatus? status,
  InscriptionType? inscriptionType,
}) =>
    StudentDto(
      id: row.id,
      matricule: row.matricule,
      nom: row.nom,
      prenoms: row.prenoms,
      dob: row.dob,
      sexe: Sexe.fromCode(row.sexe),
      birthPlace: row.birthPlace,
      birthPrefecture: row.birthPrefecture,
      birthRegion: row.birthRegion,
      birthCountry: row.birthCountry,
      photoPath: row.photoPath,
      groupe: row.groupe,
      contact: contact == null
          ? null
          : StudentContactDto(
              id: contact.id,
              phone: contact.phone,
              email: contact.email,
              address: contact.address,
              city: contact.city,
            ),
      medical: medical == null
          ? null
          : StudentMedicalDto(
              id: medical.id,
              bloodType: _parseBloodType(medical.bloodType),
              allergies: medical.allergies,
              doctor: medical.doctor,
            ),
      scholastic: scholastic == null
          ? null
          : StudentScholasticDto(
              id: scholastic.id,
              previousSchool: scholastic.previousSchool,
              transport: scholastic.transport,
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
      guardians: guardians
          .map((g) => GuardianDto(
                id: g.id,
                nom: g.nom,
                prenoms: g.prenoms,
                phone: g.phone,
                email: g.email,
                relation: g.relation,
              ))
          .toList(),
      classroomId: classroomId,
      classroomName: classroomName,
      status: status,
      inscriptionType: inscriptionType,
    );

BloodType? _parseBloodType(String? code) {
  if (code == null || code.isEmpty) return null;
  for (final b in BloodType.values) {
    if (b.name == code) return b;
  }
  return null;
}

/// Récupère, pour une liste d'IDs d'élèves, les infos d'assignation courante
/// (classroomId, classroomName, status, inscriptionType) depuis les tables
/// Drift `student_class_assignments` + `classrooms`.
Future<Map<int, _ClassAssignmentExtras>> _loadAssignmentExtras(
  AppDatabase db,
  List<int> studentIds,
) async {
  if (studentIds.isEmpty) return const {};
  final assignments = await (db.select(db.studentClassAssignments)
        ..where((t) => t.studentId.isIn(studentIds))
        ..where((t) => t.isDeleted.equals(false)))
      .get();
  if (assignments.isEmpty) return const {};

  final classroomIds = {
    for (final a in assignments) a.classroomId,
  };
  final classrooms = await (db.select(db.classrooms)
        ..where((t) => t.id.isIn(classroomIds))
        ..where((t) => t.isDeleted.equals(false)))
      .get();
  final classroomById = {
    for (final c in classrooms) c.id: c,
  };

  // Pour chaque élève, on retient la première assignation (best-effort —
  // idéalement la plus récente, mais le tri par défaut par PK suffit en V1).
  final map = <int, _ClassAssignmentExtras>{};
  for (final a in assignments) {
    if (map.containsKey(a.studentId)) continue;
    final c = classroomById[a.classroomId];
    map[a.studentId] = _ClassAssignmentExtras(
      classroomId: a.classroomId,
      classroomName: c?.name,
      status: StudentStatus.fromCode(a.status),
      inscriptionType: InscriptionType.fromCode(a.inscriptionType),
    );
  }
  return map;
}

class _ClassAssignmentExtras {
  final int classroomId;
  final String? classroomName;
  final StudentStatus? status;
  final InscriptionType? inscriptionType;
  const _ClassAssignmentExtras({
    required this.classroomId,
    this.classroomName,
    this.status,
    this.inscriptionType,
  });
}

// ---------------------------------------------------------------------------
// Providers de lecture
// ---------------------------------------------------------------------------

/// Liste filtrée des élèves.
///
/// - En ligne : `GET /students?search=&classroom_id=&sexe=&status=&page=&per_page=`,
///   cache Drift upserté en retour.
/// - Hors-ligne : lecture Drift filtrée (recherche + sexe + classe via assignations).
final studentsListProvider =
    FutureProvider.autoDispose.family<List<StudentDto>, StudentFilter>(
        (ref, filter) async {
  final conn = ref.watch(connectionProvider);
  final db = ref.watch(databaseProvider);

  if (conn.canReachServer && conn.serverUrl != null) {
    try {
      final dio = ref.watch(dioProvider);
      final url = buildUrl(conn.serverUrl!, ApiEndpoints.students);
      final resp = await dio.getJson<dynamic>(url, query: {
        if (filter.search.isNotEmpty) 'search': filter.search,
        if (filter.classroomId != null) 'classroom_id': filter.classroomId,
        if (filter.sexe != null) 'sexe': filter.sexe!.code,
        if (filter.status != null) 'status': filter.status!.code,
        'page': filter.page,
        'per_page': filter.perPage,
      });
      final data = resp.data;
      final List items;
      if (data is List) {
        items = data;
      } else if (data is Map && data['items'] is List) {
        items = data['items'] as List;
      } else {
        items = const [];
      }
      final dtos = items
          .whereType<Map>()
          .map((e) => StudentDto.fromJson(Map<String, dynamic>.from(e)))
          .toList();

      // Cache local (best-effort — n'échoue pas la requête si la persistance rate).
      await _cacheStudents(db, dtos);

      return dtos;
    } on ApiException catch (e) {
      _log.w('studentsListProvider (online) : ${e.message} → repli local');
      return _loadStudentsLocal(db, filter);
    } catch (e) {
      _log.w('studentsListProvider (online) : $e → repli local');
      return _loadStudentsLocal(db, filter);
    }
  }

  // Mode hors-ligne : lecture Drift uniquement.
  return _loadStudentsLocal(db, filter);
});

/// Détail d'un élève par ID.
///
/// En ligne : `GET /students/{id}` + cache Drift. Hors-ligne : lecture Drift
/// complète (élève + satellites).
final studentDetailProvider =
    FutureProvider.autoDispose.family<StudentDto, int>((ref, id) async {
  final conn = ref.watch(connectionProvider);
  final db = ref.watch(databaseProvider);

  if (conn.canReachServer && conn.serverUrl != null) {
    try {
      final dio = ref.watch(dioProvider);
      final url = buildUrl(conn.serverUrl!, ApiEndpoints.student(id));
      final resp = await dio.getJson<Map<String, dynamic>>(url);
      final dto = StudentDto.fromJson(resp.data ?? const {});
      await _cacheStudents(db, [dto]);
      return dto;
    } on ApiException catch (e) {
      _log.w('studentDetailProvider (online) : ${e.message} → repli local');
      return _loadStudentDetailLocal(db, id);
    } catch (e) {
      _log.w('studentDetailProvider (online) : $e → repli local');
      return _loadStudentDetailLocal(db, id);
    }
  }
  return _loadStudentDetailLocal(db, id);
});

// ---------------------------------------------------------------------------
// Repository (écritures : save / delete)
// ---------------------------------------------------------------------------

/// Erreur métier renvoyée par [StudentRepository].
class StudentRepositoryException implements Exception {
  const StudentRepositoryException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'StudentRepositoryException(${statusCode ?? ''}): $message';
}

/// Repository des élèves : gère la persistance locale + distante (avec outbox).
class StudentRepository {
  StudentRepository(this._ref);

  final Ref _ref;

  AppDatabase get _db => _ref.read(databaseProvider);
  Dio get _dio => _ref.read(dioProvider);
  Outbox get _outbox => _ref.read(outboxProvider);

  /// Crée (id null) ou met à jour (id non null) un élève.
  ///
  /// - En ligne : POST `/students` ou PATCH `/students/{id}` ; la réponse
  ///   serveur est ensuite cachée localement.
  /// - Hors-ligne : upsert Drift avec `is_dirty=true` + enqueue outbox
  ///   (`INSERT` ou `UPDATE`).
  Future<StudentDto> save(StudentDto dto) async {
    final conn = _ref.read(connectionProvider);
    final isCreate = dto.id <= 0;

    if (conn.canReachServer && conn.serverUrl != null) {
      try {
        final url = isCreate
            ? buildUrl(conn.serverUrl!, ApiEndpoints.students)
            : buildUrl(conn.serverUrl!, ApiEndpoints.student(dto.id));
        final resp = isCreate
            ? await _dio.postJson<Map<String, dynamic>>(url, data: dto.toJson())
            : await _dio.patchJson<Map<String, dynamic>>(url, data: dto.toJson());
        final saved = StudentDto.fromJson(resp.data ?? dto.toJson());
        await _cacheStudents(_db, [saved]);
        // Cache également les satellites explicites (la réponse peut ne pas les renvoyer).
        await _cacheSatellites(_db, dto, persistFromDto: true);
        return saved;
      } on ApiException catch (e) {
        throw StudentRepositoryException(e.message, statusCode: e.statusCode);
      } catch (e) {
        throw StudentRepositoryException('Échec de l\'enregistrement : $e');
      }
    }

    // Mode hors-ligne : on persiste localement avec is_dirty=true et on enfile
    // l'opération dans l'outbox pour push ultérieur.
    final localId = await _upsertStudentLocal(_db, dto, dirty: true);
    final localDto = _withId(dto, localId);
    await _cacheSatellites(_db, localDto, persistFromDto: true, dirty: true);
    await _outbox.enqueue(
      table: 'students',
      operation: isCreate ? 'INSERT' : 'UPDATE',
      recordId: isCreate ? null : dto.id,
      payload: localDto.toJson(),
    );
    return localDto;
  }

  /// Supprime un élève (soft-delete local + DELETE serveur ou outbox).
  Future<void> delete(int id) async {
    final conn = _ref.read(connectionProvider);

    // Marquage soft-delete local dans tous les cas (cohérence UI immédiate).
    await (_db.update(_db.students)..where((t) => t.id.equals(id))).write(
      const StudentsCompanion(
        isDeleted: Value(true),
        isDirty: Value(true),
      ),
    );

    if (conn.canReachServer && conn.serverUrl != null) {
      try {
        final url = buildUrl(conn.serverUrl!, ApiEndpoints.student(id));
        await _dio.deleteJson<void>(url);
      } on ApiException catch (e) {
        // 404 = déjà supprimé côté serveur : pas une erreur.
        if (e.statusCode != 404) {
          await _outbox.enqueue(
            table: 'students',
            operation: 'DELETE',
            recordId: id,
            payload: {'id': id},
          );
          throw StudentRepositoryException(e.message, statusCode: e.statusCode);
        }
      } catch (e) {
        await _outbox.enqueue(
          table: 'students',
          operation: 'DELETE',
          recordId: id,
          payload: {'id': id},
        );
        throw StudentRepositoryException('Suppression différée : $e');
      }
    } else {
      // Hors-ligne : on enfile un DELETE dans l'outbox.
      await _outbox.enqueue(
        table: 'students',
        operation: 'DELETE',
        recordId: id,
        payload: {'id': id},
      );
    }
  }
}

final studentRepositoryProvider =
    Provider<StudentRepository>((ref) => StudentRepository(ref));

// ---------------------------------------------------------------------------
// Cache local (écriture Drift)
// ---------------------------------------------------------------------------

/// Upsert en batch d'une liste d'élèves issus du serveur (et de leurs
/// satellites si présents dans le DTO). Best-effort : n'échoue pas l'appel.
Future<void> _cacheStudents(AppDatabase db, List<StudentDto> dtos) async {
  if (dtos.isEmpty) return;
  try {
    await db.batch((b) {
      for (final dto in dtos) {
        b.insert(
          db.students,
          StudentsCompanion.insert(
            id: Value(dto.id),
            matricule: dto.matricule,
            nom: dto.nom,
            prenoms: Value(dto.prenoms),
            dob: Value(dto.dob),
            sexe: Value(dto.sexe?.code),
            birthPlace: Value(dto.birthPlace),
            birthPrefecture: Value(dto.birthPrefecture),
            birthRegion: Value(dto.birthRegion),
            birthCountry: Value(dto.birthCountry),
            photoPath: Value(dto.photoPath),
            groupe: Value(dto.groupe),
            syncedAt: Value(DateTime.now().toUtc()),
            isDirty: const Value(false),
            isDeleted: const Value(false),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });

    // Satellites : on persiste également (un DTO issu du serveur les contient).
    for (final dto in dtos) {
      await _cacheSatellites(db, dto, persistFromDto: true);
    }
  } catch (e) {
    _log.w('_cacheStudents : échec partiel du cache local ($e)');
  }
}

/// Persiste les satellites d'un élève depuis le DTO. Si [persistFromDto] est
/// `false`, ne fait rien (utilisé pour nettoyer / préserver l'existant).
Future<void> _cacheSatellites(
  AppDatabase db,
  StudentDto dto, {
  bool persistFromDto = false,
  bool dirty = false,
}) async {
  if (!persistFromDto) return;
  final syncedAt = dirty ? null : DateTime.now().toUtc();

  try {
    // Contact (1-1).
    final c = dto.contact;
    if (c != null) {
      final existing = await (db.select(db.studentContacts)
            ..where((t) => t.studentId.equals(dto.id))
            ..where((t) => t.isDeleted.equals(false)))
          .getSingleOrNull();
      if (existing == null) {
        await db.into(db.studentContacts).insert(
              StudentContactsCompanion.insert(
                id: c.id == null ? const Value.absent() : Value(c.id!),
                studentId: dto.id,
                phone: Value(c.phone),
                email: Value(c.email),
                address: Value(c.address),
                city: Value(c.city),
                syncedAt: Value(syncedAt),
                isDirty: Value(dirty),
                isDeleted: const Value(false),
              ),
              mode: InsertMode.insertOrReplace,
            );
      } else {
        await (db.update(db.studentContacts)
              ..where((t) => t.id.equals(existing.id)))
            .write(StudentContactsCompanion(
          phone: Value(c.phone),
          email: Value(c.email),
          address: Value(c.address),
          city: Value(c.city),
          syncedAt: Value(syncedAt),
          isDirty: Value(dirty),
        ));
      }
    }

    // Médical (1-1).
    final m = dto.medical;
    if (m != null) {
      final existing = await (db.select(db.studentMedicals)
            ..where((t) => t.studentId.equals(dto.id))
            ..where((t) => t.isDeleted.equals(false)))
          .getSingleOrNull();
      if (existing == null) {
        await db.into(db.studentMedicals).insert(
              StudentMedicalsCompanion.insert(
                id: m.id == null ? const Value.absent() : Value(m.id!),
                studentId: dto.id,
                bloodType: Value(m.bloodType?.name),
                allergies: Value(m.allergies),
                doctor: Value(m.doctor),
                syncedAt: Value(syncedAt),
                isDirty: Value(dirty),
                isDeleted: const Value(false),
              ),
              mode: InsertMode.insertOrReplace,
            );
      } else {
        await (db.update(db.studentMedicals)
              ..where((t) => t.id.equals(existing.id)))
            .write(StudentMedicalsCompanion(
          bloodType: Value(m.bloodType?.name),
          allergies: Value(m.allergies),
          doctor: Value(m.doctor),
          syncedAt: Value(syncedAt),
          isDirty: Value(dirty),
        ));
      }
    }

    // Scolarité (1-1).
    final s = dto.scholastic;
    if (s != null) {
      final existing = await (db.select(db.studentScholastics)
            ..where((t) => t.studentId.equals(dto.id))
            ..where((t) => t.isDeleted.equals(false)))
          .getSingleOrNull();
      if (existing == null) {
        await db.into(db.studentScholastics).insert(
              StudentScholasticsCompanion.insert(
                id: s.id == null ? const Value.absent() : Value(s.id!),
                studentId: dto.id,
                previousSchool: Value(s.previousSchool),
                transport: Value(s.transport),
                syncedAt: Value(syncedAt),
                isDirty: Value(dirty),
                isDeleted: const Value(false),
              ),
              mode: InsertMode.insertOrReplace,
            );
      } else {
        await (db.update(db.studentScholastics)
              ..where((t) => t.id.equals(existing.id)))
            .write(StudentScholasticsCompanion(
          previousSchool: Value(s.previousSchool),
          transport: Value(s.transport),
          syncedAt: Value(syncedAt),
          isDirty: Value(dirty),
        ));
      }
    }

    // Parents (N).
    if (dto.parents.isNotEmpty) {
      // On supprime les anciens parents (non supprimés) puis on réinsère.
      await (db.update(db.studentParents)
            ..where((t) => t.studentId.equals(dto.id))
            ..where((t) => t.isDeleted.equals(false)))
          .write(const StudentParentsCompanion(isDeleted: Value(true)));
      for (final p in dto.parents) {
        await db.into(db.studentParents).insert(
              StudentParentsCompanion.insert(
                id: p.id == null ? const Value.absent() : Value(p.id!),
                studentId: dto.id,
                role: p.role,
                nom: Value(p.nom),
                prenoms: Value(p.prenoms),
                phone: Value(p.phone),
                profession: Value(p.profession),
                syncedAt: Value(syncedAt),
                isDirty: Value(dirty),
                isDeleted: const Value(false),
              ),
              mode: InsertMode.insertOrReplace,
            );
      }
    }

    // Tuteurs (N-N via guardians + student_guardians).
    if (dto.guardians.isNotEmpty) {
      for (final g in dto.guardians) {
        final guardianId = g.id ??
            await db.into(db.guardians).insertReturning(
                  GuardiansCompanion.insert(
                    nom: Value(g.nom),
                    prenoms: Value(g.prenoms),
                    phone: Value(g.phone),
                    email: Value(g.email),
                    relation: Value(g.relation),
                    syncedAt: Value(syncedAt),
                    isDirty: Value(dirty),
                    isDeleted: const Value(false),
                  ),
                ).then((r) => r.id);
        await db.into(db.studentGuardians).insert(
              StudentGuardiansCompanion.insert(
                studentId: dto.id,
                guardianId: guardianId,
                syncedAt: Value(syncedAt),
                isDirty: Value(dirty),
                isDeleted: const Value(false),
              ),
              mode: InsertMode.insertOrReplace,
            );
      }
    }
  } catch (e) {
    _log.w('_cacheSatellites : échec partiel ($e)');
  }
}

/// Upsert d'un élève en mode offline (is_dirty=true). Retourne l'ID persisté.
Future<int> _upsertStudentLocal(
  AppDatabase db,
  StudentDto dto, {
  required bool dirty,
}) async {
  final syncedAt = dirty ? null : DateTime.now().toUtc();
  if (dto.id > 0) {
    await db.into(db.students).insert(
          StudentsCompanion.insert(
            id: Value(dto.id),
            matricule: dto.matricule,
            nom: dto.nom,
            prenoms: Value(dto.prenoms),
            dob: Value(dto.dob),
            sexe: Value(dto.sexe?.code),
            birthPlace: Value(dto.birthPlace),
            birthPrefecture: Value(dto.birthPrefecture),
            birthRegion: Value(dto.birthRegion),
            birthCountry: Value(dto.birthCountry),
            photoPath: Value(dto.photoPath),
            groupe: Value(dto.groupe),
            syncedAt: Value(syncedAt),
            isDirty: Value(dirty),
            isDeleted: const Value(false),
          ),
          mode: InsertMode.insertOrReplace,
        );
    return dto.id;
  }
  // Création locale : on génère un ID négatif temporaire pour le distinguer
  // d'un ID serveur positif (convention simpliste — l'outbox portera le payload).
  final tempId = -DateTime.now().microsecondsSinceEpoch;
  await db.into(db.students).insert(
        StudentsCompanion.insert(
          id: Value(tempId),
          matricule: dto.matricule,
          nom: dto.nom,
          prenoms: Value(dto.prenoms),
          dob: Value(dto.dob),
          sexe: Value(dto.sexe?.code),
          birthPlace: Value(dto.birthPlace),
          birthPrefecture: Value(dto.birthPrefecture),
          birthRegion: Value(dto.birthRegion),
          birthCountry: Value(dto.birthCountry),
          photoPath: Value(dto.photoPath),
          groupe: Value(dto.groupe),
          syncedAt: Value(syncedAt),
          isDirty: Value(dirty),
          isDeleted: const Value(false),
        ),
        mode: InsertMode.insertOrReplace,
      );
  return tempId;
}

// ---------------------------------------------------------------------------
// Lecture locale (offline)
// ---------------------------------------------------------------------------

Future<List<StudentDto>> _loadStudentsLocal(
  AppDatabase db,
  StudentFilter filter,
) async {
  // 1) Assignations courantes (pour filtrage par classe/statut + enrichissement).
  final assignments = await (db.select(db.studentClassAssignments)
        ..where((t) => t.isDeleted.equals(false)))
      .get();
  final classroomIds = {
    for (final a in assignments) a.classroomId,
  };
  final classrooms = classroomIds.isEmpty
      ? const <Classroom>[]
      : await (db.select(db.classrooms)
            ..where((t) => t.id.isIn(classroomIds))
            ..where((t) => t.isDeleted.equals(false)))
          .get();
  final classroomById = {
    for (final c in classrooms) c.id: c,
  };

  // Map studentId → extras (classe courante + status + inscription).
  final extrasByStudent = <int, _ClassAssignmentExtras>{};
  for (final a in assignments) {
    if (extrasByStudent.containsKey(a.studentId)) continue;
    final c = classroomById[a.classroomId];
    extrasByStudent[a.studentId] = _ClassAssignmentExtras(
      classroomId: a.classroomId,
      classroomName: c?.name,
      status: StudentStatus.fromCode(a.status),
      inscriptionType: InscriptionType.fromCode(a.inscriptionType),
    );
  }

  // 2) Lecture des élèves (non supprimés) avec filtres simples.
  var query = db.select(db.students)
    ..where((t) => t.isDeleted.equals(false));

  if (filter.search.isNotEmpty) {
    final s = '%${filter.search}%';
    query = query
      ..where(
          (t) => t.matricule.like(s) | t.nom.like(s) | t.prenoms.like(s));
  }
  if (filter.sexe != null) {
    query = query..where((t) => t.sexe.equals(filter.sexe!.code));
  }

  final rows = await query.get();

  // 3) Filtre par classe/statut (post-fetch, via extras) + mapping.
  List<StudentDto> dtos = [];
  for (final row in rows) {
    final extras = extrasByStudent[row.id];
    if (filter.classroomId != null &&
        (extras?.classroomId != filter.classroomId)) {
      continue;
    }
    if (filter.status != null && extras?.status != filter.status) {
      continue;
    }
    dtos.add(_mapStudentRow(
      row,
      classroomId: extras?.classroomId,
      classroomName: extras?.classroomName,
      status: extras?.status,
      inscriptionType: extras?.inscriptionType,
    ));
  }

  // LimiteSoft (perPage) — sécurité pour éviter de tout matérialiser.
  if (dtos.length > filter.perPage) {
    dtos = dtos.sublist(0, filter.perPage);
  }
  return dtos;
}

Future<StudentDto> _loadStudentDetailLocal(AppDatabase db, int id) async {
  final row = await (db.select(db.students)
        ..where((t) => t.id.equals(id))
        ..where((t) => t.isDeleted.equals(false)))
      .getSingleOrNull();
  if (row == null) {
    throw const StudentRepositoryException('Élève introuvable localement.');
  }

  // Satellites (1-1) — non supprimés.
  final contact = await (db.select(db.studentContacts)
        ..where((t) => t.studentId.equals(id))
        ..where((t) => t.isDeleted.equals(false)))
      .getSingleOrNull();
  final medical = await (db.select(db.studentMedicals)
        ..where((t) => t.studentId.equals(id))
        ..where((t) => t.isDeleted.equals(false)))
      .getSingleOrNull();
  final scholastic = await (db.select(db.studentScholastics)
        ..where((t) => t.studentId.equals(id))
        ..where((t) => t.isDeleted.equals(false)))
      .getSingleOrNull();
  final parents = await (db.select(db.studentParents)
        ..where((t) => t.studentId.equals(id))
        ..where((t) => t.isDeleted.equals(false)))
      .get();
  final sgLinks = await (db.select(db.studentGuardians)
        ..where((t) => t.studentId.equals(id))
        ..where((t) => t.isDeleted.equals(false)))
      .get();
  final guardianIds = sgLinks.map((l) => l.guardianId).toSet();
  final guardians = guardianIds.isEmpty
      ? const <Guardian>[]
      : await (db.select(db.guardians)
            ..where((t) => t.id.isIn(guardianIds))
            ..where((t) => t.isDeleted.equals(false)))
          .get();

  final extras = await _loadAssignmentExtras(db, [id]);
  final e = extras[id];

  return _mapStudentRow(
    row,
    contact: contact,
    medical: medical,
    scholastic: scholastic,
    parents: parents,
    guardians: guardians,
    classroomId: e?.classroomId,
    classroomName: e?.classroomName,
    status: e?.status,
    inscriptionType: e?.inscriptionType,
  );
}
