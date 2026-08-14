/// Page "Importer des élèves" : téléchargement du modèle Excel + import
/// multipart d'un fichier rempli.
///
/// RBAC : `STUDENT_CREATE` requis (bouton d'entrée depuis la liste Élèves).
/// Hors-ligne : import désactivé (banner "Import nécessite une connexion
/// serveur").
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_state.dart';
import '../../core/config/constants.dart';
import '../../core/utils/permissions.dart';
import '../../features/connections/connection_state.dart';
import '../../shared/widgets/widgets.dart';
import 'student_controller.dart';
import 'student_import_export_controller.dart';

class StudentImportPage extends ConsumerStatefulWidget {
  const StudentImportPage({super.key});

  @override
  ConsumerState<StudentImportPage> createState() => _StudentImportPageState();
}

class _StudentImportPageState extends ConsumerState<StudentImportPage> {
  // --- Modèle (download) ---
  bool _isDownloadingTemplate = false;
  int? _templateTotal;
  int? _templateReceived;
  String? _templatePath;
  String? _templateError;

  // --- Import (upload) ---
  File? _selectedFile;
  int? _fileSizeBytes;
  bool _isImporting = false;
  int? _importTotal;
  int? _importSent;
  ImportResult? _importResult;
  String? _importError;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final canCreate = hasPermission(auth.permissions, RbacPermissions.studentCreate);
    final conn = ref.watch(connectionProvider);
    final online = conn.canReachServer;

    return Scaffold(
      appBar: AppBar(title: const Text('Importer des élèves')),
      body: !canCreate
          ? const EmptyState(
              icon: Icons.lock_outline,
              title: 'Accès refusé',
              message:
                  'Vous n\'avez pas la permission de créer des élèves (STUDENT_CREATE).',
            )
          : CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: _OfflineBanner(online: online)),
                SliverToBoxAdapter(
                  child: _TemplateSection(
                    isDownloading: _isDownloadingTemplate,
                    received: _templateReceived,
                    total: _templateTotal,
                    path: _templatePath,
                    error: _templateError,
                    online: online,
                    onDownload: _downloadTemplate,
                    onCopyPath: _copyTemplatePath,
                  ),
                ),
                SliverToBoxAdapter(
                  child: _ImportSection(
                    file: _selectedFile,
                    fileSizeBytes: _fileSizeBytes,
                    isImporting: _isImporting,
                    sent: _importSent,
                    total: _importTotal,
                    result: _importResult,
                    error: _importError,
                    online: online,
                    onPickFile: _pickFile,
                    onImport: _runImport,
                    onReset: _resetImport,
                    onCopyErrors: _copyErrors,
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 32)),
              ],
            ),
    );
  }

  // -------------------------------------------------------------------------
  // Modèle — download
  // -------------------------------------------------------------------------

  Future<void> _downloadTemplate() async {
    setState(() {
      _isDownloadingTemplate = true;
      _templateError = null;
      _templatePath = null;
      _templateReceived = null;
      _templateTotal = null;
    });
    try {
      final controller =
          ref.read(studentImportExportProvider);
      final path = await controller.downloadTemplate(
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _templateReceived = received;
            _templateTotal = total == -1 ? null : total;
          });
        },
      );
      setState(() {
        _templatePath = path;
        _isDownloadingTemplate = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Modèle téléchargé avec succès.')),
        );
      }
    } catch (e) {
      setState(() {
        _templateError = e.toString();
        _isDownloadingTemplate = false;
      });
    }
  }

  Future<void> _copyTemplatePath() async {
    if (_templatePath == null) return;
    await Clipboard.setData(ClipboardData(text: _templatePath!));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Chemin du fichier copié.')),
    );
  }

  // -------------------------------------------------------------------------
  // Import — pick + upload
  // -------------------------------------------------------------------------

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'xls', 'csv'],
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.single;
      final path = picked.path;
      if (path == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Impossible de récupérer le fichier.')),
        );
        return;
      }
      setState(() {
        _selectedFile = File(path);
        _fileSizeBytes = picked.size;
        _importResult = null;
        _importError = null;
      });
    } on PlatformException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sélection impossible : ${e.message ?? e.code}')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sélection impossible : $e')),
      );
    }
  }

  Future<void> _runImport() async {
    final file = _selectedFile;
    if (file == null) return;
    setState(() {
      _isImporting = true;
      _importError = null;
      _importResult = null;
      _importSent = null;
      _importTotal = null;
    });
    try {
      final controller = ref.read(studentImportExportProvider);
      final result = await controller.importStudents(
        file,
        onProgress: (sent, total) {
          if (!mounted) return;
          setState(() {
            _importSent = sent;
            _importTotal = total == -1 ? null : total;
          });
        },
      );
      setState(() {
        _importResult = result;
        _isImporting = false;
      });
      // Invalide la liste des élèves (les imports ajoutent généralement des
      // lignes). `studentsListProvider` est un family autoDispose — l'appel
      // `ref.invalidate` sans argument invalide toutes les instances cachées
      // et force le re-fetch au prochain `watch` (retour sur la liste).
      ref.invalidate(studentsListProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.hasErrors
                  ? 'Import terminé avec ${result.errorCount} erreur(s).'
                  : 'Import terminé : ${result.successCount} élève(s) importé(s).',
            ),
          ),
        );
      }
    } catch (e) {
      setState(() {
        _importError = e.toString();
        _isImporting = false;
      });
    }
  }

  void _resetImport() {
    setState(() {
      _selectedFile = null;
      _fileSizeBytes = null;
      _importResult = null;
      _importError = null;
      _importSent = null;
      _importTotal = null;
    });
  }

  Future<void> _copyErrors() async {
    final res = _importResult;
    if (res == null || res.errors.isEmpty) return;
    final text = StringBuffer()
      ..writeln('Erreurs d\'import GeTech-SMS — ${res.errorCount} au total')
      ..writeln();
    for (final e in res.errors) {
      text.writeln('- $e');
    }
    await Clipboard.setData(ClipboardData(text: text.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Erreurs copiées dans le presse-papier.')),
    );
  }
}

