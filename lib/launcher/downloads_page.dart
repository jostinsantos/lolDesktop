import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../data/services/download_service.dart';
import '../data/models/download_item.dart';
import '../data/services/repo_manager.dart';
import '../repo/player/player.dart';
import '../repo/contenido/contenido.dart';
import '../data/models/repo_manifest.dart';

const _card = Color(0xFF141820);
const _accent = Color(0xFFE50914);
const _border = Color(0xFF1C222C);

/// Página de descargas: progreso, completadas agrupadas y play en el player.
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  @override
  void initState() {
    super.initState();
    DownloadService.instance.setHideOverlay(true);
  }

  @override
  void dispose() {
    DownloadService.instance.setHideOverlay(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    DownloadService? svc;
    try {
      svc = context.watch<DownloadService>();
    } catch (_) {
      try {
        svc = DownloadService.instance;
      } catch (_) {}
    }

    if (svc == null) {
      return const Center(
        child: Text(
          'Servicio de descargas no disponible.\nAñade DownloadService en main.dart',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white38),
        ),
      );
    }
    final DownloadService service = svc;

    final items = service.items;
    final active = items
        .where((e) =>
            e.status == DownloadStatus.downloading ||
            e.status == DownloadStatus.queued ||
            e.status == DownloadStatus.converting ||
            e.status == DownloadStatus.paused)
        .toList();
    final done = items.where((e) => e.status == DownloadStatus.completed).toList();
    final failed = items
        .where((e) =>
            e.status == DownloadStatus.failed || e.status == DownloadStatus.cancelled)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Controles: hilos por descarga + descargas simultáneas + espacio
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 12, 28, 4),
          child: Row(
            children: [
              const Text('Hilos',
                  style: TextStyle(color: Colors.white54, fontSize: 13)),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Menos hilos (conexiones por descarga)',
                onPressed: service.maxParallel > 1
                    ? () => service.setMaxParallel(service.maxParallel - 1)
                    : null,
                icon: const Icon(Icons.remove_circle_outline, color: Colors.white54, size: 20),
                visualDensity: VisualDensity.compact,
              ),
              Text(
                '${service.maxParallel}',
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
              ),
              IconButton(
                tooltip: 'Más hilos (hasta 8)',
                onPressed: service.maxParallel < 8
                    ? () => service.setMaxParallel(service.maxParallel + 1)
                    : null,
                icon: const Icon(Icons.add_circle_outline, color: Colors.white54, size: 20),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 16),
              const Text('A la vez',
                  style: TextStyle(color: Colors.white54, fontSize: 13)),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Menos descargas simultáneas',
                onPressed: service.maxConcurrent > 1
                    ? () => service.setMaxConcurrent(service.maxConcurrent - 1)
                    : null,
                icon: const Icon(Icons.remove_circle_outline, color: Colors.white54, size: 20),
                visualDensity: VisualDensity.compact,
              ),
              Text(
                '${service.maxConcurrent}',
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
              ),
              IconButton(
                tooltip: 'Más descargas a la vez (hasta 3)',
                onPressed: service.maxConcurrent < 3
                    ? () => service.setMaxConcurrent(service.maxConcurrent + 1)
                    : null,
                icon: const Icon(Icons.add_circle_outline, color: Colors.white54, size: 20),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 8),
              Text(
                '· hilos=segmentos · a la vez=títulos en paralelo',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.35), fontSize: 11),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _showStorage(context, service),
                icon: const Icon(Icons.storage_outlined, size: 16, color: Colors.white54),
                label: const Text('Espacio', style: TextStyle(color: Colors.white54, fontSize: 12)),
              ),
            ],
          ),
        ),
        const Divider(color: Colors.white12, height: 1),
        Expanded(
          child: items.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.download_rounded, size: 56, color: Colors.white24),
                      SizedBox(height: 16),
                      Text('No hay descargas',
                          style: TextStyle(color: Colors.white54, fontSize: 16)),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(28, 16, 28, 40),
                  children: [
                    if (active.isNotEmpty) ...[
                      _section('En curso (${active.length})'),
                      for (final it in active)
                        _DownloadTile(item: it, svc: service, onPlay: null),
                      const SizedBox(height: 16),
                    ],
                    if (done.isNotEmpty) ...[
                      _section('Completadas (${done.length})'),
                      ..._buildCompletedGroups(context, done, service),
                      const SizedBox(height: 16),
                    ],
                    if (failed.isNotEmpty) ...[
                      _section('Canceladas / error (${failed.length})'),
                      for (final it in failed)
                        _DownloadTile(item: it, svc: service, onPlay: null),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  static Future<void> _showStorage(BuildContext context, DownloadService svc) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: Card(
          color: Color(0xFF1A1F2A),
          child: Padding(
            padding: EdgeInsets.all(24),
            child: SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 3, color: Color(0xFF7DD3FC)),
            ),
          ),
        ),
      ),
    );
    final used = await svc.usedDownloadBytes();
    final free = await svc.freeSpaceBytes();
    final tree = await svc.listDownloadTree();
    final root = await svc.downloadsRootPath();
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1A1F2A),
              title: const Text('Almacenamiento de descargas',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              content: SizedBox(
                width: 480,
                height: 420,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Ocupado: ${DownloadService.formatBytes(used)}',
                        style: const TextStyle(color: Colors.white70)),
                    const SizedBox(height: 4),
                    Text(
                      free != null
                          ? 'Libre: ${DownloadService.formatBytes(free)}'
                          : 'Libre: no disponible',
                      style: const TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                    const SizedBox(height: 4),
                    Text(root,
                        style: const TextStyle(color: Colors.white38, fontSize: 11)),
                    const SizedBox(height: 10),
                    const Divider(color: Colors.white12),
                    Expanded(
                      child: tree.isEmpty
                          ? const Center(
                              child: Text('No hay carpetas de descarga',
                                  style: TextStyle(color: Colors.white38)))
                          : ListView.builder(
                              itemCount: tree.length,
                              itemBuilder: (_, i) {
                                final folder = tree[i];
                                final files = (folder['files'] as List?) ?? [];
                                return ExpansionTile(
                                  iconColor: Colors.white54,
                                  collapsedIconColor: Colors.white38,
                                  title: Text(
                                    '${folder['name']}',
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 13),
                                  ),
                                  subtitle: Text(
                                    DownloadService.formatBytes(folder['size'] as int),
                                    style: const TextStyle(
                                        color: Colors.white54, fontSize: 11),
                                  ),
                                  trailing: IconButton(
                                    tooltip: 'Borrar carpeta',
                                    icon: const Icon(Icons.delete_outline,
                                        color: Colors.redAccent, size: 18),
                                    onPressed: () async {
                                      final ok = await showDialog<bool>(
                                        context: ctx,
                                        builder: (c2) => AlertDialog(
                                          backgroundColor: const Color(0xFF1A1F2A),
                                          title: const Text('¿Borrar?',
                                              style: TextStyle(color: Colors.white)),
                                          content: Text(
                                            'Se eliminará:\n${folder['path']}',
                                            style: const TextStyle(color: Colors.white70),
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () => Navigator.pop(c2, false),
                                              child: const Text('Cancelar',
                                                  style: TextStyle(color: Colors.white54)),
                                            ),
                                            TextButton(
                                              onPressed: () => Navigator.pop(c2, true),
                                              child: const Text('Borrar',
                                                  style: TextStyle(color: Colors.redAccent)),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (ok == true) {
                                        await svc.deleteDownloadFolder(folder['path'] as String);
                                        if (ctx.mounted) Navigator.pop(ctx);
                                      }
                                    },
                                  ),
                                  children: [
                                    for (final f in files)
                                      ListTile(
                                        dense: true,
                                        title: Text(
                                          '${f['name']}',
                                          style: const TextStyle(
                                              color: Colors.white70, fontSize: 12),
                                        ),
                                        subtitle: Text(
                                          DownloadService.formatBytes(f['size'] as int),
                                          style: const TextStyle(
                                              color: Colors.white38, fontSize: 11),
                                        ),
                                      ),
                                  ],
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton.icon(
                  onPressed: () => svc.openDownloadsFolder(root),
                  icon: const Icon(Icons.folder_open, color: Color(0xFF7DD3FC), size: 18),
                  label: const Text('Abrir carpeta',
                      style: TextStyle(color: Color(0xFF7DD3FC))),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cerrar', style: TextStyle(color: Colors.white54)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  static Widget _section(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 10, top: 4),
        child: Text(t,
            style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700, fontSize: 14)),
      );

  static List<Widget> _buildCompletedGroups(
    BuildContext context,
    List<DownloadItem> done,
    DownloadService svc,
  ) {
    // Películas sueltas
    final movies = done.where((e) => e.season == null || e.episode == null).toList();
    // Series: agrupar por contentId + season
    final seriesEps = done.where((e) => e.season != null && e.episode != null).toList();
    final Map<String, List<DownloadItem>> groups = {};
    for (final e in seriesEps) {
      final key = '${e.repoId}::${e.contentId}::S${e.season}';
      groups.putIfAbsent(key, () => []).add(e);
    }
    for (final list in groups.values) {
      list.sort((a, b) => (a.episode ?? 0).compareTo(b.episode ?? 0));
    }

    final out = <Widget>[];
    for (final m in movies) {
      out.add(_DownloadTile(
        item: m,
        svc: svc,
        onPlay: () => _playLocal(context, m),
      ));
    }
    final keys = groups.keys.toList()
      ..sort((a, b) {
        final ga = groups[a]!.first;
        final gb = groups[b]!.first;
        final c = ga.title.compareTo(gb.title);
        if (c != 0) return c;
        return (ga.season ?? 0).compareTo(gb.season ?? 0);
      });
    for (final key in keys) {
      final list = groups[key]!;
      final head = list.first;
      out.add(_SeasonAccordion(
        title: head.title,
        season: head.season ?? 0,
        poster: head.poster,
        episodes: list,
        svc: svc,
        onPlay: (it) => _playLocal(context, it),
        onMoreEpisodes: () => _openSeriesDetails(context, head),
      ));
    }
    return out;
  }

  /// Abre el repo + ficha de la serie para descargar más capítulos.
  static void _openSeriesDetails(BuildContext context, DownloadItem head) {
    InstalledRepo? repo;
    try {
      final mgr = context.read<RepoManager>();
      for (final r in mgr.installed) {
        if (r.manifest.id == head.repoId) {
          repo = r;
          break;
        }
      }
    } catch (_) {}

    if (repo == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'El repo "${head.repoName}" no está instalado. Instálalo para ver más capítulos.',
          ),
        ),
      );
      return;
    }

    // contentId puede venir como "seriesId" o "seriesId/ep" / "seriesId:…"
    var seriesId = head.contentId;
    final slash = seriesId.indexOf('/');
    if (slash > 0) seriesId = seriesId.substring(0, slash);
    final colon = seriesId.indexOf(':');
    if (colon > 0) seriesId = seriesId.substring(0, colon);

    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DetailsPage(
        repo: repo!,
        itemId: seriesId,
        season: head.season,
      ),
    ));
  }

  static void _playLocal(BuildContext context, DownloadItem item) {
    final path = item.localPath;
    if (path == null || path.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Archivo local no encontrado')),
      );
      return;
    }
    InstalledRepo? repo;
    try {
      final mgr = context.read<RepoManager>();
      for (final r in mgr.installed) {
        if (r.manifest.id == item.repoId) {
          repo = r;
          break;
        }
      }
    } catch (_) {}

    // Repo mínimo si ya no está instalado
    repo ??= InstalledRepo(
      manifest: RepoManifest(
        id: item.repoId,
        name: item.repoName,
        version: '0',
        description: '',
        author: '',
        repo: '',
      ),
      sourceUrl: '',
      installedAt: DateTime.now(),
    );

    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DesktopPlayerPage(
        title: item.displayTitle,
        repo: repo!,
        contentId: item.contentId,
        poster: item.poster,
        contentType: item.type,
        season: item.season,
        episode: item.episode,
        localPath: path,
      ),
    ));
  }
}

