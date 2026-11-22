import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import '../src/rust/frb_generated.dart';

/// Loads the shared Rust engine, using Tizen's absolute app-library path when
/// available. webOS uses its bundled $ORIGIN/lib RPATH like desktop Linux.
Future<void> initializeNativeRustEngine() {
  const tvOs = String.fromEnvironment('ZANZIBARR_TV_OS');
  if (tvOs == 'tizen') {
    final root = Platform.environment['AUL_ROOT_PATH'];
    if (root != null && root.isNotEmpty) {
      final path = '$root/lib/librust_lib_zanzibarr.so';
      if (File(path).existsSync()) {
        return RustLib.init(externalLibrary: ExternalLibrary.open(path));
      }
    }
  }
  return RustLib.init();
}
