/// Photos des élèves : téléchargement via l'endpoint dédié
/// `GET /api/v1/students/{id}/photo` (octets bruts, auth JWT + X-Device-Token
/// via [dioProvider]), cache disque isolé par serveur et fallback initiales.
///
/// ⚠️ Le champ `photo_path` de `StudentResponse` n'est PAS une URL : c'est un
/// chemin de fichier côté serveur. Il ne faut donc JAMAIS l'utiliser avec
/// `Image.network` — on passe toujours par l'endpoint dédié via Dio (bytes).
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/network/api_endpoints.dart';
import '../../core/network/dio_client.dart';
import '../connections/connection_state.dart';

/// Cache des photos d'élèves (une instance par serveur actif / session).
class StudentPhotoCache {
  StudentPhotoCache({required Dio dio, required this.serverUrl})
      : _dio = dio;

  /// URL du serveur actif (avec `/api/v1`) — sert à isoler le cache disque
  /// par serveur (les ids d'élèves ne sont pas globaux).
  final String? serverUrl;

  final Dio _dio;

  /// Futures en cours / résolues par élève (déduplique les téléchargements :
  /// liste + détail d'un même élève partagent une seule requête).
  final Map<int, Future<ImageProvider?>> _inFlight = {};

  /// Mémo négatif en mémoire : élèves sans photo (404) ou en échec réseau —
  /// on ne retente PAS pendant la session.
  final Set<int> _knownMissing = {};

  /// Retourne l'image de profil d'un élève (cache disque → réseau), ou `null`
  /// si aucune photo n'est disponible (l'appelant affiche les initiales).
  Future<ImageProvider?> providerFor(int studentId) {
    if (_knownMissing.contains(studentId)) {
      return Future<ImageProvider?>.value(null);
    }
    return _inFlight.putIfAbsent(studentId, () => _resolve(studentId));
  }

  Future<ImageProvider?> _resolve(int studentId) async {
    try {
      // 1. Cache disque : image déjà téléchargée pour CE serveur.
      final cached = await _cachedFile(studentId);
      if (cached != null) return FileImage(cached);

      if (serverUrl == null) {
        _knownMissing.add(studentId);
        return null;
      }

      // 2. Endpoint dédié : octets bruts (auth injectée par dioProvider).
      final url = buildUrl(serverUrl!, '/students/$studentId/photo');
      final response = await _dio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) {
        _knownMissing.add(studentId);
        return null;
      }

      // 3. Persiste sur disque (offline-first) puis sert le fichier.
      try {
        final file = await _targetFile(studentId);
        await file.writeAsBytes(bytes, flush: true);
        return FileImage(file);
      } catch (_) {
        // Disque indisponible : sert l'image en mémoire plutôt que rien.
        return MemoryImage(Uint8List.fromList(bytes));
      }
    } catch (_) {
      // 404 (pas de photo), erreur réseau, stockage KO… → initiales.
      _knownMissing.add(studentId);
      return null;
    }
  }

  /// Fichier cache existant (non vide) pour cet élève sur CE serveur.
  Future<File?> _cachedFile(int studentId) async {
    try {
      final file = await _targetFile(studentId);
      if (await file.exists() && await file.length() > 0) return file;
    } catch (_) {
      // Stockage indisponible → on tentera le réseau.
    }
    return null;
  }

  /// `<documents>/photos/<hash(serverUrl)>_<studentId>.jpg`.
  Future<File> _targetFile(int studentId) async {
    final dir = await getApplicationDocumentsDirectory();
    final photosDir = Directory('${dir.path}/photos');
    await photosDir.create(recursive: true);
    final hash = serverUrl == null ? 0 : _stableHash(serverUrl!);
    return File('${photosDir.path}/${hash}_$studentId.jpg');
  }

  /// Hash stable (FNV-1a) pour isoler le cache par serveur sans dépendre du
  /// SDK (contrairement à `String.hashCode`, non garanti entre exécutions).
  static int _stableHash(String input) {
    var h = 0x811c9dc5;
    for (final unit in input.codeUnits) {
      h ^= unit;
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return h;
  }
}

/// Provider du cache de photos. Il ne surveille QUE l'URL du serveur actif
/// (pas le statut heartbeat qui change toutes les 30 s) : le cache — et donc
/// le mémo négatif — est réinitialisé uniquement quand on change de serveur.
final studentPhotoCacheProvider = Provider<StudentPhotoCache>((ref) {
  final dio = ref.watch(dioProvider);
  final serverUrl = ref.watch(connectionProvider.select((c) => c.serverUrl));
  return StudentPhotoCache(dio: dio, serverUrl: serverUrl);
});

/// Avatar élève autonome : photo en miniature si disponible (endpoint dédié +
/// cache disque), initiales en fallback (pas de photo, 404, réseau KO ou
/// décodage impossible).
class StudentAvatar extends ConsumerStatefulWidget {
  const StudentAvatar({
    super.key,
    required this.studentId,
    this.initials = '',
    this.radius = 20,
  });

  final int studentId;

  /// Initiales de repli (ex. `student.displayInitials`).
  final String initials;

  /// Rayon du cercle (20 pour une tuile de liste, 44 pour un en-tête).
  final double radius;

  @override
  ConsumerState<StudentAvatar> createState() => _StudentAvatarState();
}

class _StudentAvatarState extends ConsumerState<StudentAvatar> {
  StudentPhotoCache? _cacheUsed;
  Future<ImageProvider?>? _future;
  bool _decodeFailed = false;

  @override
  void initState() {
    super.initState();
    _bind(ref.read(studentPhotoCacheProvider));
  }

  @override
  void didUpdateWidget(covariant StudentAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.studentId != widget.studentId) {
      _bind(ref.read(studentPhotoCacheProvider));
    }
  }

  void _bind(StudentPhotoCache cache) {
    _cacheUsed = cache;
    _decodeFailed = false;
    _future = cache.providerFor(widget.studentId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Suit un changement de serveur (nouvelle instance de cache).
    final cache = ref.watch(studentPhotoCacheProvider);
    if (!identical(cache, _cacheUsed)) _bind(cache);

    return FutureBuilder<ImageProvider?>(
      future: _future,
      builder: (context, snapshot) {
        final provider = snapshot.data;
        final hasImage = provider != null && !_decodeFailed;
        return CircleAvatar(
          radius: widget.radius,
          backgroundColor: theme.colorScheme.primaryContainer,
          foregroundColor: theme.colorScheme.onPrimaryContainer,
          foregroundImage: hasImage ? provider : null,
          onForegroundImageError: hasImage
              ? (_, __) => setState(() => _decodeFailed = true)
              : null,
          // Initiales visibles uniquement sans photo — sinon elles se
          // superposeraient à l'image (le child est peint PAR-DESSUS).
          child: hasImage ? null : _initialsText(),
        );
      },
    );
  }

  Widget _initialsText() {
    return Text(
      widget.initials,
      style: TextStyle(
        fontSize: math.max(14.0, widget.radius * 0.55),
        fontWeight: FontWeight.w600,
      ),
    );
  }
}
