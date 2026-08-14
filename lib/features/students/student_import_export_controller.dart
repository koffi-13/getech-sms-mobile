/// Contrôleur Import/Export Élèves (Excel/CSV).
///
/// Centralise les opérations de fichier côté serveur :
/// - `GET /students/export?template=true&format=xlsx` : téléchargement du
///   modèle Excel vide (avec en-têtes de colonnes pré-remplies).
/// - `GET /students/export?format=xlsx|csv&columns=...&classroom_id=...` :
///   export filtré des élèves existants.
/// - `POST /students/import` : upload multipart d'un fichier Excel/CSV rempli.
///
/// Les fichiers téléchargés sont persistés dans le répertoire
/// `getApplicationDocumentsDirectory()` et le chemin est retourné à l'appelant
/// pour ouverture/partage ultérieure.
///
/// Le serveur n'étant pas toujours documenté à 100 %, le parsing de la réponse
/// d'import est défensif (plusieurs formes acceptées : `{success_count, errors,
/// error_count}` ou `{imported, errors}` ou `{data: {...}}`).
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../connections/connection_state.dart';

final Logger _log = Logger(
  printer: PrettyPrinter(methodNames: false, noBoxingByDefault: true),
  level: Level.off,
);

// ---------------------------------------------------------------------------
// Colonnes exportables
// ---------------------------------------------------------------------------

/// Groupe logique d'une colonne d'export (pour l'UI multi-select groupée).
enum StudentColumnGroup {
  identite('Identité'),
  contact('Contact'),
  medical('Médical'),
  scolarite('Scolarité'),
  parents('Parents & Tuteur');

  final String label;
  const StudentColumnGroup(this.label);
}

/// Définition d'une colonne exportable : clé API (snake_case) + label FR.
class StudentColumn {
  final String key;
  final String label;
  final StudentColumnGroup group;

  const StudentColumn({
    required this.key,
    required this.label,
    required this.group,
  });

  @override
  String toString() => '$key ($label)';
}

/// Catalogue des colonnes exportables (référentiel GeTech-SMS).
///
/// L'ordre est preserved tel quel côté serveur (la liste `columns` envoyée
/// dans la query string contrôle l'ordre des colonnes dans le fichier généré).
class StudentColumns {
  StudentColumns._();

  static const List<StudentColumn> all = [
    StudentColumn(key: 'matricule', label: 'Matricule', group: StudentColumnGroup.identite),
    StudentColumn(key: 'nom', label: 'Nom', group: StudentColumnGroup.identite),
    StudentColumn(key: 'prenoms', label: 'Prénoms', group: StudentColumnGroup.identite),
    StudentColumn(key: 'dob', label: 'Date de naissance', group: StudentColumnGroup.identite),
    StudentColumn(key: 'sexe', label: 'Sexe', group: StudentColumnGroup.identite),
    StudentColumn(key: 'birth_place', label: 'Lieu de naissance', group: StudentColumnGroup.identite),
    StudentColumn(key: 'birth_prefecture', label: 'Préfecture', group: StudentColumnGroup.identite),
    StudentColumn(key: 'birth_region', label: 'Région', group: StudentColumnGroup.identite),
    StudentColumn(key: 'birth_country', label: 'Pays', group: StudentColumnGroup.identite),
    StudentColumn(key: 'phone', label: 'Téléphone', group: StudentColumnGroup.contact),
    StudentColumn(key: 'email', label: 'Email', group: StudentColumnGroup.contact),
    StudentColumn(key: 'address', label: 'Adresse', group: StudentColumnGroup.contact),
    StudentColumn(key: 'city', label: 'Ville', group: StudentColumnGroup.contact),
    StudentColumn(key: 'blood_type', label: 'Groupe sanguin', group: StudentColumnGroup.medical),
    StudentColumn(key: 'allergies', label: 'Allergies', group: StudentColumnGroup.medical),
    StudentColumn(key: 'doctor', label: 'Médecin', group: StudentColumnGroup.medical),
    StudentColumn(key: 'previous_school', label: 'École précédente', group: StudentColumnGroup.scolarite),
    StudentColumn(key: 'transport', label: 'Transport', group: StudentColumnGroup.scolarite),
    StudentColumn(key: 'classroom', label: 'Classe', group: StudentColumnGroup.scolarite),
    StudentColumn(key: 'status', label: 'Statut', group: StudentColumnGroup.scolarite),
    StudentColumn(key: 'inscription_type', label: 'Type d\'inscription', group: StudentColumnGroup.scolarite),
    StudentColumn(key: 'parent_pere', label: 'Père', group: StudentColumnGroup.parents),
    StudentColumn(key: 'parent_mere', label: 'Mère', group: StudentColumnGroup.parents),
    StudentColumn(key: 'guardian', label: 'Tuteur', group: StudentColumnGroup.parents),
  ];

  /// Clés par défaut (toutes) — utilisées si l'utilisateur ne filtre pas.
  static List<String> get defaultKeys => all.map((c) => c.key).toList();

