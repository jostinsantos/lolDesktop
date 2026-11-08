import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../../data/models/repo_manifest.dart';
import '../../../../data/services/repo_manager.dart';
import '../../../../data/services/repo_prefs.dart';
import '../../../../data/services/content_cache.dart';
import '../../../../data/services/js_runtime.dart';
import '../../../../data/services/settings_service.dart';
import '../../widgets/focusable.dart';
import '../main_home.dart';
import '../../widgets/tv_keyboard.dart';

class RepoSettingsPage extends StatefulWidget {
  final InstalledRepo repo;
  const RepoSettingsPage({super.key, required this.repo});
  @override
  State<RepoSettingsPage> createState() => _RepoSettingsPageState();
}

class _RepoSettingsPageState extends State<RepoSettingsPage> {
  late Map<String, TextEditingController> _controllers;
  late Map<String, String> _selectValues;
  late Map<String, Set<String>> _multiValues;
  late Map<String, bool> _boolValues;
  RepoManifest? _remoteUpdate;
  bool _checkingUpdate = false;
  bool _updating = false;

  static const _colorPresets = <String>[
    '#E50914', '#FF5722', '#FF9800', '#FFC107', '#4CAF50',
    '#009688', '#00BCD4', '#2196F3', '#3F51B5', '#9C27B0',
    '#E91E63', '#FFFFFF', '#B0BEC5', '#607D8B', '#212121',
  ];

  @override
  void initState() {
    super.initState();
    _controllers = {};
    _selectValues = {};
    _multiValues = {};
    _boolValues = {};
    for (final f in widget.repo.manifest.configFields) {
      final saved = widget.repo.userConfig[f.key] ?? f.defaultValue ?? '';
      if (f.isMulti) {
        _multiValues[f.key] = RepoConfigField.parseMulti(saved);
      } else if (f.isBool) {
        final v = saved.toLowerCase();
        _boolValues[f.key] = v == '1' || v == 'true' || v == 'yes' || v == 'on';
      } else if (f.isSelect || f.isColor) {
        _selectValues[f.key] = saved;
        if (f.isColor) {
          _controllers[f.key] = TextEditingController(text: saved);
        }
      } else {
        _controllers[f.key] = TextEditingController(text: saved);
      }
    }
    _checkUpdate();
  }

