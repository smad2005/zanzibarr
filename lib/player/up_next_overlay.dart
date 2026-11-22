import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/streaming.dart';

/// Bölüm sonunda otomatik geçişten önce beklenen süre.
const upNextCountdown = Duration(seconds: 10);

/// Doğal sıralı aday listesinden, seçilen adayın ardından gelenleri oynatma
/// kuyruğu olarak üretir.
///
/// Seçim, [listPlayableEntries] çıktısının anahtar uzayındadır (seçici
/// diyalog veya izleme geçmişinden gelen `entryKey`). Bilinmeyen/tek aday
/// durumlarında kuyruk boş döner; tek video içeren sıradan NZB'lerde otomatik
/// geçiş davranışı yoktur.
List<PlayableEntryDto> queueAfterEntry(
  List<PlayableEntryDto> entries,
  String? selectedKey,
) {
  if (selectedKey == null) return const [];
  final index = entries.indexWhere((entry) => entry.key == selectedKey);
  if (index < 0 || index + 1 >= entries.length) return const [];
  return List<PlayableEntryDto>.unmodifiable(entries.sublist(index + 1));
}

/// Bölüm sonunda sonraki bölümü duyuran geri sayım kartı (Android TV dahil
/// D-pad ile kullanılabilir).
///
/// - [onPlayNow]: "Şimdi oynat" veya geri sayım bitiminde çağrılır.
/// - [onCancel]: "Bölümü bitir", Geri/Esc veya geri sayım dışında kapatma.
/// - [onClearQueue]: "Kuyruğu temizle" — otomatik geçiş bu oturum için kapanır.
///
/// Kart yalnızca bitişte gösterilir; sonraki akış geçiş anında başlar ve motor
/// yalnızca oynatılan kareleri çeker (tembel akış kuralı). Kuyruk kurulumu ise
/// tamamen ağsız yapılır: NZB zaten ayrıştırılmış aday listesinden gelir.
class UpNextOverlay extends StatefulWidget {
  const UpNextOverlay({
    super.key,
    required this.entryName,
    required this.onPlayNow,
    required this.onCancel,
    required this.onClearQueue,
    this.countdown = upNextCountdown,
  });

  final String entryName;
  final VoidCallback onPlayNow;
  final VoidCallback onCancel;
  final VoidCallback onClearQueue;
  final Duration countdown;

  @override
  State<UpNextOverlay> createState() => _UpNextOverlayState();
}

class _UpNextOverlayState extends State<UpNextOverlay> {
  late int _remaining = widget.countdown.inSeconds;
  Timer? _timer;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _remaining <= 0) return;
      setState(() => _remaining--);
      if (_remaining <= 0) _play();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _play() {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    widget.onPlayNow();
  }

  void _cancel() {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    widget.onCancel();
  }

  void _clearQueue() {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    widget.onClearQueue();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape ||
        event.logicalKey == LogicalKeyboardKey.goBack) {
      _cancel();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final foreground = Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : Colors.black;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 96),
        child: Focus(
          onKeyEvent: _handleKey,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Material(
              color: const Color(0xF2202023),
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: Colors.white12),
              ),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.upcoming_outlined,
                          size: 16,
                          color: foreground.withValues(alpha: 0.6),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n.upNextTitle,
                            style: TextStyle(
                              color: foreground.withValues(alpha: 0.6),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                        Text(
                          l10n.upNextStarting(_remaining),
                          style: TextStyle(
                            color: foreground.withValues(alpha: 0.45),
                            fontSize: 12,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.entryName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foreground.withValues(alpha: 0.92),
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Dar ekranlarda/uzun etiketlerde satır taşmaması için
                    // düğmeler satırsonra sarılır (TV'de D-pad sırayla gezer).
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        TextButton(
                          onPressed: _clearQueue,
                          child: Text(l10n.upNextClearQueue),
                        ),
                        TextButton(
                          onPressed: _cancel,
                          child: Text(l10n.upNextFinish),
                        ),
                        FilledButton(
                          autofocus: true,
                          onPressed: _play,
                          child: Text(l10n.upNextPlayNow),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
