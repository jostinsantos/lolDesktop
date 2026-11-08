import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../../data/models/repo_manifest.dart';
import '../../data/services/content_service.dart';
import '../../data/services/library_service.dart';
import '../../data/services/repo_prefs.dart';
import '../player/playertvoline_desktop.dart';

const _kAccent = Color(0xFFE50914);
const _kBg = Color(0xFF0B0E14);

/// Live TV desktop: categorías | canales | preview + favoritos.
class RepoLivePage extends StatefulWidget {
  final InstalledRepo repo;
  const RepoLivePage({super.key, required this.repo});

  @override
  State<RepoLivePage> createState() => _RepoLivePageState();
}

class _RepoLivePageState extends State<RepoLivePage> {
  final _channelScroll = ScrollController();

  List<HomeRow> _categories = [];
  bool _legacy = true;
  bool _loading = true;
  String? _error;
  int _catIndex = 0;
  int _channelIndex = 0;
  ContentItem? _activeChannel;

  /// Canales de la categoría actual (cargados de forma progresiva).
  List<ContentItem> _visibleChannels = [];
  int _page = 0;
  bool _loadingMore = false;
  bool _hasMore = true;
  static const _kPageSize = 30;

  Player? _preview;
  VideoController? _previewVideo;
  final List<StreamSubscription> _previewSubs = [];
  bool _previewLoading = false;
  String? _previewError;
  String? _previewingId;

  @override
  void initState() {
    super.initState();
    _channelScroll.addListener(_onChannelScroll);
    _load();
  }

  @override
  void dispose() {
    _channelScroll.removeListener(_onChannelScroll);
    _channelScroll.dispose();
    unawaited(_disposePreview());
    super.dispose();
  }

  void _onChannelScroll() {
    if (!_hasMore || _loadingMore) return;
    if (!_channelScroll.hasClients) return;
    final max = _channelScroll.position.maxScrollExtent;
    final pos = _channelScroll.position.pixels;
    if (pos >= max - 200) {
      unawaited(_loadMoreChannels());
    }
  }

  Future<void> _disposePreview() async {
    for (final s in _previewSubs) {
      try {
        await s.cancel();
      } catch (_) {}
    }
    _previewSubs.clear();
    final p = _preview;
    _preview = null;
    _previewVideo = null;
    try {
      await p?.dispose();
    } catch (_) {}
  }

