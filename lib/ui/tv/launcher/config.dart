import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../data/services/settings_service.dart';
import '../../../data/services/repo_manager.dart';
import '../../../data/services/library_service.dart';
import '../widgets/focusable.dart';
import '../widgets/glass.dart';
import '../../shared/update_banner.dart';
import '../widgets/tv_keyboard.dart';

/// Configuración global TV — con todas las opciones de móvil + repos en vista separada + borrado real.
class GlobalSettingsPage extends StatefulWidget {
  const GlobalSettingsPage({super.key});

  @override
  State<GlobalSettingsPage> createState() => _GlobalSettingsPageState();
}

class _GlobalSettingsPageState extends State<GlobalSettingsPage> {
  bool _showReposView = false;
  bool _checkingUpdates = false;
  final ScrollController _mainScrollController = ScrollController();

  @override
  void dispose() {
    _mainScrollController.dispose();
    super.dispose();
  }

  void _goToMain() {
    setState(() => _showReposView = false);
    // Al volver a la config principal, sube al top
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_mainScrollController.hasClients) {
        _mainScrollController.jumpTo(0);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kTvBg,
      body: SafeArea(
        child: _showReposView ? _buildReposView() : _buildMainSettings(),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  VISTA PRINCIPAL
  // ═══════════════════════════════════════════════════════════════════
  Widget _buildMainSettings() {
    final settings = context.watch<SettingsService>();
    final manager = context.watch<RepoManager>();

    return ListView(
      controller: _mainScrollController,
      padding: const EdgeInsets.fromLTRB(36, 24, 36, 40),
      children: [
        const Text(
          'Configuración',
          style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 28),

        // ═══ ACTUALIZACIONES ═══
        _section('ACTUALIZACIONES'),
        const SizedBox(height: 10),
        _TvTile(
          autofocus: true,
          icon: Icons.system_update_rounded,
          title: 'Notificar parches',
          subtitle: 'Parches ON/OFF. Las versiones nuevas se avisan siempre.',
          trailing: _onOffBadge(settings.notifyPatches),
          onTap: () => settings.setNotifyPatches(!settings.notifyPatches),
        ),
        const SizedBox(height: 8),
        _TvTile(
          icon: Icons.download_rounded,
          title: 'Habilitar descargas',
          subtitle: 'Muestra u oculta botones de descarga en contenido.',
          trailing: _onOffBadge(settings.downloadsEnabled),
          onTap: () => settings.setDownloadsEnabled(!settings.downloadsEnabled),
        ),
        const SizedBox(height: 8),
        _TvTile(
          icon: Icons.system_update_alt_rounded,
          title: 'Verificar actualización',
          subtitle: 'Comprueba ahora y abre el modal si hay una nueva',
          onTap: () => showAppUpdateFlow(context, forceNotifyPatches: true),
        ),

        const SizedBox(height: 28),

        // ═══ MODO DE INTERFAZ ═══
        _section('MODO DE INTERFAZ'),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _ModeCard(
                title: 'TV',
                subtitle: 'Mando / foco',
                selected: settings.isTv,
                onTap: () => settings.setMode(UiMode.tv),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ModeCard(
                title: 'Móvil',
                subtitle: 'Touch',
                selected: settings.isMobile,
                onTap: () => settings.setMode(UiMode.mobile),
              ),
            ),
          ],
        ),

        const SizedBox(height: 28),

        // ═══ MENÚ DE NAVEGACIÓN ═══
        _section('MENÚ DE NAVEGACIÓN'),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _ModeCard(
                title: 'Lateral',
                subtitle: 'Barra izquierda',
                selected: true,
                onTap: () async {
                  final p = await SharedPreferences.getInstance();
                  await p.setString('menu_position', 'side');
                  if (mounted) setState(() {});
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ModeCard(
                title: 'Superior',
                subtitle: 'Barra arriba',
                selected: false,
                onTap: () async {
                  final p = await SharedPreferences.getInstance();
                  await p.setString('menu_position', 'top');
                  if (mounted) setState(() {});
                },
              ),
            ),
          ],
        ),

        const SizedBox(height: 28),

        // ═══ REPOSITORIOS ═══
        _section('REPOSITORIOS'),
        const SizedBox(height: 10),
        _TvTile(
          icon: Icons.folder_copy_rounded,
          title: 'Gestionar repositorios',
          subtitle: '${manager.installed.length} instalado(s) · updates: ${manager.updateCount}',
          onTap: () => setState(() => _showReposView = true),
        ),
        const SizedBox(height: 8),
        _TvTile(
          icon: Icons.refresh_rounded,
          title: 'Actualizar contenido',
          subtitle: 'Limpia caché y recarga home/discover de los repos',
          onTap: () async {
            await manager.refreshAllContent();
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Caché de contenido limpiada. Al abrir un repo se recargará.')),
              );
            }
          },
        ),
        const SizedBox(height: 8),
        _TvTile(
          icon: Icons.health_and_safety_outlined,
          title: 'Health-check de repos',
          subtitle: 'Prueba getHome en cada repo activo',
          onTap: () async {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Comprobando repos…')),
            );
            await manager.runAllHealthChecks();
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Health-check terminado. Mira el estado en Repositorios.')),
              );
            }
          },
        ),

        const SizedBox(height: 28),

        // ═══ APARIENCIA HOME ═══
        _section('APARIENCIA HOME'),
        const SizedBox(height: 10),
        _TvTile(
          icon: Icons.wallpaper_rounded,
          title: 'Fondo del Home',
          subtitle: _homeBgSubtitle(settings),
          onTap: () => _openHomeBgSettings(context, settings),
        ),
        const SizedBox(height: 8),
        _TvTile(
          icon: Icons.blur_on_rounded,
          title: 'Intensidad de blur',
          subtitle: '${settings.homeBgBlur.toStringAsFixed(0)} · actual por defecto 16',
          onTap: () => _openBlurPicker(context, settings),
        ),

        const SizedBox(height: 28),

        // ═══ PLAYER ═══
        _section('PLAYER'),
        const SizedBox(height: 10),
        const _PlayerSettingsCard(),
      ],
    );
  }

  String _homeBgSubtitle(SettingsService s) {
    switch (s.homeBgMode) {
      case HomeBgMode.tmdb:
        return 'Galería TMDB (rotativo)';
      case HomeBgMode.fixed:
        return s.homeBgUrl.isEmpty ? 'Fondo fijo (sin URL)' : 'Fondo fijo';
      case HomeBgMode.custom:
        return s.homeBgUrl.isEmpty ? 'Personalizado (buscar)' : 'Personalizado';
      case HomeBgMode.lol:
        return 'Catálogo LOL (wallpapers)';
    }
  }

  Future<void> _openHomeBgSettings(BuildContext context, SettingsService settings) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _HomeBgSettingsPage(settings: settings),
      ),
    );
  }

  Future<void> _openBlurPicker(BuildContext context, SettingsService settings) async {
    double value = settings.homeBgBlur;
    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return Dialog(
              backgroundColor: const Color(0xFF141A22),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              child: FocusScope(
                // Orden de foco: slider → Cancelar → Guardar
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Intensidad de blur',
                          style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(
                        '← → ajustar · ↑ ↓ botones',
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.35), fontSize: 11),
                      ),
                      const SizedBox(height: 10),
                      Text(value.toStringAsFixed(0),
                          style: const TextStyle(color: Colors.white70, fontSize: 14)),
                      // Slider solo responde a izquierda/derecha (no se pierde el foco en vertical)
                      Focus(
                        autofocus: true,
                        onKeyEvent: (node, event) {
                          if (event is! KeyDownEvent) return KeyEventResult.ignored;
                          final key = event.logicalKey;
                          if (key == LogicalKeyboardKey.arrowLeft ||
                              key == LogicalKeyboardKey.arrowRight) {
                            final dir = key == LogicalKeyboardKey.arrowRight ? 1.0 : -1.0;
                            setLocal(() {
                              value = (value + dir).clamp(0.0, 32.0);
                            });
                            return KeyEventResult.handled;
                          }
                          // ↑↓ dejan pasar el foco a los botones (FocusTraversal)
                          return KeyEventResult.ignored;
                        },
                        child: SliderTheme(
                          data: SliderTheme.of(ctx).copyWith(
                            activeTrackColor: kTvAccent,
                            thumbColor: Colors.white,
                            inactiveTrackColor: Colors.white24,
                            overlayColor: kTvAccent.withValues(alpha: 0.2),
                          ),
                          child: Slider(
                            value: value,
                            min: 0,
                            max: 32,
                            divisions: 32,
                            onChanged: (v) => setLocal(() => value = v),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          _DialogBtn(label: 'Cancelar', onTap: () => Navigator.pop(ctx)),
                          const SizedBox(width: 12),
                          _DialogBtn(
                            label: 'Guardar',
                            primary: true,
                            onTap: () async {
                              await settings.setHomeBgBlur(value);
                              if (ctx.mounted) Navigator.pop(ctx);
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  VISTA DE REPOSITORIOS (estado + updates + desinstalar)
  // ═══════════════════════════════════════════════════════════════════
  Widget _buildReposView() {
    final manager = context.watch<RepoManager>();
    final lib = context.watch<LibraryService>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 20, 28, 12),
          child: Row(
            children: [
              Focusable(
                onTap: _goToMain,
                builder: (f) => Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: f ? Colors.white : Colors.transparent, width: 2),
                  ),
                  child: Icon(Icons.arrow_back_rounded, color: f ? Colors.white : Colors.white60, size: 22),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Repositorios',
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                    ),
                    if (manager.updateCount > 0)
                      Text(
                        '${manager.updateCount} actualización(es) disponible(s)',
                        style: const TextStyle(color: Color(0xFF7DD3FC), fontSize: 12),
                      ),
                  ],
                ),
              ),
              Focusable(
                onTap: _checkingUpdates
                    ? null
                    : () async {
                        setState(() => _checkingUpdates = true);
                        final n = await manager.checkAllUpdates();
                        if (mounted) {
                          setState(() => _checkingUpdates = false);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(n == 0
                                  ? 'Todos los repos están al día'
                                  : '$n actualización(es) encontrada(s)'),
                            ),
                          );
                        }
                      },
                builder: (f) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: f ? Colors.white12 : Colors.white.withValues(alpha: 0.06),
                    border: Border.all(color: f ? Colors.white : Colors.transparent, width: 2),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_checkingUpdates)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                        )
                      else
                        const Icon(Icons.system_update_rounded, color: Colors.white70, size: 18),
                      const SizedBox(width: 6),
                      Text(
                        _checkingUpdates ? 'Comprobando…' : 'Buscar updates',
                        style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: manager.installed.isEmpty
              ? const Center(
                  child: Text('No hay repositorios instalados', style: TextStyle(color: Colors.white54)),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(28, 4, 28, 32),
                  itemCount: manager.installed.length,
                  itemBuilder: (context, i) {
                    final r = manager.installed[i];
                    final health = manager.healthOf(r);
                    final hasUpd = manager.hasUpdate(r.manifest.id);
                    return _RepoTile(
                      name: r.manifest.name,
                      repo: r.manifest.repo,
                      version: r.manifest.version,
                      enabled: r.enabled,
                      health: health,
                      hasUpdate: hasUpd,
                      remoteVersion: manager.remoteVersion(r.manifest.id),
                      onDelete: () async {
                        final ok = await _confirmDelete(context, r.manifest.name);
                        if (ok != true) return;
                        final id = r.manifest.id;
                        await manager.uninstall(id);
                        try {
                          await lib.clearRepoData(id);
                        } catch (_) {}
                        if (mounted) setState(() {});
                      },
                      onUpdate: hasUpd
                          ? () async {
                              try {
                                await manager.updateRepo(r);
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('${r.manifest.name} actualizado')),
                                  );
                                  setState(() {});
                                }
                              } catch (e) {
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Error al actualizar: $e')),
                                  );
                                }
                              }
                            }
                          : null,
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<bool?> _confirmDelete(BuildContext context, String name) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return Dialog(
          backgroundColor: const Color(0xFF141A22),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: FocusScope(
                autofocus: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Eliminar repositorio',
                        style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 10),
                    Text(
                      '¿Eliminar "$name"? Se borrarán sus datos de biblioteca.',
                      style: const TextStyle(color: Colors.white60, fontSize: 14),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        _DialogBtn(label: 'Cancelar', onTap: () => Navigator.pop(ctx, false)),
                        const SizedBox(width: 12),
                        _DialogBtn(
                          label: 'Eliminar',
                          primary: true,
                          danger: true,
                          autofocus: true,
                          onTap: () => Navigator.pop(ctx, true),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _section(String text) => Text(
        text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.4),
          fontSize: 11,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w600,
        ),
      );

  Widget _onOffBadge(bool on) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: on ? kTvAccent.withValues(alpha: 0.28) : Colors.white.withValues(alpha: 0.06),
        ),
        child: Text(
          on ? 'ON' : 'OFF',
          style: TextStyle(
            color: on ? Colors.white : Colors.white38,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
}

// ─────────────────────────────────────────────────────────────
// Tile de repo – estado + update + desinstalar
class _RepoTile extends StatefulWidget {
  final String name;
  final String repo;
  final String version;
  final bool enabled;
  final String health; // ok | no_js | disabled
  final bool hasUpdate;
  final String? remoteVersion;
  final VoidCallback onDelete;
  final VoidCallback? onUpdate;

  const _RepoTile({
    required this.name,
    required this.repo,
    required this.version,
    required this.enabled,
    required this.health,
    required this.hasUpdate,
    this.remoteVersion,
    required this.onDelete,
    this.onUpdate,
  });

  @override
  State<_RepoTile> createState() => _RepoTileState();
}

class _RepoTileState extends State<_RepoTile> {
  bool _focused = false;

  Color get _healthColor {
    switch (widget.health) {
      case 'ok':
        return const Color(0xFF4CAF50);
      case 'no_js':
        return const Color(0xFFFF9800);
      case 'disabled':
        return Colors.white38;
      default:
        return Colors.redAccent;
    }
  }

  String get _healthLabel {
    switch (widget.health) {
      case 'ok':
        return 'OK';
      case 'no_js':
        return 'Sin JS';
      case 'disabled':
        return 'Off';
      default:
        return 'Error';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: const Color(0xFF1C232C),
          border: Border.all(
            color: _focused
                ? Colors.white
                : (widget.hasUpdate ? const Color(0xFF7DD3FC).withValues(alpha: 0.5) : Colors.transparent),
            width: 2,
          ),
        ),
        child: Row(
          children: [
            // Estado
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(right: 12),
              decoration: BoxDecoration(color: _healthColor, shape: BoxShape.circle),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(widget.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
                      ),
                      const SizedBox(width: 8),
                      Text('v${widget.version}',
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.35), fontSize: 11)),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Text(widget.repo,
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 11)),
                      const SizedBox(width: 8),
                      Text('· $_healthLabel',
                          style: TextStyle(color: _healthColor.withValues(alpha: 0.9), fontSize: 11)),
                      if (widget.hasUpdate) ...[
                        const SizedBox(width: 8),
                        Text(
                          '· Update → v${widget.remoteVersion ?? "?"}',
                          style: const TextStyle(color: Color(0xFF7DD3FC), fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (widget.onUpdate != null) ...[
              Focusable(
                onTap: widget.onUpdate,
                builder: (f) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: f ? const Color(0xFF7DD3FC).withValues(alpha: 0.25) : const Color(0xFF7DD3FC).withValues(alpha: 0.12),
                    border: Border.all(color: f ? Colors.white : Colors.transparent, width: 1.5),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.system_update_rounded, color: Color(0xFF7DD3FC), size: 16),
                      SizedBox(width: 5),
                      Text('Actualizar',
                          style: TextStyle(color: Color(0xFF7DD3FC), fontSize: 12, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ],
            Focusable(
              onTap: widget.onDelete,
              builder: (f) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: f ? Colors.red.withValues(alpha: 0.25) : Colors.white.withValues(alpha: 0.06),
                  border: Border.all(color: f ? Colors.white : Colors.transparent, width: 1.5),
                ),
                child: Icon(Icons.delete_outline_rounded,
                    color: f ? Colors.redAccent : Colors.white54, size: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Tile genérico TV
class _TvTile extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback onTap;
  final bool autofocus;

  const _TvTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
    this.autofocus = false,
  });

  @override
  State<_TvTile> createState() => _TvTileState();
}

class _TvTileState extends State<_TvTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: const Color(0xFF1C232C),
            border: Border.all(color: _focused ? Colors.white : Colors.transparent, width: 2),
          ),
          child: Row(
            children: [
              Icon(widget.icon, color: _focused ? Colors.white : Colors.white70, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.title,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
                    const SizedBox(height: 2),
                    Text(widget.subtitle,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 11)),
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

// ─────────────────────────────────────────────────────────────
class _ModeCard extends StatefulWidget {
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _ModeCard({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_ModeCard> createState() => _ModeCardState();
}

class _ModeCardState extends State<_ModeCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: widget.selected
                ? kTvAccent.withValues(alpha: 0.22)
                : const Color(0xFF1C232C),
            border: Border.all(
              color: _focused ? Colors.white : (widget.selected ? kTvAccent : Colors.transparent),
              width: 2,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.title,
                  style: TextStyle(
                      color: (widget.selected || _focused) ? Colors.white : Colors.white70,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(widget.subtitle,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Player settings – left/right cambian valor, up/down cambian de fila
class _PlayerSettings extends ChangeNotifier {
  static final _PlayerSettings _instance = _PlayerSettings._();
  factory _PlayerSettings() => _instance;
  _PlayerSettings._();

  double subFontSize = 28;
  double subBottomPad = 28;
  Color subColor = const Color(0xFFFFFFFF);
  bool subBold = false;
  bool subBg = true;
  double subBorder = 1.5;
  double subtitleOffsetSec = 0.0;
  String hlsPreferredQuality = 'auto';

  void update(VoidCallback fn) {
    fn();
    notifyListeners();
  }
}

class _PlayerSettingsCard extends StatefulWidget {
  const _PlayerSettingsCard();

  @override
  State<_PlayerSettingsCard> createState() => _PlayerSettingsCardState();
}

class _PlayerSettingsCardState extends State<_PlayerSettingsCard> {
  final _local = _PlayerSettings();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _local,
      builder: (context, _) {
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1C232C),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _focusableValueRow(
                label: 'Calidad HLS predefinida',
                value: _local.hlsPreferredQuality == 'auto' ? 'Automática' : _local.hlsPreferredQuality,
                onLeft: () => _cycleQuality(-1),
                onRight: () => _cycleQuality(1),
              ),
              const SizedBox(height: 6),
              _focusableSliderRow(
                label: 'Tamaño subtítulos',
                value: _local.subFontSize,
                min: 16,
                max: 48,
                step: 1,
                display: '${_local.subFontSize.round()} px',
                onChanged: (v) => _local.update(() => _local.subFontSize = v),
              ),
              _focusableSliderRow(
                label: 'Altura desde borde inferior',
                value: _local.subBottomPad,
                min: 8,
                max: 120,
                step: 2,
                display: '${_local.subBottomPad.round()} px',
                onChanged: (v) => _local.update(() => _local.subBottomPad = v),
              ),
              _focusableSliderRow(
                label: 'Grosor del borde',
                value: _local.subBorder,
                min: 0,
                max: 4,
                step: 0.5,
                display: _local.subBorder.toStringAsFixed(1),
                onChanged: (v) => _local.update(() => _local.subBorder = v),
              ),
              _focusableSliderRow(
                label: 'Desfase (offset)',
                value: _local.subtitleOffsetSec,
                min: -5,
                max: 5,
                step: 0.5,
                display: '${_local.subtitleOffsetSec.toStringAsFixed(1)} s',
                onChanged: (v) => _local.update(() => _local.subtitleOffsetSec = v),
              ),
              const SizedBox(height: 4),
              _focusableValueRow(
                label: 'Color subtítulos',
                value: _colorName(_local.subColor),
                trailing: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: _local.subColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white24),
                  ),
                ),
                onLeft: () => _cycleColor(-1),
                onRight: () => _cycleColor(1),
              ),
              _focusableToggleRow(
                label: 'Negrita',
                value: _local.subBold,
                onToggle: () => _local.update(() => _local.subBold = !_local.subBold),
              ),
              _focusableToggleRow(
                label: 'Fondo oscuro',
                value: _local.subBg,
                onToggle: () => _local.update(() => _local.subBg = !_local.subBg),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Vista previa de subtítulos',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: _local.subFontSize * 0.65,
                    color: _local.subColor,
                    fontWeight: _local.subBold ? FontWeight.w800 : FontWeight.w500,
                    backgroundColor: _local.subBg ? const Color(0x99000000) : Colors.transparent,
                    shadows: [
                      Shadow(
                        offset: Offset(_local.subBorder, _local.subBorder),
                        blurRadius: _local.subBorder * 1.5,
                        color: Colors.black,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _cycleQuality(int dir) {
    const opts = ['auto', '1080p', '720p', '480p', '360p'];
    final i = opts.indexOf(_local.hlsPreferredQuality);
    final next = (i + dir).clamp(0, opts.length - 1);
    _local.update(() => _local.hlsPreferredQuality = opts[next]);
  }

  void _cycleColor(int dir) {
    const colors = [
      Color(0xFFFFFFFF),
      Color(0xFFFFFF00),
      Color(0xFF00FFFF),
      Color(0xFF00FF00),
      Color(0xFFFFA0A0),
    ];
    final i = colors.indexWhere((c) => c.value == _local.subColor.value);
    final next = (i + dir).clamp(0, colors.length - 1);
    _local.update(() => _local.subColor = colors[next]);
  }

  String _colorName(Color c) {
    if (c.value == 0xFFFFFFFF) return 'Blanco';
    if (c.value == 0xFFFFFF00) return 'Amarillo';
    if (c.value == 0xFF00FFFF) return 'Cian';
    if (c.value == 0xFF00FF00) return 'Verde';
    if (c.value == 0xFFFFA0A0) return 'Rosa';
    return 'Personalizado';
  }

  Widget _focusableValueRow({
    required String label,
    required String value,
    Widget? trailing,
    required VoidCallback onLeft,
    required VoidCallback onRight,
  }) {
    return _FocusableKeyRow(
      onLeft: onLeft,
      onRight: onRight,
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13))),
          if (trailing != null) ...[trailing, const SizedBox(width: 8)],
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(width: 6),
          const Icon(Icons.chevron_left, size: 16, color: Colors.white38),
          const Icon(Icons.chevron_right, size: 16, color: Colors.white38),
        ],
      ),
    );
  }

  Widget _focusableSliderRow({
    required String label,
    required double value,
    required double min,
    required double max,
    required double step,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    return _FocusableKeyRow(
      onLeft: () => onChanged((value - step).clamp(min, max)),
      onRight: () => onChanged((value + step).clamp(min, max)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13))),
              Text(display, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 2),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: ((value - min) / (max - min)).clamp(0.0, 1.0),
              minHeight: 4,
              backgroundColor: Colors.white12,
              color: kTvAccent,
            ),
          ),
        ],
      ),
    );
  }

  Widget _focusableToggleRow({
    required String label,
    required bool value,
    required VoidCallback onToggle,
  }) {
    return _FocusableKeyRow(
      onSelect: onToggle,
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(5),
              color: value ? kTvAccent.withValues(alpha: 0.3) : Colors.white.withValues(alpha: 0.06),
            ),
            child: Text(value ? 'ON' : 'OFF',
                style: TextStyle(
                    color: value ? Colors.white : Colors.white38,
                    fontSize: 11,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

class _FocusableKeyRow extends StatefulWidget {
  final Widget child;
  final VoidCallback? onLeft;
  final VoidCallback? onRight;
  final VoidCallback? onSelect;

  const _FocusableKeyRow({
    required this.child,
    this.onLeft,
    this.onRight,
    this.onSelect,
  });

  @override
  State<_FocusableKeyRow> createState() => _FocusableKeyRowState();
}

class _FocusableKeyRowState extends State<_FocusableKeyRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
          if (key == LogicalKeyboardKey.arrowLeft) widget.onLeft?.call();
          if (key == LogicalKeyboardKey.arrowRight) widget.onRight?.call();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.space) {
          widget.onSelect?.call();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: _focused ? Colors.white.withValues(alpha: 0.08) : Colors.transparent,
          border: Border.all(color: _focused ? Colors.white : Colors.transparent, width: 1.5),
        ),
        child: widget.child,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
class _DialogBtn extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final bool autofocus;
  final bool primary;
  final bool danger;

  const _DialogBtn({
    required this.label,
    required this.onTap,
    this.autofocus = false,
    this.primary = false,
    this.danger = false,
  });

  @override
  State<_DialogBtn> createState() => _DialogBtnState();
}

class _DialogBtnState extends State<_DialogBtn> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;
    if (widget.primary) {
      bg = _focused ? Colors.white : const Color(0xFFE50914);
      fg = _focused ? Colors.black : Colors.white;
    } else if (widget.danger) {
      bg = _focused ? Colors.white : Colors.red.shade900.withValues(alpha: 0.75);
      fg = _focused ? Colors.black : Colors.white;
    } else {
      bg = _focused ? Colors.white.withValues(alpha: 0.12) : Colors.white.withValues(alpha: 0.06);
      fg = Colors.white70;
    }

    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: bg,
            border: Border.all(color: _focused ? Colors.white : Colors.transparent, width: 2),
          ),
          child: Text(widget.label, style: TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}
// ═══════════════════════════════════════════════════════════════════════════
//  APARIENCIA HOME — selector de fondo
// ═══════════════════════════════════════════════════════════════════════════

class _HomeBgSettingsPage extends StatefulWidget {
  final SettingsService settings;
  const _HomeBgSettingsPage({required this.settings});

  @override
  State<_HomeBgSettingsPage> createState() => _HomeBgSettingsPageState();
}

class _HomeBgSettingsPageState extends State<_HomeBgSettingsPage> {
  late HomeBgMode _mode;
  String _url = '';
  List<_BgItem> _searchResults = [];
  List<_BgCategory> _lolCats = [];
  List<_BgCategory> _freeCats = [];
  bool _loadingSearch = false;
  bool _loadingLol = false;
  bool _loadingFree = false;
  bool _loadingGallery = false;
  String _query = '';
  /// Vista: lista de resultados de búsqueda, o galería de backdrops de un título.
  _BgItem? _galleryFor;
  List<String> _galleryUrls = [];

  static const _tmdbKey = 'a2d9bbed370d9f678e34006f8750a5a5';

  @override
  void initState() {
    super.initState();
    _mode = widget.settings.homeBgMode;
    _url = widget.settings.homeBgUrl;
    if (_mode == HomeBgMode.lol) unawaited(_loadLol());
  }

  Future<Map<String, dynamic>?> _httpJson(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', 'LOLLite/1.0');
      final res = await req.close().timeout(const Duration(seconds: 14));
      if (res.statusCode != 200) return null;
      final body = await res.transform(utf8.decoder).join();
      final j = jsonDecode(body);
      return j is Map ? Map<String, dynamic>.from(j) : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _loadLol() async {
    setState(() => _loadingLol = true);
    try {
      final j = await _httpJson(
          'https://raw.githubusercontent.com/LOLapptv/addons/main/backdrop_manifest.json');
      final cats = <_BgCategory>[];
      if (j != null && j['categories'] is List) {
        for (final c in j['categories'] as List) {
          if (c is! Map) continue;
          final name = (c['name'] ?? '').toString();
          final items = <String>[];
          if (c['items'] is List) {
            for (final u in c['items'] as List) {
              if (u is String && u.startsWith('http')) items.add(u);
            }
          }
          if (name.isNotEmpty && items.isNotEmpty) {
            cats.add(_BgCategory(name: name, items: items));
          }
        }
      }
      if (mounted) setState(() => _lolCats = cats);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loadingLol = false);
    }
  }

  /// Fuentes gratuitas: Wallhaven + Picsum + listados estáticos de wallpapers libres.
  Future<void> _loadFreeRepos() async {
    if (_freeCats.isNotEmpty) return;
    setState(() => _loadingFree = true);
    final cats = <_BgCategory>[];
    try {
      // Wallhaven — naturaleza / cine / abstract (API pública sin key)
      for (final entry in [
        ('Wallhaven · Cine', 'movie'),
        ('Wallhaven · Naturaleza', 'nature landscape'),
        ('Wallhaven · Espacio', 'space stars'),
        ('Wallhaven · Abstracto', 'abstract dark'),
      ]) {
        final j = await _httpJson(
          'https://wallhaven.cc/api/v1/search?q=${Uri.encodeComponent(entry.$2)}'
          '&categories=100&purity=100&atleast=1920x1080&sorting=favorites&page=1',
        );
        final data = j?['data'];
        if (data is List) {
          final urls = <String>[];
          for (final w in data.take(24)) {
            if (w is! Map) continue;
            final path = w['path']?.toString();
            if (path != null && path.startsWith('http')) urls.add(path);
          }
          if (urls.isNotEmpty) cats.add(_BgCategory(name: entry.$1, items: urls));
        }
      }

      // Lorem Picsum — IDs fijos de fotos de alta calidad (gratuitas)
      final picsum = <String>[
        for (final id in [1015, 1016, 1018, 1019, 1025, 1036, 1043, 1050, 1067, 1074, 1084, 110, 129, 137, 15, 167, 183, 201, 211, 235, 238, 244, 274, 287, 29])
          'https://picsum.photos/id/$id/1920/1080',
      ];
      cats.add(_BgCategory(name: 'Picsum · Fotografía', items: picsum));

      // Unsplash Source (imágenes públicas directas por colección / keywords)
      final unsplash = <String>[
        'https://images.unsplash.com/photo-1536440136628-849c177e76a1?w=1920&q=80',
        'https://images.unsplash.com/photo-1489599849927-2ee91cede3ba?w=1920&q=80',
        'https://images.unsplash.com/photo-1478720568477-152d9b164e26?w=1920&q=80',
        'https://images.unsplash.com/photo-1440404653325-ab127d49abc1?w=1920&q=80',
        'https://images.unsplash.com/photo-1594909122845-11baa439b7bf?w=1920&q=80',
        'https://images.unsplash.com/photo-1517604931445-81676945b4a9?w=1920&q=80',
        'https://images.unsplash.com/photo-1574375927938-d5a98e8ffe85?w=1920&q=80',
        'https://images.unsplash.com/photo-1485846234645-a62644f84728?w=1920&q=80',
        'https://images.unsplash.com/photo-1506905925346-21bda4d32df4?w=1920&q=80',
        'https://images.unsplash.com/photo-1464822759023-fed622ff2c3b?w=1920&q=80',
        'https://images.unsplash.com/photo-1507525428034-b723cf961d3e?w=1920&q=80',
        'https://images.unsplash.com/photo-1419242902214-272b3f66ee7a?w=1920&q=80',
        'https://images.unsplash.com/photo-1451187580459-43490279c0fa?w=1920&q=80',
        'https://images.unsplash.com/photo-1462331940025-496dfbfc7564?w=1920&q=80',
        'https://images.unsplash.com/photo-1519681393784-d120267933ba?w=1920&q=80',
        'https://images.unsplash.com/photo-1500530855697-b586d89ba3ee?w=1920&q=80',
      ];
      cats.add(_BgCategory(name: 'Unsplash · Cine y paisaje', items: unsplash));
    } catch (_) {}
    if (mounted) {
      setState(() {
        _freeCats = cats;
        _loadingFree = false;
      });
    }
  }

  /// Solo busca títulos (movie/tv). Los backdrops se cargan al elegir uno.
  Future<void> _searchTmdb(String q) async {
    final query = q.trim();
    if (query.length < 2) return;
    setState(() {
      _loadingSearch = true;
      _query = query;
      _galleryFor = null;
      _galleryUrls = [];
      _searchResults = [];
    });
    try {
      final results = <_BgItem>[];
      for (final type in ['movie', 'tv']) {
        final uri = Uri.parse('https://api.themoviedb.org/3/search/$type').replace(
          queryParameters: {
            'api_key': _tmdbKey,
            'query': query,
            'language': 'es-ES',
          },
        );
        final j = await _httpJson(uri.toString());
        final list = j?['results'];
        if (list is! List) continue;
        for (final r in list.take(12)) {
          if (r is! Map) continue;
          final id = r['id'];
          final title = (r['title'] ?? r['name'] ?? '').toString();
          if (id == null || title.isEmpty) continue;
          final poster = r['poster_path'];
          final backdrop = r['backdrop_path'];
          String thumb = '';
          if (poster is String) {
            thumb = 'https://image.tmdb.org/t/p/w185$poster';
          } else if (backdrop is String) {
            thumb = 'https://image.tmdb.org/t/p/w300$backdrop';
          }
          final year = (r['release_date'] ?? r['first_air_date'] ?? '').toString();
          results.add(_BgItem(
            title: title,
            url: thumb,
            type: type,
            tmdbId: id is int ? id : int.tryParse('$id'),
            year: year.length >= 4 ? year.substring(0, 4) : '',
          ));
        }
      }
      if (mounted) setState(() => _searchResults = results);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loadingSearch = false);
    }
  }

  /// Carga TODOS los backdrops del contenido elegido → galería en rejilla.
  Future<void> _openBackdropGallery(_BgItem item) async {
    if (item.tmdbId == null) return;
    setState(() {
      _loadingGallery = true;
      _galleryFor = item;
      _galleryUrls = [];
    });
    try {
      final uri = Uri.parse(
              'https://api.themoviedb.org/3/${item.type}/${item.tmdbId}/images')
          .replace(queryParameters: {
        'api_key': _tmdbKey,
        'include_image_language': 'null,en,es',
      });
      final j = await _httpJson(uri.toString());
      final bds = j?['backdrops'];
      final urls = <String>[];
      if (bds is List) {
        final sorted = bds.whereType<Map>().toList()
          ..sort((a, b) {
            final wa = ((a['width'] as num?) ?? 0).toDouble();
            final wb = ((b['width'] as num?) ?? 0).toDouble();
            final va = ((a['vote_average'] as num?) ?? 0).toDouble();
            final vb = ((b['vote_average'] as num?) ?? 0).toDouble();
            // Priorizar resolución y luego voto
            final c = wb.compareTo(wa);
            return c != 0 ? c : vb.compareTo(va);
          });
        for (final b in sorted) {
          final path = b['file_path'];
          final w = (b['width'] as num?) ?? 0;
          // Solo backdrops de resolución decente; usamos /original para máxima calidad HD
          if (path is String && w >= 780) {
            urls.add('https://image.tmdb.org/t/p/original$path');
          }
        }
      }
      // Fallback: al menos el backdrop de la ficha en máxima calidad
      if (urls.isEmpty && item.url.isNotEmpty) {
        urls.add(item.url
            .replaceFirst('/w185', '/original')
            .replaceFirst('/w300', '/original')
            .replaceFirst('/w780', '/original')
            .replaceFirst('/w1280', '/original'));
      }
      if (mounted) setState(() => _galleryUrls = urls);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loadingGallery = false);
    }
  }

  Future<void> _apply(HomeBgMode mode, {String url = ''}) async {
    await widget.settings.setHomeBgMode(mode);
    if (url.isNotEmpty) await widget.settings.setHomeBgUrl(url);
    if (mounted) {
      setState(() {
        _mode = mode;
        if (url.isNotEmpty) _url = url;
      });
    }
  }

  Future<void> _openKeyboardSearch() async {
    final result = await TvKeyboard.show(
      context,
      initial: _query,
      title: 'Buscar película o serie',
      hint: 'Nombre de la película o serie',
    );
    if (result != null && result.trim().isNotEmpty) {
      await _searchTmdb(result.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    // Vista de galería de backdrops de un título concreto
    if (_galleryFor != null) {
      return _buildGalleryView();
    }

    return Scaffold(
      backgroundColor: kTvBg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 20, 28, 12),
              child: Row(
                children: [
                  Focusable(
                    autofocus: true,
                    onTap: () => Navigator.pop(context),
                    builder: (f) => Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: f ? Colors.white : Colors.transparent, width: 2),
                      ),
                      child: Icon(Icons.arrow_back_rounded, color: f ? Colors.white : Colors.white60, size: 22),
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Text('Fondo del Home',
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(28, 8, 28, 32),
                children: [
                  const Text('MODO',
                      style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.2, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _modeChip('Galería TMDB', HomeBgMode.tmdb, Icons.auto_awesome_motion),
                      _modeChip('Fondo fijo', HomeBgMode.fixed, Icons.image_rounded),
                      _modeChip('Buscar TMDB', HomeBgMode.custom, Icons.search_rounded),
                      _modeChip('Catálogo LOL', HomeBgMode.lol, Icons.collections_rounded),
                      _modeChip('Imágenes gratis', HomeBgMode.fixed, Icons.photo_library_rounded, freeSource: true),
                    ],
                  ),
                  const SizedBox(height: 24),
                  if (_mode == HomeBgMode.tmdb)
                    const Text('Fondos rotativos de películas y series bien valoradas (TMDB).',
                        style: TextStyle(color: Colors.white54, fontSize: 13)),
                  if (_mode == HomeBgMode.fixed && _galleryFor == null && _freeCats.isEmpty && _searchResults.isEmpty) ...[
                    const Text('Fondo fijo actual. Cambia con Buscar TMDB, LOL o Imágenes gratis.',
                        style: TextStyle(color: Colors.white54, fontSize: 13)),
                    if (_url.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      // Preview compacto (no a pantalla completa)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          width: 320,
                          height: 100,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.white24),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: CachedNetworkImage(
                            imageUrl: _url,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) => const ColoredBox(color: Colors.black26),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(_url, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white38, fontSize: 11)),
                    ],
                  ],
                  if (_mode == HomeBgMode.custom) ...[
                    _TvTile(
                      icon: Icons.keyboard_rounded,
                      title: 'Buscar película o serie',
                      subtitle: _query.isEmpty
                          ? 'Teclado QWERTY · luego elige un título y su backdrop'
                          : 'Buscado: "$_query"',
                      onTap: _openKeyboardSearch,
                    ),
                    if (_loadingSearch)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator(color: kTvAccent)),
                      ),
                    if (!_loadingSearch && _searchResults.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text('RESULTADOS (${_searchResults.length}) — elige un título',
                          style: const TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.0)),
                      const SizedBox(height: 10),
                      ..._searchResults.map((r) => _resultTile(r)),
                    ],
                    if (!_loadingSearch && _query.isNotEmpty && _searchResults.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 16),
                        child: Text('Sin resultados. Prueba otro nombre.',
                            style: TextStyle(color: Colors.white54)),
                      ),
                  ],
                  if (_mode == HomeBgMode.lol) ...[
                    if (_loadingLol)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator(color: kTvAccent)),
                      ),
                    if (!_loadingLol && _lolCats.isEmpty)
                      const Text('No se pudo cargar el catálogo LOL.', style: TextStyle(color: Colors.white54)),
                    for (final cat in _lolCats) _categoryGallery(cat),
                  ],
                  if (_freeCats.isNotEmpty) ...[
                    if (_loadingFree)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator(color: kTvAccent)),
                      ),
                    for (final cat in _freeCats) _categoryGallery(cat),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Galería en rejilla de todos los backdrops de un título TMDB.
  Widget _buildGalleryView() {
    final item = _galleryFor!;
    return Scaffold(
      backgroundColor: kTvBg,
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
                    onTap: () => setState(() {
                      _galleryFor = null;
                      _galleryUrls = [];
                    }),
                    builder: (f) => Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: f ? Colors.white : Colors.transparent, width: 2),
                      ),
                      child: Icon(Icons.arrow_back_rounded, color: f ? Colors.white : Colors.white60, size: 22),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
                        Text(
                          '${item.type == 'tv' ? 'Serie' : 'Película'}'
                          '${item.year.isNotEmpty ? ' · ${item.year}' : ''}'
                          ' · ${_galleryUrls.length} backdrops — elige uno como fondo fijo',
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (_loadingGallery)
              const Expanded(child: Center(child: CircularProgressIndicator(color: kTvAccent)))
            else if (_galleryUrls.isEmpty)
              const Expanded(
                child: Center(child: Text('No hay backdrops para este título', style: TextStyle(color: Colors.white54))),
              )
            else
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 16 / 9,
                  ),
                  itemCount: _galleryUrls.length,
                  itemBuilder: (ctx, i) {
                    final u = _galleryUrls[i]; // URL de máxima calidad (original)
                    final selected = _url == u;
                    // Preview de baja calidad para carga rápida; el seleccionado usa original HD
                    final previewUrl = u
                        .replaceFirst('/original', '/w780')
                        .replaceFirst('/w1280', '/w780');
                    return Focusable(
                      onTap: () async {
                        // Se aplica siempre la URL de alta calidad
                        await _apply(HomeBgMode.fixed, url: u);
                        if (mounted) {
                          setState(() {
                            _galleryFor = null;
                            _galleryUrls = [];
                          });
                        }
                      },
                      builder: (f) => AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: f ? Colors.white : (selected ? kTvAccent : Colors.white12),
                            width: f || selected ? 2.5 : 1,
                          ),
                          boxShadow: f
                              ? [BoxShadow(color: kTvAccent.withValues(alpha: 0.35), blurRadius: 12)]
                              : null,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            CachedNetworkImage(
                              imageUrl: previewUrl,
                              fit: BoxFit.cover,
                              memCacheWidth: 480,
                              errorWidget: (_, __, ___) => const ColoredBox(color: Colors.black26),
                            ),
                            if (selected)
                              const Align(
                                alignment: Alignment.topRight,
                                child: Padding(
                                  padding: EdgeInsets.all(6),
                                  child: Icon(Icons.check_circle, color: kTvAccent, size: 22),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _categoryGallery(_BgCategory cat) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(cat.name.toUpperCase(),
            style: const TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.2, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        // Rejilla 4 columnas, altura fija por filas con scroll horizontal si hay muchas
        SizedBox(
          height: 100,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: cat.items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (_, i) {
              final u = cat.items[i];
              final selected = _url == u;
              return Focusable(
                onTap: () => _apply(HomeBgMode.fixed, url: u),
                builder: (f) => Container(
                  width: 170,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: f ? Colors.white : (selected ? kTvAccent : Colors.transparent),
                      width: 2,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CachedNetworkImage(
                        imageUrl: u,
                        fit: BoxFit.cover,
                        memCacheWidth: 340,
                        errorWidget: (_, __, ___) => const ColoredBox(color: Colors.black26),
                      ),
                      if (selected)
                        const Align(
                          alignment: Alignment.topRight,
                          child: Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(Icons.check_circle, color: kTvAccent, size: 18),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _modeChip(String label, HomeBgMode mode, IconData icon, {bool freeSource = false}) {
    final sel = freeSource ? _freeCats.isNotEmpty : (_mode == mode && !freeSource && _freeCats.isEmpty);
    return Focusable(
      onTap: () async {
        if (freeSource) {
          setState(() {
            _mode = HomeBgMode.fixed;
            _searchResults = [];
            _galleryFor = null;
          });
          await _loadFreeRepos();
          return;
        }
        setState(() {
          _freeCats = [];
          _galleryFor = null;
        });
        await _apply(mode);
        if (mode == HomeBgMode.lol && _lolCats.isEmpty) unawaited(_loadLol());
      },
      builder: (f) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: sel ? kTvAccent.withValues(alpha: 0.25) : Colors.white.withValues(alpha: 0.06),
          border: Border.all(color: f ? Colors.white : (sel ? kTvAccent : Colors.transparent), width: 2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: sel ? Colors.white : Colors.white70),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(color: sel ? Colors.white : Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _resultTile(_BgItem r) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Focusable(
        onTap: () => _openBackdropGallery(r),
        builder: (f) => Container(
          height: 72,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: Colors.white.withValues(alpha: 0.05),
            border: Border.all(color: f ? Colors.white : Colors.transparent, width: 2),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            children: [
              SizedBox(
                width: 52,
                height: 72,
                child: r.url.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: r.url,
                        fit: BoxFit.cover,
                        memCacheWidth: 120,
                        errorWidget: (_, __, ___) => const ColoredBox(color: Colors.black26),
                      )
                    : const ColoredBox(color: Colors.black26),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                    Text(
                      '${r.type == 'tv' ? 'Serie' : 'Película'}'
                      '${r.year.isNotEmpty ? ' · ${r.year}' : ''} · ver backdrops',
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(right: 12),
                child: Icon(Icons.chevron_right_rounded, color: Colors.white38, size: 22),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BgItem {
  final String title;
  final String url;
  final String type;
  final int? tmdbId;
  final String year;
  _BgItem({
    required this.title,
    required this.url,
    required this.type,
    this.tmdbId,
    this.year = '',
  });
}

class _BgCategory {
  final String name;
  final List<String> items;
  _BgCategory({required this.name, required this.items});
}
