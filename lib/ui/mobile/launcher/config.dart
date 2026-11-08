//  config mobil
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../data/services/settings_service.dart';
import '../../../data/services/repo_manager.dart';
import '../../../data/services/library_service.dart';
import '../widgets/focusable.dart';
import '../../shared/update_banner.dart';

class GlobalSettingsPage extends StatefulWidget {
  const GlobalSettingsPage({super.key});

  @override
  State<GlobalSettingsPage> createState() => _GlobalSettingsPageState();
}

class _GlobalSettingsPageState extends State<GlobalSettingsPage> {
  bool _showReposView = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0E14),
      body: SafeArea(
        child: _showReposView ? _buildReposView() : _buildMainSettings(),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  VISTA PRINCIPAL DE CONFIGURACIÓN
  // ═══════════════════════════════════════════════════════════════════
  Widget _buildMainSettings() {
    final settings = context.watch<SettingsService>();
    final manager = context.watch<RepoManager>();

    return ListView(
      padding: const EdgeInsets.all(28),
      children: [
        Row(
          children: [
            Focusable(
              onTap: () => Navigator.pop(context),
              builder: (f) => Icon(
                Icons.arrow_back,
                color: f ? Colors.white : Colors.white54,
              ),
            ),
            const SizedBox(width: 16),
            const Text(
              'Configuración',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 32),

        // ═══ Actualizaciones ═══
        const _SectionLabel('Actualizaciones'),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF141A22),
            borderRadius: BorderRadius.circular(12),
          ),
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Notificar parches',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              'Parches: ON = avisar también parches. Las versiones nuevas se avisan siempre.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 12,
              ),
            ),
            value: settings.notifyPatches,
            activeColor: const Color(0xFFE50914),
            onChanged: (v) => settings.setNotifyPatches(v),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF141A22),
            borderRadius: BorderRadius.circular(12),
          ),
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Habilitar descargas',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              'Muestra u oculta los botones de descarga en fichas y capítulos.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 12,
              ),
            ),
            value: settings.downloadsEnabled,
            activeColor: const Color(0xFFE50914),
            onChanged: (v) => settings.setDownloadsEnabled(v),
          ),
        ),
        const SizedBox(height: 12),
        Material(
          color: const Color(0xFF141A22),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => showAppUpdateFlow(context, forceNotifyPatches: true),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Icon(Icons.system_update_rounded,
                      color: Color(0xFFE50914), size: 22),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Verificar actualización',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Comprueba en GitHub y abre el modal si hay una nueva',
                          style: TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: Colors.white38),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 32),

        // ═══ Modo de interfaz ═══
        const _SectionLabel('Modo de interfaz'),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 500;
            final cards = [
              _ModeCard(
                title: 'TV (horizontal)',
                subtitle: 'Navegación con foco / mando',
                selected: settings.isTv,
                onTap: () => settings.setMode(UiMode.tv),
              ),
              _ModeCard(
                title: 'Móvil (vertical)',
                subtitle: 'Touch y orientación portrait',
                selected: settings.isMobile,
                onTap: () => settings.setMode(UiMode.mobile),
              ),
            ];
            if (narrow) {
              return Column(
                children: [
                  SizedBox(width: double.infinity, child: cards[0]),
                  const SizedBox(height: 12),
                  SizedBox(width: double.infinity, child: cards[1]),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: cards[0]),
                const SizedBox(width: 16),
                Expanded(child: cards[1]),
              ],
            );
          },
        ),
        const SizedBox(height: 32),

        // ═══ Repositorios (acceso a vista) ═══
        const _SectionLabel('Repositorios instalados'),
        const SizedBox(height: 12),
        Material(
          color: const Color(0xFF141A22),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _showReposView = true),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  const Icon(Icons.folder_copy_rounded,
                      color: Colors.white70, size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Gestionar repositorios',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${manager.installed.length} instalado(s) · activar, configurar, eliminar',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: Colors.white38),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Material(
          color: const Color(0xFF141A22),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () async {
              await manager.refreshAllContent();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Caché de contenido limpiada. Al abrir un repo se recargará.'),
                  ),
                );
              }
            },
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Icon(Icons.refresh_rounded, color: Colors.white70, size: 22),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Actualizar contenido',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 14)),
                        SizedBox(height: 2),
                        Text('Limpia caché y recarga home/discover',
                            style: TextStyle(color: Colors.white54, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Material(
          color: const Color(0xFF141A22),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () async {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Comprobando repos…')),
              );
              await manager.runAllHealthChecks();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Health-check terminado. Mira el estado en Repositorios.'),
                  ),
                );
              }
            },
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Icon(Icons.health_and_safety_outlined, color: Colors.white70, size: 22),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Health-check de repos',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 14)),
                        SizedBox(height: 2),
                        Text('Prueba getHome en cada repo activo',
                            style: TextStyle(color: Colors.white54, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 32),

        // ═══ Player ═══
        const _SectionLabel('Player'),
        const SizedBox(height: 12),
        _PlayerSettingsCard(),
        const SizedBox(height: 40),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  VISTA DE REPOSITORIOS
  // ═══════════════════════════════════════════════════════════════════
  Widget _buildReposView() {
    final manager = context.watch<RepoManager>();
    final lib = context.watch<LibraryService>();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(
            children: [
              Focusable(
                onTap: () => setState(() => _showReposView = false),
                builder: (f) => Icon(
                  Icons.arrow_back,
                  color: f ? Colors.white : Colors.white54,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Repositorios',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (manager.updateCount > 0)
                      Text(
                        '${manager.updateCount} actualización(es) disponible(s)',
                        style: const TextStyle(color: Color(0xFF7DD3FC), fontSize: 12),
                      ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: () async {
                  final n = await manager.checkAllUpdates();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(n == 0
                            ? 'Todos los repos están al día'
                            : '$n actualización(es) encontrada(s)'),
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.system_update_rounded, size: 18, color: Colors.white70),
                label: const Text('Updates', style: TextStyle(color: Colors.white70, fontSize: 13)),
              ),
            ],
          ),
        ),
        Expanded(
          child: manager.installed.isEmpty
              ? const Center(
                  child: Text(
                    'No hay repositorios instalados',
                    style: TextStyle(color: Colors.white54),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  itemCount: manager.installed.length,
                  itemBuilder: (context, i) {
                    final r = manager.installed[i];
                    final health = manager.healthOf(r);
                    final hasUpd = manager.hasUpdate(r.manifest.id);
                    final healthColor = health == 'ok'
                        ? const Color(0xFF4CAF50)
                        : health == 'no_js'
                            ? const Color(0xFFFF9800)
                            : Colors.white38;
                    final healthLabel = health == 'ok'
                        ? 'OK'
                        : health == 'no_js'
                            ? 'Sin JS'
                            : 'Off';
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF141A22),
                        borderRadius: BorderRadius.circular(12),
                        border: hasUpd
                            ? Border.all(color: const Color(0xFF7DD3FC).withValues(alpha: 0.45))
                            : null,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                margin: const EdgeInsets.only(right: 10),
                                decoration: BoxDecoration(color: healthColor, shape: BoxShape.circle),
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      r.manifest.name,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      '${r.manifest.repo} · v${r.manifest.version} · $healthLabel'
                                      '${hasUpd ? ' · Update v${manager.remoteVersion(r.manifest.id) ?? "?"}' : ''}',
                                      style: TextStyle(
                                        color: hasUpd ? const Color(0xFF7DD3FC) : Colors.white38,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Switch(
                                value: r.enabled,
                                activeColor: const Color(0xFFE50914),
                                onChanged: (v) =>
                                    manager.setEnabled(r.manifest.id, v),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    color: Colors.white38),
                                onPressed: () async {
                                  final ok = await _confirmDelete(context, r.manifest.name);
                                  if (ok != true) return;
                                  final id = r.manifest.id;
                                  await manager.uninstall(id);
                                  try {
                                    await lib.clearRepoData(id);
                                  } catch (_) {}
                                },
                              ),
                            ],
                          ),
                          if (hasUpd)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: OutlinedButton.icon(
                                onPressed: () async {
                                  try {
                                    await manager.updateRepo(r);
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('${r.manifest.name} actualizado')),
                                      );
                                    }
                                  } catch (e) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('Error: $e')),
                                      );
                                    }
                                  }
                                },
                                icon: const Icon(Icons.system_update_rounded,
                                    size: 16, color: Color(0xFF7DD3FC)),
                                label: const Text(
                                  'Actualizar ahora',
                                  style: TextStyle(color: Color(0xFF7DD3FC), fontSize: 12),
                                ),
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(color: Color(0xFF7DD3FC)),
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  minimumSize: const Size(0, 32),
                                ),
                              ),
                            ),
                          if (r.manifest.configFields.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: OutlinedButton.icon(
                                onPressed: () => _showConfigDialog(context, r),
                                icon: const Icon(Icons.settings,
                                    size: 16, color: Colors.white70),
                                label: const Text(
                                  'Configurar (API keys, etc.)',
                                  style: TextStyle(
                                      color: Colors.white70, fontSize: 12),
                                ),
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(color: Colors.white24),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 6),
                                  minimumSize: const Size(0, 32),
                                ),
                              ),
                            ),
                        ],
                      ),
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
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A222D),
        title: const Text('Eliminar repositorio',
            style: TextStyle(color: Colors.white)),
        content: Text(
          '¿Eliminar "$name"? Se borrarán sus datos de biblioteca.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar',
                style: TextStyle(color: Color(0xFFE50914))),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  DIÁLOGO DE CONFIG DE REPO (API keys, etc.)
  // ═══════════════════════════════════════════════════════════════════
  void _showConfigDialog(BuildContext context, dynamic r) {
    final manager = context.read<RepoManager>();
    final controllers = <String, TextEditingController>{};
    for (final f in r.manifest.configFields) {
      controllers[f.key] = TextEditingController(
        text: r.userConfig[f.key] ?? f.defaultValue ?? '',
      );
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A222D),
        title: Text('Config — ${r.manifest.name}',
            style: const TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: r.manifest.configFields.map<Widget>((f) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextField(
                  controller: controllers[f.key],
                  obscureText: f.type == 'password',
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: f.label,
                    labelStyle: const TextStyle(color: Colors.white54),
                    helperText: f.description,
                    helperStyle: const TextStyle(color: Colors.white30),
                    filled: true,
                    fillColor: const Color(0xFF0B0E14),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () {
              final map = <String, String>{};
              controllers.forEach((k, c) => map[k] = c.text);
              manager.saveUserConfig(r.manifest.id, map);
              Navigator.pop(ctx);
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
//  WIDGETS AUXILIARES
// ═════════════════════════════════════════════════════════════════════

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(color: Colors.white54, fontSize: 13),
      );
}

class _ModeCard extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Focusable(
      onTap: onTap,
      builder: (focused) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFFE50914).withValues(alpha: 0.2)
              : const Color(0xFF141A22),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: focused
                ? const Color(0xFFFF2D2D)
                : (selected ? const Color(0xFFE50914) : Colors.transparent),
            width: 2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(subtitle,
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
//  PLAYER SETTINGS (subtítulos + calidad HLS predefinida en cache)
// ═════════════════════════════════════════════════════════════════════

/// Estado local en memoria para los ajustes del player. Si tu
/// `SettingsService` ya expone estos campos, puedes migrar los getters/setters
/// a él y este widget los leerá automáticamente desde ahí (try/catch).
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

  /// 'auto' o label de calidad HLS (p.ej. '720p') predefinida para cache.
  String hlsPreferredQuality = 'auto';

  void update(VoidCallback fn) {
    fn();
    notifyListeners();
  }
}

class _PlayerSettingsCard extends StatefulWidget {
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
            color: const Color(0xFF141A22),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Calidad HLS predefinida (cache) ──
              _rowLabel('Calidad HLS predefinida'),
              const SizedBox(height: 6),
              _selectableTile(
                icon: Icons.high_quality_rounded,
                label: _local.hlsPreferredQuality == 'auto'
                    ? 'Automática'
                    : _local.hlsPreferredQuality,
                onTap: () async {
                  final picked = await _showPickerSheet<String>(
                    context: context,
                    title: 'Calidad HLS predefinida',
                    options: const [
                      ('auto', 'Automática'),
                      ('1080p', '1080p'),
                      ('720p', '720p'),
                      ('480p', '480p'),
                      ('360p', '360p'),
                    ],
                    current: _local.hlsPreferredQuality,
                  );
                  if (picked != null) {
                    _local.update(() => _local.hlsPreferredQuality = picked);
                  }
                },
              ),
              const SizedBox(height: 20),

              // ── Subtítulos ──
              _rowLabel('Subtítulos'),
              const SizedBox(height: 8),

              // Tamaño
              _sliderRow(
                label: 'Tamaño',
                value: _local.subFontSize,
                min: 16,
                max: 48,
                display: '${_local.subFontSize.round()} px',
                onChanged: (v) => _local.update(() => _local.subFontSize = v),
              ),

              // Altura
              _sliderRow(
                label: 'Altura desde borde inferior',
                value: _local.subBottomPad,
                min: 8,
                max: 120,
                display: '${_local.subBottomPad.round()} px',
                onChanged: (v) => _local.update(() => _local.subBottomPad = v),
              ),

              // Borde
              _sliderRow(
                label: 'Grosor del borde',
                value: _local.subBorder,
                min: 0,
                max: 4,
                divisions: 8,
                display: _local.subBorder.toStringAsFixed(1),
                onChanged: (v) => _local.update(() => _local.subBorder = v),
              ),

              // Offset
              _sliderRow(
                label: 'Desfase (offset)',
                value: _local.subtitleOffsetSec,
                min: -5,
                max: 5,
                divisions: 20,
                display: '${_local.subtitleOffsetSec.toStringAsFixed(1)} s',
                onChanged: (v) =>
                    _local.update(() => _local.subtitleOffsetSec = v),
              ),

              const SizedBox(height: 8),

              // Color
              _selectableTile(
                icon: Icons.palette_rounded,
                label: 'Color',
                trailing: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: _local.subColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white24),
                  ),
                ),
                onTap: () async {
                  final picked = await _showPickerSheet<Color>(
                    context: context,
                    title: 'Color de subtítulos',
                    options: const [
                      (Color(0xFFFFFFFF), 'Blanco'),
                      (Color(0xFFFFFF00), 'Amarillo'),
                      (Color(0xFF00FFFF), 'Cian'),
                      (Color(0xFF00FF00), 'Verde'),
                      (Color(0xFFFFA0A0), 'Rosa'),
                    ],
                    current: _local.subColor,
                    swatch: true,
                  );
                  if (picked != null) {
                    _local.update(() => _local.subColor = picked);
                  }
                },
              ),

              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Negrita',
                    style: TextStyle(color: Colors.white, fontSize: 14)),
                value: _local.subBold,
                activeColor: const Color(0xFFE50914),
                onChanged: (v) => _local.update(() => _local.subBold = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Fondo oscuro',
                    style: TextStyle(color: Colors.white, fontSize: 14)),
                value: _local.subBg,
                activeColor: const Color(0xFFE50914),
                onChanged: (v) => _local.update(() => _local.subBg = v),
              ),

              const SizedBox(height: 12),
              // Vista previa
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Vista previa de subtítulos',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: _local.subFontSize * 0.7,
                    color: _local.subColor,
                    fontWeight:
                        _local.subBold ? FontWeight.w800 : FontWeight.w500,
                    backgroundColor: _local.subBg
                        ? const Color(0x99000000)
                        : Colors.transparent,
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

  Widget _rowLabel(String text) => Text(
        text,
        style: const TextStyle(
            color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
      );

  Widget _sliderRow({
    required String label,
    required double value,
    required double min,
    required double max,
    int? divisions,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ),
            Text(display,
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          activeColor: const Color(0xFFE50914),
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _selectableTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Widget? trailing,
  }) {
    return Material(
      color: const Color(0xFF0B0E14),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: Colors.white54, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(label,
                    style: const TextStyle(color: Colors.white, fontSize: 14)),
              ),
              if (trailing != null) trailing,
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right, color: Colors.white38, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
//  BOTTOM SHEET SELECTOR REUTILIZABLE
//  - Se cierra confirmando al seleccionar
//  - Aplica el valor en tiempo real (el caller hace el update)
// ═════════════════════════════════════════════════════════════════════

Future<T?> _showPickerSheet<T>({
  required BuildContext context,
  required String title,
  required List<(T, String)> options,
  required T current,
  bool swatch = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: const Color(0xFF1A222D),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: options.map((opt) {
                  final isSelected = opt.$1 == current;
                  return ListTile(
                    selected: isSelected,
                    selectedTileColor:
                        const Color(0xFFE50914).withValues(alpha: 0.15),
                    leading: swatch
                        ? Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: opt.$1 as Color,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white24),
                            ),
                          )
                        : Icon(
                            isSelected
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            color: isSelected
                                ? const Color(0xFFE50914)
                                : Colors.white38,
                          ),
                    title: Text(
                      opt.$2,
                      style: TextStyle(
                        color: isSelected ? Colors.white : Colors.white70,
                        fontWeight: isSelected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                    trailing: isSelected
                        ? const Icon(Icons.check,
                            color: Color(0xFFE50914), size: 20)
                        : null,
                    // Cierra confirmando: aplica en tiempo real vía caller
                    onTap: () => Navigator.pop(ctx, opt.$1),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}