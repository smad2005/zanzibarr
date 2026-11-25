import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/app_localizations.dart';
import 'rss_backup.dart';
import 'rss_store.dart';

typedef RssBackupPickFn = Future<String?> Function();

typedef RssBackupSaveFn = Future<String?> Function(String content);

class RssImportExportCard extends StatefulWidget {
  const RssImportExportCard({
    super.key,
    this.store,
    this.pickFile,
    this.saveFile,
  });

  final RssStore? store;

  final RssBackupPickFn? pickFile;

  final RssBackupSaveFn? saveFile;

  @override
  State<RssImportExportCard> createState() => _RssImportExportCardState();

  static const _backupFileName = 'zanzibarr-rss-backup.json';
  static const _jsonGroup = [
    XTypeGroup(label: 'JSON', extensions: ['json']),
  ];

  static String stampedBackupName(DateTime now) {
    String two(int value) => value.toString().padLeft(2, '0');
    return 'zanzibarr-rss-backup-'
        '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}-'
        '${now.millisecond.toString().padLeft(3, '0')}.json';
  }

  static Future<String?> _pickFile() async {
    final file = await openFile(acceptedTypeGroups: _jsonGroup);
    return file?.readAsString();
  }

  static Future<String?> _saveFile(String content) async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final location = await getSaveLocation(
        suggestedName: _backupFileName,
        acceptedTypeGroups: _jsonGroup,
      );
      if (location == null) return null;
      final target = File(location.path);
      await target.writeAsString(content);
      return target.path;
    }
    final dir =
        await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
    final target =
        '${dir.path}${Platform.pathSeparator}${stampedBackupName(DateTime.now())}';
    await File(target).writeAsString(content);
    return target;
  }
}

class _RssImportExportCardState extends State<RssImportExportCard> {
  late final RssStore _store = widget.store ?? RssStore();
  late final RssBackupPickFn _pickFile = widget.pickFile ?? RssImportExportCard._pickFile;
  late final RssBackupSaveFn _saveFile = widget.saveFile ?? RssImportExportCard._saveFile;

  bool _exporting = false;
  bool _importing = false;

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _export() async {
    if (_exporting) return;
    final l10n = AppLocalizations.of(context);
    setState(() => _exporting = true);
    try {
      final backup = await _store.loadBackup();
      final path = await _saveFile(RssBackup.encode(backup));
      if (path != null) _snack(l10n.settingsRssExportDone(path));
    } catch (error) {
      _snack(l10n.settingsRssExportFailed('$error'));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _import() async {
    if (_importing) return;
    final l10n = AppLocalizations.of(context);
    setState(() => _importing = true);
    try {
      final raw = await _pickFile();
      if (raw == null) return;
      final backup = RssBackup.decode(raw);
      if (backup == null) {
        _snack(l10n.settingsRssImportInvalid);
        return;
      }
      if (!mounted) return;
      setState(() => _importing = false);
      final selection = await _askSelection(backup);
      if (selection == null || !mounted) return;
      setState(() => _importing = true);
      await _store.applyBackup(
        backup,
        feeds: selection.feeds,
        tags: selection.tags,
        favorites: selection.favorites,
      );
      _snack(l10n.settingsRssImportDone);
    } catch (error) {
      _snack(l10n.settingsRssImportFailed('$error'));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<({bool feeds, bool tags, bool favorites})?> _askSelection(
    RssBackup backup,
  ) async {
    final l10n = AppLocalizations.of(context);
    var feeds = true;
    var tags = true;
    var favorites = true;
    return showDialog<({bool feeds, bool tags, bool favorites})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(l10n.settingsRssImportDialogTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.settingsRssImportDialogBody),
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: feeds,
                  title: Text(l10n.settingsRssImportFeeds(backup.feeds.length)),
                  onChanged: (value) =>
                      setDialogState(() => feeds = value ?? false),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: tags,
                  title: Text(l10n.settingsRssImportTags(backup.tags.length)),
                  onChanged: (value) =>
                      setDialogState(() => tags = value ?? false),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: favorites,
                  title: Text(
                    l10n.settingsRssImportFavorites(backup.favorites.length),
                  ),
                  onChanged: (value) =>
                      setDialogState(() => favorites = value ?? false),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.rssCancel),
            ),
            FilledButton(
              onPressed: feeds || tags || favorites
                  ? () => Navigator.pop(
                      context,
                      (feeds: feeds, tags: tags, favorites: favorites),
                    )
                  : null,
              child: Text(l10n.settingsRssImportConfirm),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final foreground = Theme.of(context).colorScheme.onSurface;
    final style = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 30),
        Text(
          l10n.settingsRssTransferTitle,
          style: style.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.35,
          ),
        ),
        const SizedBox(height: 7),
        Text(
          l10n.settingsRssTransferHint,
          style: style.bodySmall?.copyWith(
            color: foreground.withValues(alpha: 0.45),
            height: 1.4,
          ),
        ),
        const SizedBox(height: 14),
        DecoratedBox(
          decoration: BoxDecoration(
            color: foreground.withValues(alpha: 0.035),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: foreground.withValues(alpha: 0.075)),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  OutlinedButton.icon(
                    onPressed: _exporting ? null : _export,
                    icon: _exporting
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 1.8),
                          )
                        : const Icon(Icons.file_download_outlined, size: 18),
                    label: Text(l10n.settingsRssExport),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _importing ? null : _import,
                    icon: _importing
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 1.8),
                          )
                        : const Icon(Icons.file_upload_outlined, size: 18),
                    label: Text(l10n.settingsRssImport),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
