import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/sources.dart';
import '../../data/datasources/remote/sources/custom_api.dart';
import 'config_shared.dart'; // sectionTitle, SourceToggleCard, kConfigAccent, etc.

class FuentesTab extends StatefulWidget {
  final VoidCallback onRequestTabFocus;
  final FocusNode? firstFocusNode;

  const FuentesTab({
    super.key,
    required this.onRequestTabFocus,
    this.firstFocusNode,
  });

  @override
  State<FuentesTab> createState() => FuentesTabState();
}

class FuentesTabState extends State<FuentesTab>
    with AutomaticKeepAliveClientMixin {
  String _seleccionarServidores = 'auto';
  String _idiomaAudio = 'latino';
  String _subtituloPred = 'spa';
  bool _reutilizarUltimoEnlace = false;
  int _ttlHours = 12;

  final Map<String, bool> _sourceEnabled = {};
  final Map<String, bool> _sourceLoading = {};

  bool _customEnabled = false;
  List<String> _customSources = [];
  bool _customLoading = true;

  final TextEditingController _codigoCtrl = TextEditingController();

  // Dummy focus nodes (solo para cumplir con SourceToggleCard de TV)
  late final FocusNode _dummyFocus1;
  late final FocusNode _dummyFocus2;
  late final FocusNode _dummyFocus3;

  static const _ttlOptions = [1, 6, 12, 24, 48];
  static const _purple = Color(0xFF9C27B0);
  static const _cardBg = Color(0xFF1C1C1E);
  static const _cardBorder = Color(0x22FFFFFF);

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();

    _dummyFocus1 = FocusNode();
    _dummyFocus2 = FocusNode();
    _dummyFocus3 = FocusNode();

    for (final s in kRegisteredSources) {
      if (s.id == 'customapi') continue;
      _sourceEnabled[s.id] = true;
      _sourceLoading[s.id] = true;
    }

    _loadSettings();
    _loadCustomApis();
  }

  @override
  void dispose() {
    _codigoCtrl.dispose();
    _dummyFocus1.dispose();
    _dummyFocus2.dispose();
    _dummyFocus3.dispose();
    super.dispose();
  }

  // ─── Persistencia ──────────────────────────────────────────────────────

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    await prefs.setBool('verificar_servidores', true);
    await prefs.setBool('un_servidor_por_idioma', false);
    await prefs.setBool('mostrar_servidores_player', true);

    setState(() {
      _seleccionarServidores =
          prefs.getString('seleccionar_servidores') ?? 'auto';
      _idiomaAudio = prefs.getString('idioma_audio_predeterminado') ?? 'latino';

      final subRaw = prefs.getString('subtitulo_predeterminado') ?? 'spa';
      if (subRaw == 'es' ||
          subRaw == 'es_MX' ||
          subRaw == 'es_ES' ||
          subRaw == 'spa') {
        _subtituloPred = 'spa';
      } else {
        _subtituloPred = 'eng';
      }

      _reutilizarUltimoEnlace =
          prefs.getBool('reutilizar_ultimo_enlace') ?? false;
      _ttlHours = prefs.getInt('servidores_cache_ttl_hours') ?? 12;

      for (final s in kRegisteredSources) {
        if (s.id == 'customapi') continue;
        final v = prefs.getBool(s.prefsKey);
        _sourceEnabled[s.id] = v ?? true;
        _sourceLoading[s.id] = false;
        if (v == null) {
          prefs.setBool(s.prefsKey, true);
        }
      }
    });
  }

  Future<void> _loadCustomApis() async {
    try {
      final cfg = await CustomApiConfig.load();
      final en = await CustomApiConfig.isEnabled();
      if (!mounted) return;

      setState(() {
        _customSources = List.from(cfg.sources);
        _customEnabled = en;
        _customLoading = false;
      });
    } catch (e) {
      debugPrint('Error cargando Mis Fuentes: $e');
      if (mounted) setState(() => _customLoading = false);
    }
  }

  Future<void> _saveString(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  Future<void> _saveBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  Future<void> _saveInt(String key, int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(key, value);
  }

  Future<void> _setModo(String value) async {
    await _saveString('seleccionar_servidores', value);
    if (mounted) setState(() => _seleccionarServidores = value);
  }

  Future<void> _setIdiomaAudio(String value) async {
    await _saveString('idioma_audio_predeterminado', value);
    if (mounted) setState(() => _idiomaAudio = value);
  }

  Future<void> _setSubtitulo(String value) async {
    await _saveString('subtitulo_predeterminado', value);
    if (mounted) setState(() => _subtituloPred = value);
  }

  Future<void> _setReutilizar(bool value) async {
    await _saveBool('reutilizar_ultimo_enlace', value);
    if (mounted) setState(() => _reutilizarUltimoEnlace = value);
  }

  Future<void> _setTtl(int hours) async {
    await _saveInt('servidores_cache_ttl_hours', hours);
    if (mounted) setState(() => _ttlHours = hours);
  }

  Future<void> _setSourceEnabled(SourceDefinition source, bool value) async {
    await _saveBool(source.prefsKey, value);
    if (mounted) setState(() => _sourceEnabled[source.id] = value);
  }

  Future<void> _toggleCustom(bool v) async {
    await CustomApiConfig.setEnabled(v);
    if (mounted) setState(() => _customEnabled = v);
  }

  // ─── Diálogo Agregar Fuente ────────────────────────────────────────────

  Future<void> _openAddSourceDialog() async {
    _codigoCtrl.clear();

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: _cardBg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: _purple.withValues(alpha: 0.5), width: 1.5),
          ),
          title: const Text(
            'Agregar fuente',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 18,
            ),
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Código (ej. 44029) o URL completa',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _codigoCtrl,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                  cursorColor: _purple,
                  textInputAction: TextInputAction.done,
                  keyboardType: TextInputType.url,
                  onSubmitted: (_) => Navigator.of(ctx).pop(true),
                  decoration: InputDecoration(
                    hintText: 'Código o URL completa',
                    hintStyle: TextStyle(
                      color: Colors.white.withValues(alpha: 0.3),
                    ),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.07),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: _purple, width: 1.5),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(
                'Cancelar',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: _purple,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text(
                'Aceptar',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        );
      },
    );

    if (result == true && mounted) {
      await _acceptCustom();
    }
  }

  Future<void> _acceptCustom() async {
    final input = _codigoCtrl.text.trim();
    if (input.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Escribe un código o una URL'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    String? err;
    if (input.startsWith('http')) {
      err = await CustomApiConfig.addSource(fullUrl: input);
    } else {
      err = await CustomApiConfig.addSource(codigo: input);
    }

    if (!mounted) return;

    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err), behavior: SnackBarBehavior.floating),
      );
      return;
    }

    await _loadCustomApis();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Fuente añadida'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _removeCustom(String url) async {
    await CustomApiConfig.removeSource(url);
    await _loadCustomApis();
  }

  String _labelOf(String url) {
    final codigo = CustomApiConfig.extractCodigo(url);
    if (codigo.isNotEmpty) return codigo;
    if (url.contains('modlyo.com')) return 'Modlyo';
    return 'API';
  }

  List<SourceDefinition> get _normalSources =>
      kRegisteredSources.where((s) => s.id != 'customapi').toList();

  // ─── BUILD ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final sources = _normalSources;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(8, 4, 24, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── REPRODUCCIÓN ──────────────────────────────────────────────
          sectionTitle('REPRODUCCIÓN', first: true),
          const SizedBox(height: 6),
          _sectionCard(
            child: _choiceRow(
              children: [
                _chip(
                  selected: _seleccionarServidores == 'auto',
                  label: 'Automático',
                  icon: Icons.bolt_rounded,
                  onTap: () => _setModo('auto'),
                ),
                const SizedBox(width: 12),
                _chip(
                  selected: _seleccionarServidores == 'manual',
                  label: 'Manual',
                  icon: Icons.list_alt_rounded,
                  onTap: () => _setModo('manual'),
                ),
              ],
              hint: _seleccionarServidores == 'auto'
                  ? 'Resuelve el m3u8 y abre el player directo'
                  : 'Muestra la lista de servidores para elegir',
            ),
          ),

          const SizedBox(height: 28),

          // ── IDIOMA DE AUDIO ───────────────────────────────────────────
          sectionTitle('IDIOMA DE AUDIO'),
          const SizedBox(height: 6),
          _sectionCard(
            child: _choiceRow(
              children: [
                _chip(
                  selected: _idiomaAudio == 'latino',
                  label: 'Latino',
                  onTap: () => _setIdiomaAudio('latino'),
                ),
                const SizedBox(width: 12),
                _chip(
                  selected: _idiomaAudio == 'castellano',
                  label: 'Castellano',
                  onTap: () => _setIdiomaAudio('castellano'),
                ),
                const SizedBox(width: 12),
                _chip(
                  selected: _idiomaAudio == 'subtitulado',
                  label: 'Subtitulado',
                  onTap: () => _setIdiomaAudio('subtitulado'),
                ),
              ],
              hint: 'Prioridad al resolver el primer servidor válido',
            ),
          ),

          const SizedBox(height: 28),

          // ── SUBTÍTULO ─────────────────────────────────────────────────
          sectionTitle('SUBTÍTULO'),
          const SizedBox(height: 6),
          _sectionCard(
            child: _choiceRow(
              children: [
                _chip(
                  selected: _subtituloPred == 'spa',
                  label: 'SPA',
                  onTap: () => _setSubtitulo('spa'),
                ),
                const SizedBox(width: 12),
                _chip(
                  selected: _subtituloPred == 'eng',
                  label: 'ENG',
                  onTap: () => _setSubtitulo('eng'),
                ),
              ],
              hint: 'Idioma preferido al cargar subtítulos',
            ),
          ),

          const SizedBox(height: 28),

          // ── OPCIONES ──────────────────────────────────────────────────
          sectionTitle('OPCIONES'),
          const SizedBox(height: 6),
          SourceToggleCard(
            title: 'Reutilizar último enlace',
            subtitleEnabled: 'Usa el último m3u8 exitoso si sigue válido',
            subtitleDisabled: 'Siempre busca de nuevo',
            enabled: _reutilizarUltimoEnlace,
            loading: false,
            icon: Icons.history_rounded,
            accentColor: const Color(0xFFEC4899),
            focusNode: _dummyFocus1,
            onTap: () => _setReutilizar(!_reutilizarUltimoEnlace),
            onArrowUp: () {},
            onArrowDown: () {},
            onArrowLeft: () {},
          ),

          const SizedBox(height: 28),

          // ── TTL DE CACHÉ ──────────────────────────────────────────────
          sectionTitle('TTL DE CACHÉ'),
          const SizedBox(height: 6),
          _sectionCard(
            child: _choiceRow(
              children: _ttlOptions.map((h) {
                final label = h < 24 ? '${h}h' : '${h ~/ 24}d';
                return Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: _chip(
                    selected: _ttlHours == h,
                    label: label,
                    onTap: () => _setTtl(h),
                  ),
                );
              }).toList(),
              hint: 'Tras este tiempo se vuelven a buscar servidores',
            ),
          ),

          const SizedBox(height: 28),

          // ── MIS FUENTES ───────────────────────────────────────────────
          sectionTitle('MIS FUENTES'),
          const SizedBox(height: 6),
          if (_customLoading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            )
          else ...[
            SourceToggleCard(
              title: 'Mis Fuentes',
              subtitleEnabled: 'Activa – puedes agregar fuentes personalizadas',
              subtitleDisabled: 'Desactivada',
              enabled: _customEnabled,
              loading: false,
              icon: Icons.cloud_rounded,
              accentColor: _purple,
              focusNode: _dummyFocus2,
              onTap: () => _toggleCustom(!_customEnabled),
              onArrowUp: () {},
              onArrowDown: () {},
              onArrowLeft: () {},
            ),
            if (_customEnabled) ...[
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: _purple,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _openAddSourceDialog,
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: const Text(
                    'Agregar fuente',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
              if (_customSources.isNotEmpty) ...[
                const SizedBox(height: 14),
                ..._customSources.map((url) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
                      decoration: BoxDecoration(
                        color: _cardBg,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: _cardBorder),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.cloud_rounded,
                            color: Color(0xFF4CAF50),
                            size: 22,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _labelOf(url),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  url,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.45),
                                    fontSize: 12.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Eliminar',
                            onPressed: () => _removeCustom(url),
                            icon: Icon(
                              Icons.close_rounded,
                              color: Colors.white.withValues(alpha: 0.55),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ],
          ],

          const SizedBox(height: 28),

          // ── FUENTES DISPONIBLES ───────────────────────────────────────
          sectionTitle('FUENTES DISPONIBLES'),
          const SizedBox(height: 4),
          Text(
            _seleccionarServidores == 'auto'
                ? 'Modo automático: se usan las fuentes activas.'
                : 'Activa o desactiva cada fuente.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 13.5,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          ...sources.map((source) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SourceToggleCard(
                title: source.label,
                subtitleEnabled: '${source.label} activado',
                subtitleDisabled: '${source.label} desactivado',
                enabled: _sourceEnabled[source.id] ?? true,
                loading: _sourceLoading[source.id] ?? false,
                icon: source.icon,
                accentColor: source.badgeColor,
                focusNode: _dummyFocus3,
                onTap: () => _setSourceEnabled(
                  source,
                  !(_sourceEnabled[source.id] ?? true),
                ),
                onArrowUp: () {},
                onArrowDown: () {},
                onArrowLeft: () {},
              ),
            );
          }),
        ],
      ),
    );
  }

  // ─── Widgets auxiliares ────────────────────────────────────────────────

  Widget _sectionCard({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _cardBorder),
      ),
      child: child,
    );
  }

  Widget _choiceRow({
    required List<Widget> children,
    required String hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: children,
        ),
        const SizedBox(height: 10),
        Text(
          hint,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.42),
            fontSize: 12.5,
          ),
        ),
      ],
    );
  }

  Widget _chip({
    required bool selected,
    required String label,
    required VoidCallback onTap,
    IconData? icon,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        hoverColor: Colors.white.withValues(alpha: 0.06),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: selected
                ? kConfigAccent.withValues(alpha: 0.22)
                : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? kConfigAccent
                  : Colors.white.withValues(alpha: 0.10),
              width: selected ? 1.6 : 1.1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 18,
                  color: selected ? Colors.white : Colors.white70,
                ),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}