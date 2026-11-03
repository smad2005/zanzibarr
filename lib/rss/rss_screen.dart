import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/app_localizations.dart';
import '../player/player_screen.dart';
import '../src/rust/api/search.dart';
import 'rss_feed.dart';
import 'rss_store.dart';

typedef RssDownloadFn = Future<String> Function(String nzbUrl, String title);

class RssScreen extends StatefulWidget {
  const RssScreen({
    super.key,
    this.store,
    this.cache,
    this.downloadFn,
    this.onDownloaded,
  });

  final RssStore? store;
  final RssFeedCache? cache;
  final RssDownloadFn? downloadFn;

  final ValueChanged<String>? onDownloaded;

  @override
  State<RssScreen> createState() => _RssScreenState();
}

class _RssScreenState extends State<RssScreen> {
  late final RssStore _store = widget.store ?? RssStore();
  late final RssFeedCache _cache = widget.cache ?? RssFeedCache.shared;
  late final RssDownloadFn _downloadFn = widget.downloadFn ?? _defaultDownload;

  List<RssFeed> _feeds = [];
  List<RssTag> _tags = [];
  List<RssTag> _sortedTags = const [];
  Map<String, DateTime> _tagNewest = const {};
  bool _drawerOpen = false;
  bool _loadingConfig = true;

  String? _selectedFeedId;
  String? _selectedTagId;

  List<RssItem>? _items;
  bool _loadingItems = false;
  List<String> _errors = const [];

  int _loadGeneration = 0;

  String? _busyNzbUrl;

  String? _savingNzbUrl;

  bool _filterOpen = false;
  final _filterController = TextEditingController();

  static Future<String> _defaultDownload(String nzbUrl, String title) async {
    final cacheDir = await getTemporaryDirectory();
    return newznabDownloadNzb(
      config: const IndexerConfigDto(baseUrl: '', apiKey: ''),
      nzbUrl: nzbUrl,
      suggestedName: title,
      downloadDir: cacheDir.path,
    );
  }

  @override
  void initState() {
    super.initState();
    _filterController.addListener(() => setState(() {}));
    _cache.addListener(_recomputeTagFreshness);
    _loadConfig();
  }

  @override
  void dispose() {
    _cache.removeListener(_recomputeTagFreshness);
    _filterController.dispose();
    super.dispose();
  }

  void _toggleFilter() {
    setState(() {
      _filterOpen = !_filterOpen;
      if (!_filterOpen) _filterController.clear();
    });
  }

  Future<void> _loadConfig() async {
    List<RssFeed> feeds = [];
    List<RssTag> tags = [];
    try {
      feeds = await _store.loadFeeds();
      tags = await _store.loadTags();
    } catch (_) {
    }
    if (!mounted) return;
    setState(() {
      _feeds = feeds;
      _tags = tags;
      _loadingConfig = false;
      _selectedFeedId = feeds.isEmpty ? null : feeds.first.id;
    });
    _recomputeTagFreshness();
    await _loadItems();
    await _prefetchAllFeeds();
  }

  Future<void> _prefetchAllFeeds() async {
    await Future.wait(
      _feeds.map((feed) async {
        try {
          await _cache.fetch(feed);
        } catch (_) {}
      }),
    );
  }

  void _recomputeTagFreshness() {
    if (!mounted) return;
    final itemsByFeed = {
      for (final feed in _feeds) feed.id: ?_cache.peek(feed),
    };
    final newest = {
      for (final tag in _tags)
        tag.id: ?newestTagMatch(tag, _feeds, itemsByFeed),
    };
    setState(() {
      _tagNewest = newest;
      _sortedTags = _drawerOpen
          ? keepTagOrder(_tags, _sortedTags)
          : sortTagsByFreshness(_tags, newest, DateTime.now().toUtc());
    });
  }

  RssFeed? get _selectedFeed =>
      _feeds.where((feed) => feed.id == _selectedFeedId).firstOrNull;

  RssTag? get _selectedTag =>
      _tags.where((tag) => tag.id == _selectedTagId).firstOrNull;

