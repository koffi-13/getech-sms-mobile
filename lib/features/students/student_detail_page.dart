/// Fichier "Détail élève" : fiche complète (identité, contact, médical, scolarité,
/// parents, tuteurs) + actions contextuelles (modifier / bulletin / absences)
/// + édition de la photo (galerie/caméra → upload multipart).
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/auth/auth_state.dart';
import '../../core/config/constants.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/dio_client.dart';
import '../../core/sync/outbox.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/permissions.dart';
import '../../shared/models/student_dto.dart';
import '../../shared/widgets/widgets.dart';
import '../connections/connection_state.dart';
import 'student_controller.dart';
import 'student_photos.dart';

class StudentDetailPage extends ConsumerWidget {
  const StudentDetailPage({super.key, required this.id});

  final int id;

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(studentDetailProvider(id));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final perms = auth.permissions;
    final canEdit = hasPermission(perms, RbacPermissions.studentCreate);
    final canGrades = hasPermission(perms, RbacPermissions.gradeRead);

    final async = ref.watch(studentDetailProvider(id));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Élève'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Rafraîchir',
            onPressed: () => _refresh(ref),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              switch (value) {
                case 'edit':
                  context.push('/students/$id/edit');
                  break;
                case 'bulletin':
                  context.push('/grades/bulletin/$id');
                  break;
                case 'absences':
                  context.push('/attendance/history?student_id=$id');
                  break;
              }
            },
            itemBuilder: (_) => [
              if (canEdit)
                const PopupMenuItem(
                  value: 'edit',
                  child: ListTile(
                    leading: Icon(Icons.edit_outlined),
                    title: Text('Modifier'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                ),
              if (canGrades)
                const PopupMenuItem(
                  value: 'bulletin',
                  child: ListTile(
                    leading: Icon(Icons.receipt_long_outlined),
                    title: Text('Bulletin'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                ),
              const PopupMenuItem(
                value: 'absences',
                child: ListTile(
                  leading: Icon(Icons.fact_check_outlined),
                  title: Text('Historique absences'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
            ],
          ),
        ],
      ),
      body: async.when(
        data: (s) => _DetailBody(student: s, onRefresh: () => _refresh(ref)),        loading: () => const AppLoading(label: 'Chargement de l\'élève…'),
        error: (e, _) => AppErrorWidget(
          message: e.toString(),
          onRetry: () => _refresh(ref),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Corps de la page
// ---------------------------------------------------------------------------

/// [Fix-PHOTO-EDIT] ConsumerStatefulWidget : l'édition de photo a besoin de
/// `ref` (connectionProvider, dioProvider) et de `mounted` après les awaits.
class _DetailBody extends ConsumerStatefulWidget {
  const _DetailBody({required this.student, required this.onRefresh});
  final StudentDto student;
  final Future<void> Function() onRefresh;

  @override
  ConsumerState<_DetailBody> createState() => _DetailBodyState();
}

class _DetailBodyState extends ConsumerState<_DetailBody> {
  StudentDto get student => widget.student;

  /// Modifier la photo de l'élève : galerie ou caméra (image_picker).
  ///
  /// [Fix-PHOTO-OFFLINE] La capture fonctionne désormais HORS LIGNE :
  /// 1. les octets sont lus et écrits dans le cache disque local
  ///    (affichage immédiat via StudentPhotoCache.saveLocal) ;
  /// 2. si le serveur est joignable : upload multipart immédiat vers
  ///    POST /students/{id}/photo (5 Mo max) ;
  /// 3. sinon : mise en file outbox (table `student_photo`, octets en
  ///    base64 dans le payload) — le sync engine la rejouera à la
  ///    reconnexion (cf. _pushStudentPhoto).
  /// Avant : hors connexion la prise de photo était REFUSÉE (« impossible
  /// hors connexion ») et rien n'était conservé.
  Future<void> _changePhoto() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: const Text('Choisir dans la galerie'),
            onTap: () => Navigator.pop(ctx, ImageSource.gallery),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera),
            title: const Text('Prendre une photo'),
            onTap: () => Navigator.pop(ctx, ImageSource.camera),
          ),
        ]),
      ),
    );
    if (source == null || !mounted) return;

    final picker = ImagePicker();
    final xfile = await picker.pickImage(
      source: source,
      maxWidth: 1024,
      imageQuality: 80,
    );
    if (xfile == null || !mounted) return;

    final bytes = await File(xfile.path).readAsBytes();
    if (bytes.isEmpty) return;
    final nameParts = xfile.name.split('.');
    final ext = nameParts.length > 1
        ? nameParts.last.toLowerCase()
        : 'jpg';

    // 1. Affichage local immédiat — y compris hors ligne.
    final cache = ref.read(studentPhotoCacheProvider);
    await cache.saveLocal(student.id, bytes);
    resetStudentPhotoCache(ref);

    final conn = ref.read(connectionProvider);
    if (conn.canReachServer && conn.serverUrl != null) {
      // 2. Upload immédiat.
      final dio = ref.read(dioProvider);
      try {
        final form = FormData.fromMap({
          'file': MultipartFile.fromBytes(
            bytes,
            filename: xfile.name,
          ),
        });
        await dio.post(
          buildUrl(conn.serverUrl!, '/students/${student.id}/photo'),
          data: form,
        );
        // Succès : purge le cache disque + les mémos négatifs (nouvelle
        // instance de cache → l'avatar se re-télécharge immédiatement).
        await cache.deleteCached(student.id);
        resetStudentPhotoCache(ref);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Photo mise à jour.')),
        );
      } catch (e) {
        // Échec en ligne → file d'attente (réessai auto à la synchro).
        await _queuePhotoUpload(bytes, ext);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Photo enregistrée — envoi au serveur en attente '
              '(${e.toString()}).',
            ),
          ),
        );
      }
    } else {
      // 3. Hors ligne → file d'attente outbox.
      await _queuePhotoUpload(bytes, ext);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Photo enregistrée hors ligne — elle sera envoyée au serveur '
            'à la reconnexion.',
          ),
        ),
      );
    }
  }

  /// [Fix-PHOTO-OFFLINE] Met la photo en file d'attente (outbox, table
  /// `student_photo`) pour rejeu à la prochaine synchro.
  Future<void> _queuePhotoUpload(List<int> bytes, String ext) async {
    try {
      await ref.read(outboxProvider).enqueue(
            table: 'student_photo',
            operation: 'POST',
            recordId: student.id,
            payload: {
              'student_id': student.id,
              'photo_base64': base64Encode(bytes),
              'extension': ext,
            },
          );
    } catch (e) {
      // Échec de la mise en file : la photo reste affichée localement
      // (cache disque déjà écrit) ; elle sera re-poussée si l'utilisateur
      // relance la modification.
      debugPrint('Photo hors-ligne non mise en file : $e');
    }
  }


  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _HeaderCard(student: student, onEditPhoto: _changePhoto),
          const SizedBox(height: 12),
          _IdentiteCard(student: student),
          const SizedBox(height: 12),
          _ContactCard(student: student),
          const SizedBox(height: 12),
          _MedicalCard(student: student),
          const SizedBox(height: 12),
          _ScolariteCard(student: student),
          const SizedBox(height: 12),
          _ParentsCard(student: student),
          const SizedBox(height: 12),
          _TuteursCard(student: student),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Carte d'en-tête (photo / identité / badges)
