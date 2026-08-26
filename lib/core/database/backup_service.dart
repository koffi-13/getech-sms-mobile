/// Service de sauvegarde et restauration de la base de données locale GeTech-SMS.
/// Exporte l'intégralité des tables répliquées en un seul fichier JSON.
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'database.dart';

/// Service gérant l'export/import JSON de la DB.
class BackupService {
  BackupService(this._ref);
  final Ref _ref;

  AppDatabase get _db => _ref.read(databaseProvider);

  /// Exporte toutes les données répliquées au format JSON et propose le partage.
  Future<void> exportBackup() async {
    try {
      final Map<String, dynamic> backup = {
        'version': '1.0.0',
        'exportedAt': DateTime.now().toIso8601String(),
        'tables': {},
      };

      final tables = {
        'establishments': _db.establishments,
        'school_years': _db.schoolYears,
        'periods': _db.periods,
        'levels': _db.levels,
        'series': _db.series,
        'streams': _db.streams,
        'classrooms': _db.classrooms,
        'subjects': _db.subjects,
        'class_subjects': _db.classSubjects,
        'assessments': _db.assessments,
        'grades': _db.grades,
        'students': _db.students,
        'student_contacts': _db.studentContacts,
        'student_medicals': _db.studentMedicals,
        'student_scholastics': _db.studentScholastics,
        'student_parents': _db.studentParents,
        'guardians': _db.guardians,
        'student_guardians': _db.studentGuardians,
        'student_class_assignments': _db.studentClassAssignments,
        'student_statuses': _db.studentStatuses,
        'inscription_types': _db.inscriptionTypes,
        'time_slots': _db.timeSlots,
        'weekly_schedules': _db.weeklySchedules,
        'course_sessions': _db.courseSessions,
        'student_absences': _db.studentAbsences,
        'lesson_records': _db.lessonRecords,
        'users': _db.users,
      };

      for (final entry in tables.entries) {
        final rows = await (entry.value as dynamic).select().get();
        backup['tables'][entry.key] = rows.map((r) => r.toJson()).toList();
      }

      final jsonStr = jsonEncode(backup);
      final tempDir = await getTemporaryDirectory();
      final fileName = 'getech_backup_${DateTime.now().millisecondsSinceEpoch}.json';
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsString(jsonStr);

      await Share.shareXFiles([XFile(file.path)], text: 'Sauvegarde GeTech-SMS');
    } catch (e) {
      throw Exception('Échec de l\'export : $e');
    }
  }

  /// Ouvre un sélecteur de fichier et restaure les données depuis le JSON choisi.
  Future<bool> importBackup() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result == null || result.files.single.path == null) return false;

      final file = File(result.files.single.path!);
      final content = await file.readAsString();
      final Map<String, dynamic> backup = jsonDecode(content);

      if (backup['version'] == null || backup['tables'] == null) {
        throw const FormatException('Fichier de sauvegarde invalide.');
      }

      final tableData = backup['tables'] as Map<String, dynamic>;

      await _db.transaction(() async {
        // Pour une restauration propre, on pourrait vouloir vider les tables d'abord.
        // Ici on fait des insertOrReplace.
        for (final entry in tableData.entries) {
          final tableName = entry.key;
          final rows = entry.value as List;
          if (rows.isEmpty) continue;

          final dynamic table = _getTableByName(tableName);
          if (table == null) continue;

          await _db.batch((b) {
            for (final row in rows) {
              final insertable = table.fromJson(row);
              b.insert(
                table as TableInfo,
                insertable,
                mode: InsertMode.insertOrReplace,
              );
            }
          });
        }
      });

      return true;
    } catch (e) {
      throw Exception('Échec de l\'import : $e');
    }
  }

  dynamic _getTableByName(String name) {
    switch (name) {
      case 'establishments': return _db.establishments;
      case 'school_years': return _db.schoolYears;
      case 'periods': return _db.periods;
      case 'levels': return _db.levels;
      case 'series': return _db.series;
      case 'streams': return _db.streams;
      case 'classrooms': return _db.classrooms;
      case 'subjects': return _db.subjects;
      case 'class_subjects': return _db.classSubjects;
      case 'assessments': return _db.assessments;
      case 'grades': return _db.grades;
      case 'students': return _db.students;
      case 'student_contacts': return _db.studentContacts;
      case 'student_medicals': return _db.studentMedicals;
      case 'student_scholastics': return _db.studentScholastics;
      case 'student_parents': return _db.studentParents;
      case 'guardians': return _db.guardians;
      case 'student_guardians': return _db.studentGuardians;
      case 'student_class_assignments': return _db.studentClassAssignments;
      case 'student_statuses': return _db.studentStatuses;
      case 'inscription_types': return _db.inscriptionTypes;
      case 'time_slots': return _db.timeSlots;
      case 'weekly_schedules': return _db.weeklySchedules;
      case 'course_sessions': return _db.courseSessions;
      case 'student_absences': return _db.studentAbsences;
      case 'lesson_records': return _db.lessonRecords;
      case 'users': return _db.users;
      default: return null;
    }
  }
}

final backupServiceProvider = Provider<BackupService>((ref) => BackupService(ref));
