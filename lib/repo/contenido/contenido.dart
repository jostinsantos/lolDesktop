import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../../data/models/repo_manifest.dart';
import '../../../data/services/content_service.dart';
import '../../../data/services/library_service.dart';
import '../../../data/services/repo_prefs.dart';
import '../../../data/services/settings_service.dart';
import '../../../data/services/download_service.dart';
import '../../../data/models/download_item.dart';
import '../../../ui/shared/download_sheet.dart';
import '../../../ui/shared/cast_sheet.dart';
import '../player/player.dart';

// ───────────────────────── Tokens ─────────────────────────
const _bg = Color(0xFF0B0D10);
const _card = Color(0xFF161A22);
const _border = Color(0xFF232A38);
const _accent = Color(0xFFE50914);
const _accentDark = Color(0xFFB20710);
const _ok = Color(0xFF4ADE80);

const _fast = Duration(milliseconds: 140);
const _mid = Duration(milliseconds: 280);

bool _isActiveDl(DownloadItem? d) =>
    d != null &&
    (d.status == DownloadStatus.downloading ||
        d.status == DownloadStatus.queued ||
        d.status == DownloadStatus.converting);

bool _isDoneDl(DownloadItem? d) => d != null && d.status == DownloadStatus.completed;

/// Ficha de contenido — backdrop + info + capítulos, adaptable a móvil, tablet, desktop y TV.
class DetailsPage extends StatefulWidget {
  final InstalledRepo repo;
  final String itemId;
  final int? season;
  final int? episode;

  const DetailsPage({
    super.key,
    required this.repo,
    required this.itemId,
    this.season,
    this.episode,
  });

  @override
  State<DetailsPage> createState() => _DetailsPageState();
}

class _DetailsPageState extends State<DetailsPage> {
  ContentItem? _item;
  bool _loading = true;
  String? _error;
  int _seasonIndex = 0;
  bool _loadingSeason = false;
  final Set<int> _loadedSeasons = {};
  bool _showEpisodes = false;