  List<RssFeed> get _sourceFeeds {
    if (_selectedFeed case final feed?) return [feed];
    if (_selectedTag case final tag?) return tag.feedsFrom(_feeds);
    return const [];
  }

  Future<void> _loadItems({bool force = false}) async {
    final feeds = _sourceFeeds;
    final tag = _selectedTag;
    final generation = ++_loadGeneration;
    if (feeds.isEmpty) {
      setState(() {
        _items = null;
        _errors = const [];
        _loadingItems = false;
      });
      return;
    }
    if (force) _cache.invalidate(feeds);
    setState(() {
      _loadingItems = true;
      _errors = const [];
    });

    final errors = <String>[];
    final results = await Future.wait(
      feeds.map((feed) async {
        try {
          return await _cache.fetch(feed);
        } catch (error) {
          errors.add('${feed.name}: $error');
          return const <RssItem>[];
        }
      }),
    );
    if (!mounted || generation != _loadGeneration) return;

    var items = [for (final list in results) ...list];
    if (tag != null) {
      items = items.where((item) => tag.matches(item.title)).toList();
      items.sort((a, b) {
        final pa = a.published, pb = b.published;
        if (pa == null || pb == null) return pa == null ? 1 : -1;
        return pb.compareTo(pa);
      });
    }
    setState(() {
      _items = items;
      _errors = errors;
      _loadingItems = false;
    });
  }

  void _selectFeed(RssFeed feed) {
    setState(() {
      _selectedFeedId = feed.id;
      _selectedTagId = null;
    });
    _loadItems();
  }

  void _selectTag(RssTag tag) {
    setState(() {
      _selectedTagId = tag.id;
      _selectedFeedId = null;
    });
    _loadItems();
  }

  static String _newId() => DateTime.now().microsecondsSinceEpoch.toString();

  Future<void> _editFeed([RssFeed? existing]) async {
    final result = await showDialog<RssFeed>(
      context: context,
      builder: (_) => _FeedDialog(existing: existing, newId: _newId),
    );
    if (result == null) return;
    final feeds = [
      for (final feed in _feeds) feed.id == result.id ? result : feed,
      if (existing == null) result,
    ];
    await _store.saveFeeds(feeds);
    if (existing != null) _cache.invalidate([existing]);
    setState(() => _feeds = feeds);
    _recomputeTagFreshness();
    _selectFeed(result);
  }

  Future<void> _deleteFeed(RssFeed feed) async {
    final feeds = _feeds.where((f) => f.id != feed.id).toList();
    final tags = [
      for (final tag in _tags)
        tag.feedIds.contains(feed.id)
            ? RssTag(
                id: tag.id,
                name: tag.name,
                pattern: tag.pattern,
                isRegex: tag.isRegex,
                feedIds: tag.feedIds.where((id) => id != feed.id).toList(),
              )
            : tag,
    ];
    await _store.saveFeeds(feeds);
    await _store.saveTags(tags);
    setState(() {
      _feeds = feeds;
      _tags = tags;
      if (_selectedFeedId == feed.id) {
        _selectedFeedId = feeds.isEmpty ? null : feeds.first.id;
      }
    });
    _recomputeTagFreshness();
    _loadItems();
  }

  Future<void> _editTag([RssTag? existing]) async {
    final result = await showDialog<RssTag>(
      context: context,
      builder: (_) =>
          _TagDialog(existing: existing, feeds: _feeds, newId: _newId),
    );
    if (result == null) return;
    final tags = [
      for (final tag in _tags) tag.id == result.id ? result : tag,
      if (existing == null) result,
    ];
    await _store.saveTags(tags);
    setState(() => _tags = tags);
    _recomputeTagFreshness();
    _selectTag(result);
  }

  Future<void> _deleteTag(RssTag tag) async {
    final tags = _tags.where((t) => t.id != tag.id).toList();
    await _store.saveTags(tags);
    setState(() {
      _tags = tags;
      if (_selectedTagId == tag.id) {
        _selectedTagId = null;
        _selectedFeedId = _feeds.isEmpty ? null : _feeds.first.id;
      }
    });
    _recomputeTagFreshness();
    _loadItems();
  }

