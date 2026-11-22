// Create an isolated Tizen or webOS dependency profile in a work copy.
//
// The main pubspec remains cross-platform. TV builds use a temporary source
// tree and remove media_kit/libmpv, whose native implementations do not
// target these TV operating systems.

import 'dart:io';

const webosPluginRef = '3a742bb86b04e261044f0864f9b1f71acf0bbad3';

String replaceOnce(String text, String old, String replacement) {
  final count = old.allMatches(text).length;
  if (count != 1) {
    final escaped = old.replaceAll('\n', r'\n');
    throw StateError('Expected exactly one pubspec entry: $escaped');
  }
  return text.replaceFirst(old, replacement);
}

String plugin(String path) => '    git:\n'
    '      url: https://github.com/lg-flutter-webos/plugins.git\n'
    '      ref: $webosPluginRef\n'
    '      path: $path\n';

void main(List<String> args) {
  if (args.length != 2 || !['tizen', 'webos'].contains(args[1])) {
    stderr.writeln('usage: configure_tv_pubspec.dart <workdir> <tizen|webos>');
    exit(64);
  }
  final platform = args[1];
  final work = Directory(args[0]).resolveSymbolicLinksSync();
  final pubspec = File('$work${Platform.pathSeparator}pubspec.yaml');
  var text = pubspec.readAsStringSync();

  // libmpv/media_kit is intentionally absent from both TV profiles.
  for (final dependency in [
    '  media_kit: ^1.2.6\n',
    '  media_kit_video: ^2.0.1\n',
    '  media_kit_libs_video: ^1.0.7\n',
    '    path: vendor/media_kit_libs_macos_video\n',
    '    path: vendor/media_kit_libs_android_video\n',
  ]) {
    text = replaceOnce(text, dependency, '');
  }
  text = text
      .replaceAll('  media_kit_libs_macos_video:\n', '')
      .replaceAll('  media_kit_libs_android_video:\n', '');
  text = replaceOnce(text, 'dependency_overrides:\n', '');

  late final String additions;
  if (platform == 'tizen') {
    text = replaceOnce(
      text,
      '  video_player: ^2.11.1\n',
      '  video_player: ^2.14.0\n',
    );
    text = replaceOnce(
      text,
      '  package_info_plus: ^9.0.0\n',
      '  package_info_plus: ^10.2.2\n',
    );
    additions = '  video_player_tizen: ^2.6.0\n'
        '  flutter_secure_storage_tizen: ^0.1.6\n'
        '  path_provider_tizen: ^2.3.3\n'
        '  package_info_plus_tizen: ^1.2.0\n'
        '  url_launcher_tizen: ^2.1.9\n';
  } else {
    text = replaceOnce(text, '  sdk: ^3.12.2\n', "  sdk: '>=3.10.0 <4.0.0'\n");
    text = replaceOnce(
      text,
      '  flutter_secure_storage: ^10.3.1\n',
      '  flutter_secure_storage: 9.2.4\n',
    );
    text = replaceOnce(
      text,
      '  package_info_plus: ^9.0.0\n',
      '  package_info_plus: 4.2.0\n',
    );
    additions = '  video_player_webos:\n'
        '${plugin('packages/video_player')}'
        '  flutter_secure_storage_webos:\n'
        '${plugin('packages/flutter_secure_storage')}'
        '  path_provider_webos:\n'
        '${plugin('packages/path_provider')}'
        '  package_info_plus_webos:\n'
        '${plugin('packages/package_info_plus')}'
        '  url_launcher_webos:\n'
        '${plugin('packages/url_launcher')}';
  }

  text = replaceOnce(text, '  file_selector: ^1.1.0\n', '$additions  file_selector: ^1.1.0\n');
  pubspec.writeAsStringSync(text);

  final lock = File('$work${Platform.pathSeparator}pubspec.lock');
  if (lock.existsSync()) lock.deleteSync();

  // Analyzer and compilers must not see native-only media_kit sources in the
  // isolated TV tree. They are unreachable from tv_main.dart, but leaving
  // them in place would make `analyze lib` require the removed dependency.
  for (final relative in [
    'lib/main.dart',
    'lib/player/player_screen.dart',
    'lib/player/advanced_playback_controller.dart',
    'lib/player/gyuni_player_controls.dart',
    'lib/player/subtitle_controls_overlay.dart',
  ]) {
    final nativeSource = File('$work${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}');
    if (nativeSource.existsSync()) nativeSource.deleteSync();
  }

  stdout.writeln('Configured $platform dependency profile: ${pubspec.path}');
}