// ---------------------------------------------------------------------------

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.student, required this.onEditPhoto});
  final StudentDto student;
  final Future<void> Function() onEditPhoto;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = student.sexe == Sexe.feminin
        ? Colors.pink.shade300
        : (student.sexe == Sexe.masculin ? Colors.blue.shade300 : Colors.teal);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Photo via l'endpoint dédié GET /students/{id}/photo (cache
            // disque, fallback initiales) — `photo_path` n'est PAS une URL.
            // [Fix-PHOTO-EDIT] bouton galerie/caméra sur l'avatar.
            Stack(
              children: [
                StudentAvatar(
                  studentId: student.id,
                  initials: student.displayInitials,
                  radius: 44,
                ),
                // [Fix-PHOTO-BUTTON] Avant : FloatingActionButton.small (40px)
                // posé à cheval sur un avatar de 88px — il couvrait une
                // grande partie de la photo. Petit bouton compact (28px)
                // en bas-droite, lisible et discret.
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: IconButton.filledTonal(
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      onPressed: onEditPhoto,
                      tooltip: 'Modifier la photo',
                      style: IconButton.styleFrom(
                        shape: const CircleBorder(),
                      ),
                      icon: const Icon(Icons.photo_camera),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              student.fullName,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'Matricule : ${student.matricule}',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (student.sexe != null)
                  _Badge(
                    label: student.sexe!.label,
                    color: color,
                    icon: student.sexe == Sexe.feminin
                        ? Icons.female
                        : Icons.male,
                  ),
                if (student.classroomName != null)
                  _Badge(
                    label: student.classroomName!,
                    color: theme.colorScheme.primary,
                    icon: Icons.school_outlined,
                  ),
                if (student.status != null)
                  _Badge(
                    label: student.status!.label,
                    color: student.status == StudentStatus.redoublant
                        ? Colors.orange
                        : Colors.green,
                    icon: Icons.label_outline,
                  ),
                if (student.inscriptionType != null)
                  _Badge(
                    label: student.inscriptionType!.label,
                    color: Colors.blueGrey,
                    icon: Icons.how_to_reg_outlined,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sections (Cartes)
// ---------------------------------------------------------------------------

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.children,
  });
  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(title, style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value, {this.icon});
  final String label;
  final String? value;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final display = (value == null || value!.isEmpty) ? '—' : value!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
          ] else
            const SizedBox(width: 24),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Text(
              display,
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class _IdentiteCard extends StatelessWidget {
  const _IdentiteCard({required this.student});
  final StudentDto student;

  @override
  Widget build(BuildContext context) {
    final birthParts = [
      student.birthPlace,
      student.birthPrefecture,
      student.birthRegion,
      student.birthCountry,
    ].where((s) => s != null && s.isNotEmpty).toList();

    return _SectionCard(
      title: 'Identité',
      icon: Icons.person_outline,
      children: [
        _InfoRow(
          'Date de naissance',
          DateFormatter.date(student.dob),
          icon: Icons.cake_outlined,
        ),
        _InfoRow(
          'Âge',
          student.age != null ? '${student.age} ans' : _computeAge(student.dob),
          icon: Icons.cake_outlined,
        ),
        if (birthParts.isNotEmpty)
          _InfoRow(
            'Lieu de naissance',
            birthParts.join(', '),
            icon: Icons.place_outlined,
          ),
        _InfoRow(
          'Groupe / Groupe sanguin',
          student.groupe,
          icon: Icons.group_outlined,
        ),
      ],
    );
  }

  /// Âge calculé localement si le serveur ne le renvoie pas.
  String? _computeAge(DateTime? dob) {
    if (dob == null) return null;
    final today = DateTime.now();
    var age = today.year - dob.year;
    final hadBirthday = today.month > dob.month ||
        (today.month == dob.month && today.day >= dob.day);
    if (!hadBirthday) age--;
    if (age < 0 || age > 130) return null;
    return '$age ans';
  }
}

class _ContactCard extends StatelessWidget {
  const _ContactCard({required this.student});
  final StudentDto student;

  @override
  Widget build(BuildContext context) {
    final c = student.contact;
    return _SectionCard(
      title: 'Contact',
      icon: Icons.contact_phone_outlined,
      children: [
        _InfoRow('Téléphone', c?.phone, icon: Icons.phone_outlined),
        _InfoRow('Email', c?.email, icon: Icons.email_outlined),
        _InfoRow('Adresse', c?.address, icon: Icons.home_outlined),
        _InfoRow('Ville', c?.city, icon: Icons.location_city_outlined),
      ],
    );
  }
}

class _MedicalCard extends StatelessWidget {
  const _MedicalCard({required this.student});
  final StudentDto student;

  String? get _bloodLabel {
    final b = student.medical?.bloodType;
    if (b == null) return null;
    // Labels conviviaux pour les groupes sanguins.
    const labels = {
      BloodType.aPlus: 'A+',
      BloodType.aMoins: 'A−',
      BloodType.bPlus: 'B+',
      BloodType.bMoins: 'B−',
      BloodType.abPlus: 'AB+',
      BloodType.abMoins: 'AB−',
      BloodType.oPlus: 'O+',
      BloodType.oMoins: 'O−',
      BloodType.inconnu: 'Inconnu',
    };
    return labels[b];
  }

  @override
  Widget build(BuildContext context) {
    final m = student.medical;
    return _SectionCard(
      title: 'Médical',
      icon: Icons.medical_services_outlined,
      children: [
        _InfoRow('Groupe sanguin', _bloodLabel, icon: Icons.bloodtype_outlined),
        _InfoRow('Allergies', m?.allergies, icon: Icons.warning_amber_outlined),
        _InfoRow('Médecin', m?.doctor, icon: Icons.local_hospital_outlined),
      ],
    );
  }
}

class _ScolariteCard extends StatelessWidget {
  const _ScolariteCard({required this.student});
  final StudentDto student;

  @override
  Widget build(BuildContext context) {
    final s = student.scholastic;
    return _SectionCard(
      title: 'Scolarité',
      icon: Icons.school_outlined,
      children: [
        _InfoRow(
          'Établissement précédent',
          s?.previousSchool,
          icon: Icons.history_edu_outlined,
        ),
        _InfoRow(
          'Transport',
          s?.transport,
          icon: Icons.directions_bus_outlined,
        ),
      ],
    );
  }
}

class _ParentsCard extends StatelessWidget {
  const _ParentsCard({required this.student});
  final StudentDto student;

  @override
  Widget build(BuildContext context) {
    if (student.parents.isEmpty) {
      return _SectionCard(
        title: 'Parents',
        icon: Icons.family_restroom_outlined,
        children: [
          Text(
            'Aucun parent enregistré.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      );
    }
    return _SectionCard(
      title: 'Parents',
      icon: Icons.family_restroom_outlined,
      children: student.parents
          .map(
            (p) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    p.role == 'MERE' ? Icons.female : Icons.male,
                    size: 18,
                    color: p.role == 'MERE'
                        ? Colors.pink.shade300
                        : Colors.blue.shade300,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p.role == 'MERE' ? 'Mère' : 'Père',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        Text(
                          p.fullName.isEmpty ? '—' : p.fullName,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        if (p.profession != null && p.profession!.isNotEmpty)
                          Text(
                            p.profession!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        if (p.phone != null && p.phone!.isNotEmpty)
                          Text(
                            p.phone!,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          )
          .toList(),
    );
  }
}

class _TuteursCard extends StatelessWidget {
  const _TuteursCard({required this.student});
  final StudentDto student;

  @override
  Widget build(BuildContext context) {
    if (student.guardians.isEmpty) {
      return _SectionCard(
        title: 'Tuteurs',
        icon: Icons.supervisor_account_outlined,
        children: [
          Text(
            'Aucun tuteur enregistré.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      );
    }
    return _SectionCard(
      title: 'Tuteurs',
      icon: Icons.supervisor_account_outlined,
      children: student.guardians
          .map(
            (g) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.person_outline, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          g.fullName.isEmpty ? '—' : g.fullName,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        if (g.relation != null && g.relation!.isNotEmpty)
                          Text(
                            g.relation!,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        if (g.phone != null && g.phone!.isNotEmpty)
                          Text(
                            g.phone!,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          )
          .toList(),
    );
  }
}

// ---------------------------------------------------------------------------
// Badge
// ---------------------------------------------------------------------------

class _Badge extends StatelessWidget {
  const _Badge({
    required this.label,
    required this.color,
    this.icon,
  });
  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
