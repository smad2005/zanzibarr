import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/subtitles.dart';
import 'opensubtitles_hash.dart';

/// FRB `searchOpensubtitles` imzası; testlerde sahte enjekte edilebilir.
typedef OpenSubtitlesSearchFn =
    Future<List<SubtitleDto>> Function(
      OpenSubtitlesConfigDto config,
      String query,
      List<String> languages,
      String? movieHash,
      BigInt? movieBytesize,
    );

/// FRB `downloadOpensubtitles` imzası; testlerde sahte enjekte edilebilir.
typedef OpenSubtitlesDownloadFn =
    Future<String> Function(
      OpenSubtitlesConfigDto config,
      BigInt fileId,
      String? downloadDir,
    );

/// moviehash hesaplayıcısı (yerel aralık sunucusu üzerinden); testlerde
/// sahte enjekte edilebilir.
typedef OpenSubtitlesHashFn =
    Future<String?> Function(String streamUrl, int streamSize);

/// Varsayılan hash hesaplayıcısı: yerel aralık sunucusundan baş/son 64 KB
/// alır, moviehash üretir; hesaplanamazsa altyazı araması ad-bazlı sürer.
Future<String?> defaultOpenSubtitlesHashFn(String url, int size) =>
    const OpenSubtitlesHasher().hashOfStream(streamUrl: url, streamSize: size);

/// Dil çiplerinde gösterilen yaygın diller (ISO → yerel ad). Liste,
/// uygulamanın 14 l10n dilini kapsar; kod dışı diller ham kodlarıyla
/// gösterilir.
const kSubtitleLanguageChoices = <String, String>{
  'tr': 'Türkçe',
  'en': 'English',
  'ar': 'العربية',
  'es': 'Español',
  'de': 'Deutsch',
  'fr': 'Français',
  'pt': 'Português',
  'it': 'Italiano',
  'ru': 'Русский',
  'zh': '中文',
  'ja': '日本語',
  'ko': '한국어',
  'hi': 'हिन्दी',
  'fa': 'فارسی',
};

/// ISO kodundan görünen dil adı; bilinmeyen kod büyük harfle döner.
String subtitleLanguageLabel(String code) {
  final native = kSubtitleLanguageChoices[code];
  if (native != null) return native;
  return code.toUpperCase();
}

/// Oynatıcıdan çıkmadan OpenSubtitles'te altyazı arayan diyalog.
///
/// Açılışta otomatik arama yapar: (varsa) film hash'i + yayın dosya adı +
/// seçili diller. Dil çipleri tercih sırasını belirler ve seçim değişince
/// arama yenilenir; sonuç satırına dokununca altyazı indirilir ve
/// [onSelected] ile oynatıcıya yolu verilir (diyalog kapanır).
///
/// TV/D-pad: sonuç listesi ve çipler odaklanabilir; arama bitince ilk
/// sonuca odak taşınır.
class SubtitleSearchDialog extends StatefulWidget {
  const SubtitleSearchDialog({
    super.key,
    required this.config,
    required this.filename,
    required this.streamUrl,
    required this.streamSize,
    required this.downloadDir,
    required this.initialLanguages,
    required this.searchFn,
    required this.downloadFn,
    required this.hashFn,
    required this.onSelected,
    required this.onLanguagesChanged,
  });

  final OpenSubtitlesConfigDto config;

  /// Yayın dosya adı (StreamInfo.filename) — arama sorgusu.
  final String filename;

  /// Yerel aralık sunucusu URL'i + çözülmüş boyut: moviehash için.
  final String streamUrl;
  final int streamSize;

  /// İndirilecek altyazıların yazılacağı dizin.
  final String downloadDir;

  /// Başlangıç dil tercihleri (OpenSubtitles ayarından).
  final List<String> initialLanguages;

  final OpenSubtitlesSearchFn searchFn;
  final OpenSubtitlesDownloadFn downloadFn;
  final OpenSubtitlesHashFn hashFn;

  /// Altyazı indirilip hazır olduğunda çağrılır: (dosya yolu, dil kodu).
  final void Function(String path, String language) onSelected;

  /// Dil çipi değişince kalıcı tercih için çağrılır (yeni seçim listesi).
  final ValueChanged<List<String>> onLanguagesChanged;

  @override
  State<SubtitleSearchDialog> createState() => _SubtitleSearchDialogState();
}

