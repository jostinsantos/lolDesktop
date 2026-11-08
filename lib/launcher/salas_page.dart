import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'dart:ui';
import '../data/services/party_service.dart';
import '../data/services/repo_manager.dart';
import '../repo/player/party_player.dart';

const _bg = Color(0xFF0A0C0F);
const _card = Color(0xFF141820);
const _border = Color(0xFF1C222C);
const _accent = Color(0xFFE50914);
const _textMuted = Color(0x8AFFFFFF);

class SalasPage extends StatefulWidget {
  const SalasPage({super.key});

  @override
  State<SalasPage> createState() => _SalasPageState();
}

class _SalasPageState extends State<SalasPage> {
  final _codeCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  List<PartyRoom> _rooms = [];
  List<PartyRoom> _myRooms = [];
  bool _loading = true;
  String? _error;
  bool _editingUsername = false;
  String _filterType = 'all';

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await PartyService.instance.init();
      final u = PartyService.instance.username;
      if (u != null && u.isNotEmpty) _usernameCtrl.text = u;
      await _refreshRooms();
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _refreshRooms() async {
    try {
      final list = await PartyService.instance.listPublicRooms(
        query: _searchCtrl.text,
      );
      List<PartyRoom> mine = [];
      try {
        mine = await PartyService.instance.listMyRooms();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _rooms = list;
          _myRooms = mine;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  List<PartyRoom> get _filtered {
    var list = _rooms;
    if (_filterType == 'movie') {
      list = list
          .where((r) =>
              r.contentType.toLowerCase().contains('movie') ||
              r.contentType == 'pelicula')
          .toList();
    } else if (_filterType == 'series') {
      list = list
          .where((r) =>
              r.contentType.toLowerCase().contains('series') ||
              r.contentType.toLowerCase().contains('tv') ||
              r.season != null)
          .toList();
    }
    return list;
  }

  Future<void> _saveUsername() async {
    try {
      await PartyService.instance.setUsername(_usernameCtrl.text);
      setState(() => _editingUsername = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nombre guardado')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _joinByCode() async {
    final code = _codeCtrl.text.trim();
    if (code.isEmpty) return;
    if (PartyService.instance.username == null ||
        PartyService.instance.username!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Primero elige un nombre de usuario')),
      );
      return;
    }
    try {
      final room = await PartyService.instance.joinRoom(code);
      if (!mounted) return;
      _openPartyPlayer(room);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('StateError: ', ''))),
      );
    }
  }

  void _openPartyPlayer(PartyRoom room) {
    final repos = context.read<RepoManager>().installed;
    final repo = repos.where((r) => r.manifest.id == room.repoId).firstOrNull;
    if (repo == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'No tienes instalado el repositorio de este contenido. Instálalo primero.'),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PartyPlayerPage(room: room, repo: repo),
      ),
    );
  }

  String _durationLabel(PartyRoom room) {
    final elapsed = DateTime.now().difference(room.createdAt);
    if (elapsed.inHours >= 1) {
      return '${elapsed.inHours}h ${elapsed.inMinutes.remainder(60)}m';
    }
    if (elapsed.inMinutes >= 1) return '${elapsed.inMinutes}m';
    return '${elapsed.inSeconds}s';
  }

  String _remainingLabel(PartyRoom room) {
    final left = room.expiresAt.difference(DateTime.now());
    if (left.isNegative) return 'expirada';
    if (left.inHours >= 1) {
      return '${left.inHours}h ${left.inMinutes.remainder(60)}m';
    }
    return '${left.inMinutes}m';
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _usernameCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final party = PartyService.instance;
    final hasUsername = party.username != null && party.username!.isNotEmpty;
    final filtered = _filtered;
    final width = MediaQuery.sizeOf(context).width;
    final cross = width >= 1200
        ? 4
        : width >= 900
            ? 3
            : 2;

    return Container(
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Username
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 6),
            child: Row(
              children: [
                const Icon(Icons.person_rounded, color: _textMuted, size: 18),
                const SizedBox(width: 10),
                if (!_editingUsername && hasUsername)
                  Expanded(
                    child: Text(
                      'Tu nombre: ${party.username}',
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 13.5),
                    ),
                  )
                else
                  Expanded(
                    child: TextField(
                      controller: _usernameCtrl,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'Elige un nombre de usuario',
                        hintStyle: const TextStyle(color: _textMuted, fontSize: 13),
                        isDense: true,
                        filled: true,
                        fillColor: _card,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: _border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: _border),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                      ),
                      maxLength: 24,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                            RegExp(r'[a-zA-Z0-9_\-áéíóúÁÉÍÓÚñÑ ]')),
                      ],
                      onSubmitted: (_) => _saveUsername(),
                    ),
                  ),
                const SizedBox(width: 8),
                if (_editingUsername || !hasUsername)
                  FilledButton(
                      onPressed: _saveUsername,
                      style: FilledButton.styleFrom(
                        backgroundColor: _accent,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                      ),
                      child: const Text('Guardar'))
                else
                  TextButton(
                    onPressed: () => setState(() => _editingUsername = true),
                    child: const Text('Cambiar',
                        style: TextStyle(color: Colors.white60)),
                  ),
              ],
            ),
          ),

          // Join by code
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _codeCtrl,
                    style: const TextStyle(
                      color: Colors.white,
                      letterSpacing: 3,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      hintText: 'Código de sala',
                      hintStyle: const TextStyle(
                        color: _textMuted,
                        letterSpacing: 0,
                        fontWeight: FontWeight.normal,
                        fontSize: 13.5,
                      ),
                      prefixIcon: const Icon(Icons.vpn_key_rounded,
                          color: _textMuted, size: 20),
                      filled: true,
                      fillColor: _card,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _border),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 14),
                    ),
                    onSubmitted: (_) => _joinByCode(),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: _joinByCode,
                  icon: const Icon(Icons.login_rounded, size: 18),
                  label: const Text('Unirse'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _accent,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(11)),
                  ),
                ),
              ],
            ),
          ),

          // Search + filters
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 6, 24, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 13.5),
                    decoration: InputDecoration(
                      hintText: 'Buscar por título, host o código…',
                      hintStyle:
                          const TextStyle(color: _textMuted, fontSize: 12.5),
                      prefixIcon: const Icon(Icons.search_rounded,
                          color: _textMuted, size: 18),
                      isDense: true,
                      filled: true,
                      fillColor: _card,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: _border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: _border),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                    ),
                    onSubmitted: (_) async {
                      setState(() => _loading = true);
                      await _refreshRooms();
                      if (mounted) setState(() => _loading = false);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: 'Todo',
                  selected: _filterType == 'all',
                  onTap: () => setState(() => _filterType = 'all'),
                ),
                const SizedBox(width: 5),
                _FilterChip(
                  label: 'Películas',
                  selected: _filterType == 'movie',
                  onTap: () => setState(() => _filterType = 'movie'),
                ),
                const SizedBox(width: 5),
                _FilterChip(
                  label: 'Series',
                  selected: _filterType == 'series',
                  onTap: () => setState(() => _filterType = 'series'),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: 'Actualizar',
                  onPressed: _loading
                      ? null
                      : () async {
                          setState(() => _loading = true);
                          await _refreshRooms();
                          if (mounted) setState(() => _loading = false);
                        },
                  icon: _loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded,
                          color: _textMuted, size: 20),
                ),
              ],
            ),
          ),

          if (_myRooms.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
              child: Text(
                'Mis salas (${_myRooms.length})',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
            ),
            SizedBox(
              height: 112,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                scrollDirection: Axis.horizontal,
                itemCount: _myRooms.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, i) {
                  final room = _myRooms[i];
                  return _MyRoomChip(
                    room: room,
                    onEnter: () async {
                      try {
                        final r =
                            await PartyService.instance.joinRoom(room.code);
                        if (!context.mounted) return;
                        _openPartyPlayer(r);
                        await _refreshRooms();
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('$e')),
                          );
                        }
                      }
                    },
                    onDelete: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          backgroundColor: _card,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                          title: const Text('Eliminar sala',
                              style: TextStyle(color: Colors.white)),
                          content: Text(
                            '¿Eliminar "${room.title}" (${room.code})?',
                            style: const TextStyle(color: Colors.white70),
                          ),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('Cancelar')),
                            FilledButton(
                                style: FilledButton.styleFrom(
                                    backgroundColor: Colors.redAccent),
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('Eliminar')),
                          ],
                        ),
                      );
                      if (ok == true) {
                        try {
                          await PartyService.instance.deleteMyRoom(room.id);
                          await _refreshRooms();
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('$e')),
                            );
                          }
                        }
                      }
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 6),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
            child: Text(
              'Salas públicas en vivo (${filtered.length})',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
          ),

          Expanded(
            child: _loading && _rooms.isEmpty
                ? const Center(child: CircularProgressIndicator(color: _accent))
                : _error != null && _rooms.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.cloud_off_rounded,
                                  size: 44, color: _textMuted),
                              const SizedBox(height: 10),
                              Text(_error!,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: _textMuted)),
                            ],
                          ),
                        ),
                      )
                    : filtered.isEmpty
                        ? const Center(
                            child: Text(
                              'No hay salas públicas con ese filtro.\nCrea una desde el reproductor (botón Party).',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: _textMuted, height: 1.4),
                            ),
                          )
                        : GridView.builder(
                            padding:
                                const EdgeInsets.fromLTRB(24, 6, 24, 24),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: cross,
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 12,
                              childAspectRatio: cross >= 3 ? 1.6 : 1.5,
                            ),
                            itemCount: filtered.length,
                            itemBuilder: (context, i) {
                              final room = filtered[i];
                              return _RoomCard(
                                room: room,
                                durationLabel: _durationLabel(room),
                                remainingLabel: _remainingLabel(room),
                                onJoin: () async {
                                  try {
                                    final r = await PartyService.instance
                                        .joinRoom(room.code);
                                    if (mounted) _openPartyPlayer(r);
                                  } catch (e) {
                                    if (mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        SnackBar(
                                          content: Text(e
                                              .toString()
                                              .replaceFirst(
                                                  'StateError: ', '')),
                                        ),
                                      );
                                    }
                                  }
                                },
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? _accent.withValues(alpha: 0.2) : _card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: selected ? _accent : _border),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? _accent : _textMuted,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _MyRoomChip extends StatelessWidget {
  final PartyRoom room;
  final VoidCallback onEnter;
  final VoidCallback onDelete;

  const _MyRoomChip({
    required this.room,
    required this.onEnter,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _card,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onEnter,
        child: Container(
          width: 210,
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.workspace_premium_rounded,
                      color: Color(0xFFFFD54F), size: 15),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      room.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                'Código ${room.code} · ${room.memberCount} en sala',
                style: const TextStyle(color: _textMuted, fontSize: 11.5),
              ),
              const Spacer(),
              Row(
                children: [
                  const Text('Entrar',
                      style: TextStyle(
                          color: _accent,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  InkWell(
                    onTap: onDelete,
                    child: const Padding(
                      padding: EdgeInsets.all(3),
                      child: Icon(Icons.delete_outline_rounded,
                          color: Colors.redAccent, size: 16),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoomCard extends StatefulWidget {
  final PartyRoom room;
  final String durationLabel;
  final String remainingLabel;
  final VoidCallback onJoin;

  const _RoomCard({
    required this.room,
    required this.durationLabel,
    required this.remainingLabel,
    required this.onJoin,
  });

  @override
  State<_RoomCard> createState() => _RoomCardState();
}

class _RoomCardState extends State<_RoomCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final room = widget.room;
    final ep = (room.season != null && room.episode != null)
        ? 'T${room.season} E${room.episode}'
        : null;
    final live = room.status == 'playing';

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedScale(
        scale: _hover ? 1.015 : 1.0,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: _hover
                  ? _accent.withValues(alpha: 0.4)
                  : _border,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(13),
              onTap: widget.onJoin,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(11, 11, 11, 9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(9),
                          child: room.poster != null && room.poster!.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: room.poster!,
                                  width: 44,
                                  height: 62,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, __, ___) => _placeholder(),
                                )
                              : _placeholder(),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                room.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                  height: 1.2,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                [
                                  if (ep != null) ep,
                                  'Host ${room.hostUsername}',
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: _textMuted, fontSize: 10.5),
                              ),
                              const SizedBox(height: 5),
                              Row(
                                children: [
                                  _badge(
                                    live ? 'EN VIVO' : 'ESPERA',
                                    live ? _accent : Colors.white54,
                                  ),
                                  const SizedBox(width: 5),
                                  _badge(
                                    '${room.memberCount}/${room.maxMembers}',
                                    Colors.white70,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${room.code} · ${widget.durationLabel} · ${widget.remainingLabel}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 10),
                          ),
                        ),
                        const SizedBox(width: 6),
                        SizedBox(
                          height: 30,
                          child: FilledButton(
                            onPressed: widget.onJoin,
                            style: FilledButton.styleFrom(
                              backgroundColor: _accent,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(9),
                              ),
                            ),
                            child: const Text(
                              'Unirse',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: TextStyle(
            color: color, fontSize: 9.5, fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      width: 44,
      height: 62,
      color: Colors.white10,
      child: const Icon(Icons.movie_rounded, color: _textMuted, size: 20),
    );
  }
}