  int? _watchPosMs;
  int? _watchDurMs;
  int? _watchSeason;
  int? _watchEpisode;
  bool _isFavorite = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  // ───────────────────────── Carga ─────────────────────────
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final item = await ContentService.instance.getDetails(widget.repo, widget.itemId);
      if (!mounted) return;
      if (item == null) {
        setState(() {
          _error = 'No se pudo cargar el contenido';
          _loading = false;
        });
        return;
      }
      setState(() {
        _item = item;
        _loading = false;
        if (item.seasons.isNotEmpty && widget.season != null) {
          final idx = item.seasons.indexWhere((s) => s.number == widget.season);
          if (idx >= 0) _seasonIndex = idx;
        }
      });
      // Estado de visionado y temporada en paralelo (más rápido)
      await Future.wait([
        _loadWatchState(),
        if (item.seasons.isNotEmpty) _ensureSeasonEpisodes(item.seasons[_seasonIndex].number),
      ]);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _ensureSeasonEpisodes(int seasonNumber) async {
    if (_loadedSeasons.contains(seasonNumber) || _item == null) return;
    final existing = _item!.seasons.where((s) => s.number == seasonNumber);
    if (existing.isNotEmpty && existing.first.episodes.isNotEmpty) {
      _loadedSeasons.add(seasonNumber);
      return;
    }
    setState(() => _loadingSeason = true);
    try {
      final updated = await ContentService.instance.getDetails(
        widget.repo,
        widget.itemId,
        season: seasonNumber,
      );
      if (!mounted) return;
      setState(() {
        if (updated != null) {
          _item = updated;
          _loadedSeasons.add(seasonNumber);
        }
        _loadingSeason = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingSeason = false);
    }
  }

  Future<void> _loadWatchState() async {
    try {
      final lib = context.read<LibraryService>();
      _isFavorite = lib.isFavorite(widget.repo.manifest.id, widget.itemId);

      final entry = await DesktopPlayerPage.loadHistorialEntry(
        repoId: widget.repo.manifest.id,
        contentId: widget.itemId,
      );
      if (entry != null) {
        final pos = (entry['positionMs'] as num?)?.toInt() ?? 0;
        final dur = (entry['durationMs'] as num?)?.toInt() ?? 0;
        final finished = entry['finished'] == true || (dur > 0 && pos / dur >= 0.9);
        if (!finished && pos > 1500) {
          _watchPosMs = pos;
          _watchDurMs = dur;
          _watchSeason = (entry['season'] as num?)?.toInt();
          _watchEpisode = (entry['episode'] as num?)?.toInt();
        } else {
          _watchPosMs = null;
          _watchDurMs = null;
          _watchSeason = null;
          _watchEpisode = null;
        }
      } else {
        final list = lib.continueWatching(widget.repo.manifest.id);
        for (final e in list) {
          if (e.contentId == widget.itemId &&
              e.positionMs > 1500 &&
              (e.durationMs <= 0 || e.positionMs / e.durationMs < 0.9)) {
            _watchPosMs = e.positionMs;
            _watchDurMs = e.durationMs;
            break;
          }
        }
      }
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[Details] watch: $e');
    }
  }

  // ───────────────────────── Helpers ─────────────────────────
  String _fmtMs(int ms) {
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _continueLabel() {
    final isSeries = (_item?.seasons.isNotEmpty ?? false) ||
        (_item?.type == 'series' || _item?.type == 'tv');
    if (_watchPosMs != null && _watchPosMs! > 1500) {
      if (isSeries && _watchSeason != null && _watchEpisode != null) {
        return 'Continuar T$_watchSeason E$_watchEpisode · ${_fmtMs(_watchPosMs!)}';
      }
      return 'Continuar · ${_fmtMs(_watchPosMs!)}';
    }
    return 'Ver ahora';
  }

  double? get _progress {
    final pos = _watchPosMs;
    final dur = _watchDurMs;
    if (pos == null || dur == null || dur <= 0) return null;
    return (pos / dur).clamp(0.0, 1.0);
  }

  Future<void> _toggleFavorite() async {
    final item = _item;
    if (item == null) return;
    final lib = context.read<LibraryService>();
    // Respuesta inmediata en UI
    setState(() => _isFavorite = !_isFavorite);
    await lib.toggleFavorite(
      repoId: widget.repo.manifest.id,
      contentId: item.id,
      title: item.title,
      poster: item.poster,
      type: item.type,
    );
    if (mounted) {
      setState(() => _isFavorite = lib.isFavorite(widget.repo.manifest.id, widget.itemId));
    }
  }

  DownloadService? _dlService(BuildContext context) {
    try {
      return context.watch<DownloadService>();
    } catch (_) {
      return null;
    }
  }

  DownloadItem? _statusFor(DownloadService? svc, {int? season, int? episode}) {
    if (svc == null) return null;
    final id = widget.itemId;
    final repoId = widget.repo.manifest.id;
    for (final it in svc.items) {
      if (it.repoId != repoId || it.contentId != id) continue;
      if (season != null && episode != null) {
        if (it.season == season && it.episode == episode) return it;
      } else if (it.season == null || it.episode == null) {
        return it;
      }
    }
    return null;
  }

  Future<void> _downloadItem({
    int? season,
    int? episode,
    String? episodeTitle,
    String? episodeId,
  }) async {
    final item = _item;
    if (item == null) return;
    await DownloadSheet.show(
      context: context,
      repo: widget.repo,
      item: item,
      season: season,
      episode: episode,
      episodeTitle: episodeTitle,
      episodeId: episodeId,
    );
  }

  // ignore: unused_element
  Future<void> _transmitItem({
    int? season,
    int? episode,
    String? episodeTitle,
    String? episodeId,
  }) async {
    final item = _item;
    if (item == null) return;
    await CastSheet.show(
      context: context,
      repo: widget.repo,
      item: item,
      season: season,
      episode: episode,
      episodeTitle: episodeTitle,
      episodeId: episodeId,
    );
  }

  Future<void> _play({int? season, int? episode}) async {
    final item = _item;
    if (item == null) return;

    final prefs = context.read<RepoPrefs>();
    final prefLang = widget.repo.userConfig['preferred_language'] ??
        prefs.preferredLanguage(widget.repo.manifest.id);

    List<EpisodeInfo>? eps;
    int? seasonNum = season;
    if (item.seasons.isNotEmpty) {
      final idx = _seasonIndex.clamp(0, item.seasons.length - 1);
      eps = item.seasons[idx].episodes;
      seasonNum ??= item.seasons[idx].number;
    }

    int startMs = 0;
    try {
      final entry = await DesktopPlayerPage.loadHistorialEntry(
        repoId: widget.repo.manifest.id,
        contentId: item.id,
        season: seasonNum,
        episode: episode,
      );
      if (entry != null) {
        startMs = (entry['positionMs'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {}

    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DesktopPlayerPage(
        title: season != null && episode != null
            ? '${item.title} · T$season E$episode'
            : item.title,
        repo: widget.repo,
        contentId: item.id,
        poster: item.poster,
        backdrop: item.backdrop,
        logo: item.logo,
        contentType: item.type,
        preferredLanguage: prefLang,
        season: seasonNum,
        episode: episode,
        episodes: eps,
        seasonNumber: seasonNum,
        startPositionMs: startMs,
      ),
    ));
    if (mounted) await _loadWatchState();
  }

  bool get _isSeries {
    final item = _item;
    if (item == null) return false;
    final typed = item.seasons.isNotEmpty || item.type == 'series' || item.type == 'tv';
    if (!typed) return false;
    var totalEps = 0;
    for (final s in item.seasons) {
      totalEps += s.episodes.length;
    }
    if (item.seasons.length == 1 && totalEps <= 1) return false;
    return true;
  }

  // ───────────────────────── Build ─────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: _bg,
        body: Center(child: CircularProgressIndicator(color: _accent)),
      );
    }
    if (_error != null || _item == null) {
      return Scaffold(
        backgroundColor: _bg,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.wifi_off_rounded, color: Colors.white38, size: 48),
                const SizedBox(height: 16),
                Text(
                  _error ?? 'Error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 15),
                ),
                const SizedBox(height: 20),
                _PrimaryButton(
                  label: 'Reintentar',
                  icon: Icons.refresh_rounded,
                  onTap: _load,
                  expand: false,
                ),
                const SizedBox(height: 10),
                TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('Volver', style: TextStyle(color: Colors.white60)),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final item = _item!;
    final downloadsOn = context.watch<SettingsService>().downloadsEnabled;
    final dlSvc = _dlService(context);

    final Widget page;
    if (_showEpisodes && _isSeries) {
      page = _EpisodesView(
        key: const ValueKey('episodes'),
        item: item,
        seasonIndex: _seasonIndex,
        loadingSeason: _loadingSeason,
        onBack: () => setState(() => _showEpisodes = false),
        onSelectSeason: (i) {
          setState(() => _seasonIndex = i);
          _ensureSeasonEpisodes(item.seasons[i].number);
        },
        onPlayEpisode: (se, ep) => _play(season: se, episode: ep),
        onDownloadEpisode: downloadsOn
            ? (se, ep, title, id) => _downloadItem(
                  season: se,
                  episode: ep,
                  episodeTitle: title,
                  episodeId: id,
                )
            : null,
        downloadIconBuilder: downloadsOn
            ? (se, ep) {
                final dl = _statusFor(dlSvc, season: se, episode: ep);
                if (_isActiveDl(dl)) {
                  return const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white70),
                  );
                }
                final done = _isDoneDl(dl);
                return Icon(
                  done ? Icons.download_done_rounded : Icons.download_rounded,
                  color: done ? _ok : Colors.white70,
                );
              }
            : null,
      );
    } else {
      final dl = _statusFor(dlSvc);
      final active = _isActiveDl(dl);
      final done = _isDoneDl(dl);
      page = _InfoView(
        key: const ValueKey('info'),
        item: item,
        isSeries: _isSeries,
        playLabel: _continueLabel(),
        progress: _progress,
        isFavorite: _isFavorite,
        onBack: () => Navigator.of(context).maybePop(),
        onPlay: () async {
          if (_watchSeason != null && _watchEpisode != null) {
            await _play(season: _watchSeason, episode: _watchEpisode);
          } else {
            await _play();
          }
        },
        onFavorite: _toggleFavorite,
        downloadButton: downloadsOn && !_isSeries
            ? _GlassButton(
                icon: done ? Icons.download_done_rounded : Icons.download_rounded,
                iconColor: done ? _ok : Colors.white,
                tooltip: active
                    ? 'Descargando…'
                    : done
                        ? 'Ya descargado'
                        : 'Descargar',
                onTap: active ? null : () => _downloadItem(),
                child: active
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                      )
                    : null,
              )
            : null,
        onEpisodes: _isSeries ? () => setState(() => _showEpisodes = true) : null,
      );
    }