  /// Regroupement pour l'affichage.
  static Map<StudentColumnGroup, List<StudentColumn>> get grouped {
    final m = <StudentColumnGroup, List<StudentColumn>>{};
    for (final c in all) {
      m.putIfAbsent(c.group, () => []).add(c);
    }
    return m;
  }

  /// Récupère le label d'une clé donnée (fallback : la clé elle-même).
  static String labelFor(String key) {
    for (final c in all) {
      if (c.key == key) return c.label;
    }
    return key;
  }
}

// ---------------------------------------------------------------------------
// Config & Result
// ---------------------------------------------------------------------------

/// Configuration de l'export des élèves.
class StudentExportConfig {
  /// Clés de colonnes à inclure (ex : ['matricule','nom','classroom']).
  /// Si vide, le serveur utilise ses colonnes par défaut.
  final List<String> columns;

  /// Format de fichier : 'xlsx' ou 'csv'.
  final String format;

  /// Filtrer par classe (optionnel).
  final int? classroomId;

  /// Inclure les photos (URL ou base64 — implémentation serveur).
  final bool includePhotos;

  const StudentExportConfig({
    this.columns = const [],
    this.format = 'xlsx',
    this.classroomId,
    this.includePhotos = false,
  });

  StudentExportConfig copyWith({
    List<String>? columns,
    String? format,
    int? classroomId,
    bool? includePhotos,
    bool clearClassroom = false,
  }) =>
      StudentExportConfig(
        columns: columns ?? this.columns,
        format: format ?? this.format,
        classroomId:
            clearClassroom ? null : (classroomId ?? this.classroomId),
        includePhotos: includePhotos ?? this.includePhotos,
      );

  /// Extension de fichier attendue pour le format choisi.
  String get fileExtension => format == 'csv' ? 'csv' : 'xlsx';
}

/// Erreur d'import d'une ligne du fichier.
class ImportRowError {
  final int? row;
  final String? matricule;
  final String message;

  const ImportRowError({
    this.row,
    this.matricule,
    required this.message,
  });

  factory ImportRowError.fromJson(Map<String, dynamic> j) => ImportRowError(
        row: (j['row'] as num?)?.toInt() ?? (j['line'] as num?)?.toInt(),
        matricule: j['matricule'] as String?,
        message: (j['message'] as String?) ??
            (j['error'] as String?) ??
            (j['detail'] as String?) ??
            'Erreur inconnue',
      );

  @override
  String toString() {
    final parts = <String>[];
    if (row != null) parts.add('Ligne ${row}');
    if (matricule != null) parts.add('matricule=$matricule');
    parts.add(message);
    return parts.join(' · ');
  }
}

/// Résultat d'un import : compteurs + liste des erreurs ligne par ligne.
class ImportResult {
  final int successCount;
  final int errorCount;
  final List<ImportRowError> errors;

  const ImportResult({
    this.successCount = 0,
    this.errorCount = 0,
    this.errors = const [],
  });

  factory ImportResult.fromJson(Map<String, dynamic> j) {
    // Plusieurs schémas possibles côté serveur — on tente les variants courants.
    final success = (j['success_count'] as num?)?.toInt() ??
        (j['imported'] as num?)?.toInt() ??
        (j['created'] as num?)?.toInt() ??
        (j['count'] as num?)?.toInt() ??
        0;
    final errorsList = j['errors'] as List? ?? const [];
    final errors = errorsList
        .whereType<Map>()
        .map((e) => ImportRowError.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final errorCount = (j['error_count'] as num?)?.toInt() ??
        (j['failed'] as num?)?.toInt() ??
        errors.length;
    return ImportResult(
      successCount: success,
      errorCount: errorCount,
      errors: errors,
    );
  }

  bool get hasErrors => errors.isNotEmpty;
}

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

/// Erreur renvoyée par [StudentImportExportController] lors d'un échec
/// de téléchargement, d'upload ou de parsing de réponse serveur.
class ImportExportException implements Exception {
  final String message;
  final int? statusCode;

  const ImportExportException(this.message, {this.statusCode});

  @override
  String toString() =>
      'ImportExportException(${statusCode ?? ''}): $message'.trim();
}

/// Contrôleur Riverpod des opérations Import/Export Élèves.
///
/// Stateless : la page appelante gère son propre indicateur de progression
/// via les callbacks `onReceiveProgress` / `onSendProgress` passés aux méthodes.
class StudentImportExportController {
  StudentImportExportController(this._ref);

  final Ref _ref;

  Dio get _dio => _ref.read(dioProvider);
  String? get _serverUrl => _ref.read(connectionProvider).serverUrl;

  /// Vérifie que le serveur est joignable et l'URL disponible.
  void _ensureReachable() {
    final conn = _ref.read(connectionProvider);
    if (!conn.canReachServer || conn.serverUrl == null) {
      throw const ImportExportException(
        'Import nécessite une connexion serveur.',
      );
    }
  }

