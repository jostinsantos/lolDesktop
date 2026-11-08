import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../data/models/download_item.dart';
import '../../data/models/repo_manifest.dart';
import '../../data/models/stream_server.dart';
import '../../data/services/content_service.dart';
import '../../data/services/download_service.dart';
import '../../data/services/settings_service.dart';

/// Entrada unificada: móvil (bottom sheet) o TV (diálogo centrado con foco).
class DownloadSheet {
  static Future<void> show({
    required BuildContext context,
    required InstalledRepo repo,
    required ContentItem item,
    int? season,
    int? episode,
    String? episodeTitle,
    String? episodeId,
  }) async {
    final isTv = context.read<SettingsService>().isTv;
    if (isTv) {
      await showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'Cerrar',
        barrierColor: Colors.black54,
        transitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (ctx, a1, a2) {
          return Center(
            child: Material(
              color: Colors.transparent,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 520,
                  maxHeight: MediaQuery.of(ctx).size.height * 0.78,
                ),
                child: _DownloadPicker(
                  repo: repo,
                  item: item,
                  season: season,
                  episode: episode,
                  episodeTitle: episodeTitle,
                  episodeId: episodeId,
                  isTv: true,
                ),
              ),
            ),
          );
        },
      );
    } else {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: const Color(0xFF141A22),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (ctx) => _DownloadPicker(
          repo: repo,
          item: item,
          season: season,
          episode: episode,
          episodeTitle: episodeTitle,
          episodeId: episodeId,
          isTv: false,
        ),
      );
    }
  }
}

class _DownloadPicker extends StatefulWidget {
  final InstalledRepo repo;
  final ContentItem item;
  final int? season;
  final int? episode;
  final String? episodeTitle;
  final String? episodeId;
  final bool isTv;

  const _DownloadPicker({
    required this.repo,
    required this.item,
    this.season,
    this.episode,
    this.episodeTitle,
    this.episodeId,
    required this.isTv,
  });

  @override
  State<_DownloadPicker> createState() => _DownloadPickerState();
}