  Future<void> _play(RssItem item) async {
    if (_busyNzbUrl != null) return;
    setState(() => _busyNzbUrl = item.nzbUrl);
    try {
      final path = await _downloadFn(item.nzbUrl, item.title);
      if (!mounted) return;
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
      if (mounted) setState(() => _busyNzbUrl = null);
    }
  }

  static const _publicDownloads = '/storage/emulated/0/Download';

  static Future<String> _saveToMobileDownloads(
    String source,
    String title,
  ) async {
    if (Platform.isAndroid) {
      final saved = await _tryCopy(source, Directory(_publicDownloads), title);
      if (saved != null) return saved;
    }
    final dir =
        await getDownloadsDirectory() ??
        await getApplicationDocumentsDirectory();
    final target = await _uniquePath(dir, title);
    await File(source).copy(target);
    return target;
  }

  static Future<String?> _tryCopy(
    String source,
    Directory dir,
    String title,
  ) async {
    try {
      final target = await _uniquePath(dir, title);
      await File(source).copy(target);
      return target;
    } on FileSystemException {
      return null;
    }
  }

  static Future<String> _uniquePath(Directory dir, String title) async {
    final separator = Platform.pathSeparator;
    var path = '${dir.path}$separator${safeNzbFileName(title)}';
    for (var n = 1; await File(path).exists(); n++) {
      path = '${dir.path}$separator${safeNzbFileName(title, suffix: ' ($n)')}';
    }
    return path;
  }