  Future<void> _load({bool refresh = false}) async {
    setState(() {
      _loading = true;
      _error = null;
      _visibleChannels = [];
      _page = 0;
      _hasMore = true;
    });
    try {
      final result = await ContentService.instance.getLiveCategories(
        widget.repo,
        forceRefresh: refresh,
      );
      if (!mounted) return;
      setState(() {
        _categories = result.rows;
        _legacy = result.legacy;
        _loading = false;
        _catIndex = 0;
        _channelIndex = 0;
        _activeChannel = null;
      });
      await _resetAndLoadPage();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  List<HomeRow> _withFavorites() {
    final lib = context.read<LibraryService>();
    final favs = lib.favorites(widget.repo.manifest.id);
    final favItems = <ContentItem>[];
    for (final f in favs) {
      ContentItem? found;
      for (final row in _categories) {
        for (final it in row.items) {
          if (it.id == f.contentId) {
            found = it;
            break;
          }
        }
        if (found != null) break;
      }
      found ??= _visibleChannels.cast<ContentItem?>().firstWhere(
            (it) => it?.id == f.contentId,
            orElse: () => null,
          );
      favItems.add(
        found ??
            ContentItem(
              id: f.contentId,
              title: f.title,
              poster: f.poster,
              logo: f.poster,
              type: f.type.isNotEmpty ? f.type : 'channel',
            ),
      );
    }
    final out = <HomeRow>[];
    if (favItems.isNotEmpty) {
      out.add(HomeRow(id: 'favorites', title: 'Favoritos', items: favItems));
    }
    out.addAll(_categories);
    return out;
  }

  List<HomeRow> get _display => _withFavorites();

  HomeRow? get _currentCategory {
    final cats = _display;
    if (cats.isEmpty) return null;
    final i = _catIndex.clamp(0, cats.length - 1);
    return cats[i];
  }

  List<ContentItem> get _channels => _visibleChannels;

  Future<void> _resetAndLoadPage() async {
    _page = 0;
    _visibleChannels = [];
    _hasMore = true;
    await _loadMoreChannels();
  }

  Future<void> _loadMoreChannels() async {
    if (_loadingMore || !_hasMore) return;
    final cat = _currentCategory;
    if (cat == null) {
      setState(() {
        _hasMore = false;
        _loadingMore = false;
      });
      return;
    }

    if (cat.id == 'favorites') {
      setState(() {
        _visibleChannels = List.from(cat.items);
        _hasMore = false;
        _loadingMore = false;
        _page = 1;
        _channelIndex = 0;
        _activeChannel =
            _visibleChannels.isNotEmpty ? _visibleChannels[0] : null;
      });
      if (_activeChannel != null) unawaited(_playPreview(_activeChannel!));
      return;
    }

    setState(() => _loadingMore = true);
    final nextPage = _page + 1;

    try {
      final page = await ContentService.instance.loadLiveCategory(
        widget.repo,
        categoryId: cat.id,
        catalogId: cat.catalogId,
        page: nextPage,
        fallbackItems: cat.items,
      );

      if (!mounted) return;
      setState(() {
        final existing = _visibleChannels.map((e) => e.id).toSet();
        final fresh =
            page.items.where((e) => !existing.contains(e.id)).toList();
        _visibleChannels = [..._visibleChannels, ...fresh];
        _page = nextPage;
        _hasMore = page.hasMore && (page.items.isNotEmpty || nextPage == 1);
        if (page.items.isEmpty && nextPage > 1) _hasMore = false;
        _loadingMore = false;
        if (_activeChannel == null && _visibleChannels.isNotEmpty) {
          _channelIndex = 0;
          _activeChannel = _visibleChannels[0];
        }
      });
      if (_activeChannel != null && _previewingId != _activeChannel!.id) {
        unawaited(_playPreview(_activeChannel!));
      }
    } catch (e) {
      debugPrint('[Live] load category ${cat.id} page $nextPage: $e');
      if (!mounted) return;
      final all = cat.items;
      final start = _page * _kPageSize;
      if (start >= all.length) {
        setState(() {
          _hasMore = false;
          _loadingMore = false;
        });
        return;
      }
      final end = (start + _kPageSize).clamp(0, all.length);
      setState(() {
        _visibleChannels = [..._visibleChannels, ...all.sublist(start, end)];
        _page = nextPage;
        _hasMore = end < all.length;
        _loadingMore = false;
        if (_activeChannel == null && _visibleChannels.isNotEmpty) {
          _channelIndex = 0;
          _activeChannel = _visibleChannels[0];
        }
      });
      if (_activeChannel != null && _previewingId != _activeChannel!.id) {
        unawaited(_playPreview(_activeChannel!));
      }
    }
  }

  void _selectCategory(int i) {
    final cats = _display;
    if (i < 0 || i >= cats.length) return;
    if (i == _catIndex && _visibleChannels.isNotEmpty) return;
    setState(() {
      _catIndex = i;
      _channelIndex = 0;
      _activeChannel = null;
      _visibleChannels = [];
      _page = 0;
      _hasMore = true;
      _loadingMore = false;
    });
    unawaited(_loadMoreChannels());
  }

  void _selectChannel(int i) {
    final items = _channels;
    if (i < 0 || i >= items.length) return;
    setState(() {
      _channelIndex = i;
      _activeChannel = items[i];
    });
    unawaited(_playPreview(items[i]));
  }

  Future<void> _playPreview(ContentItem item) async {
    if (_previewingId == item.id && _preview != null) return;
    _previewingId = item.id;
    setState(() {
      _previewLoading = true;
      _previewError = null;
    });
    try {
      final list = await ContentService.instance.getStreams(
        widget.repo,
        item.id,
        type: item.type,
      );
      if (!mounted || _previewingId != item.id) return;
      if (list.isEmpty) {
        setState(() {
          _previewLoading = false;
          _previewError = 'Sin fuente';
        });
        return;
      }
      final s = list.first;
      await _disposePreview();
      final player = Player(
        configuration: PlayerConfiguration(
          title: item.title,
          bufferSize: 16 * 1024 * 1024,
        ),
      );
      _preview = player;
      _previewVideo = VideoController(player);
      final hdrs = Map<String, String>.from(s.headers);
      hdrs.putIfAbsent(
        'User-Agent',
        () =>
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36',
      );
      await player.open(Media(s.url, httpHeaders: hdrs), play: true);
      if (!mounted || _previewingId != item.id) return;
      setState(() => _previewLoading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _previewLoading = false;
        _previewError = e.toString();
      });
    }
  }

  Future<void> _openFull() async {
    final item = _activeChannel;
    if (item == null) return;
    await _disposePreview();
    _previewingId = null;
    if (mounted) setState(() {});

    final prefs = context.read<RepoPrefs>();
    final prefLang = widget.repo.userConfig['preferred_language'] ??
        prefs.preferredLanguage(widget.repo.manifest.id);
    final guide = List<HomeRow>.from(_withFavorites());
    final catIndex =
        _catIndex.clamp(0, guide.isEmpty ? 0 : guide.length - 1);
    if (guide.isNotEmpty && _visibleChannels.isNotEmpty) {
      final cat = guide[catIndex];
      guide[catIndex] = HomeRow(
        id: cat.id,
        title: cat.title,
        type: cat.type,
        items: _visibleChannels.length >= cat.items.length
            ? _visibleChannels
            : (cat.items.isNotEmpty ? cat.items : _visibleChannels),
        catalogId: cat.catalogId,
        imageStyle: cat.imageStyle,
      );
    }

    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerDesktopOnlinePage(
        title: item.currentProgram != null
            ? '${item.title} · ${item.currentProgram}'
            : item.title,
        repoId: widget.repo.manifest.id,
        contentId: item.id,
        poster: item.poster,
        backdrop: item.backdrop,
        logo: item.logo,
        contentType: item.type,
        preferredLanguage: prefLang,
        loadRepo: widget.repo,
        categories: guide,
        initialCategoryIndex: catIndex,
        initialChannelIndex: _channelIndex,
      ),
    ));