class _DownloadPickerState extends State<_DownloadPicker> {
  bool _loading = true;
  String? _error;
  List<StreamServer> _all = [];
  int _step = 1;
  String? _selectedServerName;
  final Map<String, int?> _sizes = {};
  bool _convert = false;
  String? _busyUrl;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      String id = widget.item.id;
      if (widget.episodeId != null && widget.episodeId!.isNotEmpty) {
        id = widget.episodeId!;
      } else if (widget.episode != null) {
        id = '${widget.item.id}/${widget.episode}';
      }
      var streams = await ContentService.instance.getStreams(
        widget.repo,
        id,
        type: widget.item.type,
        season: widget.season ?? 1,
        episode: widget.episode,
      );
      if (streams.isEmpty && id != widget.item.id) {
        streams = await ContentService.instance.getStreams(
          widget.repo,
          widget.item.id,
          type: widget.item.type,
          season: widget.season,
          episode: widget.episode,
        );
      }
      if (!mounted) return;
      setState(() {
        _all = streams;
        _loading = false;
      });
      for (final s in streams.take(16)) {
        DownloadService.estimateSize(s.url, s.headers).then((b) {
          if (mounted) setState(() => _sizes[s.url] = b);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  List<String> get _serverNames {
    final seen = <String>{};
    final out = <String>[];
    for (final s in _all) {
      final n = s.name.trim().isEmpty ? 'Servidor' : s.name.trim();
      if (seen.add(n)) out.add(n);
    }
    return out;
  }

  List<StreamServer> get _qualities {
    final name = _selectedServerName;
    if (name == null) return const [];
    return _all
        .where((s) =>
            s.name.trim() == name ||
            (s.name.trim().isEmpty && name == 'Servidor'))
        .toList();
  }

  Future<void> _start(StreamServer s) async {
    setState(() => _busyUrl = s.url);
    final convert = _convert && context.read<SettingsService>().isMobile;
    await DownloadService.instance.enqueue(
      repoId: widget.repo.manifest.id,
      repoName: widget.repo.manifest.name,
      contentId: widget.item.id,
      title: widget.item.title,
      poster: widget.item.poster,
      type: widget.item.type,
      season: widget.season,
      episode: widget.episode,
      episodeTitle: widget.episodeTitle,
      server: s,
      convertOnMobile: convert,
    );
    if (!mounted) return;
    Navigator.pop(context);
  }

  void _ensureVisible(int index) {
    if (!_scroll.hasClients) return;
    final target = (index * 64.0).clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(target,
        duration: const Duration(milliseconds: 120), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = context.watch<SettingsService>().isMobile;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!widget.isTv)
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        Row(
          children: [
            if (_step == 2)
              IconButton(
                onPressed: () => setState(() {
                  _step = 1;
                  _selectedServerName = null;
                }),
                icon: const Icon(Icons.arrow_back, color: Colors.white70),
              ),
            Expanded(
              child: Text(
                _step == 1 ? 'Elegir servidor' : 'Elegir calidad',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700),
              ),
            ),
            if (widget.isTv)
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, color: Colors.white54),
              ),
          ],
        ),
        Text(
          widget.item.title +
              (widget.season != null && widget.episode != null
                  ? ' · T${widget.season} E${widget.episode}'
                  : ''),
          style: const TextStyle(color: Colors.white54, fontSize: 13),
        ),
        Text('Repo: ${widget.repo.manifest.name}',
            style: const TextStyle(color: Colors.white38, fontSize: 12)),
        if (isMobile && _step == 2)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Convertir y guardar en Descargas/lollite',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            subtitle: const Text(
              'HLS→MP4 / TS→MKV en carpeta pública del dispositivo',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
            value: _convert,
            activeColor: const Color(0xFFE50914),
            onChanged: (v) => setState(() => _convert = v),
          ),
        const Divider(color: Colors.white12),
        Expanded(
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(color: Color(0xFFE50914)))
              : _error != null
                  ? Center(
                      child: Text(_error!,
                          style: const TextStyle(color: Colors.redAccent)))
                  : _all.isEmpty
                      ? const Center(
                          child: Text('No hay servidores disponibles',
                              style: TextStyle(color: Colors.white54)))
                      : _step == 1
                          ? _serverList()
                          : _qualityList(),
        ),
      ],
    );

    if (widget.isTv) {
      return FocusTraversalGroup(
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          decoration: BoxDecoration(
            color: const Color(0xFF141A22),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white24),
          ),
          child: body,
        ),
      );
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.72,
          child: body,
        ),
      ),
    );
  }

  Widget _serverList() {
    final names = _serverNames;
    return ListView.builder(
      controller: _scroll,
      itemCount: names.length,
      itemBuilder: (ctx, i) {
        final name = names[i];
        final count = _all
            .where((s) =>
                s.name.trim() == name ||
                (s.name.trim().isEmpty && name == 'Servidor'))
            .length;
        return _FocusTile(
          autofocus: i == 0,
          isTv: widget.isTv,
          onFocus: () => _ensureVisible(i),
          title: name,
          subtitle: '$count calidad${count == 1 ? '' : 'es'}',
          trailing: const Icon(Icons.chevron_right, color: Colors.white38),
          onTap: () {
            setState(() {
              _selectedServerName = name;
              _step = 2;
            });
          },
        );
      },
    );
  }

  Widget _qualityList() {
    final list = _qualities;
    return ListView.builder(
      controller: _scroll,
      itemCount: list.length,
      itemBuilder: (ctx, i) {
        final s = list[i];
        final size = _sizes[s.url];
        final sizeLabel =
            size != null && size > 0 ? _fmtSize(size) : 'Calculando…';
        final q = s.quality ?? 'Auto';
        final lang = s.language ?? '';
        final busy = _busyUrl == s.url;
        return _FocusTile(
          autofocus: i == 0,
          isTv: widget.isTv,
          onFocus: () => _ensureVisible(i),
          title: q,
          subtitle: [
            if (lang.isNotEmpty) lang,
            s.isHls ? 'HLS' : 'Directo',
            sizeLabel,
          ].join(' · '),
          trailing: busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Color(0xFFE50914)))
              : const Icon(Icons.download_rounded, color: Colors.white70),
          onTap: busy ? null : () => _start(s),
        );
      },
    );
  }
}

class _FocusTile extends StatefulWidget {
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onFocus;
  final bool autofocus;
  final bool isTv;

  const _FocusTile({
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
    this.onFocus,
    this.autofocus = false,
    required this.isTv,
  });

  @override
  State<_FocusTile> createState() => _FocusTileState();
}

class _FocusTileState extends State<_FocusTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.isTv) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(widget.title,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w600)),
        subtitle: Text(widget.subtitle,
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
        trailing: widget.trailing,
        onTap: widget.onTap,
      );
    }
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (f) {
        setState(() => _focused = f);
        if (f) widget.onFocus?.call();
      },
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          widget.onTap?.call();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: _focused
                ? Colors.white.withValues(alpha: 0.14)
                : Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _focused ? Colors.white : Colors.transparent,
              width: 2,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.title,
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(widget.subtitle,
                        style:
                            const TextStyle(color: Colors.white54, fontSize: 12)),
                  ],
                ),
              ),
              if (widget.trailing != null) widget.trailing!,
            ],
          ),
        ),
      ),
    );
  }
}

String _fmtSize(int b) {
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  if (b < 1024 * 1024 * 1024) {
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