  Future<void> _saveNzb(RssItem item) async {
    if (_savingNzbUrl != null) return;
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final desktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    setState(() => _savingNzbUrl = item.nzbUrl);
    try {
      String? target;
      if (desktop) {
        final location = await getSaveLocation(
          suggestedName: safeNzbFileName(item.title),
          acceptedTypeGroups: const [
            XTypeGroup(label: 'NZB', extensions: ['nzb']),
          ],
        );
        if (location == null) return;
        target = location.path;
      }
      final downloaded = await _downloadFn(item.nzbUrl, item.title);
      if (target != null) {
        await File(downloaded).copy(target);
      } else {
        target = await _saveToMobileDownloads(downloaded, item.title);
      }
      messenger.showSnackBar(SnackBar(content: Text(l10n.rssSaved(target))));
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.searchDownloadFailed('$error'))),
      );
    } finally {
      if (mounted) setState(() => _savingNzbUrl = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final title = _selectedFeed?.name ?? _selectedTag?.name;
    return Scaffold(
      onDrawerChanged: (opened) {
        _drawerOpen = opened;
        if (!opened) _recomputeTagFreshness();
      },
      drawer: Drawer(
        child: SafeArea(
          child: Builder(
            builder: (drawerContext) => _Sidebar(
              feeds: _feeds,
              tags: _sortedTags,
              tagNewest: _tagNewest,
              selectedFeedId: _selectedFeedId,
              selectedTagId: _selectedTagId,
              onSelectFeed: (feed) {
                Navigator.of(drawerContext).pop();
                _selectFeed(feed);
              },
              onSelectTag: (tag) {
                Navigator.of(drawerContext).pop();
                _selectTag(tag);
              },
              onAddFeed: () => _editFeed(),
              onEditFeed: _editFeed,
              onDeleteFeed: _deleteFeed,
              onAddTag: () => _editTag(),
              onEditTag: _editTag,
              onDeleteTag: _deleteTag,
            ),
          ),
        ),
      ),
      appBar: AppBar(
        leadingWidth: 96,
        leading: Builder(
          builder: (scaffoldContext) => Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 17),
                tooltip: l10n.backTooltip,
                onPressed: () => Navigator.maybePop(context),
              ),
              IconButton(
                icon: const Icon(Icons.menu_rounded),
                tooltip: MaterialLocalizations.of(
                  context,
                ).openAppDrawerTooltip,
                onPressed: () => Scaffold.of(scaffoldContext).openDrawer(),
              ),
            ],
          ),
        ),
        title: _filterOpen
            ? TextField(
                controller: _filterController,
                autofocus: true,
                autocorrect: false,
                textInputAction: TextInputAction.search,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: l10n.rssFilterHint,
                  border: InputBorder.none,
                ),
              )
            : Text(
                title == null ? l10n.rssTitle : '${l10n.rssTitle} · $title',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
        actions: [
          IconButton(
            tooltip: _filterOpen ? l10n.rssFilterClose : l10n.rssFilter,
            onPressed: _toggleFilter,
            icon: Icon(
              _filterOpen ? Icons.close_rounded : Icons.search_rounded,
            ),
          ),
          IconButton(
            tooltip: l10n.rssRefresh,
            onPressed: _loadingItems || _sourceFeeds.isEmpty
                ? null
                : () => _loadItems(force: true),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _buildItems(context, l10n),
    );
  }

  Widget _buildItems(BuildContext context, AppLocalizations l10n) {
    if (_loadingConfig || _loadingItems) {
      return const Center(
        child: SizedBox.square(
          dimension: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_feeds.isEmpty) {
      return _Hint(
        icon: Icons.rss_feed_rounded,
        message: l10n.rssNoFeeds,
        action: FilledButton.icon(
          onPressed: () => _editFeed(),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: Text(l10n.rssAddFeed),
        ),
      );
    }
    final loaded = _items;
    if (loaded == null) {
      return _Hint(icon: Icons.rss_feed_rounded, message: l10n.rssSelectSource);
    }
    final query = _filterController.text.trim().toLowerCase();
    final items = query.isEmpty
        ? loaded
        : loaded
              .where((item) => item.title.toLowerCase().contains(query))
              .toList();
    final feedNames = {for (final feed in _feeds) feed.id: feed.name};
    final showFeedName = _selectedTag != null;
    return Column(
      children: [
        for (final error in _errors)
          MaterialBanner(
            content: Text(error, maxLines: 2, overflow: TextOverflow.ellipsis),
            leading: const Icon(Icons.error_outline),
            actions: [
              TextButton(
                onPressed: () => _loadItems(force: true),
                child: Text(l10n.retry),
              ),
            ],
          ),
        Expanded(
          child: items.isEmpty
              ? _Hint(icon: Icons.search_off_rounded, message: l10n.rssNoItems)
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return _ItemCard(
                      item: item,
                      feedName: showFeedName ? feedNames[item.feedId] : null,
                      busy: _busyNzbUrl == item.nzbUrl,
                      enabled: _busyNzbUrl == null,
                      onPlay: () => _play(item),
                      saving: _savingNzbUrl == item.nzbUrl,
                      saveEnabled: _savingNzbUrl == null,
                      onSave: () => _saveNzb(item),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.feeds,
    required this.tags,
    required this.tagNewest,
    required this.selectedFeedId,
    required this.selectedTagId,
    required this.onSelectFeed,
    required this.onSelectTag,
    required this.onAddFeed,
    required this.onEditFeed,
    required this.onDeleteFeed,
    required this.onAddTag,
    required this.onEditTag,
    required this.onDeleteTag,
  });

  final List<RssFeed> feeds;
  final List<RssTag> tags;
  final Map<String, DateTime> tagNewest;
  final String? selectedFeedId;
  final String? selectedTagId;
  final ValueChanged<RssFeed> onSelectFeed;
  final ValueChanged<RssTag> onSelectTag;
  final VoidCallback onAddFeed;
  final ValueChanged<RssFeed> onEditFeed;
  final ValueChanged<RssFeed> onDeleteFeed;
  final VoidCallback onAddTag;
  final ValueChanged<RssTag> onEditTag;
  final ValueChanged<RssTag> onDeleteTag;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final now = DateTime.now().toUtc();
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _SectionHeader(
          title: l10n.rssFeeds,
          addTooltip: l10n.rssAddFeed,
          onAdd: onAddFeed,
        ),
        for (final feed in feeds)
          _SourceTile(
            icon: Icons.rss_feed_rounded,
            title: feed.name,
            selected: feed.id == selectedFeedId,
            onTap: () => onSelectFeed(feed),
            onEdit: () => onEditFeed(feed),
            onDelete: () => onDeleteFeed(feed),
          ),
        const SizedBox(height: 12),
        _SectionHeader(
          title: l10n.rssTags,
          addTooltip: l10n.rssAddTag,
          onAdd: feeds.isEmpty ? null : onAddTag,
        ),
        for (final tag in tags)
          _SourceTile(
            icon: Icons.sell_outlined,
            title: tag.name,
            subtitle: tag.isRegex ? '/${tag.pattern}/' : tag.pattern,
            age: switch (tagNewest[tag.id]) {
              final newest? => formatRssAge(newest, now),
              null => null,
            },
            selected: tag.id == selectedTagId,
            onTap: () => onSelectTag(tag),
            onEdit: () => onEditTag(tag),
            onDelete: () => onDeleteTag(tag),
          ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.addTooltip,
    required this.onAdd,
  });

  final String title;
  final String addTooltip;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final foreground = Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 6, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: TextStyle(
                color: foreground.withValues(alpha: 0.5),
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
              ),
            ),
          ),
          IconButton(
            tooltip: addTooltip,
            visualDensity: VisualDensity.compact,
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.icon,
    required this.title,
    required this.selected,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
    this.subtitle,
    this.age,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? age;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListTile(
      dense: true,
      selected: selected,
      leading: Icon(icon, size: 18),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (age case final age?)
            Text(
              age,
              style: TextStyle(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.5),
                fontSize: 11,
              ),
            ),
          PopupMenuButton<bool>(
            icon: const Icon(Icons.more_vert_rounded, size: 18),
            onSelected: (edit) => edit ? onEdit() : onDelete(),
            itemBuilder: (_) => [
              PopupMenuItem(value: true, child: Text(l10n.rssEdit)),
              PopupMenuItem(value: false, child: Text(l10n.rssDelete)),
            ],
          ),
        ],
      ),
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({
    required this.item,
    required this.busy,
    required this.enabled,
    required this.onPlay,
    required this.saving,
    required this.saveEnabled,
    required this.onSave,
    this.feedName,
  });

  final RssItem item;
  final String? feedName;
  final bool busy;
  final bool enabled;
  final VoidCallback onPlay;
  final bool saving;
  final bool saveEnabled;
  final VoidCallback onSave;

  static String _formatSize(int bytes) {
    const giga = 1024 * 1024 * 1024;
    const mega = 1024 * 1024;
    if (bytes >= giga) return '${(bytes / giga).toStringAsFixed(1)} GB';
    if (bytes >= mega) return '${(bytes / mega).round()} MB';
    return '<1 MB';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final foreground = Theme.of(context).colorScheme.onSurface;
    final meta = [
      ?feedName,
      if (item.sizeBytes case final size?) _formatSize(size),
      if (item.published case final published?)
        formatRssAge(published, DateTime.now().toUtc()),
      ?item.category,
    ].join(' · ');
    return Material(
      color: foreground.withValues(alpha: 0.035),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: foreground.withValues(alpha: 0.075)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: [
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
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foreground.withValues(alpha: 0.5),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 4),
            saving
                ? const Padding(
                    padding: EdgeInsets.all(11),
                    child: SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    tooltip: l10n.rssDownloadNzb,
                    visualDensity: VisualDensity.compact,
                    onPressed: saveEnabled ? onSave : null,
                    icon: Icon(
                      Icons.download_rounded,
                      size: 20,
                      color: foreground.withValues(alpha: 0.6),
                    ),
                  ),
            const SizedBox(width: 2),
            busy
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton.filledTonal(
                    tooltip: l10n.rssPlay,
                    onPressed: enabled ? onPlay : null,
                    icon: const Icon(Icons.play_arrow_rounded),
                  ),
          ],
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.message, this.action});

  final IconData icon;
  final String message;
  final Widget? action;

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
                color: foreground.withValues(alpha: 0.5),
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

class _FeedDialog extends StatefulWidget {
  const _FeedDialog({required this.existing, required this.newId});

  final RssFeed? existing;
  final String Function() newId;

  @override
  State<_FeedDialog> createState() => _FeedDialogState();
}

class _FeedDialogState extends State<_FeedDialog> {
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _url = TextEditingController(text: widget.existing?.url);

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  bool get _urlValid {
    final uri = Uri.tryParse(_url.text.trim());
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  void _submit() {
    if (!_urlValid) return;
    final url = _url.text.trim();
    final name = _name.text.trim().isEmpty
        ? (Uri.parse(url).host)
        : _name.text.trim();
    Navigator.of(context).pop(
      widget.existing?.copyWith(name: name, url: url) ??
          RssFeed(id: widget.newId(), name: name, url: url),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.existing == null ? l10n.rssAddFeed : l10n.rssEditFeed),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(labelText: l10n.rssFeedName),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              autocorrect: false,
              keyboardType: TextInputType.url,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: l10n.rssFeedUrl,
                hintText: 'https://…',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.rssCancel),
        ),
        FilledButton(
          onPressed: _urlValid ? _submit : null,
          child: Text(l10n.rssSave),
        ),
      ],
    );
  }
}

