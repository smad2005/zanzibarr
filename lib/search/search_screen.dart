import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/app_localizations.dart';
import '../player/player_screen.dart';
import '../settings/indexer_settings.dart';
import '../settings/provider_settings.dart';
import '../settings/settings_screen.dart';
import '../settings/ui_preferences.dart';
import '../src/rust/api/easynews.dart' show EasynewsConfigDto, easynewsDownloadNzb;
import '../src/rust/api/health.dart' show NzbHealthDto, checkNzbHealth;
import '../src/rust/api/search.dart';
import '../src/rust/api/streaming.dart' show ProviderConfigDto;
import '../tv_focus.dart';
import 'search_history.dart';

/// Arama sonucunun geldiği kaynak (motor tarafıyla aynı sabitler).
const kSearchSourceIndexer = 'indexer';
const kSearchSourceEasynews = 'easynews';

/// FRB `searchSources` imzası; testlerde sahte enjekte edilebilir.
typedef MultiSourceSearchFn =
    Future<SearchPageDto> Function({
      List<IndexerConfigDto>? indexers,
      EasynewsConfigDto? easynews,
      required String query,
      required int limit,
      required int offset,
    });

/// FRB `newznabDownloadNzb` imzası; testlerde sahte enjekte edilebilir.
typedef NewznabDownloadFn =
    Future<String> Function(
      IndexerConfigDto config,
      String nzbUrl,
      String suggestedName,
    );

/// FRB `easynewsDownloadNzb` imzası; testlerde sahte enjekte edilebilir.
typedef EasynewsDownloadFn =
    Future<String> Function(
      EasynewsConfigDto config,
      String nzbUrl,
      String suggestedName,
    );

/// FRB `checkNzbHealth` imzası; testlerde sahte enjekte edilebilir.
typedef NzbHealthFn =
    Future<NzbHealthDto> Function(ProviderConfigDto config, String nzbPath);

