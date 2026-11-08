import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../data/models/download_item.dart';
import '../../data/models/stream_server.dart';
import '../../data/services/download_service.dart';
import '../../data/services/settings_service.dart';
import '../tv/repo/player/player.dart' as tv_player;
import '../mobile/repo/player/player.dart' as mobile_player;

/// Página de descargas (TV y móvil).
class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<DownloadService>.value(
      value: DownloadService.instance,
      child: const _DownloadsBody(),
    );
  }
}

class _DownloadsBody extends StatelessWidget {
  const _DownloadsBody();

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<DownloadService>();
    final items = svc.items;

    return Scaffold(
      backgroundColor: const Color(0xFF0B0E14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B0E14),
        title: const Text('Descargas', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (svc.activeCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  '${svc.activeCount} activas',
                  style: const TextStyle(color: Color(0xFF7DD3FC), fontSize: 13),
                ),
              ),
            ),
        ],
      ),
      body: items.isEmpty
          ? const Center(
              child: Text(
                'No hay descargas',
                style: TextStyle(color: Colors.white54, fontSize: 16),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (ctx, i) => _DownloadTile(item: items[i]),
            ),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  final DownloadItem item;
  const _DownloadTile({required this.item});

  Color get _statusColor {
    switch (item.status) {
      case DownloadStatus.completed:
        return const Color(0xFF4CAF50);
      case DownloadStatus.downloading:
      case DownloadStatus.converting:
        return const Color(0xFF7DD3FC);
      case DownloadStatus.failed:
      case DownloadStatus.cancelled:
        return Colors.redAccent;
      case DownloadStatus.paused:
        return Colors.orangeAccent;
      case DownloadStatus.queued:
        return Colors.white54;
    }
  }

  String get _statusLabel {
    switch (item.status) {
      case DownloadStatus.queued:
        return 'En cola';
      case DownloadStatus.downloading:
        return 'Descargando ${(item.progress * 100).toStringAsFixed(0)}%';
      case DownloadStatus.paused:
        return 'Pausada';
      case DownloadStatus.completed:
        return 'Completada';
      case DownloadStatus.failed:
        return 'Error';
      case DownloadStatus.converting:
        return 'Convirtiendo…';
      case DownloadStatus.cancelled:
        return 'Cancelada';
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = DownloadService.instance;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF141A22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 56,
              height: 80,
              child: item.poster != null && item.poster!.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: item.poster!,
                      fit: BoxFit.cover,
                      memCacheWidth: 120,
                      errorWidget: (_, __, ___) =>
                          const ColoredBox(color: Colors.black26),
                    )
                  : const ColoredBox(
                      color: Colors.black26,
                      child: Icon(Icons.movie, color: Colors.white24),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.displayTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Repo: ${item.repoName}',
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
                Text(
                  [
                    item.serverName,
                    if (item.quality != null) item.quality!,
                    item.kind.name.toUpperCase(),
                    item.sizeLabel,
                  ].join(' · '),
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
                const SizedBox(height: 6),
                Text(
                  _statusLabel,
                  style: TextStyle(color: _statusColor, fontSize: 12, fontWeight: FontWeight.w600),
                ),
                if (item.status == DownloadStatus.downloading ||
                    item.status == DownloadStatus.converting) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: item.progress.clamp(0.0, 1.0),
                      minHeight: 4,
                      backgroundColor: Colors.white12,
                      color: const Color(0xFF7DD3FC),
                    ),
                  ),
                ],
                if (item.error != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    item.error!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 11),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (item.status == DownloadStatus.downloading ||
                        item.status == DownloadStatus.queued)
                      TextButton(
                        onPressed: () => svc.cancel(item.id),
                        child: const Text('Cancelar',
                            style: TextStyle(color: Colors.white70, fontSize: 12)),
                      ),
                    if (item.status == DownloadStatus.failed ||
                        item.status == DownloadStatus.cancelled)
                      TextButton(
                        onPressed: () => svc.retry(item.id),
                        child: const Text('Reintentar',
                            style: TextStyle(color: Color(0xFF7DD3FC), fontSize: 12)),
                      ),
                    if (item.status == DownloadStatus.completed &&
                        item.localPath != null)
                      TextButton(
                        onPressed: () {
                          final server = DownloadService.instance.offlineServerFor(
                            repoId: item.repoId,
                            contentId: item.contentId,
                            season: item.season,
                            episode: item.episode,
                          );
                          if (server == null) return;
                          final isTv = context.read<SettingsService>().isTv;
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => isTv
                                  ? tv_player.PlayerPage(
                                      title: item.displayTitle,
                                      url: server.url,
                                      poster: item.poster,
                                      contentType: item.type,
                                      servers: [server],
                                      season: item.season,
                                      episode: item.episode,
                                      isTv: true,
                                    )
                                  : mobile_player.PlayerPage(
                                      title: item.displayTitle,
                                      url: server.url,
                                      poster: item.poster,
                                      contentType: item.type,
                                      servers: [server],
                                      season: item.season,
                                      episode: item.episode,
                                      isTv: false,
                                    ),
                            ),
                          );
                        },
                        child: const Text('Reproducir',
                            style: TextStyle(color: Color(0xFF4CAF50), fontSize: 12)),
                      ),
                    TextButton(
                      onPressed: () => svc.remove(item.id),
                      child: const Text('Eliminar',
                          style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
