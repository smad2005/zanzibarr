import 'dart:io';

import 'package:flutter/material.dart';

import 'app_shell.dart';
import 'player/player_launcher.dart';
import 'player/tv/tv_platform.dart';
import 'player/tv/tv_player_screen.dart';
import 'settings/ui_preferences.dart';

/// Shared entrypoint for Samsung Tizen and LG webOS TV builds.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final platform = currentTvPlatform;
  PlayerLauncher.register(
    ({required nzbPath, initialEntryKey}) => TvPlayerScreen(
      nzbPath: nzbPath,
      initialEntryKey: initialEntryKey,
      platform: platform,
    ),
    fileSelection: false,
  );

  final debugNzb = Platform.environment['ZANZIBARR_DEBUG_NZB'];
  runApp(
    ZanzibarrBootstrap(
      uiPreferences: UiPreferencesController(UiPreferencesStore()),
      debugNzbPath: debugNzb?.isNotEmpty == true ? debugNzb : null,
    ),
  );
}
