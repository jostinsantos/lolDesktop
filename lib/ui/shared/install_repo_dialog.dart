import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../data/models/repo_manifest.dart';

/// Modal de confirmación al instalar un repo.
/// Muestra icono, datos del manifest y resumen del contract.json si existe.
Future<bool> showInstallRepoDialog(
  BuildContext context, {
  required RepoManifest manifest,
  RepoContract? contract,
  String? userRepo,
  String? fallbackAvatarUrl,
}) async {
  final iconUrl = (manifest.icon != null && manifest.icon!.isNotEmpty)
      ? manifest.icon
      : fallbackAvatarUrl;
  final accent = manifest.accentColor;
  final lines = <String>[];
  lines.add('Versión: ${manifest.version}');
  if (manifest.author.isNotEmpty) lines.add('Autor: ${manifest.author}');
  if (userRepo != null && userRepo.isNotEmpty) lines.add('Repo: $userRepo');
  if (manifest.apiVersion != null) lines.add('apiVersion: ${manifest.apiVersion}');
  if (manifest.browser) {
    lines.add('Puede abrir páginas web ocultas para encontrar el video');
  }
  if (manifest.capabilities.isNotEmpty) {
    lines.add('Capacidades: ${manifest.capabilities.join(', ')}');
  }
  if (contract != null) {
    lines.addAll(contract.summaryLines);
  }
  if (manifest.description.isNotEmpty) {
    lines.add('');
    lines.add(manifest.description);
  }

  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      return AlertDialog(
        backgroundColor: const Color(0xFF1A222D),
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 44,
                height: 44,
                child: iconUrl != null && iconUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: iconUrl,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => _letterBox(manifest.name, accent),
                      )
                    : _letterBox(manifest.name, accent),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Instalar ${manifest.sectionLabel ?? manifest.name}',
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  Text(
                    'Confirma permisos y capacidades',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in lines)
                    if (line.isEmpty)
                      const SizedBox(height: 8)
                    else
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Icon(Icons.circle, size: 6, color: accent),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                line,
                                style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.35),
                              ),
                            ),
                          ],
                        ),
                      ),
                  if (contract == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'Este repo no publica contract.json. Se instalará con la información del manifest.',
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 11),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: accent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Instalar'),
          ),
        ],
      );
    },
  );
  return result == true;
}

Widget _letterBox(String name, Color accent) {
  return Container(
    color: accent.withValues(alpha: 0.25),
    alignment: Alignment.center,
    child: Text(
      name.isNotEmpty ? name[0].toUpperCase() : '?',
      style: TextStyle(color: accent, fontWeight: FontWeight.bold, fontSize: 20),
    ),
  );
}
