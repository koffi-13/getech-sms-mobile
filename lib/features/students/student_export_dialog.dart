/// Dialogue / bottom sheet "Exporter les élèves" : choix du format
/// (Excel/CSV), filtre classe optionnel, sélection multi-colonnes groupée,
/// puis appel à [StudentImportExportController.exportStudents].
///
/// RBAC : `STUDENT_READ` requis (l'export est en lecture seule).
///
/// Utilisation :
/// ```dart
/// showDialog(context: context, builder: (_) => const StudentExportDialog());
/// // ou
/// showModalBottomSheet(context: context, builder: (_) => const StudentExportDialog());
/// ```
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_state.dart';
import '../../core/config/constants.dart';
import '../../core/utils/permissions.dart';
import '../../features/connections/connection_state.dart';
import '../../shared/models/classroom_dto.dart';
import '../../shared/widgets/widgets.dart';
import '../classrooms/classroom_controller.dart';
import 'student_import_export_controller.dart';

class StudentExportDialog extends ConsumerStatefulWidget {
  const StudentExportDialog({super.key, this.classroomId});

  /// Pré-sélection éventuelle d'une classe (depuis la liste Élèves filtrée).
  final int? classroomId;

  @override
  ConsumerState<StudentExportDialog> createState() =>
      _StudentExportDialogState();
}

class _StudentExportDialogState extends ConsumerState<StudentExportDialog> {
  late String _format = 'xlsx';
  late int? _classroomId = widget.classroomId;
  late Set<String> _selectedColumns = Set<String>.from(StudentColumns.defaultKeys);
  bool _includePhotos = false;

  bool _isExporting = false;
  int? _exportReceived;
  int? _exportTotal;
  String? _exportedPath;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final canRead =
        hasPermission(auth.permissions, RbacPermissions.studentRead);
    final conn = ref.watch(connectionProvider);
    final online = conn.canReachServer;

    final mediaQuery = MediaQuery.of(context);
    final isBottomSheet = mediaQuery.size.height * 0.6 < 480;

