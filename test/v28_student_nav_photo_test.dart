/// [Fix-PHOTO-VIEWER / Fix-STUDENT-NAV] Régressions mobiles :
///
/// 1. La page de détail élève accepte `navStudentIds` (liste ordonnée de
///    la sélection FILTRÉE de la liste) et la route `/students/:id` la
///    lit depuis `state.extra` — sans elle, pas de Précédent/Suivant.
/// 2. La liste d'élèves transmet les IDs filtrés au moment du tap
///    (`extra` de go_router) — la navigation suit l'ordre AFFICHÉ
///    (filtres + recherche), pas l'ordre brut de la base.
/// 3. La visionneuse photo plein écran existe et est routée sur
///    `/students/:id/photo` (toucher la photo du détail).
library;

import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';

/// Lit un fichier du projet (les tests s'exécutent depuis la racine).
String readFile(String relativePath) => io.File(relativePath).readAsStringSync();

void main() {
  group('[Fix-STUDENT-NAV] navigation élève ↔ élève', () {
    test('StudentDetailPage expose navStudentIds (constructeur + champ)', () {
      final src = readFile('lib/features/students/student_detail_page.dart');
      expect(
        src,
        contains('final List<int>? navStudentIds;'),
        reason: 'Le champ navStudentIds doit exister (liste filtrée '
            'transmise par la page Liste).',
      );
      expect(
        src,
        contains('this.navStudentIds'),
        reason: 'Le constructeur doit accepter navStudentIds.',
      );
      expect(
        src,
        contains('context.replace('),
        reason: 'La navigation doit utiliser context.replace (pas '
            "d'empilement d'historique à chaque élève).",
      );
      expect(
        src,
        contains('extra: ids,'),
        reason: 'La liste filtrée doit être re-transmise lors de la '
            'navigation (sinon Précédent/Suivant se casse après 1 saut).',
      );
    });

    test('la liste transmet les IDs FILTRÉS ordonnés (extra)', () {
      final src = readFile('lib/features/students/students_list_page.dart');
      expect(
        src,
        contains('students.map((s) => s.id).toList(growable: false)'),
        reason: 'Les IDs transmis doivent suivre l\'ordre de la liste '
            'AFFICHÉE (déjà filtrée par studentsListProvider).',
      );
      expect(
        src,
        contains('extra: navStudentIds'),
        reason: 'Le tap doit transmettre la liste via go_router extra.',
      );
    });

    test('la route /students/:id lit extra (List<int>)', () {
      final src = readFile('lib/app.dart');
      expect(
        src,
        contains('state.extra is List<int>'),
        reason: 'La route doit lire la liste d\'IDs depuis state.extra '
            '(tolérante aux autres entrées : dashboard, etc.).',
      );
    });

    test('le compteur et les bornes utilisent la liste filtrée', () {
      final src = readFile('lib/features/students/student_detail_page.dart');
      expect(
        src,
        contains('indexOf(id) + 1'),
        reason: 'L\'AppBar affiche la position (3 / 25) dans la liste '
            'filtrée.',
      );
      expect(
        src,
        contains('target >= 0 && target < ids.length'),
        reason: 'Précédent/Suivant doivent être désactivés aux extrémités.',
      );
    });
  });

  group('[Fix-PHOTO-VIEWER] visionneuse plein écran', () {
    test('la page viewer existe et zoome (InteractiveViewer)', () {
      final src =
          readFile('lib/features/students/student_photo_viewer_page.dart');
      expect(
        src,
        contains('class StudentPhotoViewerPage'),
        reason: 'La page de visionneuse doit exister.',
      );
      expect(
        src,
        contains('InteractiveViewer'),
        reason: 'Le zoom pincé passe par InteractiveViewer.',
      );
      expect(
        src,
        contains('providerFor(studentId)'),
        reason: 'La visionneuse réutilise le cache photo existant '
            '(hors-ligne OK).',
      );
    });

    test("toucher la photo du détail ouvre la visionneuse", () {
      final src = readFile('lib/features/students/student_detail_page.dart');
      expect(
        src,
        contains('onViewPhoto:'),
        reason: 'Le _HeaderCard doit exposer le tap sur la photo.',
      );
      expect(
        src,
        contains('/photo?name='),
        reason: 'Le tap pousse la route de la visionneuse (avec le nom).',
      );
    });

    test('la route /students/:id/photo est déclarée', () {
      final src = readFile('lib/app.dart');
      expect(
        src,
        contains("path: '/students/:id/photo'"),
        reason: 'La route de la visionneuse doit être routée.',
      );
    });
  });
}
