/// Utilitaires de formatage : dates (JJ/MM/AAAA), montants (XOF), notes.
library;

import 'package:intl/intl.dart';

import '../config/constants.dart';

/// Formatage des dates et heures en français.
class DateFormatter {
  DateFormatter._();

  static String date(DateTime? d) {
    if (d == null) return '—';
    return DateFormat(dateFormatFr, 'fr').format(d.toLocal());
  }

  static String dateTime(DateTime? d) {
    if (d == null) return '—';
    return DateFormat(dateTimeFormatFr, 'fr').format(d.toLocal());
  }

  static String time(DateTime? d) {
    if (d == null) return '—';
    return DateFormat(timeFormatFr, 'fr').format(d.toLocal());
  }

  /// Durée relative humanisée : "il y a 5 min", "il y a 2 h".
  static String relative(DateTime? d, {DateTime? now}) {
    if (d == null) return 'jamais';
    final ref = (now ?? DateTime.now()).toLocal();
    final diff = ref.difference(d.toLocal());
    if (diff.isNegative) return 'à l\'instant';
    if (diff.inSeconds < 60) return 'à l\'instant';
    if (diff.inMinutes < 60) return 'il y a ${diff.inMinutes} min';
    if (diff.inHours < 24) return 'il y a ${diff.inHours} h';
    if (diff.inDays < 7) return 'il y a ${diff.inDays} j';
    return date(d);
  }

  /// Parse une date ISO-8601 (UTC) depuis l'API.
  static DateTime? parse(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      return DateTime.parse(s);
    } catch (_) {
      return null;
    }
  }

  /// Sérialise une date en ISO-8601 UTC pour l'API.
  static String? toIso(DateTime? d) => d?.toUtc().toIso8601String();
}

/// Formatage des montants en Francs CFA (XOF).
class MoneyFormatter {
  MoneyFormatter._();

  /// Format compact : "1 250 000 FCFA".
  static String format(num? amount, {bool withSymbol = true}) {
    final value = amount ?? 0;
    final formatted = NumberFormat.decimalPattern('fr').format(value);
    return withSymbol ? '$formatted FCFA' : formatted;
  }

  /// Format abrégé pour les KPI : "1,2 M", "950 k".
  static String compact(num? amount) {
    final value = (amount ?? 0).toDouble();
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)} M FCFA';
    }
    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(0)} k FCFA';
    }
    return '${value.toStringAsFixed(0)} FCFA';
  }
}

/// Formatage des notes (0–20, incréments de 0.5).
class GradeFormatter {
  GradeFormatter._();

  static String format(double? value, {double max = defaultMaxScore}) {
    if (value == null) return 'Abs';
    return '${value.toStringAsFixed(2)} / ${max.toStringAsFixed(0)}';
  }

  /// Arrondit une note au pas de 0.5 le plus proche.
  static double snap(double value) {
    return (value * 2).round() / 2;
  }

  /// Moyenne pondérée.
  static double weightedAverage(List<double> values, List<double> weights) {
    if (values.length != weights.length || values.isEmpty) return 0;
    double sum = 0;
    double wSum = 0;
    for (var i = 0; i < values.length; i++) {
      sum += values[i] * weights[i];
      wSum += weights[i];
    }
    return wSum == 0 ? 0 : sum / wSum;
  }
}

/// Formatage d'un effectif avec pluriel.
class CountFormatter {
  CountFormatter._();

  static String students(int n) => '$n élève${n > 1 ? 's' : ''}';
  static String classrooms(int n) => '$n classe${n > 1 ? 's' : ''}';
  static String teachers(int n) => '$n enseignant${n > 1 ? 's' : ''}';
}