    final body = !canRead
        ? const EmptyState(
            icon: Icons.lock_outline,
            title: 'Accès refusé',
            message: 'STUDENT_READ requis pour exporter.',
          )
        : SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                16 + mediaQuery.viewInsets.bottom,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Poignée pour bottom sheet (sans effet en dialog).
                  if (isBottomSheet) ...[
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Theme.of(context).dividerColor,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ],
                  _Header(online: online),
                  const SizedBox(height: 12),
                  _FormatSelector(
                    format: _format,
                    onChanged: (v) => setState(() => _format = v),
                  ),
                  const SizedBox(height: 12),
                  _ClassroomFilter(
                    classroomId: _classroomId,
                    onChanged: (id) =>
                        setState(() => _classroomId = id),
                  ),
                  const SizedBox(height: 12),
                  _ColumnsSelector(
                    selected: _selectedColumns,
                    onToggle: _toggleColumn,
                    onToggleGroup: _toggleGroup,
                    onSelectAll: () => setState(() => _selectedColumns =
                        Set<String>.from(StudentColumns.defaultKeys)),
                    onClearAll: () => setState(() => _selectedColumns = const {}),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    title: const Text('Inclure les photos'),
                    subtitle: const Text(
                      'Augmente la taille du fichier (base64 ou URL).',
                      style: TextStyle(fontSize: 12),
                    ),
                    value: _includePhotos,
                    onChanged: (v) =>
                        setState(() => _includePhotos = v),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    AppErrorWidget(message: _error!, compact: true),
                  ],
                  if (_exportedPath != null) ...[
                    const SizedBox(height: 12),
                    _ExportSuccessCard(
                      path: _exportedPath!,
                      format: _format,
                      onCopy: _copyPath,
                    ),
                  ],
                  const SizedBox(height: 12),
                  _Actions(
                    isExporting: _isExporting,
                    canExport: online &&
                        !_isExporting &&
                        _selectedColumns.isNotEmpty,
                    onExport: _runExport,
                    onCancel: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(height: 4),
                  if (isBottomSheet) const SizedBox(height: 8),
                ],
              ),
            ),
          );

    // Si on est invoqué via showDialog, on wrap dans un Dialog ; sinon
    // (showModalBottomSheet) on renvoie juste le Scaffold blanc.
    if (isBottomSheet) {
      return Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: SafeArea(child: body),
      );
    }
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
        child: body,
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  void _toggleColumn(String key) {
    setState(() {
      if (_selectedColumns.contains(key)) {
        _selectedColumns.remove(key);
      } else {
        _selectedColumns.add(key);
      }
    });
  }

  void _toggleGroup(StudentColumnGroup group, bool select) {
    setState(() {
      final keys = StudentColumns.all
          .where((c) => c.group == group)
          .map((c) => c.key)
          .toList();
      if (select) {
        _selectedColumns.addAll(keys);
      } else {
        _selectedColumns.removeAll(keys);
      }
    });
  }

  Future<void> _runExport() async {
    setState(() {
      _isExporting = true;
      _error = null;
      _exportedPath = null;
      _exportReceived = null;
      _exportTotal = null;
    });
    try {
      final controller = ref.read(studentImportExportProvider);
      // On préserve l'ordre du catalogue lors de l'envoi (le serveur l'utilise
      // pour ordonner les colonnes du fichier généré).
      final orderedColumns = StudentColumns.all
          .where((c) => _selectedColumns.contains(c.key))
          .map((c) => c.key)
          .toList();
      final config = StudentExportConfig(
        columns: orderedColumns,
        format: _format,
        classroomId: _classroomId,
        includePhotos: _includePhotos,
      );
      final path = await controller.exportStudents(
        config,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _exportReceived = received;
            _exportTotal = total == -1 ? null : total;
          });
        },
      );
      setState(() {
        _exportedPath = path;
        _isExporting = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export terminé : $path')),
        );
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isExporting = false;
      });
    }
  }

  Future<void> _copyPath() async {
    if (_exportedPath == null) return;
    await Clipboard.setData(ClipboardData(text: _exportedPath!));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Chemin copié.')),
    );
  }
}

// ---------------------------------------------------------------------------
// Sous-widgets
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({required this.online});
  final bool online;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(Icons.file_download_outlined,
              color: theme.colorScheme.primary, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Exporter les élèves',
                  style: theme.textTheme.titleLarge),
              Text(
                online
                    ? 'Sélectionnez le format, la classe et les colonnes.'
                    : 'Hors-ligne — export indisponible.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: online
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.error,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FormatSelector extends StatelessWidget {
  const _FormatSelector({required this.format, required this.onChanged});
  final String format;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Format',
            style: theme.textTheme.labelLarge
                ?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(
              value: 'xlsx',
              label: Text('Excel (.xlsx)'),
              icon: Icon(Icons.table_chart_outlined),
            ),
            ButtonSegment(
              value: 'csv',
              label: Text('CSV'),
              icon: Icon(Icons.description_outlined),
            ),
          ],
          selected: {format},
          onSelectionChanged: (s) => onChanged(s.first),
        ),
      ],
    );
  }
}

class _ClassroomFilter extends ConsumerWidget {
  const _ClassroomFilter({required this.classroomId, required this.onChanged});
  final int? classroomId;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(classroomsProvider);
    final classrooms = async.maybeWhen(
      data: (list) => list,
      orElse: () => const <ClassroomDto>[],
    );

