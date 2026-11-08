import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../data/models/download_item.dart';
import '../../../data/services/download_service.dart';
import '../repo/player/player.dart';
import '../widgets/focusable.dart';

/// Página de descargas optimizada para TV (foco D-pad).
class TvDownloadsPage extends StatefulWidget {
  const TvDownloadsPage({super.key});

  @override
  State<TvDownloadsPage> createState() => _TvDownloadsPageState();
}

class _TvDownloadsPageState extends State<TvDownloadsPage> {
  Future<void> _openThreadsModal() async {
    final svc = DownloadService.instance;
    var value = svc.maxParallel;
    final result = await showGeneralDialog<int>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Cerrar',
      barrierColor: Colors.black54,
      pageBuilder: (ctx, a1, a2) {
        return Center(
          child: Material(
            color: Colors.transparent,
            child: StatefulBuilder(
              builder: (ctx, setLocal) {
                return FocusTraversalGroup(
                  child: Container(
                    width: 420,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: const Color(0xFF141A22),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Hilos de descarga',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Izquierda / derecha para cambiar · arriba / abajo para botones',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                        const SizedBox(height: 20),
                        Focus(
                          autofocus: true,
                          onKeyEvent: (node, event) {
                            if (event is! KeyDownEvent) {
                              return KeyEventResult.ignored;
                            }
                            if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                                event.logicalKey == LogicalKeyboardKey.arrowDown &&
                                    false) {
                              // left
                            }
                            if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                              setLocal(() => value = (value - 1).clamp(1, 8));
                              return KeyEventResult.handled;
                            }
                            if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                              setLocal(() => value = (value + 1).clamp(1, 8));
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                          child: Builder(builder: (context) {
                            final f = Focus.of(context).hasFocus;
                            return AnimatedContainer(
                              duration: const Duration(milliseconds: 100),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 16),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: f ? Colors.white : Colors.white24,
                                  width: f ? 2.5 : 1,
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.chevron_left,
                                      color: Colors.white54),
                                  const SizedBox(width: 16),
                                  Text(
                                    '$value',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 36,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  const Icon(Icons.chevron_right,
                                      color: Colors.white54),
                                ],
                              ),
                            );
                          }),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          value == 1
                              ? '1 hilo (más estable)'
                              : '$value hilos en paralelo',
                          style: const TextStyle(color: Colors.white54),
                        ),
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: Focusable(
                                onTap: () => Navigator.pop(ctx, null),
                                builder: (f) => Container(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: f
                                        ? Colors.white24
                                        : Colors.white.withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                        color: f
                                            ? Colors.white
                                            : Colors.transparent,
                                        width: 2),
                                  ),
                                  child: const Text('Cancelar',
                                      style: TextStyle(color: Colors.white70)),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Focusable(
                                onTap: () => Navigator.pop(ctx, value),
                                builder: (f) => Container(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: f
                                        ? Colors.white
                                        : const Color(0xFFE50914),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                        color: f
                                            ? const Color(0xFFE50914)
                                            : Colors.transparent,
                                        width: 2),
                                  ),
                                  child: Text('Aceptar',
                                      style: TextStyle(
                                          color: f
                                              ? Colors.black
                                              : Colors.white,
                                          fontWeight: FontWeight.w700)),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
    if (result != null) {
      await svc.setMaxParallel(result);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<DownloadService>();
    final items = svc.items;

    return Scaffold(
      backgroundColor: const Color(0xFF0B0E14),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 16, 28, 8),
              child: Row(
                children: [
                  Focusable(
                    autofocus: true,
                    onTap: () => Navigator.pop(context),
                    builder: (f) => Icon(
                      Icons.arrow_back_rounded,
                      color: f ? Colors.white : Colors.white70,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 16),
                  const Text(
                    'Descargas',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'Hilos: ${svc.maxParallel}',
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                  const SizedBox(width: 12),
                  Focusable(
                    onTap: _openThreadsModal,
                    builder: (f) => Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: f ? Colors.white24 : Colors.white10,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: f ? Colors.white : Colors.transparent,
                            width: 2),
                      ),
                      child: const Text('Cambiar hilos',
                          style:
                              TextStyle(color: Colors.white70, fontSize: 12)),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: items.isEmpty
                  ? const Center(
                      child: Text('No hay descargas',
                          style:
                              TextStyle(color: Colors.white54, fontSize: 16)),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(28, 8, 28, 32),
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (ctx, i) => _TvTile(item: items[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TvTile extends StatelessWidget {
  final DownloadItem item;
  const _TvTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final svc = DownloadService.instance;
    return Focusable(
      onTap: () {},
      builder: (f) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF141A22),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: f ? Colors.white : Colors.white10,
            width: f ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 64,
                height: 90,
                child: item.poster != null
                    ? CachedNetworkImage(
                        imageUrl: item.poster!,
                        fit: BoxFit.cover,
                        memCacheWidth: 128)
                    : const ColoredBox(color: Colors.black26),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.displayTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600)),
                  Text(
                      'Repo: ${item.repoName} · ${item.serverName} · ${item.kind.name.toUpperCase()}',
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 12)),
                  const SizedBox(height: 6),
                  Text(
                    _status(item),
                    style: TextStyle(
                        color: _color(item),
                        fontSize: 13,
                        fontWeight: FontWeight.w600),
                  ),
                  if (item.status == DownloadStatus.downloading) ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: item.progress.clamp(0.0, 1.0),
                      minHeight: 4,
                      color: const Color(0xFF7DD3FC),
                      backgroundColor: Colors.white12,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (item.status == DownloadStatus.completed)
              Focusable(
                onTap: () {
                  final server = svc.offlineServerFor(
                    repoId: item.repoId,
                    contentId: item.contentId,
                    season: item.season,
                    episode: item.episode,
                  );
                  if (server == null) return;
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PlayerPage(
                        title: item.displayTitle,
                        url: server.url,
                        poster: item.poster,
                        contentType: item.type,
                        servers: [server],
                        season: item.season,
                        episode: item.episode,
                        isTv: true,
                      ),
                    ),
                  );
                },
                builder: (pf) => Icon(Icons.play_circle_fill,
                    color: pf ? Colors.white : const Color(0xFF4CAF50),
                    size: 36),
              ),
            if (item.status == DownloadStatus.downloading ||
                item.status == DownloadStatus.queued)
              Focusable(
                onTap: () => svc.cancel(item.id),
                builder: (cf) =>
                    Icon(Icons.close, color: cf ? Colors.white : Colors.white54),
              ),
            Focusable(
              onTap: () => svc.remove(item.id),
              builder: (rf) => Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Icon(Icons.delete_outline,
                    color: rf ? Colors.redAccent : Colors.white38),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _status(DownloadItem item) {
    switch (item.status) {
      case DownloadStatus.queued:
        return 'En cola';
      case DownloadStatus.downloading:
        return 'Descargando ${(item.progress * 100).toStringAsFixed(0)}% · ${item.sizeLabel}';
      case DownloadStatus.completed:
        return 'Completada · ${item.sizeLabel}';
      case DownloadStatus.failed:
        return 'Error';
      case DownloadStatus.converting:
        return 'Convirtiendo…';
      case DownloadStatus.cancelled:
        return 'Cancelada';
      case DownloadStatus.paused:
        return 'Pausada';
    }
  }

  static Color _color(DownloadItem item) {
    switch (item.status) {
      case DownloadStatus.completed:
        return const Color(0xFF4CAF50);
      case DownloadStatus.downloading:
      case DownloadStatus.converting:
        return const Color(0xFF7DD3FC);
      case DownloadStatus.failed:
      case DownloadStatus.cancelled:
        return Colors.redAccent;
      default:
        return Colors.white54;
    }
  }
}
