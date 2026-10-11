/// Photos des élèves : téléchargement via l'endpoint dédié
/// `GET /api/v1/students/{id}/photo` (octets bruts, auth JWT + X-Device-Token
/// via [dioProvider]), cache disque isolé par serveur et fallback initiales.
///
/// ⚠️ Le champ `photo_path` de `StudentResponse` n'est PAS une URL : c'est un
/// chemin de fichier côté serveur. Il ne faut donc JAMAIS l'utiliser avec
/// `Image.network` — on passe toujours par l'endpoint dédié via Dio (bytes).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exceptions.dart';
import '../../core/network/dio_client.dart';
import '../connections/connection_state.dart';

/// Cache des photos d'élèves (une instance par serveur actif / session).
///
/// [Fix-PHOTO-BURST] Une liste d'élèves déclenche autant de téléchargements
/// simultanés — la rafale sature le serveur et les requêtes en surnombre
/// échouaient, puis étaient mémorisées À JAMAIS comme « sans photo » : seul
/// le premier élève gardait sa miniature. Désormais :
/// - les téléchargements passent par une file à concurrence limitée
///   ([maxConcurrentDownloads]) ;
/// - seul un 404 franc (« aucune photo ») mémorise l'absence de façon
///   permanente ;
/// - les erreurs réseau/serveur (timeout, 5xx, connexion) sont réessayables
///   après un court délai ([_transientRetryAfter]).
class StudentPhotoCache {
  StudentPhotoCache({required Dio dio, required this.serverUrl})
      : _dio = dio;

  /// URL du serveur actif (avec `/api/v1`) — sert à isoler le cache disque
  /// par serveur (les ids d'élèves ne sont pas globaux).
  final String? serverUrl;

  final Dio _dio;

  /// Téléchargements simultanés maximum (évite la rafale qui saturait le
  /// serveur à l'ouverture d'une liste de plusieurs dizaines d'élèves).
  static const int maxConcurrentDownloads = 3;

  /// Délai avant de retenter un élève dont le téléchargement a échoué pour
  /// une raison transitoire (réseau, serveur momentanément saturé).
  static const Duration _transientRetryAfter = Duration(seconds: 20);

  /// Futures en cours / résolues par élève (déduplique les téléchargements :
  /// liste + détail d'un même élève partagent une seule requête).
  final Map<int, Future<ImageProvider?>> _inFlight = {};

  /// Mémo négatif PERMANENT : élèves sans photo (404 explicite du serveur).
  final Set<int> _knownMissing = {};

  /// Mémo négatif TEMPORAIRE (échecs transitoires, réessayables) :
  /// élève → instant du dernier échec.
  final Map<int, DateTime> _transientFailures = {};

  /// File de téléchargement : au plus [maxConcurrentDownloads] en vol, le
  /// reste attend dans [_queue].
  final Queue<void Function()> _queue = Queue<void Function()>();
  int _activeDownloads = 0;

  void _enqueue(void Function() task) {
    _queue.add(task);
    _drainQueue();
  }

  void _drainQueue() {
    while (_activeDownloads < maxConcurrentDownloads && _queue.isNotEmpty) {
      final task = _queue.removeFirst();
      _activeDownloads++;
      task();
    }
  }

  void _downloadDone() {
    _activeDownloads--;
    _drainQueue();
  }

  /// Retourne l'image de profil d'un élève (cache disque → réseau), ou `null`
  /// si aucune photo n'est disponible (l'appelant affiche les initiales).
  Future<ImageProvider?> providerFor(int studentId) {
    if (_knownMissing.contains(studentId)) {
      return Future<ImageProvider?>.value(null);
    }
    final lastTransient = _transientFailures[studentId];
    if (lastTransient != null) {
      if (DateTime.now().isBefore(lastTransient.add(_transientRetryAfter))) {
        return Future<ImageProvider?>.value(null);
      }
      _transientFailures.remove(studentId);
    }
    return _inFlight.putIfAbsent(studentId, () => _resolve(studentId));
  }