    // Sécurise le `value` : si l'ID pré-sélectionné n'est pas encore dans la
    // liste (chargement en cours), on retombe sur null pour éviter une
    // assertion error du DropdownButtonFormField.
    final effectiveValue = (classroomId != null &&
            classrooms.any((c) => c.id == classroomId))
        ? classroomId
        : null;

    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<int?>(
            value: effectiveValue,
            decoration: const InputDecoration(
              labelText: 'Classe (optionnel)',
              hintText: 'Toutes les classes',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.school_outlined),
              isDense: true,
            ),
            items: [
              const DropdownMenuItem<int?>(
                value: null,
                child: Text('Toutes les classes'),
              ),
              ...classrooms.map((c) => DropdownMenuItem<int?>(
                    value: c.id,
                    child: Text(c.name),
                  )),
            ],
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

class _ColumnsSelector extends StatelessWidget {
  const _ColumnsSelector({
    required this.selected,
    required this.onToggle,
    required this.onToggleGroup,
    required this.onSelectAll,
    required this.onClearAll,
  });

  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final void Function(StudentColumnGroup group, bool select) onToggleGroup;
  final VoidCallback onSelectAll;
  final VoidCallback onClearAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final grouped = StudentColumns.grouped;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Colonnes (${selected.length}/${StudentColumns.all.length})',
                style: theme.textTheme.labelLarge
                    ?.copyWith(fontWeight: FontWeight.w600)),
            Row(
              children: [
                TextButton.icon(
                  onPressed: onSelectAll,
                  icon: const Icon(Icons.select_all, size: 18),
                  label: const Text('Tout'),
                ),
                TextButton.icon(
                  onPressed: onClearAll,
                  icon: const Icon(Icons.deselect, size: 18),
                  label: const Text('Aucun'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: theme.colorScheme.outline.withValues(alpha: 0.4),
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          constraints: const BoxConstraints(maxHeight: 260),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 4),
            children: [
              for (final entry in grouped.entries) ...[
                _GroupHeader(
                  group: entry.key,
                  items: entry.value,
                  selected: selected,
                  onToggleGroup: onToggleGroup,
                ),
                for (final col in entry.value)
                  CheckboxListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    contentPadding:
                        const EdgeInsets.only(left: 32, right: 12),
                    controlAffinity: ListTileControlAffinity.leading,
                    value: selected.contains(col.key),
                    onChanged: (_) => onToggle(col.key),
                    title: Text(col.label,
                        style: theme.textTheme.bodyMedium),
                    subtitle: Text(col.key,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        )),
                  ),
                if (entry.key != grouped.keys.last)
                  Divider(
                    height: 1,
                    indent: 12,
                    color: theme.dividerColor.withValues(alpha: 0.4),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.group,
    required this.items,
    required this.selected,
    required this.onToggleGroup,
  });

  final StudentColumnGroup group;
  final List<StudentColumn> items;
  final Set<String> selected;
  final void Function(StudentColumnGroup group, bool select) onToggleGroup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allKeys = items.map((c) => c.key).toSet();
    final selectedInGroup = allKeys.intersection(selected);
    final isAll = selectedInGroup.length == allKeys.length;
    final isSome = selectedInGroup.isNotEmpty && !isAll;

    return InkWell(
      onTap: () => onToggleGroup(group, !isAll),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Checkbox(
              value: isAll ? true : (isSome ? null : false),
              tristate: true,
              onChanged: (v) => onToggleGroup(group, v ?? false),
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 4),
            Text(group.label,
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(width: 6),
            Text(
              '${selectedInGroup.length}/${allKeys.length}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExportSuccessCard extends StatelessWidget {
  const _ExportSuccessCard({
    required this.path,
    required this.format,
    required this.onCopy,
  });

  final String path;
  final String format;
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
          Icon(Icons.check_circle, color: theme.colorScheme.primary, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Export terminé',
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

class _Actions extends StatelessWidget {
  const _Actions({
    required this.isExporting,
    required this.canExport,
    required this.onExport,
    required this.onCancel,
  });

  final bool isExporting;
  final bool canExport;
  final VoidCallback onExport;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    if (isExporting) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(onPressed: onCancel, child: const Text('Annuler')),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: canExport ? onExport : null,
          icon: const Icon(Icons.download),
          label: const Text('Exporter'),
        ),
      ],
    );
  }
}