class _SeasonAccordion extends StatefulWidget {
  final String title;
  final int season;
  final String? poster;
  final List<DownloadItem> episodes;
  final DownloadService svc;
  final void Function(DownloadItem) onPlay;
  final VoidCallback? onMoreEpisodes;

  const _SeasonAccordion({
    required this.title,
    required this.season,
    required this.poster,
    required this.episodes,
    required this.svc,
    required this.onPlay,
    this.onMoreEpisodes,
  });

  @override
  State<_SeasonAccordion> createState() => _SeasonAccordionState();
}

class _SeasonAccordionState extends State<_SeasonAccordion> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 48,
                      height: 68,
                      child: widget.poster != null && widget.poster!.isNotEmpty
                          ? CachedNetworkImage(imageUrl: widget.poster!, fit: BoxFit.cover)
                          : Container(color: const Color(0xFF12151C)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14.5),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Temporada ${widget.season} · ${widget.episodes.length} episodio(s)',
                          style: const TextStyle(color: Colors.white54, fontSize: 12.5),
                        ),
                        if (widget.onMoreEpisodes != null) ...[
                          const SizedBox(height: 8),
                          TextButton.icon(
                            onPressed: widget.onMoreEpisodes,
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFF7DD3FC),
                              backgroundColor:
                                  const Color(0xFF7DD3FC).withValues(alpha: 0.12),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                            ),
                            icon: const Icon(Icons.playlist_add_rounded, size: 16),
                            label: const Text(
                              'Ver más capítulos',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Icon(
                    _open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    color: Colors.white54,
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            ...widget.episodes.map(
              (ep) => Container(
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: _border)),
                ),
                child: _DownloadTile(
                  item: ep,
                  svc: widget.svc,
                  onPlay: () => widget.onPlay(ep),
                  compact: true,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  final DownloadItem item;
  final DownloadService svc;
  final VoidCallback? onPlay;
  final bool compact;

  const _DownloadTile({
    required this.item,
    required this.svc,
    required this.onPlay,
    this.compact = false,
  });

  String _statusLabel() {
    switch (item.status) {
      case DownloadStatus.queued:
        return 'En cola';
      case DownloadStatus.downloading:
        return 'Descargando…';
      case DownloadStatus.converting:
        return 'Convirtiendo…';
      case DownloadStatus.paused:
        return 'Pausada';
      case DownloadStatus.completed:
        return 'Completada';
      case DownloadStatus.failed:
        return 'Error';
      case DownloadStatus.cancelled:
        return 'Cancelada';
    }
  }

  Color _statusColor() {
    switch (item.status) {
      case DownloadStatus.downloading:
      case DownloadStatus.converting:
        return const Color(0xFF7DD3FC);
      case DownloadStatus.completed:
        return const Color(0xFF4ADE80);
      case DownloadStatus.failed:
        return Colors.redAccent;
      case DownloadStatus.cancelled:
        return Colors.white38;
      default:
        return Colors.white54;
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = item.progress.clamp(0.0, 1.0);
    final showBar = item.status == DownloadStatus.downloading ||
        item.status == DownloadStatus.converting ||
        item.status == DownloadStatus.queued;

    return Container(
      margin: compact ? EdgeInsets.zero : const EdgeInsets.only(bottom: 10),
      padding: EdgeInsets.all(compact ? 10 : 14),
      decoration: compact
          ? null
          : BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _border),
            ),
      child: Row(
        children: [
          if (!compact) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 56,
                height: 80,
                child: item.poster != null && item.poster!.isNotEmpty
                    ? CachedNetworkImage(imageUrl: item.poster!, fit: BoxFit.cover)
                    : Container(
                        color: const Color(0xFF12151C),
                        child: const Icon(Icons.movie, color: Colors.white24),
                      ),
              ),
            ),
            const SizedBox(width: 14),
          ] else
            const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  compact
                      ? (item.episodeTitle?.isNotEmpty == true
                          ? 'E${item.episode} · ${item.episodeTitle}'
                          : 'Episodio ${item.episode}')
                      : item.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13.5),
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    'Repo: ${item.repoName}',
                    item.serverName,
                    item.quality,
                    if (item.status == DownloadStatus.completed) item.sizeLabel,
                  ].where((e) => e != null && e.toString().isNotEmpty).join(' · '),
                  style: const TextStyle(color: Colors.white38, fontSize: 11.5),
                ),
                const SizedBox(height: 4),
                Text(_statusLabel(),
                    style: TextStyle(color: _statusColor(), fontSize: 12, fontWeight: FontWeight.w600)),
                if (showBar) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: item.status == DownloadStatus.queued ? null : progress,
                      minHeight: 4,
                      backgroundColor: Colors.white12,
                      color: _accent,
                    ),
                  ),
                  if (item.status == DownloadStatus.downloading) ...[
                    const SizedBox(height: 3),
                    Builder(builder: (_) {
                      final eta = svc.etaLabel(item.id);
                      final bps = svc.speedBps(item.id);
                      final speedTxt = bps > 1024 * 1024
                          ? '${(bps / (1024 * 1024)).toStringAsFixed(1)} MB/s'
                          : (bps > 1024
                              ? '${(bps / 1024).toStringAsFixed(0)} KB/s'
                              : null);
                      if (eta == null && speedTxt == null) {
                        return const SizedBox.shrink();
                      }
                      return Text(
                        [
                          if (speedTxt != null) speedTxt,
                          if (eta != null) 'ETA $eta',
                        ].join(' · '),
                        style: const TextStyle(color: Colors.white38, fontSize: 11),
                      );
                    }),
                  ],
                ],
                if (item.error != null && item.error!.isNotEmpty)
                  Text(item.error!, style: const TextStyle(color: Colors.redAccent, fontSize: 11)),
              ],
            ),
          ),
          if (onPlay != null && item.status == DownloadStatus.completed)
            IconButton(
              tooltip: 'Reproducir',
              onPressed: onPlay,
              icon: const Icon(Icons.play_circle_fill_rounded, color: _accent, size: 32),
            ),
          if (item.status == DownloadStatus.completed &&
              item.localPath != null &&
              item.localPath!.isNotEmpty)
            IconButton(
              tooltip: 'Abrir ubicación',
              onPressed: () {
                final path = item.localPath!;
                final i = path.replaceAll(r'\', '/').lastIndexOf('/');
                final folder = i > 0 ? path.substring(0, i) : path;
                svc.openDownloadsFolder(folder);
              },
              icon: const Icon(Icons.folder_open, color: Colors.white54, size: 22),
            ),
          if (item.status == DownloadStatus.downloading || item.status == DownloadStatus.queued)
            IconButton(
              tooltip: 'Cancelar',
              onPressed: () => svc.cancel(item.id),
              icon: const Icon(Icons.close, color: Colors.white54),
            )
          else if (item.status == DownloadStatus.completed ||
              item.status == DownloadStatus.failed ||
              item.status == DownloadStatus.cancelled)
            IconButton(
              tooltip: 'Eliminar',
              onPressed: () => svc.remove(item.id),
              icon: const Icon(Icons.delete_outline, color: Colors.white38),
            ),
        ],
      ),
    );
  }
}
