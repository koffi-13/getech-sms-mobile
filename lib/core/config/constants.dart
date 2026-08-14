/// Constantes métier GeTech-SMS : codes RBAC, énumérations, référentiels.
///
/// Ces valeurs reflètent le schéma du terminal principal (desktop) tel que
/// documenté dans PROMPT.md. Elles évitent les chaînes magiques dans le code.
library;

import 'package:flutter/material.dart';

/// Codes de permission RBAC (côté serveur).
///
/// Le superuser reçoit le code `*` qui bypass toutes les vérifications.
class RbacPermissions {
  RbacPermissions._();

  static const String wildcard = '*';

  // Élèves
  static const String studentRead = 'STUDENT_READ';
  static const String studentCreate = 'STUDENT_CREATE';

  // Notes
  static const String gradeRead = 'GRADE_READ';
  static const String gradeEdit = 'GRADE_EDIT';

  // Classes
  static const String classroomManage = 'CLASSROOM_MANAGE';

  // Matières
  static const String subjectManage = 'SUBJECT_MANAGE';

  // Utilisateurs
  static const String userRead = 'USER_READ';
  static const String userManage = 'USER_MANAGE';

  // Finances
  static const String paymentRead = 'PAYMENT_READ';
  static const String paymentValidate = 'PAYMENT_VALIDATE';

  /// Toutes les permissions connues (pour audit/UI debug).
  static const List<String> all = [
    studentRead,
    studentCreate,
    gradeRead,
    gradeEdit,
    classroomManage,
    subjectManage,
    userRead,
    userManage,
    paymentRead,
    paymentValidate,
  ];
}

/// Sexe d'un élève.
enum Sexe {
  masculin('M', 'Masculin'),
  feminin('F', 'Féminin');

  final String code;
  final String label;
  const Sexe(this.code, this.label);

  static Sexe? fromCode(String? code) {
    if (code == null) return null;
    for (final s in values) {
      if (s.code == code) return s;
    }
    return null;
  }
}

/// Statut d'un élève (référentiel).
enum StudentStatus {
  nouveau('NOUVEAU', 'Nouveau'),
  redoublant('REDOUBLANT', 'Redoublant');

  final String code;
  final String label;
  const StudentStatus(this.code, this.label);

  static StudentStatus? fromCode(String? code) {
    if (code == null) return null;
    for (final s in values) {
      if (s.code == code) return s;
    }
    return null;
  }
}

/// Type d'inscription d'un élève (référentiel).
enum InscriptionType {
  nouveau('NOUVEAU', 'Nouveau'),
  ancien('ANCIEN', 'Ancien'),
  exclu('EXCLU', 'Exclu'),
  abandon('ABANDON', 'Abandon');

  final String code;
  final String label;
  const InscriptionType(this.code, this.label);

  static InscriptionType? fromCode(String? code) {
    if (code == null) return null;
    for (final s in values) {
      if (s.code == code) return s;
    }
    return null;
  }
}

/// État d'une session de cours (présence).
enum CourseSessionState {
  pending('PENDING', 'En attente'),
  completed('COMPLETED', 'Terminée'),
  cancelled('CANCELLED', 'Annulée');

  final String code;
  final String label;
  const CourseSessionState(this.code, this.label);

  static CourseSessionState? fromCode(String? code) {
    if (code == null) return null;
    for (final s in values) {
      if (s.code == code) return s;
    }
    return null;
  }
}

/// Type de semaine (emploi du temps alterné A/B).
enum WeekType { a, b }

/// Jours de la semaine scolaire (Lundi=1 .. Samedi=6, pas de dimanche).
enum SchoolDay {
  lundi(1, 'Lundi'),
  mardi(2, 'Mardi'),
  mercredi(3, 'Mercredi'),
  jeudi(4, 'Jeudi'),
  vendredi(5, 'Vendredi'),
  samedi(6, 'Samedi');

  final int index;
  final String label;
  const SchoolDay(this.index, this.label);

  static SchoolDay? fromIndex(int? i) {
    if (i == null) return null;
    for (final d in values) {
      if (d.index == i) return d;
    }
    return null;
  }
}