class _TagDialog extends StatefulWidget {
  const _TagDialog({
    required this.existing,
    required this.feeds,
    required this.newId,
  });

  final RssTag? existing;
  final List<RssFeed> feeds;
  final String Function() newId;

  @override
  State<_TagDialog> createState() => _TagDialogState();
}

class _TagDialogState extends State<_TagDialog> {
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _pattern = TextEditingController(text: widget.existing?.pattern);
  late bool _isRegex = widget.existing?.isRegex ?? false;
  late bool _allFeeds = widget.existing?.appliesToAllFeeds ?? true;
  late final Set<String> _feedIds = {...?widget.existing?.feedIds};

  @override
  void dispose() {
    _name.dispose();
    _pattern.dispose();
    super.dispose();
  }

  bool get _regexInvalid =>
      _isRegex && RssTag.tryCompileRegex(_pattern.text) == null;

  bool get _canSave =>
      _name.text.trim().isNotEmpty &&
      _pattern.text.isNotEmpty &&
      !_regexInvalid &&
      (_allFeeds || _feedIds.isNotEmpty);

  void _submit() {
    if (!_canSave) return;
    Navigator.of(context).pop(
      RssTag(
        id: widget.existing?.id ?? widget.newId(),
        name: _name.text.trim(),
        pattern: _pattern.text,
        isRegex: _isRegex,
        feedIds: _allFeeds
            ? const []
            : [
                for (final feed in widget.feeds)
                  if (_feedIds.contains(feed.id)) feed.id,
              ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.existing == null ? l10n.rssAddTag : l10n.rssEditTag),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: l10n.rssTagName),
              ),
              const SizedBox(height: 16),
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(
                    value: false,
                    label: Text(l10n.rssTagModeContains),
                  ),
                  ButtonSegment(value: true, label: Text(l10n.rssTagModeRegex)),
                ],
                selected: {_isRegex},
                onSelectionChanged: (value) =>
                    setState(() => _isRegex = value.single),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pattern,
                autocorrect: false,
                onChanged: (_) => setState(() {}),
                style: _isRegex
                    ? const TextStyle(fontFamily: 'monospace')
                    : null,
                decoration: InputDecoration(
                  labelText: l10n.rssTagPattern,
                  errorText: _regexInvalid ? l10n.rssInvalidRegex : null,
                ),
              ),
              const SizedBox(height: 16),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _allFeeds,
                title: Text(l10n.rssTagAllFeeds),
                onChanged: (value) =>
                    setState(() => _allFeeds = value ?? true),
              ),
              if (!_allFeeds)
                for (final feed in widget.feeds)
                  CheckboxListTile(
                    contentPadding: const EdgeInsets.only(left: 16),
                    dense: true,
                    value: _feedIds.contains(feed.id),
                    title: Text(feed.name),
                    onChanged: (value) => setState(
                      () => value == true
                          ? _feedIds.add(feed.id)
                          : _feedIds.remove(feed.id),
                    ),
                  ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.rssCancel),
        ),
        FilledButton(
          onPressed: _canSave ? _submit : null,
          child: Text(l10n.rssSave),
        ),
      ],
    );
  }
}