  Future<void> _checkUpdate() async {
    setState(() => _checkingUpdate = true);
    try {
      final remote =
          await context.read<RepoManager>().checkForUpdate(widget.repo);
      if (mounted) setState(() => _remoteUpdate = remote);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }


  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Aplica config al JS, limpia solo caché de contenido del repo y cierra.
  /// NO borra favoritos ni historial.
  Future<void> _applyConfigAndRestart(String message) async {
    final id = widget.repo.manifest.id;
    final mgr = context.read<RepoManager>();
    final repo = mgr.getById(id) ?? widget.repo;

    // 1) Inyectar config nueva en el runtime JS
    try {
      final code = repo.jsCode;
      if (code != null && code.trim().isNotEmpty) {
        await JsAddonRuntime.instance.loadAddonCode(id, code);
        await JsAddonRuntime.instance.setConfig(id, repo.userConfig);
      }
    } catch (e) {
      debugPrint('[RepoSettings] setConfig: $e');
    }

    // 2) Invalidar caché de contenido del repo (home, meta, search, streams…)
    //    Favoritos e historial se conservan.
    try {
      await ContentCache.instance.clearRepo(id);
    } catch (e) {
      debugPrint('[RepoSettings] clearCache: $e');
    }

    // 3) Notificar para que UIs se refresquen
    try {
      mgr.notifyListeners();
    } catch (_) {}

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );

    // Cerrar config + repo: al reabrir carga con la nueva config
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _restartAndCloseRepo(String message) async {
    await _applyConfigAndRestart(message);
  }

  Future<void> _doUpdate() async {
    setState(() => _updating = true);
    try {
      await context.read<RepoManager>().updateRepo(widget.repo);
      if (!mounted) return;
      setState(() {
        _remoteUpdate = null;
        _updating = false;
      });
      await _applyConfigAndRestart(
        'Plugin actualizado. Vuelve a abrir el repo para aplicarlo.',
      );
    } catch (e) {
      if (mounted) {
        setState(() => _updating = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al actualizar: $e')),
        );
      }
    }
  }

  Future<void> _save() async {
    final map = <String, String>{};
    _controllers.forEach((k, c) => map[k] = c.text);
    _selectValues.forEach((k, v) => map[k] = v);
    _multiValues.forEach((k, v) => map[k] = RepoConfigField.encodeMulti(v));
    _boolValues.forEach((k, v) => map[k] = v ? 'true' : 'false');
    for (final f in widget.repo.manifest.configFields) {
      if (f.isColor) {
        final fromText = _controllers[f.key]?.text.trim();
        final fromSelect = _selectValues[f.key];
        if (fromText != null && fromText.isNotEmpty) {
          map[f.key] = fromText.startsWith('#') ? fromText : '#$fromText';
        } else if (fromSelect != null && fromSelect.isNotEmpty) {
          map[f.key] = fromSelect;
        }
      }
    }

    final id = widget.repo.manifest.id;
    await context.read<RepoManager>().saveUserConfig(id, map);

    final lang = map['preferred_language'] ?? map['idioma'] ?? '';
    if (lang.isNotEmpty) {
      await context.read<RepoPrefs>().setPreferredLanguage(id, lang);
    }

    if (!mounted) return;
    await _applyConfigAndRestart(
      'Configuración aplicada. El repo se recargará con la nueva config.',
    );
  }


  Color _parseColor(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const Color(0xFFE50914);
    var s = raw.trim();
    if (s.startsWith('#')) s = s.substring(1);
    if (s.length == 3) s = s.split('').map((c) => '$c$c').join();
    if (s.length == 6) s = 'FF$s';
    if (s.length != 8) return const Color(0xFFE50914);
    try {
      return Color(int.parse(s, radix: 16));
    } catch (_) {
      return const Color(0xFFE50914);
    }
  }

  Widget _buildField(RepoConfigField f) {
    if (f.isMulti) return _buildMulti(f);
    if (f.isBool) return _buildBool(f);
    if (f.isColor) return _buildColor(f);
    if (f.isSelect) return _buildSelect(f);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TvTextField(
        controller: _controllers[f.key],
        label: f.label,
        hint: f.placeholder ?? f.label,
      ),
    );
  }