/// Type d'évaluation.
enum AssessmentType {
  devoir('DEVOIR', 'Devoir'),
  compose('COMPOSE', 'Composition'),
  interrogation('INTERRO', 'Interrogation'),
  tp('TP', 'Travail pratique');

  final String code;
  final String label;
  const AssessmentType(this.code, this.label);
}

/// Type de transaction (aligné sur PaymentType du desktop).
enum PaymentType {
  paiement('PAYMENT', 'Paiement'),
  remboursement('REFUND', 'Remboursement');

  final String code;
  final String label;
  const PaymentType(this.code, this.label);

  static PaymentType? fromCode(String? code) {
    if (code == null) return null;
    for (final p in values) {
      if (p.code == code) return p;
    }
    return null;
  }
}

/// Catégorie de frais (alignée sur FeeCategory du desktop).
enum FeeCategoryCode {
  inscription('ENR', 'Inscription'),
  scolarite('SCHOOL_FEES', 'Scolarité'),
  cantine('CANTEEN', 'Cantine'),
  transport('TRANSPORT', 'Transport'),
  activite('ACTIVITIES', 'Activités'),
  autre('OTHER', 'Autre');

  final String code;
  final String label;
  const FeeCategoryCode(this.code, this.label);

  static FeeCategoryCode? fromCode(String? code) {
    if (code == null) return null;
    for (final f in values) {
      if (f.code == code) return f;
    }
    return null;
  }
}

/// Méthode de paiement (alignée sur PaymentMethod du desktop).
enum PaymentMethod {
  espece('CASH', 'Espèces'),
  mobileMoney('MOBILE_MONEY', 'Mobile Money'),
  virement('BANK_TRANSFER', 'Virement'),
  carte('CARD', 'Carte'),
  cheque('CHEQUE', 'Chèque'),
  autre('OTHER', 'Autre');

  final String code;
  final String label;
  const PaymentMethod(this.code, this.label);

  static PaymentMethod? fromCode(String? code) {
    if (code == null) return null;
    for (final m in values) {
      if (m.code == code) return m;
    }
    return null;
  }
}

/// Statut d'un paiement (aligné sur PaymentStatus du desktop).
enum PaymentStatus {
  enAttente('PENDING', 'En attente'),
  valide('COMPLETED', 'Validé'),
  echec('FAILED', 'Échec'),
  rembourse('REFUNDED', 'Remboursé'),
  annule('CANCELLED', 'Annulé');

  final String code;
  final String label;
  const PaymentStatus(this.code, this.label);

  static PaymentStatus? fromCode(String? code) {
    if (code == null) return null;
    for (final s in values) {
      if (s.code == code) return s;
    }
    return null;
  }
}

/// Statut d'une subscription de frais (aligné sur SubscriptionStatus du desktop).
enum SubscriptionStatus {
  active('ACTIVE', 'Active'),
  partiel('PARTIAL', 'Partiel'),
  payed('PAID', 'Soldée'),
  annule('CANCELLED', 'Annulée');

  final String code;
  final String label;
  const SubscriptionStatus(this.code, this.label);

  static SubscriptionStatus? fromCode(String? code) {
    if (code == null) return null;
    for (final s in values) {
      if (s.code == code) return s;
    }
    return null;
  }
}

/// Groupe sanguin (référentiel médical).
enum BloodType { aPlus, aMoins, bPlus, bMoins, abPlus, abMoins, oPlus, oMoins, inconnu }

/// État de synchro d'un enregistrement local.
enum SyncState { synced, dirty, pending, conflict }

/// Mode d'appairage d'un appareil (module Connexions).
enum PairingMode { mdns, qrCode, manual }

/// Type de terminal (pour paired_devices).
enum DeviceType { mobile, desktop, web, tablet }

/// Devise utilisée (Franc CFA — XOF).
const String defaultCurrency = 'XOF';

/// Note maximale par défaut.
const double defaultMaxScore = 20.0;

/// Incrément de saisie des notes.
const double gradeStep = 0.5;

/// Format de date affiché (JJ/MM/AAAA).
const String dateFormatFr = 'dd/MM/yyyy';
const String dateTimeFormatFr = 'dd/MM/yyyy HH:mm';
const String timeFormatFr = 'HH:mm';