/// Newznab indexer'da arama yapıp sonucu NZB indirmeden oynatıcıya bağlayan
/// ekran.
///
/// Ayarlar OS secure storage'dan okunur; API anahtarı ve `nzbUrl` hiçbir
/// zaman loglanmaz. Varsayılan arama/indirme gerçek FRB köprüsünü çağırır,
/// testler [searchFn]/[downloadFn]/[onDownloaded] ile sahte kurar.
class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    this.store,
    this.searchFn,
    this.downloadFn,
    this.easynewsDownloadFn,
    this.onDownloaded,
    this.uiPreferences,
    this.providerStore,
    this.healthFn,
    this.historyStore,
  });

  /// Testlerde sahte depo enjekte edebilmek için; null ise gerçek depo kullanılır.
  final IndexerSettingsStore? store;

  /// Null ise FRB `searchSources` kullanılır (indexer + Easynews birleşik).
  final MultiSourceSearchFn? searchFn;

  /// Null ise FRB `newznabDownloadNzb` kullanılır.
  final NewznabDownloadFn? downloadFn;

  /// Null ise FRB `easynewsDownloadNzb` kullanılır.
  final EasynewsDownloadFn? easynewsDownloadFn;

  /// İndirme bitince çağrılır; null ise [PlayerScreen]'e push edilir.
  /// Testlerde oynatıcının native çağrılarını atlamak için kullanılır.
  final ValueChanged<String>? onDownloaded;

  /// Ayarlar ekranına taşınır; oradaki Uygulama bölümü (dil/tema) ve TV
  /// autofocus hedefi için gerekli.
  final UiPreferencesController? uiPreferences;

  /// NNTP sağlayıcı ayarları: sağlık ön kontrolü (rozetler) bunu ister.
  /// Testlerde sahte depo enjekte edilir; null ise gerçek depo okunur ve
  /// ayarlar eksikse rozetler sessizce gizlenir.
  final ProviderSettingsStore? providerStore;

  /// Null ise FRB `checkNzbHealth` kullanılır.
  final NzbHealthFn? healthFn;

  /// Son/kayıtlı aramalar için; null ise gerçek depo kullanılır.
  final SearchHistoryStore? historyStore;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  static const _pageSize = 50;

  late final IndexerSettingsStore _store =
      widget.store ?? IndexerSettingsStore();
  late final ProviderSettingsStore _providerStore =
      widget.providerStore ?? ProviderSettingsStore();
  late final MultiSourceSearchFn _searchFn = widget.searchFn ?? _defaultSearch;
  late final NewznabDownloadFn _downloadFn =
      widget.downloadFn ?? _defaultDownload;
  late final EasynewsDownloadFn _easynewsDownloadFn =
      widget.easynewsDownloadFn ?? _defaultEasynewsDownload;
  late final NzbHealthFn _healthFn = widget.healthFn ?? _defaultHealth;
  late final SearchHistoryStore _historyStore =
      widget.historyStore ?? SearchHistoryStore();

  final _queryController = TextEditingController();

  /// TV kumandasında aşağı ok alandan çıkıp sonuç kartlarına inebilsin diye
  /// D-pad gezintili odak düğümü (issue #4).
  late final _queryFocusNode = dpadTraversalFocusNode(_queryController);

  ProviderSettings _providerSettings = const ProviderSettings();

  /// Kayıtlı indexer profilleri (çoklu indexer). Arama, tam yapılandırılmış
  /// ve açık olanların tamamını paralel sorgular.
  List<IndexerProfile> _indexerProfiles = const [];
  bool _loadingSettings = true;

  /// Sağlayıcı Easynews ise web araması için türetilen yapılandırma;
  /// sağlayıcı easynews.com'un alt alanı DEĞİLSE null (Ek ayar yok —
  /// members.easynews.com aynı NNTP hesabına bakar).
  EasynewsConfigDto? _easynewsConfig;

  List<SearchItemDto>? _items;
  int? _total;
  bool _searching = false;
  Object? _error;

  /// Şu an NZB'si indirilen öğenin listedeki sırası; spinner burada gösterilir.
  int? _busyIndex;

  /// Arama geçmişi ve kayıtlı aramalar (roadmap #9). Öntanımlı olarak boş;
  /// depo yüklenince tek seferlik doldurulur.
  List<String> _recentQueries = const [];
  List<String> _savedQueries = const [];

  /// Sonuçlar gelince odak ilk karta taşınır; TV kumandası kullanıcısı
  /// IME'den çıkınca doğrudan listeyi dolaşmaya başlar (issue #4).
  final _firstResultFocusNode = FocusNode();

  // ---- NZB sağlık ön kontrolü (rozetler) -----------------------------------
  /// Gecikmiş eski tarama adımlarının yeni sonuçlara yazmasını önlemek
  /// için tarama kuşağı: yeni arama/temizleme bunu artırır.
  int _healthGeneration = 0;

  /// indeks → ön kontrol durumu (null = sırası gelmedi).
  final Map<int, _HealthState> _healthStates = {};

  /// Denetim sırasında indirilmiş NZB yolları: kullanıcı "oynat" derse
  /// aynı küçük dosya yeniden indirilmez.
  final Map<int, String> _downloadedPaths = {};

  static Future<SearchPageDto> _defaultSearch({
    List<IndexerConfigDto>? indexers,
    EasynewsConfigDto? easynews,
    required String query,
    required int limit,
    required int offset,
  }) => searchSources(
    indexers: indexers,
    easynews: easynews,
    query: query,
    limit: limit,
    offset: offset,
  );

  static Future<NzbHealthDto> _defaultHealth(
    ProviderConfigDto config,
    String nzbPath,
  ) => checkNzbHealth(config: config, nzbPath: nzbPath);

  /// Sağlayıcı adından Easynews web arama yapılandırması türetir:
  /// host `easynews.com` veya `*.easynews.com` ise ve NNTP kimlik bilgileri
  /// doluysa aynı hesapla web araması açılır; aksi hâlde null.
  static EasynewsConfigDto? _deriveEasynewsConfig(ProviderSettings provider) {
    final host = provider.host.trim().toLowerCase();
    final isEasynews = host == 'easynews.com' || host.endsWith('.easynews.com');
    if (!isEasynews) return null;
    if (provider.username.trim().isEmpty || provider.password.isEmpty) {
      return null;
    }
    return EasynewsConfigDto(
      // Bazı bölgelerde engellenirse ayarlardan değiştirilebilir; boş URL
      // motor tarafında varsayılana (members.easynews.com) düşer.
      baseUrl: '',
      username: provider.username,
      password: provider.password,
    );
  }

  static Future<String> _defaultDownload(
    IndexerConfigDto config,
    String nzbUrl,
    String suggestedName,
  ) async {
    // Android'de Rust tarafının std::env::temp_dir() kullanımı çalışmaz
    // (TMPDIR yok, /tmp yazılamaz); NZB uygulamanın önbellek dizinine iner.
    // Masaüstünde de aynı dizin kullanılır (izin gerektirmez).
    final cacheDir = await getTemporaryDirectory();
    return newznabDownloadNzb(
      config: config,
      nzbUrl: nzbUrl,
      suggestedName: suggestedName,
      downloadDir: cacheDir.path,
    );
  }

  static Future<String> _defaultEasynewsDownload(
    EasynewsConfigDto config,
    String nzbUrl,
    String suggestedName,
  ) async {
    final cacheDir = await getTemporaryDirectory();
    return easynewsDownloadNzb(
      config: config,
      nzbUrl: nzbUrl,
      suggestedName: suggestedName,
      downloadDir: cacheDir.path,
    );
  }

  @override
  void initState() {
    super.initState();
    // Temizle düğmesi yalnızca metin varken görünsün.
    _queryController.addListener(() => setState(() {}));
    _loadSettings();
    _loadHistory();
  }

  /// Geçmiş/kayıtlı aramaları depodan çizer. Secure storage test ortamında
  /// tamamlanmayabilir (sağlayıcı ayarları gibi); kısa zaman aşımı sessiz
  /// düşüş sağlar ve ekran boş listelerle açılır.
  Future<void> _loadHistory() async {
    try {
      final results = await Future.wait([
        _historyStore.loadRecent(),
        _historyStore.loadSaved(),
      ]);
      if (!mounted) return;
      setState(() {
        _recentQueries = results[0];
        _savedQueries = results[1];
      });
    } catch (_) {
      // Depo okunamazsa geçmiş sessizce boş kalır.
    }
  }

  @override
  void dispose() {
    _queryController.dispose();
    _queryFocusNode.dispose();
    _firstResultFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    List<IndexerProfile> profiles = const [];
    ProviderSettings provider = const ProviderSettings();
    try {
      // Arama sonuçları geldiği profille etiketlenir (sourceId); indirme
      // ve ön kontrol o hesapla yapılır.
      profiles = await _store.loadProfiles();
    } catch (_) {
      // Secure storage okunamazsa indexer yokmuş gibi davran; kullanıcı
      // ayarlardan yeniden girmeyi deneyebilir.
    }
    try {
      // Sağlayıcı ayarları yalnız ön kontrol rozetleri için gereklidir;
      // depo beklenmedik biçimde yanıt vermezse (ör. test ortamı) arama
      // ve oynatma akışı ezilmesin diye kısa bir zaman aşımı koruması var.
      provider = await _providerStore
          .load()
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      // Sağlayıcı ayarı okunamazsa ön kontrol sessizce kapalı kalır.
    }
    if (!mounted) return;
    setState(() {
      _indexerProfiles = profiles;
      _providerSettings = provider;
      _easynewsConfig = _deriveEasynewsConfig(provider);
      _loadingSettings = false;
    });
  }

  /// Aramaya katılacak indexer yapılandırmaları: açık ve tam olan profiller,
  /// kayıt sırasıyla (tekilleştirme baştaki hesabı tercih eder — kullanıcı
  /// öncelik sırasını ayarlardaki liste sırasıyla belirler).
  List<IndexerConfigDto> get _searchIndexers => [
        for (final profile in _indexerProfiles)
          if (profile.searchable)
            IndexerConfigDto(
              id: profile.id,
              baseUrl: profile.baseUrl,
              apiKey: profile.apiKey,
            ),
      ];

  /// Indexer kaynakları hazır mı (hazır olmayan kaynak aramaya katılmaz).
  bool get _indexerReady => _searchIndexers.isNotEmpty;

  Future<void> _search() async {
    final query = _queryController.text.trim();
    if (query.isEmpty || _searching) return;
    if (!_indexerReady && _easynewsConfig == null) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final indexers = _searchIndexers;
      final page = await _searchFn(
        indexers: indexers.isEmpty ? null : indexers,
        easynews: _easynewsConfig,
        query: query,
        limit: _pageSize,
        offset: 0,
      );
      if (!mounted) return;
      // Aramayı geçmişe kaydet (aynı sorgu en öne taşınır).
      unawaited(_historyStore.recordSearch(query));
      // Yeni sonuç kümesi: eski ön kontrol durumları ve indirilmiş NZB
      // yolları geçersiz; kuşak artırılır (elle denetim yeniden başlar).
      _healthGeneration++;
      _healthStates.clear();
      _downloadedPaths.clear();
      setState(() {
        _items = page.items;
        _total = page.total?.toInt();
        _searching = false;
      });
      if (page.items.isNotEmpty) {
        // Klavyeden "ara" eylemi alan odağını düşürür; D-pad zinciri
        // kopmasın diye odak ilk sonuç kartına taşınır.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _firstResultFocusNode.requestFocus();
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _searching = false;
      });
    }
  }

  /// Sonuç listesindeki NZB'leri sırayla ön kontrolden geçirir (kullanıcı
  /// daha oynat tuşuna basmadan).
  ///
  /// Davranış sınırları:
  /// - Sağlayıcı ayarları eksikse hiç başlamaz (rozetler gizli kalır).
  /// - Her öğe için NZB küçük olduğundan bir kez indirilir ve yol
  ///   [`_downloadedPaths`]te saklanır; oynatmada yeniden indirilmez.
  /// - Üst üste iki hata (indirme/sunucu erişimi) taramayı keser;
  ///   kalan kartlarda rozet çıkmaz.
  /// - Yeni arama/temizleme kuşağı geçersiz kılarsa bekleyen adımlar
  ///   sonuç uygulamaz.
  /// Sonucun NZB'sini indirir: kaynak Easynews'te `dl-nzb` POST'u, indexer'da
  /// klasik NZB bağlantısı. Çoklu indexer'da sonuç hangi profilden geldiyse
  /// (`sourceId`) o profil indirir. Sağlık ön kontrolü ve oynatma aynı yolu
  /// kullanır.
  Future<String> _downloadItemNzb(SearchItemDto item) async {
    if (item.source == kSearchSourceEasynews) {
      final easynewsConfig = _easynewsConfig;
      if (easynewsConfig == null) {
        throw StateError('Easynews yapılandırması olmadan Easynews sonucu');
      }
      return _easynewsDownloadFn(easynewsConfig, item.nzbUrl, item.title);
    }
    return _downloadFn(_configForItem(item), item.nzbUrl, item.title);
  }

  /// Sonucun köken profiline ait indexer yapılandırması. Profil bulunamazsa
  /// (ör. sonuç ayarlardan silinmiş profilden kaldı) aramaya açık ilk
  /// profil kullanılır; hiçbiri yoksa boş yapılandırma hatayı döndürür.
  IndexerConfigDto _configForItem(SearchItemDto item) {
    final profiles = _indexerProfiles;
    final byId = profiles.where((p) => p.id == item.sourceId).toList();
    final fallback =
        profiles.where((p) => p.searchable).toList(growable: false);
    final profile =
        byId.isNotEmpty ? byId.first : (fallback.isEmpty ? null : fallback.first);
    if (profile == null) {
      return const IndexerConfigDto(id: '', baseUrl: '', apiKey: '');
    }
    return IndexerConfigDto(
      id: profile.id,
      baseUrl: profile.baseUrl,
      apiKey: profile.apiKey,
    );
  }

  /// Karttaki kontrol simgesiyle tek bir sonucun NZB sağlığını denetler.
  /// Otomatik tarama yapılmaz; yalnızca kullanıcı isteğiyle çalışır.
  Future<void> _checkHealth(int index) async {
    final items = _items;
    if (items == null || index < 0 || index >= items.length) return;
    if (!mounted || !_providerSettings.isComplete) return;
    if (_healthStates[index] is _HealthChecking) return;
    final generation = _healthGeneration;
    final providerConfig = ProviderConfigDto(
      host: _providerSettings.host,
      port: _providerSettings.port,
      username: _providerSettings.username,
      password: _providerSettings.password,
      maxConnections: _providerSettings.maxConnections,
    );
    setState(() => _healthStates[index] = _HealthChecking());
    try {
      // Denetim küçük NZB indirerek yapılır; aynı dosya oynatmada da
      // kullanılır (yeniden indirme yok).
      var path = _downloadedPaths[index];
      if (path == null) {
        path = await _downloadItemNzb(items[index]);
        if (!mounted || generation != _healthGeneration) return;
        _downloadedPaths[index] = path;
      }
      final report = await _healthFn(providerConfig, path);
      if (!mounted || generation != _healthGeneration) return;
      setState(() => _healthStates[index] = _HealthDone(report));
    } catch (_) {
      if (!mounted || generation != _healthGeneration) return;
      setState(() => _healthStates[index] = _HealthFailed());
    }
  }

  Future<void> _downloadAndPlay(int index) async {
    if (_busyIndex != null) return;
    final item = _items![index];
    setState(() => _busyIndex = index);
    try {
      // Ön kontrol aynı NZB'yi zaten indirdiyse yol yeniden kullanılır.
      final path = _downloadedPaths[index] ?? await _downloadItemNzb(item);
      if (!mounted) return;
      _downloadedPaths[index] = path;
      final onDownloaded = widget.onDownloaded;
      if (onDownloaded != null) {
        onDownloaded(path);
      } else {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => PlayerScreen(nzbPath: path)),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context).searchDownloadFailed('$error'),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busyIndex = null);
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(uiPreferences: widget.uiPreferences),
      ),
    );
    // Ayarlardan dönüldüğünde indexer yeni girilmiş olabilir.
    await _loadSettings();
  }

  /// Çipten tetiklenen arama: sorgu alana yazılır ve doğrudan aranır.
  Future<void> _runQuery(String query) async {
    if (_searching) return;
    _queryController.text = query;
    _queryController.selection = TextSelection.collapsed(
      offset: query.length,
    );
    await _search();
  }

  Future<void> _saveCurrentSearch() async {
    final query = _queryController.text.trim();
    if (query.isEmpty) return;
    try {
      await _historyStore.saveSearch(query);
      final saved = await _historyStore.loadSaved();
      if (!mounted) return;
      setState(() => _savedQueries = saved);
    } catch (_) {
      // Kayıt başarısızsa sessiz kalınır; arama akışı etkilenmez.
    }
  }

  Future<void> _removeSavedSearch(String query) async {
    try {
      await _historyStore.removeSaved(query);
      final saved = await _historyStore.loadSaved();
      if (!mounted) return;
      setState(() => _savedQueries = saved);
    } catch (_) {
      // Aynı şekilde sessiz.
    }
  }

  Future<void> _clearRecentSearches() async {
    try {
      await _historyStore.clearRecent();
      if (!mounted) return;
      setState(() => _recentQueries = const []);
    } catch (_) {
      // Sessiz.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 17),
          tooltip: l10n.backTooltip,
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Text(
          l10n.searchTitle,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _queryController,
                    focusNode: _queryFocusNode,
                    // TV kumandasında D-pad gezintisi metin alanından başlar.
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    autocorrect: false,
                    decoration: InputDecoration(
                      hintText: l10n.searchHint,
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      suffixIcon: _queryController.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: l10n.searchClearTooltip,
                              icon: const Icon(Icons.close_rounded, size: 18),
                              onPressed: () {
                                _queryController.clear();
                                // Bekleyen ön kontrol adımları geçersiz.
                                _healthGeneration++;
                                _healthStates.clear();
                                _downloadedPaths.clear();
                                setState(() {
                                  _items = null;
                                  _total = null;
                                  _error = null;
                                });
                              },
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                IconButton.filled(
                  tooltip: l10n.searchTooltip,
                  onPressed: _searching ? null : _search,
                  icon: const Icon(Icons.search_rounded, size: 20),
                ),
                // Kaydet düğmesi yalnızca yazılan sorgu varken görünür.
                if (_queryController.text.trim().isNotEmpty) ...[
                  const SizedBox(width: 10),
                  IconButton(
                    tooltip: l10n.saveSearchTooltip,
                    onPressed: _saveCurrentSearch,
                    icon: const Icon(
                      Icons.bookmark_add_outlined,
                      size: 20,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (_total != null && _items != null && !_searching)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                child: Text(
                  l10n.searchResultsTotal(_total!),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.45),
                  ),
                ),
              ),
            ),
          Expanded(child: _buildBody(context, l10n)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    if (_loadingSettings) {
      return const Center(
        child: SizedBox.square(
          dimension: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    // Hiçbir arama kaynağı yoksa (indexer da Easynews de hazır değilse)
    // yönlendirme görünümü; tek kaynak hazırken arama yapılabilir.
    if (!_indexerReady && _easynewsConfig == null) {
      return _IndexerMissing(onOpenSettings: _openSettings);
    }
    if (_searching) {
      return const Center(
        child: SizedBox.square(
          dimension: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error case final error?) {
      return _SearchError(error: error, onRetry: _search);
    }
    final items = _items;
    if (items == null) {
      // Henüz arama yapılmadı: geçmiş/kayıtlı aramalar varsa çip paneli,
      // yoksa klasik ipucu görünümü gösterilir.
      if (_recentQueries.isNotEmpty || _savedQueries.isNotEmpty) {
        return _HistoryPanel(
          recent: _recentQueries,
          saved: _savedQueries,
          onRunQuery: (query) => unawaited(_runQuery(query)),
          onRemoveSaved: (query) => unawaited(_removeSavedSearch(query)),
          onClearRecent: () => unawaited(_clearRecentSearches()),
        );
      }
      return _HintView(
        icon: Icons.travel_explore_rounded,
        message: l10n.searchEmptyHint,
      );
    }
    if (items.isEmpty) {
      return _HintView(
        icon: Icons.search_off_rounded,
        message: l10n.searchNoResults,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) => _SearchResultCard(
        item: items[index],
        busy: _busyIndex == index,
        enabled: _busyIndex == null,
        health: _healthStates[index],
        onCheckHealth: () => unawaited(_checkHealth(index)),
        focusNode: index == 0 ? _firstResultFocusNode : null,
        onTap: () => _downloadAndPlay(index),
      ),
    );
  }
}

/// Arama sonucu başına ön kontrol durumu.
sealed class _HealthState {}

/// NZB denetleniyor (rozet yeri küçük bir spinner taşır).
class _HealthChecking extends _HealthState {}

/// Denetim bitti; rozet raporuyla çizilir.
class _HealthDone extends _HealthState {
  _HealthDone(this.report);

  final NzbHealthDto report;
}

/// Denetim başarısız; bu kartta rozet gösterilmez.
class _HealthFailed extends _HealthState {}

/// Tek arama sonucu kartı: tür simgesi, başlık, rozetler ve sağda boyut/yaş.
///
/// [health] null ise ön kontrol rozeti çizilmez (sıra gelmedi ya da
/// sağlayıcı ayarı eksik); [_HealthChecking] küçük bir spinner gösterir;
/// [_HealthDone] renkli rozeti basar.
class _SearchResultCard extends StatefulWidget {
  const _SearchResultCard({
    required this.item,
    required this.busy,
    required this.enabled,
    required this.onTap,
    required this.onCheckHealth,
    this.health,
    this.focusNode,
  });

  final SearchItemDto item;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  /// Karttaki kontrol simgesi: elle sağlık denetimi başlatır.
  final VoidCallback onCheckHealth;

  /// Bu sonucun ön kontrol durumu; null = rozet yok.
  final _HealthState? health;

  /// İlk sonuç kartında kullanılır: arama bitince odak buraya taşınır.
  final FocusNode? focusNode;

  @override
  State<_SearchResultCard> createState() => _SearchResultCardState();
}

class _SearchResultCardState extends State<_SearchResultCard> {
  bool _focused = false;

  static IconData _mediaIcon(String mediaKind) => switch (mediaKind) {
    'movie' => Icons.movie_outlined,
    'tv' => Icons.tv_rounded,
    _ => Icons.insert_drive_file_outlined,
  };

  /// Ön kontrol rozetinin rengi/simgesi. Durum dizgileri Rust'ın
  /// `HealthStatus::as_str` değerleridir.
  static (Color, IconData, String) _healthVisual(
    NzbHealthDto report,
    AppLocalizations l10n,
  ) => switch (report.status) {
    'good' => (
      const Color(0xFF34A853),
      Icons.check_circle_outline_rounded,
      l10n.searchHealthGood,
    ),
    'repairable' => (
      const Color(0xFFB88A00),
      Icons.healing_rounded,
      l10n.searchHealthRepairable,
    ),
    'risky' => (
      const Color(0xFFDD7A1B),
      Icons.warning_amber_outlined,
      l10n.searchHealthRisky,
    ),
    _ => (
      const Color(0xFFDA3A2C),
      Icons.error_outline_rounded,
      l10n.searchHealthMissing,
    ),
  };

  /// Rozetin uzun basılabilir açıklaması: örnekleme, cilt ve PAR2 özeti.
  static String _healthTooltip(NzbHealthDto report, AppLocalizations l10n) {
    final lines = [
      l10n.searchHealthSampled(
        report.missingArticles,
        report.sampledArticles,
      ),
      if (report.volumeGaps > 0) l10n.searchHealthMissingVolumes,
      if (report.par2Present)
        l10n.searchHealthPar2Blocks(report.par2RecoveryBlocks)
      else if (report.status != 'good')
        l10n.searchHealthNoPar2,
    ];
    return lines.join('\n');
  }

  /// Renkli ön kontrol rozeti; rozet satırının ilk öğesidir.
  Widget _healthChip(BuildContext context, NzbHealthDto report) {
    final l10n = AppLocalizations.of(context);
    final (color, icon, label) = _healthVisual(report, l10n);
    return Tooltip(
      message: _healthTooltip(report, l10n),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Ön kontrol sürerken gösterilen minik spinner (etiketsiz).
  Widget _healthPendingChip(BuildContext context) {
    final foreground = Theme.of(context).colorScheme.onSurface;
    return SizedBox.square(
      dimension: 14,
      child: CircularProgressIndicator(
        strokeWidth: 1.6,
        color: foreground.withValues(alpha: 0.45),
      ),
    );
  }

  /// GB/MB biçiminde boyut; `null` ise boş döner (gösterilmez).
  static String _formatSize(BigInt sizeBytes) {
    final bytes = sizeBytes.toInt();
    const giga = 1024 * 1024 * 1024;
    const mega = 1024 * 1024;
    if (bytes >= giga) return '${(bytes / giga).toStringAsFixed(1)} GB';
    if (bytes >= mega) return '${(bytes / mega).round()} MB';
    return '<1 MB';
  }

  /// Yayın yaşını gün/ay/yıl kısaltmasıyla verir; `null` ise boş döner.
  static String _formatAge(int publishedEpochSecs, bool turkish) {
    final published = DateTime.fromMillisecondsSinceEpoch(
      publishedEpochSecs * 1000,
    );
    var days = DateTime.now().difference(published).inDays;
    if (days < 0) days = 0;
    if (days < 31) return turkish ? '$days g' : '${days}d';
    if (days < 365) {
      final months = days ~/ 30;
      return turkish ? '$months ay' : '${months}mo';
    }
    return '${days ~/ 365} y';
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final foreground = Theme.of(context).colorScheme.onSurface;
    final accent = Theme.of(context).colorScheme.primary;
    final isTurkish = Localizations.localeOf(context).languageCode == 'tr';
    final sizeText = item.sizeBytes == null ? null : _formatSize(item.sizeBytes!);
    final ageText = item.publishedEpochSecs == null
        ? null
        : _formatAge(item.publishedEpochSecs!.toInt(), isTurkish);
    return Material(
      color: foreground.withValues(alpha: _focused ? 0.08 : 0.035),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: _focused ? accent : foreground.withValues(alpha: 0.075),
          width: _focused ? 1.8 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.enabled ? widget.onTap : null,
        focusNode: widget.focusNode,
        hoverColor: foreground.withValues(alpha: 0.045),
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: foreground.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: widget.busy
                    ? Padding(
                        padding: const EdgeInsets.all(11),
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: foreground.withValues(alpha: 0.7),
                        ),
                      )
                    : Icon(
                        _mediaIcon(item.mediaKind),
                        size: 19,
                        color: foreground.withValues(alpha: 0.7),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        height: 1.25,
                      ),
                    ),
                    if (item.badges.isNotEmpty ||
                        widget.health != null) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 5,
                        runSpacing: 4,
                        children: [
                          switch (widget.health) {
                            _HealthDone(:final report) => _healthChip(
                              context,
                              report,
                            ),
                            _HealthChecking() => _healthPendingChip(context),
                            _ => const SizedBox.shrink(),
                          },
                          // Kaynak etiketi: Easynews sonuçlarında açık; indexer
                          // sonuçları (ana akım) etiketsiz kalır.
                          if (item.source == kSearchSourceEasynews)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: accent.withValues(alpha: 0.3),
                                ),
                              ),
                              child: Text(
                                'Easynews',
                                style: TextStyle(
                                  color: accent.withValues(alpha: 0.85),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ),
                          for (final badge in item.badges)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: foreground.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                badge,
                                style: TextStyle(
                                  color: foreground.withValues(alpha: 0.75),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Tooltip(
                    message: AppLocalizations.of(
                      context,
                    ).searchHealthCheckTooltip,
                    child: IconButton(
                      icon: Icon(
                        Icons.health_and_safety_outlined,
                        size: 18,
                        color: foreground.withValues(alpha: 0.55),
                      ),
                      onPressed: widget.enabled &&
                              widget.health is! _HealthChecking
                          ? widget.onCheckHealth
                          : null,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  if (sizeText != null)
                    Text(
                      sizeText,
                      style: TextStyle(
                        color: foreground.withValues(alpha: 0.6),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  if (ageText != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        ageText,
                        style: TextStyle(
                          color: foreground.withValues(alpha: 0.38),
                          fontSize: 11,
                        ),
                      ),
                    ),
                  if (item.year != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '${item.year}',
                        style: TextStyle(
                          color: foreground.withValues(alpha: 0.38),
                          fontSize: 11,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Indexer ayarları eksikken gösterilen yönlendirme görünümü.
class _IndexerMissing extends StatelessWidget {
  const _IndexerMissing({required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final foreground = Theme.of(context).colorScheme.onSurface;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.travel_explore_rounded,
                size: 32,
                color: foreground.withValues(alpha: 0.54),
              ),
              const SizedBox(height: 14),
              Text(
                l10n.indexerMissingHint,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: foreground.withValues(alpha: 0.7),
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: onOpenSettings,
                icon: const Icon(Icons.settings_outlined, size: 18),
                label: Text(l10n.goToIndexerSettings),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Arama hatası; oynatıcıdaki _ErrorView tarzının sade hâli.
class _SearchError extends StatelessWidget {
  const _SearchError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final foreground = Theme.of(context).colorScheme.onSurface;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 40,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 12),
              Text(
                '$error',
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: foreground.withValues(alpha: 0.7),
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(l10n.retry),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Boş durum ipucu görünümü (henüz arama yapılmadı / sonuç yok).
class _HintView extends StatelessWidget {  const _HintView({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final foreground = Theme.of(context).colorScheme.onSurface;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 30, color: foreground.withValues(alpha: 0.3)),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: foreground.withValues(alpha: 0.38),
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Son aramalar / kayıtlı aramalar çip paneli (roadmap #9). Arama yapılmadan
/// önce gösterilir; çipe dokununca sorgu alana yazılıp doğrudan aranır.
///
/// TV/D-pad: çipler odaklanabilir; kayıtlı aramanın kaldırma düğmesi çipin
/// içinde ayrı bir odaklanabilir öğedir.
class _HistoryPanel extends StatelessWidget {
  const _HistoryPanel({
    required this.recent,
    required this.saved,
    required this.onRunQuery,
    required this.onRemoveSaved,
    required this.onClearRecent,
  });

  final List<String> recent;
  final List<String> saved;
  final ValueChanged<String> onRunQuery;
  final ValueChanged<String> onRemoveSaved;
  final VoidCallback onClearRecent;

  Widget _section({
    required BuildContext context,
    required String title,
    required List<String> queries,
    required ValueChanged<String> onRun,
    VoidCallback? onClear,
    ValueChanged<String>? onRemove,
  }) {
    final l10n = AppLocalizations.of(context);
    final foreground = Theme.of(context).colorScheme.onSurface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: foreground.withValues(alpha: 0.5),
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              if (onClear != null)
                IconButton(
                  tooltip: l10n.searchClearRecentTooltip,
                  icon: Icon(
                    Icons.clear_all_rounded,
                    size: 18,
                    color: foreground.withValues(alpha: 0.5),
                  ),
                  onPressed: onClear,
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final query in queries)
                _QueryChip(
                  label: query,
                  onTap: () => onRun(query),
                  onRemove: onRemove == null ? null : () => onRemove(query),
                ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (recent.isNotEmpty)
          _section(
            context: context,
            title: l10n.searchRecentTitle,
            queries: recent,
            onRun: onRunQuery,
            onClear: onClearRecent,
          ),
        if (saved.isNotEmpty)
          _section(
            context: context,
            title: l10n.searchSavedTitle,
            queries: saved,
            onRun: onRunQuery,
            onRemove: onRemoveSaved,
          ),
      ],
    );
  }
}

/// Tek sorgu çipi: gövdeye dokununca arama; [onRemove] verilirse sağda küçük
/// bir kaldırma düğmesi taşır (yalnız kayıtlı aramalarda).
class _QueryChip extends StatelessWidget {
  const _QueryChip({
    required this.label,
    required this.onTap,
    this.onRemove,
  });

  final String label;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final foreground = Theme.of(context).colorScheme.onSurface;
    final accent = Theme.of(context).colorScheme.primary;
    final bookmarked = onRemove != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: 0.045),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: foreground.withValues(alpha: 0.09)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(999),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    bookmarked
                        ? Icons.bookmark_rounded
                        : Icons.history_rounded,
                    size: 13,
                    color: (bookmarked ? accent : foreground)
                        .withValues(alpha: 0.6),
                  ),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 240),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: foreground.withValues(alpha: 0.85),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (bookmarked) ...[
            const SizedBox(width: 2),
            SizedBox.square(
              dimension: 26,
              child: IconButton(
                padding: EdgeInsets.zero,
                iconSize: 13,
                tooltip: AppLocalizations.of(
                  context,
                ).removeSavedSearchTooltip,
                icon: Icon(
                  Icons.close_rounded,
                  color: foreground.withValues(alpha: 0.5),
                ),
                onPressed: onRemove,
              ),
            ),
            const SizedBox(width: 2),
          ],
        ],
      ),
    );
  }
}
