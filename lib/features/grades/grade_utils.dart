/// Utilitaires métier du module Notes : mentions, couleurs, types d'évaluation.
///
/// ⚠️ Aligné sur la logique du desktop (grade_service.get_mention,
/// grade_service.get_mention_color, models/academic/assessment_type.py).
///
/// Les mentions sont calculées côté client à partir de la moyenne :
///   ≥ 18 → Excellent
///   ≥ 16 → Très Bien
///   ≥ 14 → Bien
///   ≥ 12 → Assez Bien
///   ≥ 10 → Passable
///   < 10 → Insuffisant
library;

import 'package:flutter/material.dart';

import '../../core/config/constants.dart';

/// Calcul des mentions et couleurs associées (miroir de grade_service.py).
class MentionHelper {
  MentionHelper._();

  /// Retourne le libellé de la mention pour une moyenne donnée.
  static String mention(double? average) {
    if (average == null) return '—';
    if (average >= 18) return 'Excellent';
    if (average >= 16) return 'Très Bien';
    if (average >= 14) return 'Bien';
    if (average >= 12) return 'Assez Bien';
    if (average >= 10) return 'Passable';
    return 'Insuffisant';
  }

  /// Retourne la couleur associée à la mention.
  static Color color(double? average) {
    if (average == null) return Colors.grey;
    if (average >= 16) return const Color(0xFF10B981); // emerald
    if (average >= 14) return const Color(0xFF3B82F6); // blue
    if (average >= 10) return const Color(0xFFF59E0B); // amber
    return const Color(0xFFEF4444); // red
  }

  /// Retourne la couleur de fond (clair) pour un badge de mention.
  static Color backgroundColor(double? average) => color(average).withValues(alpha: 0.12);

  /// Indique si la moyenne est de réussite (≥ 10).
  static bool isPassing(double? average) => average != null && average >= 10;
}

/// Type d'évaluation (AssessmentType côté desktop).
///
/// ⚠️ Aucun endpoint REST ne liste les types d'évaluation pour le moment.
/// Ces valeurs sont codées en dur en attendant l'endpoint `/assessment-types`.
/// Les IDs doivent correspondre aux IDs de la table `assessment_types` côté serveur.
class AssessmentTypeInfo {
  final int id;
  final String name;
  final String code;
  final AssessmentCategory category;
  final int defaultMaxScore;

  const AssessmentTypeInfo({
    required this.id,
    required this.name,
    required this.code,
    required this.category,
    this.defaultMaxScore = 20,
  });
}

/// Catégorie d'évaluation (AssessmentCategory côté desktop).
enum AssessmentCategory {
  classe('CLASS', 'Cours'),
  examen('EXAM', 'Examen');

  final String code;
  final String label;
  const AssessmentCategory(this.code, this.label);
}

/// Types d'évaluation courants (alignés sur le référentiel desktop).
///
/// Ces valeurs sont indicatives ; les IDs réels dépendent de la base serveur.
/// L'admin doit créer les types d'évaluation côté desktop. En attendant
/// l'endpoint REST, l'utilisateur peut saisir l'ID manuellement.
class CommonAssessmentTypes {
  CommonAssessmentTypes._();

  /// Types d'évaluation prédéfinis (IDs typiques).
  /// En production, ces IDs doivent correspondre à la table `assessment_types`.
  static const List<AssessmentTypeInfo> defaults = [
    AssessmentTypeInfo(
      id: 1,
      name: 'Interrogation',
      code: 'INTERRO',
      category: AssessmentCategory.classe,
    ),
    AssessmentTypeInfo(
      id: 2,
      name: 'Devoir',
      code: 'DEVOIR',
      category: AssessmentCategory.classe,
    ),
    AssessmentTypeInfo(
      id: 3,
      name: 'Composition',
      code: 'COMPOSITION',
      category: AssessmentCategory.examen,
    ),
  ];

  /// Recherche un type par ID.
  static AssessmentTypeInfo? findById(int? id) {
    if (id == null) return null;
    for (final t in defaults) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// Recherche un type par code.
  static AssessmentTypeInfo? findByCode(String? code) {
    if (code == null) return null;
    for (final t in defaults) {
      if (t.code == code) return t;
    }
    return null;
  }
}

/// Extension du [GradeFormatter] existant pour la mention.
extension GradeMentionExtension on double? {
  String get mentionText => MentionHelper.mention(this);
  Color get mentionColor => MentionHelper.color(this);
}