    return PopScope(
      canPop: !(_showEpisodes && _isSeries),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _showEpisodes) setState(() => _showEpisodes = false);
      },
      child: AnimatedSwitcher(
        duration: _mid,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
        child: page,
      ),
    );
  }
}

// ───────────────────────── Componentes base ─────────────────────────

/// Envoltorio táctil: escala al presionar, resalta con mouse y con foco (mando/teclado).
class _Tap extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius? radius;
  final double hoverScale;

  const _Tap({
    required this.child,
    required this.onTap,
    this.radius,
    this.hoverScale = 1.03,
  });

  @override
  State<_Tap> createState() => _TapState();
}

class _TapState extends State<_Tap> {
  bool _hover = false;
  bool _focus = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final scale = !enabled
        ? 1.0
        : _down
            ? 0.95
            : (_hover || _focus)
                ? widget.hoverScale
                : 1.0;

    return FocusableActionDetector(
      enabled: enabled,
      mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onShowHoverHighlight: (v) => setState(() => _hover = v),
      onShowFocusHighlight: (v) => setState(() => _focus = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onTap?.call();
          return null;
        }),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapUp: enabled ? (_) => setState(() => _down = false) : null,
        onTapCancel: enabled ? () => setState(() => _down = false) : null,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: scale,
          duration: _fast,
          curve: Curves.easeOut,
          child: Container(
            foregroundDecoration: (_focus && widget.radius != null)
                ? BoxDecoration(
                    borderRadius: widget.radius,
                    border: Border.all(color: Colors.white, width: 2),
                  )
                : null,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Botón principal: degradado rojo, brillo suave, alto cómodo para el dedo.
class _PrimaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool expand;

  const _PrimaryButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.expand = true,
  });

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(16));
    return _Tap(
      onTap: onTap,
      radius: radius,
      hoverScale: 1.04,
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 26),
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: const LinearGradient(
            colors: [_accent, _accentDark],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: _accent.withValues(alpha: 0.38),
              blurRadius: 22,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 28),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Botón secundario con borde translúcido.
