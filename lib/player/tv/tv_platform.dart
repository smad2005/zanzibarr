enum TvPlatform { tizen, webos }

const _platformName = String.fromEnvironment('ZANZIBARR_TV_OS');

TvPlatform get currentTvPlatform =>
    _platformName == 'webos' ? TvPlatform.webos : TvPlatform.tizen;

extension TvPlatformCapabilities on TvPlatform {
  bool get supportsInAppVolume => this == TvPlatform.tizen;

  String get playerBadge => switch (this) {
    TvPlatform.tizen => 'Tizen Media Player',
    TvPlatform.webos => 'webOS Media',
  };
}