  Widget _buildSelect(RepoConfigField f) {
    final val = _selectValues[f.key]?.isNotEmpty == true
        ? _selectValues[f.key]!
        : (f.defaultValue ?? 'Elegir…');
    String display = val;
    for (var i = 0; i < f.options.length; i++) {
      if (f.valueAt(i) == val) {
        display = f.labelAt(i);
        break;
      }
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Focusable(
        isFirstInRow: true,
        onLeftEdge: () => RepoNavScope.of(context)?.requestMenuFocus(),
        onTap: () => _pickSelect(f),
        builder: (focused) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF1A222D),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: focused ? Colors.white : Colors.transparent,
              width: 2,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(f.label,
                        style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    const SizedBox(height: 4),
                    Text(display,
                        style: const TextStyle(color: Colors.white, fontSize: 15)),
                    if (f.description != null)
                      Text(f.description!,
                          style: const TextStyle(color: Colors.white30, fontSize: 11)),
                  ],
                ),
              ),
              const Icon(Icons.keyboard_arrow_down, color: Colors.white54),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMulti(RepoConfigField f) {
    final selected = _multiValues[f.key] ?? {};
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1A222D),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(f.label,
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
            if (f.description != null) ...[
              const SizedBox(height: 4),
              Text(f.description!,
                  style: const TextStyle(color: Colors.white30, fontSize: 11)),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (var i = 0; i < f.options.length; i++)
                  Focusable(
                    onTap: () {
                      setState(() {
                        final set = {...(_multiValues[f.key] ?? <String>{})};
                        final v = f.valueAt(i);
                        if (set.contains(v)) {
                          set.remove(v);
                        } else {
                          set.add(v);
                        }
                        _multiValues[f.key] = set;
                      });
                    },
                    builder: (focused) {
                      final on = selected.contains(f.valueAt(i));
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: on
                              ? const Color(0xFFE50914).withValues(alpha: 0.3)
                              : Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: focused
                                ? Colors.white
                                : (on ? const Color(0xFFE50914) : Colors.transparent),
                            width: 2,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              on ? Icons.check_box : Icons.check_box_outline_blank,
                              size: 18,
                              color: on ? Colors.white : Colors.white54,
                            ),
                            const SizedBox(width: 8),
                            Text(f.labelAt(i),
                                style: TextStyle(
                                  color: on ? Colors.white : Colors.white70,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                )),
                          ],
                        ),
                      );
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBool(RepoConfigField f) {
    final on = _boolValues[f.key] ?? false;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Focusable(
        isFirstInRow: true,
        onLeftEdge: () => RepoNavScope.of(context)?.requestMenuFocus(),
        onTap: () => setState(() => _boolValues[f.key] = !on),
        builder: (focused) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF1A222D),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: focused ? Colors.white : Colors.transparent,
              width: 2,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(f.label,
                        style: const TextStyle(color: Colors.white, fontSize: 14)),
                    if (f.description != null)
                      Text(f.description!,
                          style: const TextStyle(color: Colors.white30, fontSize: 11)),
                  ],
                ),
              ),
              Icon(
                on ? Icons.toggle_on : Icons.toggle_off,
                size: 36,
                color: on ? const Color(0xFFE50914) : Colors.white38,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildColor(RepoConfigField f) {
    final current = _selectValues[f.key] ??
        _controllers[f.key]?.text ??
        f.defaultValue ??
        '#E50914';
    final presets = [
      ..._colorPresets,
      if (f.options.isNotEmpty) ...f.options,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: const Color(0xFF1A222D),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: _parseColor(current),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white38),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(f.label,
                          style: const TextStyle(color: Colors.white54, fontSize: 12)),
                      Text(current,
                          style: const TextStyle(color: Colors.white, fontSize: 14)),
                    ],
                  ),
                ),
              ],
            ),
            if (f.description != null) ...[
              const SizedBox(height: 4),
              Text(f.description!,
                  style: const TextStyle(color: Colors.white30, fontSize: 11)),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final hex in presets)
                  Focusable(
                    onTap: () {
                      final h = hex.startsWith('#') ? hex : '#$hex';
                      setState(() {
                        _selectValues[f.key] = h;
                        _controllers[f.key]?.text = h;
                      });
                    },
                    builder: (focused) {
                      final h = hex.startsWith('#') ? hex : '#$hex';
                      final sel = current.toUpperCase() == h.toUpperCase();
                      return Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: _parseColor(hex),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: focused || sel ? Colors.white : Colors.white24,
                            width: focused || sel ? 2.5 : 1,
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TvTextField(
              controller: _controllers.putIfAbsent(
                  f.key, () => TextEditingController(text: current)),
              label: 'Hex (#RRGGBB)',
              hint: '#E50914',
            ),
          ],
        ),
      ),
    );
  }

  void _pickSelect(RepoConfigField f) {
    final current = _selectValues[f.key] ?? f.defaultValue ?? '';
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(f.label,
                    style: const TextStyle(
                        color: Colors.white70, fontWeight: FontWeight.w600)),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (var i = 0; i < f.options.length; i++)
                      ListTile(
                        title: Text(f.labelAt(i),
                            style: const TextStyle(color: Colors.white)),
                        trailing: f.valueAt(i) == current
                            ? const Icon(Icons.check, color: Color(0xFFE50914))
                            : null,
                        onTap: () {
                          setState(() => _selectValues[f.key] = f.valueAt(i));
                          Navigator.pop(ctx);
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final prefs = context.watch<RepoPrefs>();
    final id = widget.repo.manifest.id;
    final fields = widget.repo.manifest.configFields;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(widget.repo.manifest.name,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold)),
        Text(widget.repo.manifest.repo,
            style: const TextStyle(color: Colors.white38, fontSize: 12)),
        const SizedBox(height: 4),
        Text('Versión ${widget.repo.manifest.version}',
            style: const TextStyle(color: Colors.white38, fontSize: 12)),
        const SizedBox(height: 12),
        if (_checkingUpdate)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Row(children: [
              SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 10),
              Text('Comprobando actualizaciones…',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
            ]),
          )
        else if (_remoteUpdate != null)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1A222D),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: const Color(0xFFE50914).withOpacity(0.5)),
            ),
            child: Row(
              children: [
                const Icon(Icons.system_update,
                    color: Color(0xFFE50914), size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Actualización disponible',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600)),
                      Text('Nueva versión: ${_remoteUpdate!.version}',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12)),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: _updating ? null : _doUpdate,
                  child: _updating
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Actualizar'),
                ),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                const Icon(Icons.check_circle_outline,
                    color: Colors.white38, size: 16),
                const SizedBox(width: 6),
                const Text('Plugin al día',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
                const Spacer(),
                TextButton(
                  onPressed: _checkUpdate,
                  child:
                      const Text('Comprobar', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
        Builder(builder: (ctx) {
          final ad = prefs.lastAd(id);
          if (ad == null) return const SizedBox.shrink();
          final title = ad['title'] ?? '';
          final message = ad['message'] ?? '';
          if (title.isEmpty && message.isEmpty) return const SizedBox.shrink();
          return Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF1A222D),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Aviso del repositorio',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 6),
                if (title.isNotEmpty)
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600)),
                if (message.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(message,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 13, height: 1.3)),
                ],
              ],
            ),
          );
        }),
        const Text(
          'Opciones definidas por el creador del repositorio (lol.json → config).',
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
        const SizedBox(height: 24),
        if (fields.isEmpty)
          const Text('Este repo no define campos en config.',
              style: TextStyle(color: Colors.white38))
        else
          ...fields.map((f) => _buildField(f)),
        const SizedBox(height: 8),
        Focusable(
          isFirstInRow: true,
          onLeftEdge: () => RepoNavScope.of(context)?.requestMenuFocus(),
          onTap: _save,
          builder: (f) => Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFE50914),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: f ? Colors.white : Colors.transparent, width: 2),
            ),
            child: const Text('Guardar',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ),
        const SizedBox(height: 32),
        const Divider(color: Colors.white12),
        const SizedBox(height: 12),
        const Text('Interfaz (app)',
            style: TextStyle(color: Colors.white38, fontSize: 12)),
        const SizedBox(height: 10),
        if (settings.isTv) ...[
          const Text('Menú TV',
              style: TextStyle(color: Colors.white54, fontSize: 13)),
          const SizedBox(height: 8),
          Row(children: [
            _sysChip('Superior', prefs.menuMode(id) == TvMenuMode.superior,
                () => prefs.setMenuMode(id, TvMenuMode.superior)),
            const SizedBox(width: 8),
            _sysChip('Lateral', prefs.menuMode(id) == TvMenuMode.lateral,
                () => prefs.setMenuMode(id, TvMenuMode.lateral)),
          ]),
          const SizedBox(height: 12),
        ],
        const Text('Tamaño de póster',
            style: TextStyle(color: Colors.white54, fontSize: 13)),
        const SizedBox(height: 8),
        Row(children: [
          _sysChip('S', prefs.posterSize(id) == PosterSize.small,
              () => prefs.setPosterSize(id, PosterSize.small)),
          const SizedBox(width: 8),
          _sysChip('M', prefs.posterSize(id) == PosterSize.medium,
              () => prefs.setPosterSize(id, PosterSize.medium)),
          const SizedBox(width: 8),
          _sysChip('L', prefs.posterSize(id) == PosterSize.large,
              () => prefs.setPosterSize(id, PosterSize.large)),
        ]),
      ],
    );
  }

  Widget _sysChip(String label, bool selected, VoidCallback onTap) {
    return Focusable(
      isFirstInRow: true,
      onLeftEdge: () => RepoNavScope.of(context)?.requestMenuFocus(),
      onTap: onTap,
      builder: (focused) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? Colors.white12 : const Color(0xFF1A222D),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: focused ? Colors.white38 : Colors.transparent, width: 2),
        ),
        child:
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
      ),
    );
  }
}