class _GhostButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool expand;

  const _GhostButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.expand = true,
  });

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(16));
    return _Tap(
      onTap: onTap,
      radius: radius,
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(
          borderRadius: radius,
          color: Colors.white.withValues(alpha: 0.10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
        ),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 24),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Botón circular de cristal (favorito, descargar, volver).
class _GlassButton extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String tooltip;
  final VoidCallback? onTap;
  final Widget? child;
  final double size;
  final Color? tint;

  const _GlassButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.iconColor = Colors.white,
    this.child,
    this.size = 56,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: _Tap(
        onTap: onTap,
        radius: BorderRadius.circular(size),
        child: AnimatedContainer(
          duration: _mid,
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: tint ?? Colors.white.withValues(alpha: 0.12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
          ),
          child: child ??
              AnimatedSwitcher(
                duration: _fast,
                transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                child: Icon(icon, key: ValueKey('$icon$iconColor'), color: iconColor, size: size * 0.46),
              ),
        ),
      ),
    );
  }
}

/// Entrada suave única del bloque de información.
class _Reveal extends StatelessWidget {
  final Widget child;
  const _Reveal({required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 480),
      curve: Curves.easeOutCubic,
      builder: (_, v, c) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, 18 * (1 - v)), child: c),
      ),
      child: child,
    );
  }
}

/// Logo anclado a la izquierda; cae a título si no hay imagen.
class _LeftLogo extends StatelessWidget {
  final String? logoUrl;
  final String title;
  final double height;
  final double maxWidth;
  final double fontSize;

  const _LeftLogo({
    required this.logoUrl,
    required this.title,
    required this.height,
    required this.maxWidth,
    required this.fontSize,
  });

  Widget _titleText() => Text(
        title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.left,
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
          height: 1.12,
          letterSpacing: -0.5,
          shadows: const [Shadow(color: Colors.black54, blurRadius: 12)],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final url = logoUrl?.trim() ?? '';
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Align(
        alignment: Alignment.centerLeft,
        child: url.isEmpty
            ? _titleText()
            : SizedBox(
                height: height,
                child: CachedNetworkImage(
                  imageUrl: url,
                  height: height,
                  alignment: Alignment.centerLeft,
                  fit: BoxFit.contain,
                  memCacheHeight: (height * 3).round(),
                  fadeInDuration: _mid,
                  fadeOutDuration: Duration.zero,
                  placeholder: (_, __) => const SizedBox.shrink(),
                  errorWidget: (_, __, ___) => _titleText(),
                ),
              ),
      ),
    );
  }
}

