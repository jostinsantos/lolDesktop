import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../data/models/download_item.dart';
import '../../../data/services/download_service.dart';
import '../repo/player/player.dart';

/// Página de descargas móvil (táctil + conversión + hilos).
class MobileDownloadsPage extends StatelessWidget {
  const MobileDownloadsPage({super.key});

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
      ),
      body: Column(
        children: [
          // Controles globales
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                const Text('Hilos de descarga',
                    style: TextStyle(color: Colors.white70, fontSize: 13)),
                const Spacer(),
                IconButton(
                  onPressed: svc.maxParallel > 1
                      ? () => svc.setMaxParallel(svc.maxParallel - 1)
                      : null,
                  icon: const Icon(Icons.remove_circle_outline, color: Colors.white54),
                ),
                Text('${svc.maxParallel}',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
                IconButton(
                  onPressed: svc.maxParallel < 8
                      ? () => svc.setMaxParallel(svc.maxParallel + 1)
                      : null,
                  icon: const Icon(Icons.add_circle_outline, color: Colors.white54),
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white12, height: 1),
          Expanded(
            child: items.isEmpty
                ? const Center(
                    child: Text('No hay descargas',
                        style: TextStyle(color: Colors.white54)))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (ctx, i) => _MobileTile(item: items[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

class _MobileTile extends StatelessWidget {
  final DownloadItem item;
  const _MobileTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final svc = DownloadService.instance;
    final canConvert = item.status == DownloadStatus.completed &&
        item.localPath != null &&
        (item.kind == DownloadKind.hls ||
            item.kind == DownloadKind.ts ||
            (item.localPath!.endsWith('.ts') || item.localPath!.endsWith('.m3u8')));

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
              child: item.poster != null
                  ? CachedNetworkImage(
                      imageUrl: item.poster!, fit: BoxFit.cover, memCacheWidth: 120)
                  : const ColoredBox(color: Colors.black26),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.displayTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
                Text('Repo: ${item.repoName}',
                    style: const TextStyle(color: Colors.white38, fontSize: 11)),
                Text(
                  [
                    item.serverName,
                    if (item.quality != null) item.quality!,
                    item.kind.name.toUpperCase(),
                    item.sizeLabel,
                  ].join(' · '),
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
                const SizedBox(height: 4),
                Text(_label(item),
                    style: TextStyle(
                        color: _color(item), fontSize: 12, fontWeight: FontWeight.w600)),
                if (item.status == DownloadStatus.downloading ||
                    item.status == DownloadStatus.converting) ...[
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: item.progress.clamp(0.0, 1.0),
                    minHeight: 4,
                    color: const Color(0xFF7DD3FC),
                    backgroundColor: Colors.white12,
                  ),
                ],
                const SizedBox(height: 6),
                Wrap(
                  spacing: 4,
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
                    if (item.status == DownloadStatus.completed)
                      TextButton(
                        onPressed: () {
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
                                isTv: false,
                              ),
                            ),
                          );
                        },
                        child: const Text('Reproducir',
                            style: TextStyle(color: Color(0xFF4CAF50), fontSize: 12)),
                      ),
                    if (canConvert)
                      TextButton(
                        onPressed: () => svc.convertItem(item.id),
                        child: Text(
                          item.kind == DownloadKind.hls ||
                                  (item.localPath?.endsWith('.m3u8') ?? false)
                              ? 'Convertir a MP4'
                              : 'Convertir a MKV',
                          style: const TextStyle(color: Color(0xFFFFB74D), fontSize: 12),
                        ),
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

  static String _label(DownloadItem item) {
    switch (item.status) {
      case DownloadStatus.queued:
        return 'En cola';
      case DownloadStatus.downloading:
        return 'Descargando ${(item.progress * 100).toStringAsFixed(0)}%';
      case DownloadStatus.completed:
        return 'Completada';
      case DownloadStatus.failed:
        return 'Error${item.error != null ? ': ${item.error}' : ''}';
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