  Future<ImageProvider?> _resolve(int studentId) async {
    // [Fix-PHOTO-BURST] La partie réseau passe par la file à concurrence
    // limitée ; le cache disque, lui, est consulté immédiatement.
    try {
      // 1. Cache disque : image déjà téléchargée pour CE serveur.
      final cached = await _cachedFile(studentId);
      if (cached != null) return FileImage(cached);

      if (serverUrl == null) {
        _knownMissing.add(studentId);
        return null;
      }

      // 2. Endpoint dédié : octets bruts (auth injectée par dioProvider),
      //    à travers la file (concurrence limitée).
      final bytes = await _downloadQueued(studentId);
      if (bytes == null || bytes.isEmpty) {
        // Échec transitoire → on oublie le future résolu pour qu'un nouvel
        // appel (après le délai de réessai) relance le téléchargement.
        if (_transientFailures.containsKey(studentId)) {
          _inFlight.remove(studentId);
        }
        return null; // Le statut a déjà été mémorisé par _downloadQueued.
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
      // Erreur inattendue → traitée comme transitoire (réessayable).
      _markTransient(studentId);
      _inFlight.remove(studentId);
      return null;
    }
  }

  /// Télécharge les octets de la photo en passant par la file. Retourne
  /// `null` et mémorise l'absence (permanente sur 404, temporaire sinon).
  Future<Uint8List?> _downloadQueued(int studentId) {
    final completer = Completer<Uint8List?>();
    _enqueue(() async {
      try {
        final url = buildUrl(serverUrl!, '/students/$studentId/photo');
        final response = await _dio.get<List<int>>(
          url,
          options: Options(responseType: ResponseType.bytes),
        );
        final bytes = response.data;
        if (bytes == null || bytes.isEmpty) {
          // Réponse vide considérée comme « sans photo » (permanente).
          _knownMissing.add(studentId);
          completer.complete(null);
          return;
        }
        completer.complete(Uint8List.fromList(bytes));
      } on DioException catch (e) {
        final api = (e.error is ApiException)
            ? e.error as ApiException
            : dioErrorToApiException(e);
        if (api.statusCode == 404) {
          // 404 explicite : l'élève n'a VRAIMENT pas de photo → permanent.
          _knownMissing.add(studentId);
          completer.complete(null);
        } else {
          // Réseau/serveur transitoire (timeout, 5xx, 403…) → réessayable.
          _markTransient(studentId);
          completer.complete(null);
        }
      } catch (_) {
        _markTransient(studentId);
        completer.complete(null);
      } finally {
        _downloadDone();
      }
    });
    return completer.future;
  }

  void _markTransient(int studentId) {
    _transientFailures[studentId] = DateTime.now();
  }

  /// [Fix-PHOTO-RETRY] Purge les mémos négatifs (« sans photo » et échecs
  /// transitoires) ainsi que les futures résolus : le prochain accès
  /// relance le téléchargement. Appelé par le pull-to-refresh des listes
  /// — après un correctif serveur (chemin de photo réparé), les miniatures
  /// reviennent sans redémarrer l'application.
  void resetMemos() {
    _knownMissing.clear();
    _transientFailures.clear();
    _inFlight.clear();
  }

  /// [Fix-PHOTO-DECODE] Supprime le fichier cache d'un élève dont les
  /// octets ne se décodent pas (réponse non-image cachée par erreur, fichier
  /// tronqué…) — sinon l'avatar resterait sur les initiales à chaque
  /// session tant que le fichier invalide traîne sur le disque.
  Future<void> deleteCached(int studentId) async {
    try {
      final file = await _targetFile(studentId);
      if (await file.exists()) await file.delete();
    } catch (_) {}
    _knownMissing.remove(studentId);
    _transientFailures.remove(studentId);
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

/// [Fix-PHOTO-RETRY] Époque du cache photo : incrémentée par
/// [StudentPhotoCache.resetMemos] via le provider — chaque incrément crée
/// une NOUVELLE instance de cache (les avatars se relient et les photos
/// échouées sont retéléchargées).
final _photoCacheEpochProvider = StateProvider<int>((ref) => 0);

/// Provider du cache de photos. Il ne surveille QUE l'URL du serveur actif
/// (pas le statut heartbeat qui change toutes les 30 s) : le cache — et donc
/// le mémo négatif — est réinitialisé uniquement quand on change de serveur
/// ou qu'on purge les mémos (pull-to-refresh).
final studentPhotoCacheProvider = Provider<StudentPhotoCache>((ref) {
  final dio = ref.watch(dioProvider);
  final serverUrl = ref.watch(connectionProvider.select((c) => c.serverUrl));
  // L'époque force une nouvelle instance quand les mémos sont purgés.
  ref.watch(_photoCacheEpochProvider);
  return StudentPhotoCache(dio: dio, serverUrl: serverUrl);
});

/// [Fix-PHOTO-RETRY] Purge les mémos négatifs ET force une nouvelle
/// instance de cache (incrément d'époque) : tous les avatars se relient et
/// retéléchargent leur photo. À appeler sur le pull-to-refresh des listes
/// d'élèves (après réparation serveur, les miniatures reviennent sans
/// redémarrer l'application).
///
/// [ref] accepte aussi bien un `Ref` (provider) qu'un `WidgetRef` (page) —
/// les deux exposent `read`, sans supertype commun en Riverpod 2.x.
void resetStudentPhotoCache(dynamic ref) {
  (ref as dynamic).read(studentPhotoCacheProvider).resetMemos();
  (ref as dynamic).read(_photoCacheEpochProvider.notifier).state++;
}

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

  /// [Fix-PHOTO-DECODE] Purge le fichier cache invalide au premier échec
  /// de décodage : le prochain refresh re-téléchargera des octets propres.
  void _onDecodeError() {
    setState(() => _decodeFailed = true);
    _cacheUsed?.deleteCached(widget.studentId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Suit un changement de serveur OU une purge des mémos
    // ([Fix-PHOTO-RETRY] nouvelle instance de cache → re-téléchargement).
    final cache = ref.watch(studentPhotoCacheProvider);
    if (!identical(cache, _cacheUsed)) {
      _bind(cache);
    } else if (_future == null) {
      // Cas défensif (rebuild après dispose du future) — rebind.
      _bind(cache);
    }

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
          onForegroundImageError: hasImage ? (_, __) => _onDecodeError() : null,
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