/// Píldora de metadatos.
class _Pill extends StatelessWidget {
  final Widget child;
  final Color? color;
  const _Pill({required this.child, this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color ?? Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: child,
    );
  }
}

/// Sinopsis expandible.
class _Overview extends StatefulWidget {
  final String text;
  final int collapsedLines;
  const _Overview({required this.text, required this.collapsedLines});

  @override
  State<_Overview> createState() => _OverviewState();
}

class _OverviewState extends State<_Overview> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(color: Colors.white70, height: 1.5, fontSize: 14.5);
    return LayoutBuilder(builder: (context, c) {
      final tp = TextPainter(
        text: TextSpan(text: widget.text, style: style),
        maxLines: widget.collapsedLines,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: c.maxWidth);
      final overflow = tp.didExceedMaxLines;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedSize(
            duration: _mid,
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: Text(
              widget.text,
              maxLines: _open ? null : widget.collapsedLines,
              overflow: _open ? TextOverflow.visible : TextOverflow.ellipsis,
              style: style,
            ),
          ),
          if (overflow)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _Tap(
                onTap: () => setState(() => _open = !_open),
                hoverScale: 1.0,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    _open ? 'Ver menos' : 'Ver más',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    });
  }
}

String _typeLabel(String type) {
  switch (type.toLowerCase()) {
    case 'movie':
      return 'Película';
    case 'series':
      return 'Serie';
    case 'tv':
      return 'TV';
    case 'anime':
      return 'Anime';
    default:
      return type.isEmpty ? 'Contenido' : '${type[0].toUpperCase()}${type.substring(1)}';
  }
}

// ───────────────────────── Vista principal ─────────────────────────
class _InfoView extends StatelessWidget {
  final ContentItem item;
  final bool isSeries;
  final String playLabel;
  final double? progress;
  final bool isFavorite;
  final VoidCallback onBack;
  final VoidCallback onPlay;
  final VoidCallback onFavorite;
  final Widget? downloadButton;
  final VoidCallback? onEpisodes;

  const _InfoView({
    super.key,
    required this.item,
    required this.isSeries,
    required this.playLabel,
    required this.progress,
    required this.isFavorite,
    required this.onBack,
    required this.onPlay,
    required this.onFavorite,
    this.downloadButton,
    this.onEpisodes,
  });

