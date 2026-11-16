/// Visionneuse plein écran de la photo d'un élève.
///
/// Ouverte au toucher de la photo sur la page de détail [StudentDetailPage].
/// Réutilise [StudentPhotoCache] (cache disque + endpoint dédié) : la photo
/// s'affiche même hors ligne si elle a déjà été consultée, et retombe sur
/// un message explicite si l'élève n'a pas de photo.
///
/// Fonctionnalités :
/// - zoom / déplacement à deux doigts ([InteractiveViewer]) ;
/// - fond noir immersif, fermeture au toucher ou bouton retour ;
/// - indicateur de chargement pendant la résolution du cache.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'student_photos.dart';

class StudentPhotoViewerPage extends ConsumerWidget {
  const StudentPhotoViewerPage({
    super.key,
    required this.studentId,
    required this.displayName,
  });

  final int studentId;

  /// Nom complet affiché en surimpression (barre du bas).
  final String displayName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cache = ref.watch(studentPhotoCacheProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Photo zoomable, centrée.
          Center(
            child: FutureBuilder<ImageProvider?>(
              future: cache.providerFor(studentId),
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const CircularProgressIndicator(color: Colors.white);
                }
                final provider = snapshot.data;
                if (provider == null) {
                  return const Padding(
                    padding: EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.person_off_outlined,
                          size: 56,
                          color: Colors.white54,
                        ),
                        SizedBox(height: 12),
                        Text(
                          'Aucune photo disponible pour cet élève.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  );
                }
                return InteractiveViewer(
                  maxScale: 5,
                  child: Image(
                    image: provider,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.broken_image_outlined,
                      size: 56,
                      color: Colors.white54,
                    ),
                  ),
                );
              },
            ),
          ),

          // Fermeture au toucher (zone photo vide).
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              behavior: HitTestBehavior.translucent,
            ),
          ),

          // Bouton fermer (haut gauche).
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                tooltip: 'Fermer',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ),

          // Nom de l'élève (bas d'écran).
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  displayName,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
