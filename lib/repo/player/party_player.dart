import 'package:flutter/material.dart';
import '../../data/models/repo_manifest.dart';
import '../../data/services/party_service.dart';
import '../../ui/shared/party_sync_player.dart';

/// Desktop: entra al player dedicado de sala (modales chat/ajustes).
class PartyPlayerPage extends StatelessWidget {
  final PartyRoom room;
  final InstalledRepo repo;

  const PartyPlayerPage({
    super.key,
    required this.room,
    required this.repo,
  });

  @override
  Widget build(BuildContext context) {
    return PartySyncPlayer(
      room: room,
      repo: repo,
      isTv: false, // en escritorio el layout inmersivo + modales (pantalla ancha)
    );
  }
}