  /// Télécharge le modèle Excel vide (`GET /students/export?template=true&format=xlsx`).
  ///
  /// Persiste les bytes reçus dans `getApplicationDocumentsDirectory()` sous
  /// `getech_modele_eleves_<timestamp>.xlsx` et retourne le chemin absolu.
  Future<String> downloadTemplate({
    void Function(int received, int total)? onProgress,
  }) async {
    _ensureReachable();
    final url = buildUrl(_serverUrl!, ApiEndpoints.studentsExport);
    try {
      final resp = await _dio.get<List<int>>(
        url,
        queryParameters: {
          'template': 'true',
          'format': 'xlsx',
        },
        options: Options(responseType: ResponseType.bytes),
        onReceiveProgress: onProgress,
      );
      return await _persistBytes(
        bytes: resp.data ?? const [],
        filename: _timestampedFilename(prefix: 'getech_modele_eleves', ext: 'xlsx'),
      );
    } on DioException catch (e) {
      throw _wrapDioError(e);
    } catch (e) {
      _log.w('downloadTemplate: $e');
      throw ImportExportException('Échec du téléchargement du modèle : $e');
    }
  }

  /// Exporte les élèves selon [config] (`GET /students/export?format=...&columns=...`).
  ///
  /// Retourne le chemin absolu du fichier généré côté mobile.
  Future<String> exportStudents(
    StudentExportConfig config, {
    void Function(int received, int total)? onProgress,
  }) async {
    _ensureReachable();
    final url = buildUrl(_serverUrl!, ApiEndpoints.studentsExport);
    final query = <String, dynamic>{
      'format': config.format,
      if (config.columns.isNotEmpty) 'columns': config.columns.join(','),
      if (config.classroomId != null) 'classroom_id': config.classroomId,
      if (config.includePhotos) 'include_photos': 'true',
    };
    try {
      final resp = await _dio.get<List<int>>(
        url,
        queryParameters: query,
        options: Options(responseType: ResponseType.bytes),
        onReceiveProgress: onProgress,
      );
      return await _persistBytes(
        bytes: resp.data ?? const [],
        filename: _timestampedFilename(
          prefix: 'getech_export_eleves',
          ext: config.fileExtension,
        ),
      );
    } on DioException catch (e) {
      throw _wrapDioError(e);
    } catch (e) {
      _log.w('exportStudents: $e');
      throw ImportExportException('Échec de l\'export : $e');
    }
  }

  /// Importe un fichier Excel/CSV rempli (`POST /students/import` multipart).
  ///
  /// [file] : fichier local sélectionné via `file_picker`.
  /// Retourne un [ImportResult] avec compteurs + erreurs détaillées.
  Future<ImportResult> importStudents(
    File file, {
    void Function(int sent, int total)? onProgress,
  }) async {
    _ensureReachable();
    if (!await file.exists()) {
      throw const ImportExportException('Fichier introuvable sur l\'appareil.');
    }
    final url = buildUrl(_serverUrl!, ApiEndpoints.studentsImport);
    final filename = p.basename(file.path);

    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(file.path, filename: filename),
    });

    try {
      final resp = await _dio.post<dynamic>(
        url,
        data: form,
        // NB : ne PAS fixer `Content-Type: multipart/form-data` manuellement —
        // Dio le calcule automatiquement à partir du FormData (boundary inclus).
        options: Options(),
        onSendProgress: onProgress,
      );
      final data = resp.data;
      if (data is Map<String, dynamic>) {
        return ImportResult.fromJson(data);
      }
      if (data is Map) {
        return ImportResult.fromJson(Map<String, dynamic>.from(data));
      }
      // Réponse inattendue — on suppose un succès sans détail.
      _log.w('importStudents: réponse non-JSON reçue (${data.runtimeType})');
      return const ImportResult();
    } on DioException catch (e) {
      // Le serveur peut renvoyer 422 avec un body JSON détaillant les erreurs
      // de validation — on tente de le parser pour afficher les erreurs.
      final resp = e.response;
      if (resp != null && resp.data is Map) {
        try {
          return ImportResult.fromJson(
            Map<String, dynamic>.from(resp.data as Map),
          );
        } catch (_) {
          // Fallthrough vers l'erreur générique.
        }
      }
      throw _wrapDioError(e);
    } catch (e) {
      _log.w('importStudents: $e');
      throw ImportExportException('Échec de l\'import : $e');
    }
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// Écrit les bytes reçus dans le dossier Documents de l'app et retourne
  /// le chemin complet.
  Future<String> _persistBytes({
    required List<int> bytes,
    required String filename,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, filename);
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return path;
  }

  /// Génère un nom de fichier daté : `<prefix>_<YYYYMMDD_HHmmss>.<ext>`.
  String _timestampedFilename({
    required String prefix,
    required String ext,
  }) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}';
    return '${prefix}_$stamp.$ext';
  }

  ImportExportException _wrapDioError(DioException e) {
    final api = (e.error is ApiException)
        ? e.error as ApiException
        : dioErrorToApiException(e);
    return ImportExportException(
      api.message,
      statusCode: api.statusCode,
    );
  }
}

/// Provider du contrôleur Import/Export Élèves.
final studentImportExportProvider =
    Provider<StudentImportExportController>((ref) {
  return StudentImportExportController(ref);
});