    if (mounted && _activeChannel != null) {
      unawaited(_playPreview(_activeChannel!));
    }
  }

  Future<void> _toggleFav() async {
    final item = _activeChannel;
    if (item == null) return;
    await context.read<LibraryService>().toggleFavorite(
          repoId: widget.repo.manifest.id,
          contentId: item.id,
          title: item.title,
          poster: item.logo ?? item.poster,
          type: item.type.isNotEmpty ? item.type : 'channel',
        );
    if (mounted) setState(() {});
  }

  Widget _thumb(String? url, String title) {
    if (url != null && url.startsWith('http')) {
      return CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => _initials(title),
      );
    }
    return _initials(title);
  }

  Widget _initials(String title) {
    final t = title.trim();
    final letters = t.isEmpty
        ? '?'
        : t
            .split(RegExp(r'\s+'))
            .take(2)
            .map((w) => w.isNotEmpty ? w[0].toUpperCase() : '')
            .join();
    return Container(
      color: const Color(0xFF1A222D),
      alignment: Alignment.center,
      child: Text(letters,
          style: const TextStyle(
              color: Colors.white70, fontWeight: FontWeight.w800)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.repo.manifest.backgroundColor;
    final accent = widget.repo.manifest.accentColor;
    final lib = context.watch<LibraryService>();
    final isFav = _activeChannel != null &&
        lib.isFavorite(widget.repo.manifest.id, _activeChannel!.id);

    if (_loading) {
      return ColoredBox(
        color: bg,
        child: const Center(child: CircularProgressIndicator(color: _kAccent)),
      );
    }
    if (_error != null) {
      return ColoredBox(
        color: bg,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => _load(refresh: true),
                child: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      );
    }

    final cats = _display;
    final channels = _channels;

    return ColoredBox(
      color: bg,
      child: Row(
        children: [
          // Categorías
          SizedBox(
            width: 200,
            child: Container(
              color: Colors.black.withValues(alpha: 0.35),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 18, 16, 12),
                    child: Text('Categorías',
                        style: TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.w600,
                            fontSize: 13)),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: cats.length,
                      itemBuilder: (_, i) {
                        final sel = i == _catIndex;
                        return InkWell(
                          onTap: () => _selectCategory(i),
                          child: Container(
                            margin: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 3),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                              color: sel ? accent : Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              cats[i].title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: sel ? Colors.white : Colors.white70,
                                fontWeight:
                                    sel ? FontWeight.w700 : FontWeight.w500,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Canales
          SizedBox(
            width: 300,
            child: Container(
              color: Colors.black.withValues(alpha: 0.2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
                    child: Text(
                      channels.isEmpty
                          ? 'Canales'
                          : '${channels.length} canales',
                      style: const TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w600,
                          fontSize: 13),
                    ),
                  ),
                  Expanded(
                    child: channels.isEmpty && _loadingMore
                        ? const Center(
                            child: SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: _kAccent),
                            ),
                          )
                        : channels.isEmpty
                            ? const Center(
                                child: Text('Sin canales',
                                    style: TextStyle(color: Colors.white38)))
                            : ListView.builder(
                                controller: _channelScroll,
                                itemCount:
                                    channels.length + (_loadingMore ? 1 : 0),
                                itemBuilder: (_, i) {
                                  if (i >= channels.length) {
                                    return const Padding(
                                      padding: EdgeInsets.symmetric(vertical: 16),
                                      child: Center(
                                        child: SizedBox(
                                          width: 22,
                                          height: 22,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2, color: _kAccent),
                                        ),
                                      ),
                                    );
                                  }
                                  final item = channels[i];
                                  final sel = i == _channelIndex;
                                  return InkWell(
                                    onTap: () => _selectChannel(i),
                                    onDoubleTap: () => unawaited(_openFull()),
                                    child: Container(
                                      margin: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 4),
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: sel
                                            ? accent
                                            : Colors.transparent,
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Row(
                                        children: [
                                          ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(6),
                                            child: SizedBox(
                                              width: 56,
                                              height: 36,
                                              child: _thumb(
                                                  item.logo ?? item.poster,
                                                  item.title),
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Text(
                                              item.title,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: sel
                                                    ? Colors.white
                                                    : Colors.white70,
                                                fontWeight: sel
                                                    ? FontWeight.w700
                                                    : FontWeight.w500,
                                                fontSize: 13.5,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                  ),
                ],
              ),
            ),
          ),
          // Preview
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Material(
                      color: const Color(0xFF12161E),
                      borderRadius: BorderRadius.circular(14),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => unawaited(_openFull()),
                        child: _activeChannel == null
                            ? const Center(
                                child: Text('Selecciona un canal',
                                    style: TextStyle(color: Colors.white38)))
                            : Stack(
                                fit: StackFit.expand,
                                children: [
                                  if (_previewVideo != null)
                                    Video(
                                      controller: _previewVideo!,
                                      controls: NoVideoControls,
                                      fit: BoxFit.contain,
                                    )
                                  else
                                    _thumb(
                                      _activeChannel!.backdrop ??
                                          _activeChannel!.poster ??
                                          _activeChannel!.logo,
                                      _activeChannel!.title,
                                    ),
                                  if (_previewLoading)
                                    const Center(
                                      child: CircularProgressIndicator(
                                          color: _kAccent, strokeWidth: 2.5),
                                    ),
                                  if (_previewError != null &&
                                      !_previewLoading)
                                    Center(
                                      child: Text(_previewError!,
                                          style: const TextStyle(
                                              color: Colors.white54)),
                                    ),
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    bottom: 0,
                                    child: Container(
                                      padding: const EdgeInsets.fromLTRB(
                                          20, 40, 20, 18),
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [
                                            Colors.transparent,
                                            Colors.black
                                                .withValues(alpha: 0.85),
                                          ],
                                        ),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            _activeChannel!.title,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 22,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          Row(
                                            children: [
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 12,
                                                        vertical: 6),
                                                decoration: BoxDecoration(
                                                  color: accent,
                                                  borderRadius:
                                                      BorderRadius.circular(6),
                                                ),
                                                child: const Text('EN VIVO',
                                                    style: TextStyle(
                                                        color: Colors.white,
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        fontSize: 12)),
                                              ),
                                              const SizedBox(width: 12),
                                              Text(
                                                'CH ${_channelIndex + 1}/${channels.length}',
                                                style: TextStyle(
                                                    color: Colors.white
                                                        .withValues(
                                                            alpha: 0.6)),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 48,
                    child: Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: isFav
                                  ? accent
                                  : Colors.white.withValues(alpha: 0.1),
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () => unawaited(_toggleFav()),
                            icon: Icon(isFav
                                ? Icons.favorite
                                : Icons.favorite_border),
                            label: Text(
                                isFav ? 'En favoritos' : 'Favorito'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: accent,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () => unawaited(_openFull()),
                            icon: const Icon(Icons.fullscreen_rounded),
                            label: const Text('Pantalla completa'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