  @override
  Widget build(BuildContext context) {
    final bgUrl = (item.backdrop != null && item.backdrop!.isNotEmpty) ? item.backdrop : item.poster;
    final posterUrl = item.poster;

    return Scaffold(
      backgroundColor: _bg,
      body: LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth;
        final wide = w >= 800;
        final showPoster = w >= 1000 && posterUrl != null && posterUrl.isNotEmpty;
        final hPad = wide ? (w * 0.06).clamp(32.0, 80.0) : 20.0;
        final contentMax = wide ? 640.0 : double.infinity;

        return Stack(
          fit: StackFit.expand,
          children: [
            // Fondo
            if (bgUrl != null && bgUrl.isNotEmpty)
              CachedNetworkImage(
                imageUrl: bgUrl,
                fit: BoxFit.cover,
                alignment: wide ? Alignment.center : const Alignment(0.2, -1),
                memCacheWidth: 1600,
                fadeInDuration: const Duration(milliseconds: 350),
                placeholder: (_, __) => const ColoredBox(color: _bg),
                errorWidget: (_, __, ___) => const ColoredBox(color: _bg),
              )
            else
              const ColoredBox(color: _bg),

            // Degradado vertical
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.30),
                    Colors.black.withValues(alpha: 0.30),
                    _bg.withValues(alpha: 0.92),
                    _bg,
                  ],
                  stops: const [0.0, 0.30, 0.72, 1.0],
                ),
              ),
            ),
            // Degradado lateral (legibilidad del texto en pantallas anchas)
            if (wide)
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      _bg.withValues(alpha: 0.85),
                      _bg.withValues(alpha: 0.30),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                ),
              ),

            // Volver
            SafeArea(
              child: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: EdgeInsets.all(wide ? 20 : 12),
                  child: _GlassButton(
                    icon: Icons.arrow_back_rounded,
                    tooltip: 'Volver',
                    onTap: onBack,
                    size: 48,
                    tint: Colors.black.withValues(alpha: 0.40),
                  ),
                ),
              ),
            ),

            // Contenido
            SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(hPad, 24, hPad, wide ? 48 : 24),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: contentMax),
                          child: SingleChildScrollView(
                            reverse: true,
                            physics: const ClampingScrollPhysics(),
                            child: _Reveal(child: _content(wide)),
                          ),
                        ),
                      ),
                    ),
                    if (showPoster) ...[
                      const SizedBox(width: 40),
                      _PosterCard(url: posterUrl, width: (w * 0.2).clamp(200.0, 300.0)),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      }),
    );
  }

  Widget _content(bool wide) {
    final overview = item.overview ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _LeftLogo(
          logoUrl: item.logo,
          title: item.title,
          height: wide ? 84 : 60,
          maxWidth: wide ? 360 : 260,
          fontSize: wide ? 40 : 28,
        ),
        SizedBox(height: wide ? 16 : 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (item.rating != null)
              _Pill(
                color: Colors.amber.withValues(alpha: 0.16),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.star_rounded, size: 16, color: Colors.amber),
                    const SizedBox(width: 4),
                    Text(
                      item.rating!.toStringAsFixed(1),
                      style: const TextStyle(
                        color: Colors.amber,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            if (item.year != null)
              _Pill(
                child: Text(
                  '${item.year}',
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            _Pill(
              child: Text(
                _typeLabel(item.type),
                style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        if (overview.isNotEmpty) ...[
          const SizedBox(height: 16),
          _Overview(text: overview, collapsedLines: wide ? 4 : 3),
        ],
        SizedBox(height: wide ? 24 : 20),
        if (progress != null) ...[
          SizedBox(
            width: wide ? 340 : double.infinity,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: progress!),
                duration: const Duration(milliseconds: 700),
                curve: Curves.easeOutCubic,
                builder: (_, v, __) => LinearProgressIndicator(
                  value: v,
                  minHeight: 4,
                  color: _accent,
                  backgroundColor: Colors.white24,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
        ],
        _actions(wide),
      ],
    );
  }

  Widget _actions(bool wide) {
    final play = _PrimaryButton(
      label: playLabel,
      icon: Icons.play_arrow_rounded,
      onTap: onPlay,
      expand: !wide,
    );
    final fav = _GlassButton(
      icon: isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
      iconColor: isFavorite ? _accent : Colors.white,
      tooltip: isFavorite ? 'Quitar de favoritos' : 'Añadir a favoritos',
      onTap: onFavorite,
    );
    final eps = onEpisodes == null
        ? null
        : _GhostButton(
            label: 'Ver capítulos',
            icon: Icons.view_list_rounded,
            onTap: onEpisodes!,
            expand: !wide,
          );

    if (wide) {
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          play,
          if (eps != null) eps,
          fav,
          if (downloadButton != null) downloadButton!,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: play),
            const SizedBox(width: 12),
            fav,
            if (downloadButton != null) ...[
              const SizedBox(width: 12),
              downloadButton!,
            ],
          ],
        ),
        if (eps != null) ...[
          const SizedBox(height: 12),
          eps,
        ],
      ],
    );
  }
}

class _PosterCard extends StatelessWidget {
  final String url;
  final double width;
  const _PosterCard({required this.url, required this.width});

  @override
  Widget build(BuildContext context) {
    return _Reveal(
      child: Container(
        width: width,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.6),
              blurRadius: 40,
              offset: const Offset(0, 20),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(17),
          child: AspectRatio(
            aspectRatio: 2 / 3,
            child: CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              memCacheWidth: 600,
              fadeInDuration: _mid,
              placeholder: (_, __) => const ColoredBox(color: _card),
              errorWidget: (_, __, ___) => const ColoredBox(color: _card),
            ),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── Capítulos ─────────────────────────
class _EpisodesView extends StatelessWidget {
  final ContentItem item;
  final int seasonIndex;
  final bool loadingSeason;
  final VoidCallback onBack;
  final ValueChanged<int> onSelectSeason;
  final void Function(int season, int episode) onPlayEpisode;
  final void Function(int season, int episode, String? title, String? id)? onDownloadEpisode;
  final Widget Function(int season, int episode)? downloadIconBuilder;

  const _EpisodesView({
    super.key,
    required this.item,
    required this.seasonIndex,
    required this.loadingSeason,
    required this.onBack,
    required this.onSelectSeason,
    required this.onPlayEpisode,
    this.onDownloadEpisode,
    this.downloadIconBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final seasons = item.seasons;
    final safeIdx = seasonIndex.clamp(0, seasons.isEmpty ? 0 : seasons.length - 1);
    final season = seasons.isEmpty ? null : seasons[safeIdx];
    final eps = season?.episodes ?? const <EpisodeInfo>[];
    final bgUrl = (item.backdrop != null && item.backdrop!.isNotEmpty) ? item.backdrop : item.poster;

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E1116),
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        toolbarHeight: 64,
        leadingWidth: 68,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Center(
            child: _GlassButton(
              icon: Icons.arrow_back_rounded,
              tooltip: 'Volver',
              onTap: onBack,
              size: 44,
            ),
          ),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 17,
              ),
            ),
            if (season != null)
              Text(
                '${seasons.length} temporada${seasons.length == 1 ? '' : 's'} · ${eps.length} episodios',
                style: const TextStyle(color: Colors.white54, fontSize: 12.5),
              ),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: _border),
        ),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Fondo oscurecido (sin blur costoso: más fluido)
          if (bgUrl != null && bgUrl.isNotEmpty)
            CachedNetworkImage(
              imageUrl: bgUrl,
              fit: BoxFit.cover,
              memCacheWidth: 800,
              fadeInDuration: _mid,
              errorWidget: (_, __, ___) => const ColoredBox(color: _bg),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  _bg.withValues(alpha: 0.86),
                  _bg.withValues(alpha: 0.96),
                ],
              ),
            ),
          ),
          LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth >= 760;
            final list = _episodeList(context, season, eps, wide);

            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SeasonSidebar(
                    seasons: seasons,
                    activeIndex: safeIdx,
                    onSelect: onSelectSeason,
                  ),
                  Expanded(child: list),
                ],
              );
            }
            return Column(
              children: [
                if (seasons.length > 1)
                  _SeasonChips(
                    seasons: seasons,
                    activeIndex: safeIdx,
                    onSelect: onSelectSeason,
                  ),
                Expanded(child: list),
              ],
            );
          }),
        ],
      ),
    );
  }

  Widget _episodeList(BuildContext context, SeasonInfo? season, List<EpisodeInfo> eps, bool wide) {
    final Widget body;
    if (loadingSeason) {
      body = const Center(
        key: ValueKey('loading'),
        child: CircularProgressIndicator(color: _accent),
      );
    } else if (eps.isEmpty || season == null) {
      body = const Center(
        key: ValueKey('empty'),
        child: Text('Esta temporada aún no tiene episodios', style: TextStyle(color: Colors.white38)),
      );
    } else {
      body = ListView.separated(
        key: ValueKey('list-${season.number}'),
        padding: EdgeInsets.all(wide ? 24 : 14),
        itemCount: eps.length,
        separatorBuilder: (_, __) => SizedBox(height: wide ? 12 : 10),
        itemBuilder: (context, i) {
          final ep = eps[i];
          return RepaintBoundary(
            child: _EpisodeCard(
              ep: ep,
              wide: wide,
              onPlay: () => onPlayEpisode(season.number, ep.number),
              onDownload: onDownloadEpisode == null
                  ? null
                  : () => onDownloadEpisode!(season.number, ep.number, ep.title, ep.id),
              downloadIcon: downloadIconBuilder?.call(season.number, ep.number),
            ),
          );
        },
      );
    }
    return AnimatedSwitcher(
      duration: _mid,
      transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
      child: body,
    );
  }
}

