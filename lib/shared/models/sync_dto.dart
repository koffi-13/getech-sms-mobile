/// DTOs Tableau de bord (KPIs + alertes) et Synchro (pull/push).
library;

import '../../core/utils/formatters.dart';

/// Statistiques du tableau de bord : `GET /dashboard/stats`.
class DashboardStatsDto {
  final int totalStudents;
  final int totalClassrooms;
  final int totalTeachers;
  final double paymentsToday;
  final double outstandingBalance;
  final Map<String, int> studentsBySex; // {'M': 120, 'F': 95}
  final List<ClassOccupancyDto> classOccupancy;
  final List<AbsenteeAlertDto> absenteeAlerts;
  final List<OverduePaymentDto> overduePayments;

  const DashboardStatsDto({
    this.totalStudents = 0,
    this.totalClassrooms = 0,
    this.totalTeachers = 0,
    this.paymentsToday = 0,
    this.outstandingBalance = 0,
    this.studentsBySex = const {},
    this.classOccupancy = const [],
    this.absenteeAlerts = const [],
    this.overduePayments = const [],
  });

  factory DashboardStatsDto.fromJson(Map<String, dynamic> j) => DashboardStatsDto(
        totalStudents: (j['total_students'] as num?)?.toInt() ?? 0,
        totalClassrooms: (j['total_classrooms'] as num?)?.toInt() ?? 0,
        totalTeachers: (j['total_teachers'] as num?)?.toInt() ?? 0,
        paymentsToday: (j['payments_today'] as num?)?.toDouble() ?? 0,
        outstandingBalance:
            (j['outstanding_balance'] as num?)?.toDouble() ?? 0,
        studentsBySex: Map<String, int>.from(
          (j['students_by_sex'] as Map?)?.map(
                  (k, v) => MapEntry(k.toString(), (v as num).toInt())) ??
              const {},
        ),
        classOccupancy: (j['class_occupancy'] as List?)
                ?.map((e) =>
                    ClassOccupancyDto.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        absenteeAlerts: (j['absentee_alerts'] as List?)
                ?.map((e) =>
                    AbsenteeAlertDto.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        overduePayments: (j['overdue_payments'] as List?)
                ?.map((e) =>
                    OverduePaymentDto.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );
}

class ClassOccupancyDto {
  final int classroomId;
  final String classroomName;
  final int studentCount;
  final int capacity;

  const ClassOccupancyDto({
    required this.classroomId,
    required this.classroomName,
    required this.studentCount,
    this.capacity = 0,
  });

  double get rate => capacity == 0 ? 0 : studentCount / capacity;

  factory ClassOccupancyDto.fromJson(Map<String, dynamic> j) =>
      ClassOccupancyDto(
        classroomId: (j['classroom_id'] as num).toInt(),
        classroomName: j['classroom_name'] as String? ?? '',
        studentCount: (j['student_count'] as num).toInt(),
        capacity: (j['capacity'] as num?)?.toInt() ?? 0,
      );
}

class AbsenteeAlertDto {
  final int studentId;
  final String studentName;
  final String? matricule;
  final String? classroomName;
  final int absenceCount;
  final DateTime? lastAbsence;

  const AbsenteeAlertDto({
    required this.studentId,
    required this.studentName,
    this.matricule,
    this.classroomName,
    this.absenceCount = 0,
    this.lastAbsence,
  });

  factory AbsenteeAlertDto.fromJson(Map<String, dynamic> j) => AbsenteeAlertDto(
        studentId: (j['student_id'] as num).toInt(),
        studentName: j['student_name'] as String? ?? '',
        matricule: j['matricule'] as String?,
        classroomName: j['classroom_name'] as String?,
        absenceCount: (j['absence_count'] as num?)?.toInt() ?? 0,
        lastAbsence: DateFormatter.parse(j['last_absence'] as String?),
      );
}

class OverduePaymentDto {
  final int studentId;
  final String studentName;
  final String? classroomName;
  final double amountDue;
  final DateTime? dueDate;

  const OverduePaymentDto({
    required this.studentId,
    required this.studentName,
    this.classroomName,
    this.amountDue = 0,
    this.dueDate,
  });

  factory OverduePaymentDto.fromJson(Map<String, dynamic> j) =>
      OverduePaymentDto(
        studentId: (j['student_id'] as num).toInt(),
        studentName: j['student_name'] as String? ?? '',
        classroomName: j['classroom_name'] as String?,
        amountDue: (j['amount_due'] as num?)?.toDouble() ?? 0,
        dueDate: DateFormatter.parse(j['due_date'] as String?),
      );
}

// --- Synchro ---

/// Réponse du pull incrémental : `GET /sync/pull?since=<timestamp>`.
class SyncPullResponse {
  final DateTime serverTime;
  final Map<String, List<Map<String, dynamic>>> changes;
  final List<String> deleted; // IDs supprimés côté serveur (soft-delete)

  const SyncPullResponse({
    required this.serverTime,
    this.changes = const {},
    this.deleted = const [],
  });

  int get totalChanges =>
      changes.values.fold(0, (sum, list) => sum + list.length);

  factory SyncPullResponse.fromJson(Map<String, dynamic> j) => SyncPullResponse(
        serverTime: DateFormatter.parse(j['server_time'] as String?) ??
            DateTime.now().toUtc(),
        changes: (j['changes'] as Map?)?.map((k, v) => MapEntry(
              k.toString(),
              (v as List)
                  .map((e) => Map<String, dynamic>.from(e as Map))
                  .toList(),
            )) ??
            const {},
        deleted: List<String>.from(j['deleted'] as List? ?? const []),
      );
}

/// Requête de push : `POST /sync/push`.
class SyncPushRequest {
  final Map<String, List<Map<String, dynamic>>> changes;

  const SyncPushRequest({required this.changes});

  Map<String, dynamic> toJson() => {'changes': changes};
}

/// Réponse du push (résultat par table + conflits éventuels).
class SyncPushResponse {
  final DateTime serverTime;
  final Map<String, int> applied; // table -> count
  final List<String> conflicts; // server-wins : IDs ignorés

  const SyncPushResponse({
    required this.serverTime,
    this.applied = const {},
    this.conflicts = const [],
  });

  factory SyncPushResponse.fromJson(Map<String, dynamic> j) => SyncPushResponse(
        serverTime: DateFormatter.parse(j['server_time'] as String?) ??
            DateTime.now().toUtc(),
        applied: Map<String, int>.from(
          (j['applied'] as Map?)?.map(
                  (k, v) => MapEntry(k.toString(), (v as num).toInt())) ??
              const {},
        ),
        conflicts: List<String>.from(j['conflicts'] as List? ?? const []),
      );
}
