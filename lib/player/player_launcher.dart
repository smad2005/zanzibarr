import 'package:flutter/widgets.dart';

/// Creates the platform's player without making the shared home/search UI
/// depend on media_kit (desktop/mobile) or video_player (Tizen/webOS).
typedef PlayerWidgetBuilder =
    Widget Function({required String nzbPath, String? initialEntryKey});

/// Runtime registry selected by each application entrypoint.
///
/// `lib/main.dart` registers the media_kit player; `lib/tv_main.dart` registers
/// the native TV player. Tests and the shared app shell stay backend-neutral.
abstract final class PlayerLauncher {
  static PlayerWidgetBuilder? _builder;

  /// Whether the platform offers a native NZB file picker. TV builds hide this
  /// action because file_selector currently has no Tizen/webOS implementation.
  static bool supportsFileSelection = true;

  static void register(
    PlayerWidgetBuilder builder, {
    required bool fileSelection,
  }) {
    _builder = builder;
    supportsFileSelection = fileSelection;
  }

  static Widget create({required String nzbPath, String? initialEntryKey}) {
    final builder = _builder;
    if (builder == null) {
      throw StateError(
        'No player backend registered. Call PlayerLauncher.register() from the application entrypoint.',
      );
    }
    return builder(nzbPath: nzbPath, initialEntryKey: initialEntryKey);
  }
}
