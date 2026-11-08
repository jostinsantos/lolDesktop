import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/services/settings_service.dart';
import '../data/services/repo_manager.dart';
import '../core/desktop_window.dart';
import '../data/services/ui_scale_service.dart';
import '../data/services/version_service.dart';
import '../ui/shared/update_banner.dart';

const _card = Color(0xFF161A22);
const _accent = Color(0xFFE50914);
const _border = Color(0xFF1E2430);

/// Ajustes desktop: fondo launcher, blur, subtítulos, Windows, descargas, escala UI.
class LauncherConfigPage extends StatefulWidget {
  const LauncherConfigPage({super.key});

  @override
  State<LauncherConfigPage> createState() => _LauncherConfigPageState();
}

class _LauncherConfigPageState extends State<LauncherConfigPage> {
  // Subtitle prefs
  double _subSize = 42;
  double _subMarginY = 18;
  double _subBorder = 2;
  bool _subBold = true;
  bool _subBg = false;
  Color _subColor = Colors.white;

  // Windows / UI
  bool _startWithWindows = false;
  bool _closeToTray = true;
  double _uiScale = 1.0;

  @override
  void initState() {
    super.initState();
    _loadLocal();
  }

  Future<void> _loadLocal() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _subSize = p.getDouble('sub_size') ?? 42;
      _subMarginY = p.getDouble('sub_margin_y') ?? 18;
      _subBorder = p.getDouble('sub_border') ?? 2;
      _subBold = p.getBool('sub_bold') ?? true;
      _subBg = p.getBool('sub_bg') ?? false;
      final c = p.getInt('sub_color');
      if (c != null) _subColor = Color(c);
      _startWithWindows = p.getBool('start_with_windows') ?? false;
      _closeToTray = p.getBool('close_to_tray') ?? true;
      _uiScale = p.getDouble('ui_scale') ?? 1.0;
    });
    UiScaleService.instance.setScale(_uiScale);
  }

  Future<void> _saveLocal() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble('sub_size', _subSize);
    await p.setDouble('sub_margin_y', _subMarginY);
    await p.setDouble('sub_border', _subBorder);
    await p.setBool('sub_bold', _subBold);
    await p.setBool('sub_bg', _subBg);
    await p.setInt('sub_color', _subColor.value);
    await p.setBool('start_with_windows', _startWithWindows);
    await p.setBool('close_to_tray', _closeToTray);
    await p.setDouble('ui_scale', _uiScale);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final manager = context.watch<RepoManager>();

    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 48),
      children: [
        const Text('Ajustes', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
        const SizedBox(height: 20),

        _section('Actualizaciones'),
        _cardBox(
          children: [
            ListTile(
              title: const Text('Verificar actualizaciones', style: TextStyle(color: Colors.white)),
              subtitle: Text(
                'v${VersionService.currentVersionName} · parche ${VersionService.currentParche}',
                style: const TextStyle(color: Colors.white38),
              ),
              trailing: const Icon(Icons.system_update_alt, color: Colors.white54),
              onTap: () => showAppUpdateFlow(context, forceNotifyPatches: true),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'Al actualizar, tus repos, descargas y ajustes se conservan. '
                'Solo se reemplaza el ejecutable de la app.',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ),
          ],
        ),

        _section('Fondo del Home (launcher)'),
        _cardBox(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _modeChip(settings, 'Desactivado', null, onTap: () async {
                    await settings.setHomeBgMode(HomeBgMode.fixed);
                    await settings.setHomeBgUrl('');
                  }, selected: settings.homeBgMode == HomeBgMode.fixed && settings.homeBgUrl.isEmpty),
                  _modeChip(settings, 'Automático TMDB', HomeBgMode.tmdb),
                  _modeChip(settings, 'Buscar TMDB', HomeBgMode.custom),
                  _modeChip(settings, 'Catálogo LOL', HomeBgMode.lol),
                  _modeChip(settings, 'Imágenes gratis', HomeBgMode.fixed, selected: settings.homeBgMode == HomeBgMode.fixed && settings.homeBgUrl.isNotEmpty),
                ],
              ),
            ),
            if (settings.homeBgMode == HomeBgMode.custom ||
                (settings.homeBgMode == HomeBgMode.fixed && settings.homeBgUrl.isNotEmpty) ||
                settings.homeBgMode == HomeBgMode.lol)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: TextField(
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'URL de imagen (elige una y pégala aquí)',
                    labelStyle: TextStyle(color: Colors.white54),
                    helperText: 'TMDB / LOL / gratis: pega la URL de la imagen elegida',
                    helperStyle: TextStyle(color: Colors.white30),
                  ),
                  controller: TextEditingController(text: settings.homeBgUrl)
                    ..selection = TextSelection.collapsed(offset: settings.homeBgUrl.length),
                  onSubmitted: (v) => settings.setHomeBgUrl(v.trim()),
                ),
              ),
            ListTile(
              title: const Text('Intensidad de blur', style: TextStyle(color: Colors.white)),
              subtitle: Slider(
                value: settings.homeBgBlur.clamp(0, 32),
                min: 0,
                max: 32,
                divisions: 32,
                activeColor: _accent,
                label: settings.homeBgBlur.toStringAsFixed(0),
                onChanged: (v) => settings.setHomeBgBlur(v),
              ),
            ),
            ListTile(
              title: const Text('Oscurecer fondo', style: TextStyle(color: Colors.white)),
              subtitle: Slider(
                value: settings.homeBgDim.clamp(0, 1),
                min: 0,
                max: 1,
                divisions: 20,
                activeColor: _accent,
                label: settings.homeBgDim.toStringAsFixed(2),
                onChanged: (v) => settings.setHomeBgDim(v),
              ),
            ),
          ],
        ),

        _section('Subtítulos'),
        _cardBox(
          children: [
            SwitchListTile(
              title: const Text('Negrita', style: TextStyle(color: Colors.white)),
              value: _subBold,
              activeColor: _accent,
              onChanged: (v) {
                setState(() => _subBold = v);
                _saveLocal();
              },
            ),
            SwitchListTile(
              title: const Text('Fondo detrás del texto', style: TextStyle(color: Colors.white)),
              value: _subBg,
              activeColor: _accent,
              onChanged: (v) {
                setState(() => _subBg = v);
                _saveLocal();
              },
            ),
            _sliderTile('Tamaño', _subSize, 18, 72, (v) {
              setState(() => _subSize = v);
              _saveLocal();
            }),
            _sliderTile('Separación inferior', _subMarginY, 0, 80, (v) {
              setState(() => _subMarginY = v);
              _saveLocal();
            }),
            _sliderTile('Grosor del borde (por letra)', _subBorder, 0, 8, (v) {
              setState(() => _subBorder = v);
              _saveLocal();
            }),
            ListTile(
              title: const Text('Color del subtítulo', style: TextStyle(color: Colors.white)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final c in [Colors.white, Colors.yellow, Colors.cyanAccent, Colors.lightGreenAccent])
                    GestureDetector(
                      onTap: () {
                        setState(() => _subColor = c);
                        _saveLocal();
                      },
                      child: Container(
                        width: 28,
                        height: 28,
                        margin: const EdgeInsets.only(left: 6),
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _subColor == c ? _accent : Colors.white24,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'El borde es un contorno negro por letra (no sombra). Se aplica en el player al abrir un stream.',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ),
          ],
        ),

        _section('Descargas'),
        _cardBox(
          children: [
            SwitchListTile(
              title: const Text('Habilitar descargas', style: TextStyle(color: Colors.white)),
              subtitle: const Text('Muestra botones y gestiona archivos en Windows', style: TextStyle(color: Colors.white38)),
              value: settings.downloadsEnabled,
              activeColor: _accent,
              onChanged: (v) => settings.setDownloadsEnabled(v),
            ),
          ],
        ),

        _section('Windows'),
        _cardBox(
          children: [
            ListTile(
              leading: const Icon(Icons.push_pin_outlined, color: Colors.white70),
              title: const Text('Crear acceso directo en el Escritorio',
                  style: TextStyle(color: Colors.white)),
              subtitle: const Text(
                'LOL Lite.lnk en el escritorio (un clic para abrir)',
                style: TextStyle(color: Colors.white38),
              ),
              trailing: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _accent),
                onPressed: () async {
                  final ok =
                      await VersionService.instance.createDesktopShortcut();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(ok
                          ? 'Acceso directo creado en el Escritorio'
                          : (VersionService.instance.lastInstallError ??
                              'No se pudo crear el acceso directo')),
                    ),
                  );
                },
                child: const Text('Crear'),
              ),
            ),
            const Divider(color: _border, height: 20),
            SwitchListTile(
              title: const Text('Iniciar con Windows', style: TextStyle(color: Colors.white)),
              subtitle: const Text('Se registra en el inicio de Windows. Se actualiza solo tras cada update.', style: TextStyle(color: Colors.white38)),
              value: _startWithWindows,
              activeColor: _accent,
              onChanged: (v) async {
                setState(() => _startWithWindows = v);
                await _saveLocal();
                await DesktopWindowController.instance.setStartWithWindows(v);
              },
            ),
            SwitchListTile(
              title: const Text('Cerrar a la bandeja', style: TextStyle(color: Colors.white)),
              subtitle: const Text(
                'Al pulsar X se oculta en la flechita de notificaciones (bandeja) y sale de la barra de tareas. Minimizar sigue funcionando normal.',
                style: TextStyle(color: Colors.white38),
              ),
              value: _closeToTray,
              activeColor: _accent,
              onChanged: (v) async {
                setState(() => _closeToTray = v);
                await _saveLocal();
                await DesktopWindowController.instance.setCloseToTray(v);
              },
            ),
            _sliderTile('Escala de la UI', _uiScale, 0.8, 1.4, (v) {
              setState(() => _uiScale = v);
              _saveLocal();
              UiScaleService.instance.setScale(v);
            }, divisions: 12),
          ],
        ),

        _section('Repositorios'),
        _cardBox(
          children: [
            ListTile(
              title: const Text('Instalados', style: TextStyle(color: Colors.white)),
              subtitle: Text('${manager.installed.length} repositorio(s)', style: const TextStyle(color: Colors.white38)),
            ),
            ListTile(
              title: const Text('Limpiar caché de contenido', style: TextStyle(color: Colors.white)),
              subtitle: const Text('Fuerza recarga de home/discover', style: TextStyle(color: Colors.white38)),
              trailing: const Icon(Icons.cleaning_services_outlined, color: Colors.white54),
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Caché: usa pull-to-refresh en Home/Descubrir')),
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _modeChip(SettingsService settings, String label, HomeBgMode? mode, {VoidCallback? onTap, bool? selected}) {
    final sel = selected ?? (mode != null && settings.homeBgMode == mode);
    return ChoiceChip(
      label: Text(label),
      selected: sel,
      selectedColor: _accent,
      labelStyle: TextStyle(color: sel ? Colors.white : Colors.white70, fontSize: 12.5),
      backgroundColor: const Color(0xFF1A1F2A),
      onSelected: (_) async {
        if (onTap != null) {
          onTap();
        } else if (mode != null) {
          await settings.setHomeBgMode(mode);
        }
      },
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 10),
        child: Text(t, style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700, fontSize: 13)),
      );

  Widget _cardBox({required List<Widget> children}) => Container(
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _border),
        ),
        child: Column(children: children),
      );

  Widget _sliderTile(String title, double value, double min, double max, ValueChanged<double> onChanged, {int divisions = 20}) {
    return ListTile(
      title: Text(title, style: const TextStyle(color: Colors.white)),
      subtitle: Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        divisions: divisions,
        activeColor: _accent,
        label: value.toStringAsFixed(value >= 5 ? 0 : 2),
        onChanged: onChanged,
      ),
    );
  }
}