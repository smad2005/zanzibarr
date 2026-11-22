import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TV dependency profiles remove media_kit and native-only sources', () {
    for (final platform in ['tizen', 'webos']) {
      final work = Directory.systemTemp.createTempSync('zanzibarr-profile');
      try {
        File('pubspec.yaml').copySync('${work.path}/pubspec.yaml');
        final result = Process.runSync('dart', [
          'tools/configure_tv_pubspec.dart',
          work.path,
          platform,
        ]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final configured = File('${work.path}/pubspec.yaml').readAsStringSync();
        expect(configured, isNot(contains('media_kit:')));
        expect(configured, contains('video_player_$platform'));
        for (final native in [
          'lib/main.dart',
          'lib/player/player_screen.dart',
          'lib/player/advanced_playback_controller.dart',
          'lib/player/gyuni_player_controls.dart',
          'lib/player/subtitle_controls_overlay.dart',
        ]) {
          expect(File('${work.path}/$native').existsSync(), isFalse);
        }
      } finally {
        work.deleteSync(recursive: true);
      }
    }
  });

  test('Tizen manifests request required privileges for both API lines', () {
    for (final path in [
      'tizen/tizen-manifest.xml',
      'tizen/tizen-manifest-10.0.xml',
    ]) {
      final manifest = File(path).readAsStringSync();
      expect(manifest, contains('com.zanzibarr.zanzibarr'));
      expect(manifest, contains('http://tizen.org/privilege/internet'));
      expect(manifest, contains('http://tizen.org/privilege/mediastorage'));
      expect(manifest, contains('http://tizen.org/privilege/externalstorage'));
      expect(manifest, contains('<label>Zanzibarr</label>'));
    }
    expect(
      File('tizen/tizen-manifest.xml').readAsStringSync(),
      contains('api-version="6.0"'),
    );
    expect(
      File('tizen/tizen-manifest-10.0.xml').readAsStringSync(),
      contains('api-version="10.0"'),
    );
  });

  test('webOS native player configuration enables the video plane', () {
    final info =
        jsonDecode(File('webos/meta/appinfo.json').readAsStringSync())
            as Map<String, Object?>;
    expect(info['id'], 'com.zanzibarr.zanzibarr');
    expect(info['title'], 'Zanzibarr');
    expect(info['type'], 'native');
    expect(info['transparent'], isTrue);
  });

  test('Rust webOS plugin is an FFI bundle with the correct library name', () {
    final pluginPubspec = File('rust_builder/pubspec.yaml').readAsStringSync();
    final cmake = File('rust_builder/webos/CMakeLists.txt').readAsStringSync();
    expect(pluginPubspec, contains('webos:\n        ffiPlugin: true'));
    expect(cmake, contains('rust_lib_zanzibarr_bundled_libraries'));
    expect(cmake, contains('lib/librust_lib_zanzibarr.so'));
    expect(cmake, contains('lib/libstdc++.so.6'));
  });

  test('TV build and preparation scripts have valid shell syntax', () {
    for (final script in [
      'tools/prepare_tv_workdir.sh',
      'tools/build_tizen.sh',
      'tools/build_webos.sh',
      'tools/verify_tv_package.sh',
    ]) {
      final result = Process.runSync('bash', ['-n', script]);
      expect(result.exitCode, 0, reason: '$script: ${result.stderr}');
    }
  });
}
