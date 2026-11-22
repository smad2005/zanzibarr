import '../../src/rust/api/streaming.dart';

/// Rust streaming surface used by the TV player. Small by design so widget
/// tests can exercise the full screen without NNTP or a native Rust library.
abstract interface class TvStreamBackend {
  Future<List<PlayableEntryDto>> listEntries(String nzbPath);

  Future<BigInt> begin({
    required ProviderConfigDto config,
    required String nzbPath,
    String? entryKey,
  });

  Future<StreamInfo> awaitInfo(BigInt sessionId);

  Future<void> stop(BigInt sessionId);
}

class FrbTvStreamBackend implements TvStreamBackend {
  const FrbTvStreamBackend();

  @override
  Future<List<PlayableEntryDto>> listEntries(String nzbPath) =>
      listPlayableEntries(nzbPath: nzbPath);

  @override
  Future<BigInt> begin({
    required ProviderConfigDto config,
    required String nzbPath,
    String? entryKey,
  }) => beginStream(config: config, nzbPath: nzbPath, entryKey: entryKey);

  @override
  Future<StreamInfo> awaitInfo(BigInt sessionId) =>
      awaitStream(sessionId: sessionId);

  @override
  Future<void> stop(BigInt sessionId) => stopStream(sessionId: sessionId);
}
