import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../data/models/repo_manifest.dart';
import '../../../../data/services/library_service.dart';
import '../../../../data/services/repo_prefs.dart';
import '../../../../data/services/settings_service.dart';
import '../../widgets/focusable.dart';
import '../player/player.dart';
import '../contenido/contenido.dart';

class RepoLibraryPage extends StatelessWidget {
  final InstalledRepo repo;
  const RepoLibraryPage({super.key, required this.repo});

  Future<void> _openPlayer(BuildContext context, WatchEntry e) async {
    final prefs = context.read<RepoPrefs>();
    final isTv = context.read<SettingsService>().isTv;
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
        preferredLanguage: prefs.preferredLanguage(repo.manifest.id),
        isTv: isTv,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryService>();
    final watching = lib.continueWatching(repo.manifest.id);
    final favs = lib.favorites(repo.manifest.id);

    return ListView(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 20, 24, 8),
          child: Text('Historial · Continuar viendo',
              style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
        ),
        if (watching.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text('Aún no hay historial', style: TextStyle(color: Colors.white38)),
          )
        else
          SizedBox(
            height: 170,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: watching.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, i) {
                final e = watching[i];
                return Focusable(
                  onTap: () => _openPlayer(context, e),
                  builder: (focused) => AnimatedContainer(
                    duration: const Duration(milliseconds: 100),
                    width: 120,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: focused ? const Color(0xFFFF2D2D) : Colors.transparent,
                        width: 2.5,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          e.poster != null
                              ? Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    CachedNetworkImage(imageUrl: e.poster!, fit: BoxFit.cover),
                                    Positioned(
                                      left: 0, right: 0, top: 0, height: 42,
                                      child: IgnorePointer(
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: Alignment.topCenter,
                                              end: Alignment.bottomCenter,
                                              colors: [
                                                Colors.white.withValues(alpha: 0.22),
                                                Colors.transparent,
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                )
                              : Container(color: const Color(0xFF1A222D)),
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: LinearProgressIndicator(
                              value: e.progress,
                              minHeight: 3,
                              color: const Color(0xFFE50914),
                              backgroundColor: Colors.white12,
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
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 24, 24, 12),
          child: Text('Favoritos', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
        ),
        if (favs.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text('Sin favoritos', style: TextStyle(color: Colors.white38)),
          )
        else
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 20),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 140,
              childAspectRatio: 0.65,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: favs.length,
            itemBuilder: (context, i) {
              final e = favs[i];
              return Focusable(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => DetailsPage(repo: repo, itemId: e.contentId),
                )),
                builder: (focused) => AnimatedContainer(
                  duration: const Duration(milliseconds: 100),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: focused ? const Color(0xFFFF2D2D) : Colors.transparent,
                      width: 2.5,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: e.poster != null
                        ? Stack(
                            fit: StackFit.expand,
                            children: [
                              CachedNetworkImage(imageUrl: e.poster!, fit: BoxFit.cover),
                              Positioned(
                                left: 0, right: 0, top: 0, height: 42,
                                child: IgnorePointer(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          Colors.white.withValues(alpha: 0.22),
                                          Colors.transparent,
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : Container(color: const Color(0xFF1A222D)),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}