class _SubtitleSearchDialogState extends State<SubtitleSearchDialog> {
  List<String> _languages = [];
  List<SubtitleDto> _results = [];
  bool _searching = false;
  BigInt? _downloading;
  Object? _error;
  String? _hash;
  bool _hashComputed = false;
  int _generation = 0;
  final _firstResultFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _languages = List.of(widget.initialLanguages);
    unawaited(_search());
  }

  @override
  void dispose() {
    _firstResultFocus.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (_languages.isEmpty) {
      // Dil seçimi olmadan arama yapılmaz; kullanıcı çip seçer.
      setState(() => _results = []);
      return;
    }
    final generation = ++_generation;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      if (!_hashComputed) {
        _hash = await widget.hashFn(widget.streamUrl, widget.streamSize);
        _hashComputed = true;
        if (!mounted) return;
      }
      final results = await widget.searchFn(
        widget.config,
        widget.filename,
        List.unmodifiable(_languages),
        _hash,
        BigInt.from(widget.streamSize),
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = results;
        _searching = false;
      });
      if (results.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _firstResultFocus.canRequestFocus) {
            _firstResultFocus.requestFocus();
          }
        });
      }
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error;
        _searching = false;
        _results = [];
      });
    }
  }

  Future<void> _toggleLanguage(String code) async {
    final next = List.of(_languages);
    if (next.contains(code)) {
      if (next.length == 1) return; // en az bir dil kalmalı
      next.remove(code);
    } else {
      next.add(code);
    }
    setState(() => _languages = next);
    widget.onLanguagesChanged(List.unmodifiable(next));
    unawaited(_search());
  }

  Future<void> _download(SubtitleDto item) async {
    if (_downloading != null) return;
    setState(() => _downloading = item.fileId);
    try {
      final path = await widget.downloadFn(widget.config, item.fileId, widget.downloadDir);
      if (!mounted) return;
      widget.onSelected(path, item.language);
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _downloading = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.subtitleSearchTitle),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
      content: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.filename,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 10),
            if (_languages.isNotEmpty) ...[
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final entry in kSubtitleLanguageChoices.entries)
                    _LanguageChip(
                      label: entry.value,
                      selected: _languages.contains(entry.key),
                      onPressed: () => unawaited(_toggleLanguage(entry.key)),
                    ),
                ],
              ),
              const SizedBox(height: 10),
            ],
            const Divider(height: 1),
            const SizedBox(height: 8),
            Expanded(child: _buildBody(context)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.subtitleSearchClose)),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_searching) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 10),
            Text(l10n.subtitleSearching),
          ],
        ),
      );
    }
    if (_error != null) {
      return _MessageView(
        icon: Icons.cloud_off_rounded,
        message: l10n.subtitleSearchFailed,
        detail: '$_error',
        actionLabel: l10n.retry,
        onAction: () => unawaited(_search()),
      );
    }
    if (_results.isEmpty) {
      if (_languages.isEmpty) {
        return _MessageView(
          icon: Icons.language_rounded,
          message: l10n.subtitleSearchPickLanguage,
        );
      }
      return _MessageView(icon: Icons.subtitles_off_rounded, message: l10n.subtitleSearchNoResults);
    }
    return ListView.separated(
      shrinkWrap: true,
      itemCount: _results.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (context, index) {
        final item = _results[index];
        return _SubtitleResultTile(
          item: item,
          downloading: _downloading == item.fileId,
          autofocus: index == 0,
          focusNode: index == 0 ? _firstResultFocus : null,
          onTap: () => unawaited(_download(item)),
        );
      },
    );
  }
}

/// Tek sonuç satırı: dil, dosya adı, indirme sayısı, hash-eşleşme mi.
class _SubtitleResultTile extends StatelessWidget {
  const _SubtitleResultTile({
    required this.item,
    required this.downloading,
    required this.onTap,
    this.autofocus = false,
    this.focusNode,
  });

  final SubtitleDto item;
  final bool downloading;
  final VoidCallback onTap;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final foreground = Theme.of(context).colorScheme.onSurface;
    return Focus(
      focusNode: focusNode,
      autofocus: autofocus,
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          return InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: focused
                    ? foreground.withValues(alpha: 0.08)
                    : Colors.transparent,
                border: Border.all(
                  color: focused
                      ? foreground.withValues(alpha: 0.3)
                      : Colors.transparent,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: foreground.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      item.language.toUpperCase(),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.fileName.isEmpty ? item.release : item.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            if (item.matchedByHash) ...[
                              Icon(
                                Icons.verified_rounded,
                                size: 12,
                                color: foreground.withValues(alpha: 0.55),
                              ),
                              const SizedBox(width: 3),
                              Text(
                                l10n.subtitleSearchMatch,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: foreground.withValues(alpha: 0.55),
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            Text(
                              l10n.subtitleSearchDownloads(
                                item.downloadCount.toInt(),
                              ),
                              style: TextStyle(
                                fontSize: 11,
                                color: foreground.withValues(alpha: 0.5),
                              ),
                            ),
                            if (item.hearingImpaired) ...[
                              const SizedBox(width: 8),
                              Text(
                                'HI',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: foreground.withValues(alpha: 0.5),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (downloading)
                    const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 1.8),
                    )
                  else
                    Icon(Icons.download_rounded, size: 18, color: foreground.withValues(alpha: 0.6)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _LanguageChip extends StatelessWidget {
  const _LanguageChip({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final foreground = Theme.of(context).colorScheme.onSurface;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: selected
              ? foreground.withValues(alpha: 0.12)
              : Colors.transparent,
          border: Border.all(
            color: selected
                ? foreground.withValues(alpha: 0.4)
                : foreground.withValues(alpha: 0.15),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              Icon(Icons.check_rounded, size: 13, color: foreground.withValues(alpha: 0.7)),
              const SizedBox(width: 3),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageView extends StatelessWidget {
  const _MessageView({
    required this.icon,
    required this.message,
    this.detail,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final String? detail;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final foreground = Theme.of(context).colorScheme.onSurface;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 32, color: foreground.withValues(alpha: 0.45)),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(message, textAlign: TextAlign.center),
          ),
          if (detail != null && detail!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                detail!,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: foreground.withValues(alpha: 0.45),
                ),
              ),
            ),
          ],
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}
