import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/search.dart';
import '../tv_focus.dart';
import 'indexer_settings.dart';
import 'opensubtitles_settings.dart';
import 'provider_settings.dart';
import 'ui_preferences.dart';

/// FRB `newznabCheckCaps` imzası; testlerde sahte enjekte edilebilir.
typedef NewznabCapsFn =
    Future<IndexerCapsDto> Function(IndexerConfigDto config);

/// Sağlayıcı (NNTP) kimlik bilgileri için ayar ekranı.
///
/// Değerler OS secure storage'a yazılır; ekran açılışında oradan okunur.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.store,
    this.uiPreferences,
    this.indexerStore,
    this.capsFn,
    this.osStore,
  });

  /// Testlerde sahte depo enjekte edebilmek için; null ise gerçek depo kullanılır.
  final ProviderSettingsStore? store;

  /// Dil/görünüm seçicileri için; null ise "Uygulama" bölümü gösterilmez.
  final UiPreferencesController? uiPreferences;

  /// Indexer (Newznab) ayarları için; null ise gerçek depo kullanılır.
  final IndexerSettingsStore? indexerStore;

  /// "Bağlantıyı sına" düğmesinin çağırdığı caps sorgusu; null ise FRB
  /// `newznabCheckCaps` kullanılır.
  final NewznabCapsFn? capsFn;

  /// OpenSubtitles (altyazı arama) ayarları için; null ise gerçek depo
  /// kullanılır.
  final OpenSubtitlesSettingsStore? osStore;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  late final ProviderSettingsStore _store =
      widget.store ?? ProviderSettingsStore();
  late final IndexerSettingsStore _indexerStore =
      widget.indexerStore ?? IndexerSettingsStore();
  late final OpenSubtitlesSettingsStore _osStore =
      widget.osStore ?? OpenSubtitlesSettingsStore();
  late final NewznabCapsFn _capsFn =
      widget.capsFn ?? (config) => newznabCheckCaps(config: config);

  final _formKey = GlobalKey<FormState>();
  final _hostController = TextEditingController();
  final _portController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _maxConnectionsController = TextEditingController();

  // Indexer bölümü NNTP formundan bağımsızdır: ayrı Form, ayrı kaydet düğmesi.
  final _indexerFormKey = GlobalKey<FormState>();
  final _indexerUrlController = TextEditingController();
  final _indexerApiKeyController = TextEditingController();

  // Çoklu NNTP hesabı (profil): ayarlar ekranı hesap listesini yönetir,
  // kaydedilen hesap akışta kullanılan aktif hesap olur.
  static const _newAccountSentinel = '__yeni__';

  /// Kayıtlı NNTP hesapları; liste boşsa eski tek-hesap anahtarlarından
  /// otomatik göçle doldurulur.
  List<ProviderProfile> _providerProfiles = const [];

  /// Şu anda düzenlenmekte olan hesap; null = "yeni hesap" kipi.
  String? _editingProviderId;
  final _providerLabelController = TextEditingController();

  // Çoklu indexer (profil): arama açık hesapların tamamını sorgular.
  /// Kayıtlı indexer hesapları.
  List<IndexerProfile> _indexerProfiles = const [];

  /// Şu anda düzenlenmekte olan indexer; null = "yeni indexer" kipi.
  String? _editingIndexerId;
  final _indexerLabelController = TextEditingController();

  /// Düzenlenen indexer aramalara katılıyor mu.
  bool _indexerJoinSearches = true;

  // OpenSubtitles bölümü de kendi Form'unu taşır (API anahtarı + hesap).
  final _osFormKey = GlobalKey<FormState>();
  final _osUrlController = TextEditingController();
  final _osApiKeyController = TextEditingController();
  final _osUsernameController = TextEditingController();
  final _osPasswordController = TextEditingController();

  // TV kumandasında yukarı/aşağı oklar alandan çıkabilsin diye D-pad
  // gezintili odak düğümleri (issue #4). Parola/API anahtarı alanlarının
  // göz simgeleri `skipTraversal` ile yön gezintisinden çıkarılmıştır —
  // aksi halde aşağı ok bir üst alandan inerken alanı atlayıp simgeye
  // düşüyordu (simge dikeyde alanın metin bölgesinden daha yüksekte).
  // Simgelere yalnızca alanın metin sonundan sağ okla geçilir.
  late final _hostFocusNode = dpadTraversalFocusNode(_hostController);
  late final _portFocusNode = dpadTraversalFocusNode(_portController);
  late final _maxConnectionsFocusNode = dpadTraversalFocusNode(
    _maxConnectionsController,
  );
  late final _usernameFocusNode = dpadTraversalFocusNode(_usernameController);
  late final FocusNode _passwordFocusNode = dpadTraversalFocusNode(
    _passwordController,
    focusOnRightEdge: () => _passwordEyeFocusNode,
  );
  late final FocusNode _passwordEyeFocusNode = dpadFieldActionFocusNode(
    controller: _passwordController,
    fieldNode: _passwordFocusNode,
  );
  late final _indexerUrlFocusNode = dpadTraversalFocusNode(
    _indexerUrlController,
  );
  late final _providerLabelFocusNode = dpadTraversalFocusNode(
    _providerLabelController,
  );
  late final _indexerLabelFocusNode = dpadTraversalFocusNode(
    _indexerLabelController,
  );
  final _providerDeleteFocusNode = FocusNode();
  final _indexerDeleteFocusNode = FocusNode();
  late final FocusNode _indexerApiKeyFocusNode = dpadTraversalFocusNode(
    _indexerApiKeyController,
    focusOnRightEdge: () => _indexerApiKeyEyeFocusNode,
  );
  late final FocusNode _indexerApiKeyEyeFocusNode = dpadFieldActionFocusNode(
    controller: _indexerApiKeyController,
    fieldNode: _indexerApiKeyFocusNode,
  );
  // OpenSubtitles alanları: indexer bölümüyle aynı D-pad düzeni.
  late final _osUrlFocusNode = dpadTraversalFocusNode(_osUrlController);
  late final FocusNode _osApiKeyFocusNode = dpadTraversalFocusNode(
    _osApiKeyController,
    focusOnRightEdge: () => _osApiKeyEyeFocusNode,
  );
  late final FocusNode _osApiKeyEyeFocusNode = dpadFieldActionFocusNode(
    controller: _osApiKeyController,
    fieldNode: _osApiKeyFocusNode,
  );
  late final _osUsernameFocusNode = dpadTraversalFocusNode(
    _osUsernameController,
  );
  late final FocusNode _osPasswordFocusNode = dpadTraversalFocusNode(
    _osPasswordController,
    focusOnRightEdge: () => _osPasswordEyeFocusNode,
  );
  late final FocusNode _osPasswordEyeFocusNode = dpadFieldActionFocusNode(
    controller: _osPasswordController,
    fieldNode: _osPasswordFocusNode,
  );

  bool _loading = true;
  bool _saving = false;
  bool _obscurePassword = true;
  bool _savingIndexer = false;
  bool _testingIndexer = false;
  bool _obscureApiKey = true;
  bool _savingOpenSubtitles = false;
  bool _obscureOsApiKey = true;
  bool _obscureOsPassword = true;
  /// Dil tercihleri (arama diyalogundaki çipler) kaydetmede korunur.
  List<String> _osLanguages = OpenSubtitlesSettings.defaultLanguages;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _loadIndexer();
    _loadOpenSubtitles();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && mounted) {
      if (!_obscurePassword || !_obscureApiKey) {
        setState(() {
          _obscurePassword = true;
          _obscureApiKey = true;
        });
      }
      if (!_obscureOsApiKey || !_obscureOsPassword) {
        setState(() {
          _obscureOsApiKey = true;
          _obscureOsPassword = true;
        });
      }
    }
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      final profiles = await _store.loadProfiles();
      final active = profiles.isEmpty
          ? null
          : await _store.activeProfileOf(profiles);
      if (!mounted) return;
      setState(() {
        _providerProfiles = profiles;
        _editingProviderId = active?.id;
        _fillProviderForm(active);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error;
        _loading = false;
      });
    }
  }

  /// Seçili hesabın alanlarını forma doldurur; null gelenektir yeni hesap
  /// kipidir (boş alanlar).
  void _fillProviderForm(ProviderProfile? profile) {
    _providerLabelController.text = profile?.label ?? '';
    _hostController.text = profile?.host ?? '';
    _portController.text = (profile?.port ?? 563).toString();
    _usernameController.text = profile?.username ?? '';
    _passwordController.text = profile?.password ?? '';
    _maxConnectionsController.text =
        (profile?.maxConnections ?? 10).toString();
  }

  /// Hesap seçici değişince düzenlenecek hesap forma yüklenir; "yeni hesap"
  /// girdisi alanları boşaltır. Kaydet basılmadan depo değişmez.
  void _onProviderAccountChanged(String? value) {
    if (value == null) return;
    if (value == _newAccountSentinel) {
      setState(() {
        _editingProviderId = null;
        _fillProviderForm(null);
      });
      return;
    }
    final match = _providerProfiles
        .where((profile) => profile.id == value)
        .toList(growable: false);
    if (match.isEmpty) return;
    setState(() {
      _editingProviderId = value;
      _fillProviderForm(match.first);
    });
  }

  /// Depodan profil listesini yeniden çeker ve seçiciyi günceller.
  Future<void> _refreshProviderProfiles({String? editingId}) async {
    final profiles = await _store.loadProfiles();
    if (!mounted) return;
    setState(() {
      _providerProfiles = profiles;
      _editingProviderId = editingId;
    });
  }

  Future<void> _deleteProviderAccount() async {
    final id = _editingProviderId;
    if (id == null || _saving || _providerProfiles.isEmpty) return;
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.settingsAccountDeleteTitle),
        content: Text(l10n.settingsAccountDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.settingsAccountDeleteCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.settingsAccountDeleteConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _store.deleteProfile(id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).settingsSaveFailed('$e')),
        ),
      );
      return;
    }
    final profiles = await _store.loadProfiles();
    if (!mounted) return;
    final active = profiles.isEmpty
        ? null
        : await _store.activeProfileOf(profiles);
    if (!mounted) return;
    setState(() {
      _providerProfiles = profiles;
      _editingProviderId = active?.id;
      _fillProviderForm(active);
    });
  }

  /// Indexer okuması NNTP'den bağımsızdır: depo okunamazsa (veya hiç
  /// tamamlanamazsa) NNTP formu kilitlenmesin, indexer alanları boş kalsın.
  Future<void> _loadIndexer() async {
    try {
      final profiles = await _indexerStore.loadProfiles();
      if (!mounted) return;
      final editing = profiles.isEmpty
          ? null
          : profiles.firstWhere(
              (profile) => profile.searchable,
              orElse: () => profiles.first,
            );
      setState(() {
        _indexerProfiles = profiles;
        _editingIndexerId = editing?.id;
        _fillIndexerForm(editing);
      });
    } catch (_) {}
  }

  /// Seçili indexer'ın alanlarını forma doldurur; null yeni-indexer kipidir.
  void _fillIndexerForm(IndexerProfile? profile) {
    _indexerLabelController.text = profile?.label ?? '';
    _indexerUrlController.text = profile?.baseUrl ?? '';
    _indexerApiKeyController.text = profile?.apiKey ?? '';
    _indexerJoinSearches = profile?.enabled ?? true;
  }

  void _onIndexerAccountChanged(String? value) {
    if (value == null) return;
    if (value == _newAccountSentinel) {
      setState(() {
        _editingIndexerId = null;
        _fillIndexerForm(null);
      });
      return;
    }
    final match = _indexerProfiles
        .where((profile) => profile.id == value)
        .toList(growable: false);
    if (match.isEmpty) return;
    setState(() {
      _editingIndexerId = value;
      _fillIndexerForm(match.first);
    });
  }

  Future<void> _deleteIndexerAccount() async {
    final id = _editingIndexerId;
    if (id == null || _indexerProfiles.isEmpty) return;
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.settingsAccountDeleteTitle),
        content: Text(l10n.settingsAccountDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.settingsAccountDeleteCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.settingsAccountDeleteConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _indexerStore.deleteProfile(id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).settingsSaveFailed('$e')),
        ),
      );
      return;
    }
    final profiles = await _indexerStore.loadProfiles();
    if (!mounted) return;
    setState(() {
      _indexerProfiles = profiles;
      _editingIndexerId = profiles.isEmpty
          ? null
          : (profiles.firstWhere(
              (profile) => profile.searchable,
              orElse: () => profiles.first,
            )).id;
      _fillIndexerForm(
        profiles.isEmpty
            ? null
            : profiles.firstWhere(
                (profile) => profile.id == _editingIndexerId,
                orElse: () => profiles.first,
              ),
      );
    });
  }

  Future<void> _saveIndexer() async {
    if (_savingIndexer) return;
    if (!_indexerFormKey.currentState!.validate()) return;
    setState(() {
      _savingIndexer = true;
      _obscureApiKey = true;
    });
    var saved = false;
    // Yeni-indexer kipinde kayıt yeni kimlikle oluşturulur.
    final id = _editingIndexerId ?? IndexerProfile.newId();
    try {
      await _indexerStore.saveProfile(
        IndexerProfile(
          id: id,
          label: _indexerLabelController.text.trim(),
          baseUrl: _indexerUrlController.text.trim(),
          apiKey: _indexerApiKeyController.text.trim(),
          enabled: _indexerJoinSearches,
        ),
      );
      saved = true;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).settingsSaveFailed('$e')),
        ),
      );
    } finally {
      if (mounted) setState(() => _savingIndexer = false);
    }
    if (!mounted || !saved) return;
    try {
      final profiles = await _indexerStore.loadProfiles();
      if (mounted) {
        setState(() {
          _indexerProfiles = profiles;
          _editingIndexerId = id;
        });
      }
    } catch (_) {}
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).settingsSaved)),
    );
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _obscurePassword = true;
    });
    var saved = false;
    // Yeni hesap kipinde (seçici "yeni" girdisinde) kayıt yeni kimlikle
    // oluşturulur; kaydet aynı zamanda bu hesabı aktif yapar.
    final id = _editingProviderId ?? ProviderProfile.newId();
    try {
      await _store.saveProfile(
        ProviderProfile(
          id: id,
          label: _providerLabelController.text.trim(),
          host: _hostController.text.trim(),
          port: int.parse(_portController.text.trim()),
          username: _usernameController.text.trim(),
          password: _passwordController.text,
          maxConnections: int.parse(_maxConnectionsController.text.trim()),
        ),
      );
      saved = true;
    } catch (e) {
      // Keychain yazımı başarısızsa (ör. entitlement eksik) uygulamayı
      // düşürmeden kullanıcıya bildir.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).settingsSaveFailed('$e')),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (!mounted || !saved) return;
    try {
      await _refreshProviderProfiles(editingId: id);
    } catch (_) {
      // Liste yenilenemezse kayıt yine geçerlidir; seçici eski kalır.
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).settingsSaved)),
    );
  }

  Future<void> _loadOpenSubtitles() async {
    // Indexer bölümüyle aynı desen: widget testlerinde secure storage hiç
    // hata vermeden askıda kalabilir; herhangi bir koşulda bölüm varsayılan
    // (boş) alanlarla sessizce açılır. Zamanlayıcı kullanılmaz — test
    // sonunda bekleyen Timer kalmaz.
    try {
      final settings = await _osStore.load();
      if (!mounted) return;
      setState(() {
        _osUrlController.text = settings.baseUrl;
        _osApiKeyController.text = settings.apiKey;
        _osUsernameController.text = settings.username;
        _osPasswordController.text = settings.password;
        _osLanguages = settings.languages;
      });
    } catch (_) {
      // Depo okunamıyorsa bölüm boş formlarla açılır.
    }
  }

  /// OpenSubtitles bölümünü kaydeder. Dil tercihleri arama diyalogundan
  /// yönetilir; burada korunarak geri yazılır (ezilmesin).
  Future<void> _saveOpenSubtitles() async {
    if (_savingOpenSubtitles) return;
    if (!_osFormKey.currentState!.validate()) return;
    setState(() {
      _savingOpenSubtitles = true;
      _obscureOsApiKey = true;
      _obscureOsPassword = true;
    });
    var saved = false;
    try {
      await _osStore.save(
        OpenSubtitlesSettings(
          baseUrl: _osUrlController.text.trim(),
          apiKey: _osApiKeyController.text.trim(),
          username: _osUsernameController.text.trim(),
          password: _osPasswordController.text,
          languages: _osLanguages,
        ),
      );
      saved = true;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).settingsSaveFailed('$e')),
        ),
      );
    } finally {
      if (mounted) setState(() => _savingOpenSubtitles = false);
    }
    if (!mounted || !saved) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).settingsSaved)),
    );
  }

  /// URL opsiyoneldir (motor varsayılanı kullanılır); girildiyse http(s)
  /// ile başlamalıdır.
  String? _validateOpenSubtitlesUrl(String? value) {
    final url = value?.trim() ?? '';
    if (url.isEmpty) return null;
    final uri = Uri.tryParse(url);
    final valid =
        (uri?.scheme == 'http' || uri?.scheme == 'https') &&
        (uri?.host.isNotEmpty ?? false);
    if (!valid) {
      return AppLocalizations.of(context).indexerUrlInvalid;
    }
    return null;
  }

  /// Ayarlar ekranındaki OpenSubtitles bölümü: kök adres, API anahtarı,
  /// kullanıcı adı/parola (indirme kotası için opsiyonel hesap) ve kaydet
  /// düğmesi. Indexer bölümüyle aynı D-pad kolaylaştırma desenini taşır.
  Widget _buildOpenSubtitlesSection(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 30),
        Text(
          l10n.settingsOsSectionTitle,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.35,
          ),
        ),
        const SizedBox(height: 7),
        Text(
          l10n.settingsOsSectionSubtitle,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.45),
            height: 1.4,
          ),
        ),
        const SizedBox(height: 24),
        // OpenSubtitles bölümü de kendi Form'unu taşır: bağımsız doğrulama
        // + bağımsız kaydet (indexer deseni).
        Form(
          key: _osFormKey,
          child: Column(
            children: [
              _SettingsCard(
                children: [
                  TextFormField(
                    controller: _osUrlController,
                    focusNode: _osUrlFocusNode,
                    decoration: InputDecoration(
                      labelText: l10n.settingsOsUrlLabel,
                      hintText: 'https://api.opensubtitles.com',
                      prefixIcon: const Icon(Icons.public_rounded, size: 19),
                    ),
                    textInputAction: TextInputAction.next,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    validator: _validateOpenSubtitlesUrl,
                  ),
                  const SizedBox(height: 12),
                  // Göz düğmesi skipTraversal'lı: indexer bölümüyle aynı
                  // D-pad deseni (issue #4).
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _osApiKeyController,
                          focusNode: _osApiKeyFocusNode,
                          obscureText: _obscureOsApiKey,
                          enableSuggestions: false,
                          autocorrect: false,
                          onFieldSubmitted: (_) => _saveOpenSubtitles(),
                          decoration: InputDecoration(
                            labelText: l10n.settingsOsApiKeyLabel,
                            prefixIcon: const Icon(Icons.key_rounded, size: 19),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        focusNode: _osApiKeyEyeFocusNode,
                        tooltip: _obscureOsApiKey
                            ? l10n.passwordShowTooltip
                            : l10n.passwordHideTooltip,
                        icon: Icon(
                          _obscureOsApiKey
                              ? Icons.visibility_rounded
                              : Icons.visibility_off_rounded,
                          size: 18,
                        ),
                        onPressed: () => setState(
                          () => _obscureOsApiKey = !_obscureOsApiKey,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _osUsernameController,
                    focusNode: _osUsernameFocusNode,
                    enableSuggestions: false,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: l10n.settingsOsUsernameLabel,
                      prefixIcon: const Icon(
                        Icons.person_outline_rounded,
                        size: 19,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _osPasswordController,
                          focusNode: _osPasswordFocusNode,
                          obscureText: _obscureOsPassword,
                          enableSuggestions: false,
                          autocorrect: false,
                          onFieldSubmitted: (_) => _saveOpenSubtitles(),
                          decoration: InputDecoration(
                            labelText: l10n.settingsOsPasswordLabel,
                            prefixIcon: const Icon(
                              Icons.lock_outline_rounded,
                              size: 19,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        focusNode: _osPasswordEyeFocusNode,
                        tooltip: _obscureOsPassword
                            ? l10n.passwordShowTooltip
                            : l10n.passwordHideTooltip,
                        icon: Icon(
                          _obscureOsPassword
                              ? Icons.visibility_rounded
                              : Icons.visibility_off_rounded,
                          size: 18,
                        ),
                        onPressed: () => setState(
                          () => _obscureOsPassword = !_obscureOsPassword,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 22),
              // Kaydet düğmesi dikey zincirde tek başına: TV kumandasında
              // yukarı/aşağı hatasız iner (issue #4).
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _savingOpenSubtitles
                      ? null
                      : _saveOpenSubtitles,
                  icon: _savingOpenSubtitles
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 1.8),
                        )
                      : const Icon(Icons.check_rounded, size: 18),
                  label: Text(
                    _savingOpenSubtitles
                        ? l10n.savingLabel
                        : l10n.settingsOsSaveLabel,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Formdaki güncel değerlerle `?t=caps` sorgusu atar; sonucu SnackBar'da
  /// gösterir. API anahtarı hiçbir yere yazılmaz/loglanmaz.
  Future<void> _testIndexer() async {
    if (_testingIndexer) return;
    if (!_indexerFormKey.currentState!.validate()) return;
    final l10n = AppLocalizations.of(context);
    final baseUrl = _indexerUrlController.text.trim();
    final apiKey = _indexerApiKeyController.text.trim();
    if (baseUrl.isEmpty || apiKey.isEmpty) {
      // Boş URL indexer kapalı demektir; sınanacak bir bağlantı yok.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.indexerMissingHint)),
      );
      return;
    }
    setState(() => _testingIndexer = true);
    try {
      final caps = await _capsFn(
        IndexerConfigDto(
          // Caps sınaması formdaki (düzenlenen) hesapla yapılır.
          id: _editingIndexerId ?? '',
          baseUrl: baseUrl,
          apiKey: apiKey,
        ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.indexerTestSuccess(caps.serverTitle ?? baseUrl)),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.indexerTestFailed('$error'))),
      );
    } finally {
      if (mounted) setState(() => _testingIndexer = false);
    }
  }

  /// Boş URL geçerlidir (indexer kapalı); doluysa http(s) URL'si olmalı.
  String? _validateIndexerUrl(String? value) {
    final l10n = AppLocalizations.of(context);
    final url = value?.trim() ?? '';
    if (url.isEmpty) return null;
    if (url.contains(RegExp(r'\s'))) return l10n.indexerUrlInvalid;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !(uri.isScheme('http') || uri.isScheme('https')) ||
        uri.host.isEmpty) {
      return l10n.indexerUrlInvalid;
    }
    return null;
  }

  /// URL doluyken API anahtarı zorunludur.
  String? _validateIndexerApiKey(String? value) {
    final url = _indexerUrlController.text.trim();
    if (url.isNotEmpty) {
      return _required(value, AppLocalizations.of(context).indexerApiKeyLabel);
    }
    return null;
  }

  String? _validateIntegerRange(
    String? value,
    String fieldName,
    int minimum,
    int maximum,
  ) {
    final parsed = int.tryParse(value?.trim() ?? '');
    if (parsed == null || parsed < minimum || parsed > maximum) {
      return AppLocalizations.of(
        context,
      ).validationIntegerRange(fieldName, minimum, maximum);
    }
    return null;
  }

  String? _required(String? value, String fieldName) =>
      value == null || value.trim().isEmpty
          ? AppLocalizations.of(context).validationRequired(fieldName)
          : null;

  String? _validateHost(String? value) {
    final l10n = AppLocalizations.of(context);
    final host = value?.trim() ?? '';
    if (host.isEmpty) return l10n.validationRequired(l10n.serverAddressLabel);
    if (host.length > 253 ||
        host.contains(RegExp(r'\s')) ||
        host.contains('://') ||
        host.contains(RegExp(r'[/@?#:]'))) {
      return l10n.validationHostNoProtocol;
    }
    final hostname = RegExp(
      r'^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)'
      r'(?:\.(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?))*\.?$',
    );
    if (!hostname.hasMatch(host)) return l10n.validationHostInvalid;
    return null;
  }

  Widget _portField() => TextFormField(
    controller: _portController,
    focusNode: _portFocusNode,
    decoration: InputDecoration(
      labelText: AppLocalizations.of(context).portLabel,
      hintText: '563',
    ),
    textInputAction: TextInputAction.next,
    keyboardType: TextInputType.number,
    validator: (value) => _validateIntegerRange(
      value,
      AppLocalizations.of(context).portLabel,
      1,
      65535,
    ),
  );

  Widget _connectionField() => TextFormField(
    controller: _maxConnectionsController,
    focusNode: _maxConnectionsFocusNode,
    decoration: InputDecoration(
      labelText: AppLocalizations.of(context).connectionLimitLabel,
      hintText: AppLocalizations.of(context).connectionLimitHint,
    ),
    textInputAction: TextInputAction.next,
    keyboardType: TextInputType.number,
    validator: (value) => _validateIntegerRange(
      value,
      AppLocalizations.of(context).connectionLimitLabel,
      1,
      60,
    ),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController
      ..clear()
      ..dispose();
    _maxConnectionsController.dispose();
    _indexerUrlController.dispose();
    _indexerApiKeyController
      ..clear()
      ..dispose();
    _providerLabelController.dispose();
    _indexerLabelController.dispose();
    _hostFocusNode.dispose();
    _portFocusNode.dispose();
    _maxConnectionsFocusNode.dispose();
    _usernameFocusNode.dispose();
    _passwordFocusNode.dispose();
    _passwordEyeFocusNode.dispose();
    _indexerUrlFocusNode.dispose();
    _indexerApiKeyFocusNode.dispose();
    _indexerApiKeyEyeFocusNode.dispose();
    _providerLabelFocusNode.dispose();
    _indexerLabelFocusNode.dispose();
    _providerDeleteFocusNode.dispose();
    _indexerDeleteFocusNode.dispose();
    super.dispose();
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
          l10n.providerTitle,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      body: _loading
          ? const Center(
              child: SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : _loadError != null
          ? _SettingsLoadError(error: _loadError!, onRetry: _load)
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: Form(
                  key: _formKey,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(24, 18, 24, 32),
                    children: [
                      if (widget.uiPreferences case final prefs?) ...[
                        Text(
                          l10n.appSectionTitle,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.35,
                              ),
                        ),
                        const SizedBox(height: 7),
                        Text(
                          l10n.appSectionSubtitle,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: 0.45),
                                height: 1.4,
                              ),
                        ),
                        const SizedBox(height: 24),
                        _SettingsCard(
                          children: [
                            DropdownButtonFormField<Locale>(
                              initialValue: prefs.locale,
                              // TV kumandasında D-pad gezintisi bu ilk
                              // kontrolden başlar (metin alanı olmadığı için
                              // girişte ekran klavyesi açılmaz).
                              autofocus: true,
                              decoration: InputDecoration(
                                labelText: l10n.languageLabel,
                                prefixIcon: const Icon(
                                  Icons.language_rounded,
                                  size: 19,
                                ),
                              ),
                              items: [
                                for (final (locale, name)
                                    in supportedAppLocales)
                                  DropdownMenuItem(
                                    value: locale,
                                    child: Text(name),
                                  ),
                              ],
                              onChanged: (locale) {
                                if (locale != null) {
                                  prefs.setLocale(locale);
                                }
                              },
                            ),
                            const SizedBox(height: 16),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                l10n.themeLabel,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.55),
                                    ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: SegmentedButton<ThemeMode>(
                                showSelectedIcon: false,
                                segments: [
                                  ButtonSegment(
                                    value: ThemeMode.dark,
                                    icon: const Icon(
                                      Icons.dark_mode_rounded,
                                      size: 17,
                                    ),
                                    label: Text(l10n.themeDark),
                                  ),
                                  ButtonSegment(
                                    value: ThemeMode.light,
                                    icon: const Icon(
                                      Icons.light_mode_rounded,
                                      size: 17,
                                    ),
                                    label: Text(l10n.themeLight),
                                  ),
                                ],
                                selected: {prefs.themeMode},
                                onSelectionChanged: (selection) =>
                                    prefs.setThemeMode(selection.first),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                      ],
                      Text(
                        l10n.nntpSectionTitle,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.35,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        l10n.nntpSectionSubtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.45),
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 24),
                      // Hesap seçici: çoklu NNTP hesabı arasında gezinme,
                      // ekleme ve silme. Kaydedilen hesap akışta kullanılır.
                      _SettingsCard(
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  // Uygulama bölümü yoksa D-pad gezintisi bu
                                  // ilk kontrolden başlar.
                                  autofocus: widget.uiPreferences == null,
                                  initialValue:
                                      _editingProviderId ??
                                      _newAccountSentinel,
                                  decoration: InputDecoration(
                                    labelText: l10n.settingsAccountLabel,
                                    prefixIcon: const Icon(
                                      Icons.account_circle_outlined,
                                      size: 19,
                                    ),
                                  ),
                                  items: [
                                    for (final profile
                                        in _providerProfiles)
                                      DropdownMenuItem(
                                        value: profile.id,
                                        child: Text(profile.displayName),
                                      ),
                                    DropdownMenuItem(
                                      value: _newAccountSentinel,
                                      child: Text(l10n.settingsAccountNew),
                                    ),
                                  ],
                                  onChanged: _onProviderAccountChanged,
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                focusNode: _providerDeleteFocusNode,
                                tooltip: l10n.settingsAccountDeleteTooltip,
                                icon: const Icon(
                                  Icons.person_remove_outlined,
                                  size: 18,
                                ),
                                // Yeni-hesap kipinde silinecek kayıt yok.
                                onPressed:
                                    _editingProviderId == null ||
                                        _providerProfiles.isEmpty
                                    ? null
                                    : _deleteProviderAccount,
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            l10n.settingsAccountSaveHint,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface.withValues(
                                    alpha: 0.45,
                                  ),
                                  height: 1.4,
                                ),
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _providerLabelController,
                            focusNode: _providerLabelFocusNode,
                            decoration: InputDecoration(
                              labelText: l10n.settingsAccountNameLabel,
                              prefixIcon: const Icon(
                                Icons.label_outline_rounded,
                                size: 19,
                              ),
                            ),
                            textInputAction: TextInputAction.next,
                            autocorrect: false,
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _SettingsCard(
                        children: [
                          TextFormField(
                            controller: _hostController,
                            focusNode: _hostFocusNode,
                            decoration: InputDecoration(
                              labelText: l10n.serverAddressLabel,
                              hintText: 'news.example.com',
                              prefixIcon: const Icon(Icons.dns_rounded, size: 19),
                            ),
                            textInputAction: TextInputAction.next,
                            keyboardType: TextInputType.url,
                            autocorrect: false,
                            validator: _validateHost,
                          ),
                          const SizedBox(height: 12),
                          LayoutBuilder(
                            builder: (context, constraints) {
                              if (constraints.maxWidth < 440) {
                                return Column(
                                  children: [
                                    _portField(),
                                    const SizedBox(height: 12),
                                    _connectionField(),
                                  ],
                                );
                              }
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(child: _portField()),
                                  const SizedBox(width: 12),
                                  Expanded(child: _connectionField()),
                                ],
                              );
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _SettingsCard(
                        children: [
                          TextFormField(
                            controller: _usernameController,
                            focusNode: _usernameFocusNode,
                            decoration: InputDecoration(
                              labelText: l10n.usernameLabel,
                              prefixIcon: const Icon(
                                Icons.person_outline_rounded,
                                size: 19,
                              ),
                            ),
                            autofillHints: const [AutofillHints.username],
                            textInputAction: TextInputAction.next,
                            autocorrect: false,
                            validator: (value) =>
                                _required(value, l10n.usernameLabel),
                          ),
                          const SizedBox(height: 12),
                          // Göz düğmesi alanın İÇİNDE değil yanında durur ve
                          // skipTraversal ile yön gezintisi adaylığından
                          // çıkarılmıştır: aşağı ok bu satıra inerken her
                          // zaman alanı seçer; simgeye yalnızca alanın metin
                          // sonundan sağ okla geçilir (issue #4).
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: TextFormField(
                                  controller: _passwordController,
                                  focusNode: _passwordFocusNode,
                                  obscureText: _obscurePassword,
                                  enableSuggestions: false,
                                  autocorrect: false,
                                  autofillHints: const [AutofillHints.password],
                                  onFieldSubmitted: (_) => _save(),
                                  validator: (value) =>
                                      _required(value, l10n.passwordLabel),
                                  decoration: InputDecoration(
                                    labelText: l10n.passwordLabel,
                                    prefixIcon: const Icon(
                                      Icons.lock_outline_rounded,
                                      size: 19,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                focusNode: _passwordEyeFocusNode,
                                tooltip: _obscurePassword
                                    ? l10n.passwordShowTooltip
                                    : l10n.passwordHideTooltip,
                                icon: Icon(
                                  _obscurePassword
                                      ? Icons.visibility_rounded
                                      : Icons.visibility_off_rounded,
                                  size: 18,
                                ),
                                onPressed: () => setState(
                                  () => _obscurePassword = !_obscurePassword,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const _ConnectionHint(),
                      const SizedBox(height: 22),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.icon(
                          onPressed: _saving ? null : _save,
                          icon: _saving
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.8,
                                  ),
                                )
                              : const Icon(Icons.check_rounded, size: 18),
                          label: Text(
                            _saving ? l10n.savingLabel : l10n.saveSecurelyLabel,
                          ),
                        ),
                      ),
                      const SizedBox(height: 30),
                      Text(
                        l10n.indexerSectionTitle,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.35,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        l10n.indexerSectionSubtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.45),
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 24),
                      // Indexer ayarları NNTP formundan bağımsız kaydedilir;
                      // iç içe Form'lar alanları ayrı ayrı doğrular.
                      Form(
                        key: _indexerFormKey,
                        child: Column(
                          children: [
                            _SettingsCard(
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Expanded(
                                      child: DropdownButtonFormField<String>(
                                        initialValue:
                                            _editingIndexerId ??
                                            _newAccountSentinel,
                                        decoration: InputDecoration(
                                          labelText:
                                              l10n.settingsIndexerAccountLabel,
                                          prefixIcon: const Icon(
                                            Icons.travel_explore_rounded,
                                            size: 19,
                                          ),
                                        ),
                                        items: [
                                          for (final profile
                                              in _indexerProfiles)
                                            DropdownMenuItem(
                                              value: profile.id,
                                              child: Text(
                                                profile.displayName,
                                              ),
                                            ),
                                          DropdownMenuItem(
                                            value: _newAccountSentinel,
                                            child: Text(
                                              l10n.settingsIndexerNew,
                                            ),
                                          ),
                                        ],
                                        onChanged: _onIndexerAccountChanged,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      focusNode: _indexerDeleteFocusNode,
                                      tooltip:
                                          l10n.settingsAccountDeleteTooltip,
                                      icon: const Icon(
                                        Icons.delete_outline_rounded,
                                        size: 18,
                                      ),
                                      // Yeni-indexer kipinde silinecek kayıt yok.
                                      onPressed:
                                          _editingIndexerId == null ||
                                              _indexerProfiles.isEmpty
                                          ? null
                                          : _deleteIndexerAccount,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                TextFormField(
                                  controller: _indexerLabelController,
                                  focusNode: _indexerLabelFocusNode,
                                  decoration: InputDecoration(
                                    labelText: l10n.settingsIndexerNameLabel,
                                    prefixIcon: const Icon(
                                      Icons.label_outline_rounded,
                                      size: 19,
                                    ),
                                  ),
                                  textInputAction: TextInputAction.next,
                                  autocorrect: false,
                                ),
                                const SizedBox(height: 12),
                                // Çoklu indexer: kapalı hesap listede durur
                                // ama aramalara katılmaz.
                                SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(l10n.settingsIndexerJoinLabel),
                                  subtitle: Text(
                                    l10n.settingsIndexerJoinHint,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(height: 1.3),
                                  ),
                                  value: _indexerJoinSearches,
                                  onChanged: (value) => setState(
                                    () => _indexerJoinSearches = value,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            _SettingsCard(
                              children: [
                                TextFormField(
                                  controller: _indexerUrlController,
                                  focusNode: _indexerUrlFocusNode,
                                  decoration: InputDecoration(
                                    labelText: l10n.indexerUrlLabel,
                                    hintText: 'https://indexer.example',
                                    prefixIcon: const Icon(
                                      Icons.travel_explore_rounded,
                                      size: 19,
                                    ),
                                  ),
                                  textInputAction: TextInputAction.next,
                                  keyboardType: TextInputType.url,
                                  autocorrect: false,
                                  validator: _validateIndexerUrl,
                                ),
                                const SizedBox(height: 12),
                                // Parola alanıyla aynı düzen: göz düğmesi
                                // yanda ve skipTraversal'lı; sağ okla alandan
                                // geçilir (issue #4).
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Expanded(
                                      child: TextFormField(
                                        controller: _indexerApiKeyController,
                                        focusNode: _indexerApiKeyFocusNode,
                                        obscureText: _obscureApiKey,
                                        enableSuggestions: false,
                                        autocorrect: false,
                                        onFieldSubmitted: (_) =>
                                            _saveIndexer(),
                                        validator: _validateIndexerApiKey,
                                        decoration: InputDecoration(
                                          labelText: l10n.indexerApiKeyLabel,
                                          prefixIcon: const Icon(
                                            Icons.key_rounded,
                                            size: 19,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      focusNode: _indexerApiKeyEyeFocusNode,
                                      tooltip: _obscureApiKey
                                          ? l10n.passwordShowTooltip
                                          : l10n.passwordHideTooltip,
                                      icon: Icon(
                                        _obscureApiKey
                                            ? Icons.visibility_rounded
                                            : Icons.visibility_off_rounded,
                                        size: 18,
                                      ),
                                      onPressed: () => setState(
                                        () =>
                                            _obscureApiKey = !_obscureApiKey,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            // Prowlarr / NZBHydra2 kullanıcıları için adres
                            // biçimi ipucu: ikisi de newznab-uyumlu uç verir.
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(top: 1),
                                  child: Icon(
                                    Icons.info_outline_rounded,
                                    size: 16,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant
                                        .withValues(alpha: 0.6),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    l10n.settingsIndexerProxyHint,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                          height: 1.4,
                                        ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 22),
                            // Düğmeler dikey dizilir: yan yana olsalardı aşağı
                            // ok yalnızca birine inebilirdi; kumandayla ikisi
                            // de dikey zincirde olmalı (issue #4).
                            Align(
                              alignment: Alignment.centerRight,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed:
                                        _testingIndexer ? null : _testIndexer,
                                    icon: _testingIndexer
                                        ? const SizedBox.square(
                                            dimension: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 1.8,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.cable_rounded,
                                            size: 18,
                                          ),
                                    label: Text(l10n.indexerTestButton),
                                  ),
                                  const SizedBox(height: 8),
                                  FilledButton.icon(
                                    onPressed:
                                        _savingIndexer ? null : _saveIndexer,
                                    icon: _savingIndexer
                                        ? const SizedBox.square(
                                            dimension: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 1.8,
                                            ),
                                          )
                                        : const Icon(Icons.check_rounded, size: 18),
                                    label: Text(
                                      _savingIndexer
                                          ? l10n.savingLabel
                                          : l10n.indexerSaveLabel,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      _buildOpenSubtitlesSection(context),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cardForeground = Theme.of(context).colorScheme.onSurface;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cardForeground.withValues(alpha: 0.035),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cardForeground.withValues(alpha: 0.075)),
      ),
      // Kartlara açılır menü (DropdownButtonFormField) konduğunda içindeki
      // ListTile mürekkep efekti için kendi Material'ına ihtiyaç duyar;
      // şeffaf aralık DecoratedBox'un varsayılan arka planı gizleme
      // uyarısını da keser (dil seçici uzun süredir aynı durumdaydı).
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(children: children),
        ),
      ),
    );
  }
}

class _SettingsLoadError extends StatelessWidget {
  const _SettingsLoadError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

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
                Icons.lock_outline_rounded,
                color: foreground.withValues(alpha: 0.54),
                size: 32,
              ),
              const SizedBox(height: 14),
              Text(
                l10n.secureStorageUnavailable,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                '$error',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: foreground.withValues(alpha: 0.38),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
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

class _ConnectionHint extends StatelessWidget {
  const _ConnectionHint();

  @override
  Widget build(BuildContext context) {
    final hintColor = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(
            Icons.info_outline_rounded,
            size: 16,
            color: hintColor.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            AppLocalizations.of(context).connectionLimitWarning,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: hintColor, height: 1.4),
          ),
        ),
      ],
    );
  }
}
