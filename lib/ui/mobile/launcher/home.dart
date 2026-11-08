import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import '../../../data/services/repo_manager.dart';
import '../../../data/services/library_service.dart';
import '../../../data/services/repo_prefs.dart';
import '../../../data/services/content_service.dart';
import '../../../data/models/repo_manifest.dart';
import '../repo/main_home.dart';
import '../launcher/comunidad_repos.dart';
import '../launcher/config.dart';
import '../launcher/buscar.dart';
import '../repo/player/player.dart';
import 'downloads_page.dart';

/// Launcher móvil: continuar viendo + iconos de repos (sin home del repo).
class LauncherHome extends StatefulWidget {
  const LauncherHome({super.key});
  @override
  State<LauncherHome> createState() => _LauncherHomeState();
}

class _LauncherHomeState extends State<LauncherHome> {
  /// Novedades: un slider por cada repo
  final Map<String, List<Map<String, dynamic>>> _newsByRepo = {};
  final Map<String, String> _repoNames = {};
  final Map<String, String> _repoNewsStyle = {}; // poster | banner
  bool _loadingNews = false;

  RepoManager? _manager;
  String _lastRepoSignature = '';
  bool _loadingNewsJob = false;
  int _newsGen = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _manager = context.read<RepoManager>();
      _manager?.addListener(_onReposChanged);
      _lastRepoSignature = _repoSignature(_manager);
      _loadNews();
    });
  }

  @override
  void dispose() {
    _manager?.removeListener(_onReposChanged);
    super.dispose();
  }

  String _repoSignature(RepoManager? m) {
    if (m == null) return '';
    final ids = m.enabled.map((r) => r.manifest.id).toList()..sort();
    return ids.join('|');
  }

  void _onReposChanged() {
    if (!mounted) return;
    final sig = _repoSignature(_manager);
    if (sig == _lastRepoSignature) return;
    _lastRepoSignature = sig;
    _loadNews(forceRefresh: false);
  }

  Future<void> _loadNews({bool forceRefresh = false}) async {
    if (_loadingNewsJob && !forceRefresh) return;
    _loadingNewsJob = true;
    final gen = ++_newsGen;
    final manager = context.read<RepoManager>();
    if (manager.enabled.isEmpty) {
      if (mounted && gen == _newsGen) {
        setState(() {
          _newsByRepo.clear();
          _repoNames.clear();
          _repoNewsStyle.clear();
          _loadingNews = false;
        });
      }
      _loadingNewsJob = false;
      return;
    }
    if (mounted) setState(() => _loadingNews = true);

    final byRepo = <String, List<Map<String, dynamic>>>{};
    final names = <String, String>{};
    final styles = <String, String>{};

    final results = await Future.wait(manager.enabled.map((repo) async {
      try {
        final items = await ContentService.instance
            .getNews(repo, forceRefresh: forceRefresh)
            .timeout(const Duration(seconds: 12),
                onTimeout: () => const <Map<String, dynamic>>[]);
        if (items.isEmpty) return null;
        final id = repo.manifest.id;
        return (
          id: id,
          name: repo.manifest.name,
          style: repo.manifest.newsImageStyle,
          items: items.take(14).map((n) {
            return {...n, '_repoName': repo.manifest.name, '_repoId': id};
          }).toList(),
        );
      } catch (_) {
        return null;
      }
    }));
    for (final r in results) {
      if (r == null) continue;
      names[r.id] = r.name;
      styles[r.id] = r.style;
      byRepo[r.id] = r.items;
    }

    if (!mounted || gen != _newsGen) {
      _loadingNewsJob = false;
      return;
    }
    setState(() {
      _newsByRepo
        ..clear()
        ..addAll(byRepo);
      _repoNames
        ..clear()
        ..addAll(names);
      _repoNewsStyle
        ..clear()
        ..addAll(styles);
      _loadingNews = false;
    });
    _loadingNewsJob = false;
  }

  String _styleForItem(String repoId, Map n) {
    final raw = (n['imageStyle'] ??
            n['style'] ??
            n['card'] ??
            n['layout'] ??
            '')
        .toString()
        .toLowerCase();
    if (raw.contains('banner') ||
        raw.contains('back') ||
        raw.contains('horizontal') ||
        raw == 'wide') {
      return 'banner';
    }
    if (raw.contains('poster') || raw.contains('vertical')) {
      return 'poster';
    }
    return _repoNewsStyle[repoId] ?? 'poster';
  }

  String _imageForNews(Map n, String style) {
    if (style == 'banner') {
      final v = (n['banner'] ??
              n['backdrop'] ??
              n['image'] ??
              n['poster'] ??
              '')
          .toString();
      if (v.isNotEmpty) return v;
    }
    return (n['poster'] ??
            n['image'] ??
            n['backdrop'] ??
            n['banner'] ??
            '')
        .toString();
  }

  void _openRepo(InstalledRepo repo) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => RepoMainHome(repo: repo)));
  }

  Future<void> _openContinue(WatchEntry e) async {
    final manager = context.read<RepoManager>();
    final prefs = context.read<RepoPrefs>();
    InstalledRepo? repo;
    for (final r in manager.installed) {
      if (r.manifest.id == e.repoId) {
        repo = r;
        break;
      }
    }
    if (repo == null) return;
    final lang = prefs.preferredLanguage(repo.manifest.id);
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerPage(
        title: e.title,
        url: '',
        repoId: e.repoId,
        contentId: e.contentId,
        poster: e.poster,
        contentType: e.type,
        startPositionMs: e.positionMs,
        loadRepo: repo,
        preferredLanguage: lang,
        isTv: true,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<RepoManager>();
    final lib = context.watch<LibraryService>();
    final apps = manager.enabled;
    final watching = lib.continueWatchingAll();
    final now = DateTime.now();
    final time = DateFormat('HH:mm').format(now);
    String date;
    try {
      date = DateFormat('EEEE d MMMM', 'es').format(now).toUpperCase();
    } catch (_) {
      date = DateFormat('EEEE d MMMM').format(now).toUpperCase();
    }

    // Tamaños adaptativos según pantalla
    final screenW = MediaQuery.of(context).size.width;
    final isSmall = screenW < 380;
    final hPad = isSmall ? 16.0 : 24.0;

    return Scaffold(
      backgroundColor: const Color(0xFF0B0E14),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header: hora grande, fecha debajo, iconos a la derecha
                    Padding(
                      padding: EdgeInsets.fromLTRB(hPad, 12, hPad, 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // Columna hora + fecha
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                time,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: isSmall ? 34 : 40,
                                  fontWeight: FontWeight.w300,
                                  height: 1.0,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                date,
                                style: TextStyle(
                                  color: Colors.white54,
                                  fontSize: isSmall ? 11 : 12,
                                  letterSpacing: 0.8,
                                ),
                              ),
                            ],
                          ),
                          const Spacer(),
                          // Botones con InkWell + padding generoso para tap
                          _HeaderIcon(
                            icon: Icons.search,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const GlobalSearchPage()),
                            ),
                          ),
                          _HeaderIcon(
                            icon: Icons.public,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const CommunityPage()),
                            ),
                          ),
                          _HeaderIcon(
                            icon: Icons.download_rounded,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const MobileDownloadsPage()),
                            ),
                          ),
                          _HeaderIcon(
                            icon: Icons.settings,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const GlobalSettingsPage()),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_loadingNews && _newsByRepo.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFFE50914),
                            ),
                          ),
                        ),
                      ),
                    // Novedades: un slider horizontal por cada repo
                    if (_newsByRepo.isNotEmpty)
                      ..._newsByRepo.entries.map((entry) {
                        final repoId = entry.key;
                        final items = entry.value;
                        final repoName = _repoNames[repoId] ?? repoId;
                        final defaultStyle =
                            _repoNewsStyle[repoId] ?? 'poster';
                        final isBanner = defaultStyle == 'banner';
                        final rowHeight = isBanner ? 118.0 : 168.0;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding:
                                  EdgeInsets.fromLTRB(hPad, 10, hPad, 8),
                              child: Text(
                                'NOVEDADES · $repoName'.toUpperCase(),
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 1.1,
                                ),
                              ),
                            ),
                            SizedBox(
                              height: rowHeight,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                padding: EdgeInsets.symmetric(
                                    horizontal: hPad - 4),
                                itemCount: items.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(width: 12),
                                itemBuilder: (context, i) {
                                  final n = items[i];
                                  final style = _styleForItem(repoId, n);
                                  final banner = style == 'banner';
                                  final title =
                                      (n['title'] ?? n['text'] ?? '')
                                          .toString();
                                  final msg = (n['message'] ??
                                          n['subtitle'] ??
                                          '')
                                      .toString();
                                  final img = _imageForNews(n, style);
                                  final cardW = banner ? 220.0 : 108.0;
                                  final cardH = banner ? 110.0 : 160.0;
                                  return GestureDetector(
                                    onTap: () {
                                      final mgr =
                                          context.read<RepoManager>();
                                      InstalledRepo? repo;
                                      for (final r in mgr.installed) {
                                        if (r.manifest.id == repoId) {
                                          repo = r;
                                          break;
                                        }
                                      }
                                      if (repo != null) _openRepo(repo);
                                    },
                                    child: Container(
                                      width: cardW,
                                      height: cardH,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF1A222D),
                                        borderRadius:
                                            BorderRadius.circular(10),
                                      ),
                                      clipBehavior: Clip.antiAlias,
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          if (img.isNotEmpty)
                                            CachedNetworkImage(
                                              imageUrl: img,
                                              fit: BoxFit.cover,
                                              memCacheWidth:
                                                  banner ? 440 : 220,
                                              errorWidget: (_, __, ___) =>
                                                  const ColoredBox(
                                                      color:
                                                          Color(0xFF1A222D)),
                                            )
                                          else
                                            const ColoredBox(
                                                color: Color(0xFF1A222D)),
                                          const DecoratedBox(
                                            decoration: BoxDecoration(
                                              gradient: LinearGradient(
                                                begin: Alignment.topCenter,
                                                end: Alignment.bottomCenter,
                                                colors: [
                                                  Colors.transparent,
                                                  Color(0xCC000000),
                                                ],
                                              ),
                                            ),
                                          ),
                                          Positioned(
                                            left: 8,
                                            right: 8,
                                            bottom: 8,
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  title.isNotEmpty
                                                      ? title
                                                      : 'Novedad',
                                                  maxLines: banner ? 1 : 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.w600,
                                                    fontSize: 12,
                                                  ),
                                                ),
                                                if (msg.isNotEmpty)
                                                  Text(
                                                    msg,
                                                    maxLines: 1,
                                                    overflow: TextOverflow
                                                        .ellipsis,
                                                    style: const TextStyle(
                                                        color: Colors.white70,
                                                        fontSize: 10),
                                                  ),
                                              ],
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
                        );
                      }),
                    // Continuar viendo
                    if (watching.isNotEmpty) ...[
                      Padding(
                        padding: EdgeInsets.fromLTRB(hPad, 12, hPad, 10),
                        child: const Text('CONTINUAR VIENDO',
                            style: TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 1.2)),
                      ),
                      SizedBox(
                        height: 160,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          padding:
                              EdgeInsets.symmetric(horizontal: hPad - 4),
                          itemCount: watching.length.clamp(0, 20),
                          separatorBuilder: (_, __) =>
                              const SizedBox(width: 12),
                          itemBuilder: (context, i) {
                            final e = watching[i];
                            return GestureDetector(
                              onTap: () => _openContinue(e),
                              child: Container(
                                width: 120,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      if (e.poster != null)
                                        CachedNetworkImage(
                                            imageUrl: e.poster!,
                                            fit: BoxFit.cover)
                                      else
                                        Container(
                                            color: const Color(0xFF1A222D)),
                                      Align(
                                        alignment: Alignment.bottomCenter,
                                        child: LinearProgressIndicator(
                                          value: e.progress,
                                          minHeight: 3,
                                          backgroundColor: Colors.white12,
                                          color: const Color(0xFFE50914),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ] else
                      Padding(
                        padding: EdgeInsets.fromLTRB(hPad, 24, hPad, 8),
                        child: const Text(
                            'Continúa donde lo dejaste cuando reproduzcas algo',
                            style: TextStyle(color: Colors.white38)),
                      ),
                    const SizedBox(height: 28),
                  ],
                ),
              ),
            ),
            // Barra fija de aplicaciones / repos
            Container(
              decoration: const BoxDecoration(
                color: Color(0xFF0B0E14),
                border: Border(top: BorderSide(color: Colors.white10)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(hPad, 10, hPad, 8),
                    child: const Text('APLICACIONES',
                        style: TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.2)),
                  ),
                  SizedBox(
                    height: 116,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: EdgeInsets.fromLTRB(hPad - 4, 0, hPad - 4, 12),
                      itemCount: apps.length + 1,
                      separatorBuilder: (_, __) => const SizedBox(width: 14),
                      itemBuilder: (context, i) {
                        if (i == apps.length) {
                          return _AppIcon(
                            letter: '+',
                            label: 'Añadir',
                            isAdd: true,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const CommunityPage()),
                            ),
                          );
                        }
                        final repo = apps[i];
                        return _AppIcon(
                          letter: repo.manifest.name.isNotEmpty
                              ? repo.manifest.name[0].toUpperCase()
                              : '?',
                          label: repo.manifest.name,
                          logo: repo.manifest.icon ??
                              _githubAvatar(repo.manifest.repo),
                          onTap: () => _openRepo(repo),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String? _githubAvatar(String userRepo) {
    final parts = userRepo.split('/');
    if (parts.isEmpty || parts.first.isEmpty) return null;
    return 'https://github.com/${parts.first}.png';
  }
}

/// Botón de icono del header con área táctil amplia (móvil).
class _HeaderIcon extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _HeaderIcon({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: Colors.white70, size: 24),
        ),
      ),
    );
  }
}

/// Icono de app/repo con feedback táctil (sin foco de TV).
class _AppIcon extends StatelessWidget {
  final String letter;
  final String label;
  final String? logo;
  final bool isAdd;
  final VoidCallback onTap;
  const _AppIcon({
    required this.letter,
    required this.label,
    required this.onTap,
    this.logo,
    this.isAdd = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: const Color(0xFF1A222D),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white12, width: 1),
            ),
            child: logo != null && logo!.isNotEmpty
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: CachedNetworkImage(
                        imageUrl: logo!, fit: BoxFit.cover),
                  )
                : Center(
                    child: Text(
                      letter,
                      style: TextStyle(
                        color: isAdd ? Colors.white54 : Colors.white,
                        fontSize: isAdd ? 32 : 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: 80,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}