// ---------------------------------------------------------------------------
// Bannière hors-ligne
// ---------------------------------------------------------------------------

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.online});
  final bool online;

  @override
  Widget build(BuildContext context) {
    if (online) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.cloud_off,
                size: 20, color: theme.colorScheme.onErrorContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Import nécessite une connexion serveur.',
                style: TextStyle(
                  color: theme.colorScheme.onErrorContainer,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section 1 — Modèle
// ---------------------------------------------------------------------------

class _TemplateSection extends StatelessWidget {
  const _TemplateSection({
    required this.isDownloading,
    required this.received,
    required this.total,
    required this.path,
    required this.error,
    required this.online,
    required this.onDownload,
    required this.onCopyPath,
  });

  final bool isDownloading;
  final int? received;
  final int? total;
  final String? path;
  final String? error;
  final bool online;
  final VoidCallback onDownload;
  final VoidCallback onCopyPath;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader(
            title: 'Modèle',
            subtitle: 'Téléchargez le modèle Excel, remplissez-le, puis importez-le.',
            icon: Icons.download_outlined,
          ),
          Card(
            margin: const EdgeInsets.symmetric(vertical: 8),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(Icons.table_view_outlined,
                            color: theme.colorScheme.primary, size: 24),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Modèle Excel (.xlsx)',
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'En-têtes pré-remplies avec les colonnes attendues.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (isDownloading) ...[
                    const SizedBox(height: 16),
                    _ProgressBar(
                      received: received,
                      total: total,
                      label: 'Téléchargement…',
                    ),
                  ],
                  if (path != null) ...[
                    const SizedBox(height: 16),
                    _FileSavedCard(
                      path: path!,
                      onCopy: onCopyPath,
                    ),
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    AppErrorWidget(message: error!, compact: true),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: (online && !isDownloading) ? onDownload : null,
                    icon: const Icon(Icons.download),
                    label: const Text('Télécharger le modèle'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section 2 — Import
// ---------------------------------------------------------------------------

class _ImportSection extends StatelessWidget {
  const _ImportSection({
    required this.file,
    required this.fileSizeBytes,
    required this.isImporting,
    required this.sent,
    required this.total,
    required this.result,
    required this.error,
    required this.online,
    required this.onPickFile,
    required this.onImport,
    required this.onReset,
    required this.onCopyErrors,
  });

  final File? file;
  final int? fileSizeBytes;
  final bool isImporting;
  final int? sent;
  final int? total;
  final ImportResult? result;
  final String? error;
  final bool online;
  final VoidCallback onPickFile;
  final VoidCallback onImport;
  final VoidCallback onReset;
  final VoidCallback onCopyErrors;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader(
            title: 'Importer',
            subtitle: 'Sélectionnez un fichier Excel ou CSV rempli.',
            icon: Icons.upload_outlined,
          ),
          Card(
            margin: const EdgeInsets.symmetric(vertical: 8),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Drop zone / pick.
                  InkWell(
                    onTap: (online && !isImporting) ? onPickFile : null,
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          vertical: 20, horizontal: 16),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: theme.colorScheme.outline.withValues(alpha: 0.5),
                        ),
                        borderRadius: BorderRadius.circular(12),
                        color: theme.colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.4),
                      ),
                      child: Column(
                        children: [
                          Icon(
                            file != null
                                ? Icons.description_outlined
                                : Icons.upload_file,
                            size: 36,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            file != null
                                ? _basename(file!.path)
                                : 'Choisir un fichier',
                            style: theme.textTheme.titleSmall,
                            textAlign: TextAlign.center,
                          ),
                          if (file != null && fileSizeBytes != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              _formatBytes(fileSizeBytes!),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                          const SizedBox(height: 4),
                          Text(
                            'Formats acceptés : .xlsx, .xls, .csv',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (file != null) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: (online && !isImporting) ? onPickFile : null,
                          icon: const Icon(Icons.swap_horiz, size: 18),
                          label: const Text('Changer'),
                        ),
                        TextButton.icon(
                          onPressed: onReset,
                          icon: const Icon(Icons.clear, size: 18),
                          label: const Text('Retirer'),
                        ),
                      ],
                    ),
                  ],
                  if (isImporting) ...[
                    const SizedBox(height: 16),
                    _ProgressBar(
                      received: sent,
                      total: total,
                      label: 'Envoi du fichier…',
                    ),
                  ],
                  if (result != null) ...[
                    const SizedBox(height: 16),
                    _ImportResultCard(result: result!, onCopyErrors: onCopyErrors),
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    AppErrorWidget(message: error!, compact: true),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: (online && file != null && !isImporting)
                        ? onImport
                        : null,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Lancer l\'import'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Résultat Import
// ---------------------------------------------------------------------------

class _ImportResultCard extends StatelessWidget {
  const _ImportResultCard({required this.result, required this.onCopyErrors});
  final ImportResult result;
  final VoidCallback onCopyErrors;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasErrors = result.hasErrors;
    final color = hasErrors
        ? (result.successCount > 0 ? Colors.orange : theme.colorScheme.error)
        : theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(hasErrors ? Icons.warning_amber : Icons.check_circle,
                  color: color, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${result.successCount} élève(s) importé(s) · ${result.errorCount} erreur(s)',
                  style: theme.textTheme.titleSmall?.copyWith(color: color),
                ),
              ),
            ],
          ),
          if (hasErrors) ...[
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Détail des erreurs',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                TextButton.icon(
                  onPressed: onCopyErrors,
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copier'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: result.errors.length,
                separatorBuilder: (_, __) => Divider(
                  height: 1,
                  color: theme.dividerColor.withValues(alpha: 0.4),
                ),
                itemBuilder: (context, i) {
                  final e = result.errors[i];
                  return ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 12,
                      backgroundColor: color.withValues(alpha: 0.15),
                      child: Text(
                        '${i + 1}',
                        style: TextStyle(
                          color: color,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    title: Text(
                      e.toString(),
                      style: theme.textTheme.bodySmall,
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Widgets utilitaires
// ---------------------------------------------------------------------------

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({
    required this.received,
    required this.total,
    required this.label,
  });

  final int? received;
  final int? total;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasTotal = total != null && total! > 0;
    final progress = hasTotal ? (received ?? 0) / total! : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: theme.textTheme.bodySmall),
            Text(
              hasTotal
                  ? '${_formatBytes(received ?? 0)} / ${_formatBytes(total!)}'
                  : (received != null ? _formatBytes(received!) : '…'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        LinearProgressIndicator(
          value: progress,
          minHeight: 8,
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
        ),
      ],
    );
  }
}

class _FileSavedCard extends StatelessWidget {
  const _FileSavedCard({required this.path, required this.onCopy});
  final String path;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle, color: theme.colorScheme.primary, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Fichier enregistré',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  path,
                  style: theme.textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            tooltip: 'Copier le chemin',
            onPressed: onCopy,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers formatage
// ---------------------------------------------------------------------------

String _basename(String path) {
  final i = path.lastIndexOf(Platform.pathSeparator);
  return i == -1 ? path : path.substring(i + 1);
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes o';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} Ko';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} Mo';
}