class _SeasonSidebar extends StatelessWidget {
  final List<SeasonInfo> seasons;
  final int activeIndex;
  final ValueChanged<int> onSelect;

  const _SeasonSidebar({
    required this.seasons,
    required this.activeIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 230,
      decoration: BoxDecoration(
        color: _bg.withValues(alpha: 0.80),
        border: const Border(right: BorderSide(color: _border)),
      ),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        itemCount: seasons.length,
        itemBuilder: (context, i) {
          final s = seasons[i];
          final active = i == activeIndex;
          final hasName = s.name != null && s.name!.isNotEmpty && s.name != 'Temporada ${s.number}';
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _Tap(
              onTap: () => onSelect(i),
              radius: BorderRadius.circular(14),
              hoverScale: 1.02,
              child: AnimatedContainer(
                duration: _mid,
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: active ? _accent.withValues(alpha: 0.16) : Colors.white.withValues(alpha: 0.04),
                  border: Border.all(
                    color: active ? _accent.withValues(alpha: 0.7) : Colors.transparent,
                    width: 1.4,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Temporada ${s.number}',
                            style: TextStyle(
                              color: active ? Colors.white : Colors.white70,
                              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                              fontSize: 15,
                            ),
                          ),
                          if (hasName) ...[
                            const SizedBox(height: 2),
                            Text(
                              s.name!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white38, fontSize: 12),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (active) const Icon(Icons.chevron_right_rounded, color: _accent, size: 22),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SeasonChips extends StatelessWidget {
  final List<SeasonInfo> seasons;
  final int activeIndex;
  final ValueChanged<int> onSelect;

  const _SeasonChips({
    required this.seasons,
    required this.activeIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 62,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        itemCount: seasons.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final active = i == activeIndex;
          return _Tap(
            onTap: () => onSelect(i),
            radius: BorderRadius.circular(24),
            hoverScale: 1.04,
            child: AnimatedContainer(
              duration: _mid,
              curve: Curves.easeOut,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                color: active ? _accent : Colors.white.withValues(alpha: 0.08),
                border: Border.all(
                  color: active ? _accent : Colors.white.withValues(alpha: 0.14),
                ),
              ),
              child: Text(
                'Temporada ${seasons[i].number}',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 14,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _EpisodeCard extends StatelessWidget {
  final EpisodeInfo ep;
  final bool wide;
  final VoidCallback onPlay;
  final VoidCallback? onDownload;
  final Widget? downloadIcon;

  const _EpisodeCard({
    required this.ep,
    required this.wide,
    required this.onPlay,
    this.onDownload,
    this.downloadIcon,
  });

  @override
  Widget build(BuildContext context) {
    final thumbW = wide ? 190.0 : 116.0;
    final hasStill = ep.still != null && ep.still!.isNotEmpty;
    final title = (ep.title != null && ep.title!.isNotEmpty) ? ep.title! : 'Episodio ${ep.number}';
    final overview = ep.overview ?? '';
    final radius = BorderRadius.circular(16);

    return _Tap(
      onTap: onPlay,
      radius: radius,
      hoverScale: 1.015,
      child: Container(
        padding: EdgeInsets.all(wide ? 12 : 10),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: radius,
          border: Border.all(color: _border),
        ),
        child: Row(
          children: [
            // Miniatura con número y botón de play
            ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: SizedBox(
                width: thumbW,
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (hasStill)
                        CachedNetworkImage(
                          imageUrl: ep.still!,
                          fit: BoxFit.cover,
                          memCacheWidth: 420,
                          fadeInDuration: _fast,
                          errorWidget: (_, __, ___) => const ColoredBox(color: Color(0xFF12151C)),
                        )
                      else
                        const ColoredBox(color: Color(0xFF12151C)),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Colors.black.withValues(alpha: 0.55)],
                          ),
                        ),
                      ),
                      Positioned(
                        left: 8,
                        bottom: 6,
                        child: Text(
                          '${ep.number}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 18,
                            shadows: [Shadow(color: Colors.black87, blurRadius: 6)],
                          ),
                        ),
                      ),
                      Center(
                        child: Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.black.withValues(alpha: 0.45),
                            border: Border.all(color: Colors.white54),
                          ),
                          child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 24),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(width: wide ? 16 : 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: wide ? 15.5 : 14.5,
                    ),
                  ),
                  if (overview.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      overview,
                      maxLines: wide ? 3 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: wide ? 13 : 12.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (onDownload != null) ...[
              const SizedBox(width: 8),
              _GlassButton(
                icon: Icons.download_rounded,
                tooltip: 'Descargar',
                onTap: onDownload,
                size: 44,
                child: downloadIcon,
              ),
            ],
          ],
        ),
      ),
    );
  }
}