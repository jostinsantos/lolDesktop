import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../../data/models/repo_manifest.dart';
import '../../../data/services/library_service.dart';
import '../contenido/contenido.dart';
import '../player/player.dart';

const _card = Color(0xFF161A22);
const _accent = Color(0xFFE50914);

class BibliotecaPage extends StatelessWidget {
  final InstalledRepo repo;
  const BibliotecaPage({super.key, required this.repo});

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryService>();
    final watching = lib.continueWatching(repo.manifest.id);
    final favs = lib.favorites(repo.manifest.id);

    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            indicatorColor: _accent,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white54,
            tabs: [
              Tab(text: 'Continuar viendo'),
              Tab(text: 'Favoritos'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _buildList(context, watching, empty: 'Nada en progreso'),
                _buildList(context, favs, empty: 'Sin favoritos', isFav: true),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context, List items, {required String empty, bool isFav = false}) {
    if (items.isEmpty) {
      return Center(child: Text(empty, style: const TextStyle(color: Colors.white38)));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(24),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final e = items[i];
        final title = isFav ? (e.title as String? ?? '') : (e.title as String? ?? '');
        final poster = isFav ? (e.poster as String?) : (e.poster as String?);
        final contentId = isFav ? (e.contentId as String? ?? '') : (e.contentId as String? ?? '');

        return Material(
          color: _card,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              if (contentId.isEmpty) return;
              if (!isFav) {
                final pos = (e.positionMs as int?) ?? 0;
                final type = (e.type as String?) ?? 'movie';
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => DesktopPlayerPage(
                      title: title,
                      repo: repo,
                      contentId: contentId,
                      poster: poster,
                      contentType: type,
                      startPositionMs: pos,
                    ),
                  ),
                );
                return;
              }
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DetailsPage(repo: repo, itemId: contentId),
                ),
              );
            },
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 52,
                      height: 78,
                      child: poster != null && poster.isNotEmpty
                          ? CachedNetworkImage(imageUrl: poster, fit: BoxFit.cover)
                          : Container(color: const Color(0xFF12151C)),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
