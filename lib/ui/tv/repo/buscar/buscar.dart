import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../data/models/repo_manifest.dart';
import '../../../../data/services/content_service.dart';
import '../../widgets/focusable.dart';
import '../main_home.dart';
import '../contenido/contenido.dart';

const _kAccent = Color(0xFFE50914);
const _kBg = Color(0xFF0B0E14);
const _kKey = Color(0xFF2A2A38);

/// Buscador TV: teclado a la izquierda + grid de resultados (estilo Nuvio).
class RepoSearchPage extends StatefulWidget {
  final InstalledRepo repo;
  const RepoSearchPage({super.key, required this.repo});

  @override
  State<RepoSearchPage> createState() => _RepoSearchPageState();
}

class _RepoSearchPageState extends State<RepoSearchPage> {
  String _query = '';
  bool _loading = false;
  bool _searched = false;
  List<ContentItem> _items = [];
  Timer? _debounce;
  int _searchId = 0;
  bool _showAccents = false;

  /// Historial de búsquedas (elementos buscados anteriormente).
  final List<String> _history = [];
  static const int _maxHistory = 12;

  final FocusNode _aKeyFocus = FocusNode();
  final FocusNode _firstResultFocus = FocusNode(debugLabel: 'firstResult');
  final FocusNode _searchButtonFocus = FocusNode(debugLabel: 'searchButton');

  @override
  void dispose() {
    _debounce?.cancel();
    _aKeyFocus.dispose();
    _firstResultFocus.dispose();
    _searchButtonFocus.dispose();
    super.dispose();
  }

  void _goMenu() => RepoNavScope.of(context)?.requestMenuFocus();

  void _setQuery(String value) {
    _query = value;
    setState(() {});
    // Ya no se busca automáticamente: solo se actualiza el texto.
  }

  void _onKey(String char) => _setQuery(_query + char);

  void _onBackspace() {
    if (_query.isEmpty) return;
    _setQuery(_query.substring(0, _query.length - 1));
  }

  void _onClear() {
    _debounce?.cancel();
    setState(() {
      _query = '';
      _items = [];
      _searched = false;
      _loading = false;
    });
  }

  /// Se ejecuta SOLO cuando el usuario pulsa el botón Buscar.
  void _onSearchPressed() {
    final q = _query.trim();
    if (q.isEmpty || q.length < 2) return;

    // Guardar en historial (sin duplicados, más reciente primero).
    _history.remove(q);
    _history.insert(0, q);
    if (_history.length > _maxHistory) _history.removeLast();

    _debounce?.cancel();
    _doSearch();
  }

  Future<void> _doSearch() async {
    final q = _query.trim();
    if (q.isEmpty) return;
    final id = ++_searchId;
    setState(() {
      _loading = true;
      _searched = true;
    });
    try {
      final list = await ContentService.instance.search(widget.repo, q);
      if (id != _searchId || !mounted) return;
      setState(() {
        _items = list;
        _loading = false;
      });
    } catch (_) {
      if (id != _searchId || !mounted) return;
      setState(() {
        _items = [];
        _loading = false;
      });
    }
  }

  void _open(ContentItem item) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DetailsPage(repo: widget.repo, itemId: item.id),
    ));
  }

  /// Al pulsar un elemento del historial: se rellena la query y se busca.
  void _onHistoryTap(String q) {
    setState(() {
      _query = q;
      _items = [];
      _searched = false;
      _loading = false;
    });
    _onSearchPressed();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Teclado izquierdo ──
              SizedBox(
                width: 260,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Campo query (solo display)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.search, color: Colors.white54, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _query.isEmpty ? 'Buscar...' : _query,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: _query.isEmpty ? Colors.white38 : Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: SingleChildScrollView(
                          physics: const ClampingScrollPhysics(),
                          child: _Keyboard(
                            showAccents: _showAccents,
                            onKey: _onKey,
                            onBackspace: _onBackspace,
                            onClear: _onClear,
                            onToggleAccents: () =>
                                setState(() => _showAccents = !_showAccents),
                            onSearch: _onSearchPressed,
                            searchEnabled: _query.trim().length >= 2,
                            aKeyFocusNode: _aKeyFocus,
                            searchButtonFocusNode: _searchButtonFocus,
                            onRequestMenuFocus: _goMenu,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ── Resultados / Historial ──
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 12, 16, 12),
                  child: _buildResults(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResults() {
    // Mientras no se haya buscado nada: mostrar historial.
    if (!_searched) {
      return _buildHistory();
    }
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          'Sin resultados para "$_query"',
          style: const TextStyle(color: Colors.white54, fontSize: 14),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Resultados',
          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 2),
        Text(
          '${_items.length} título${_items.length == 1 ? '' : 's'}',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 11),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: GridView.builder(
            itemCount: _items.length,
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 120,
              mainAxisSpacing: 12,
              crossAxisSpacing: 10,
              childAspectRatio: 0.62,
            ),
            itemBuilder: (context, i) {
              final item = _items[i];
              return Focusable(
                autofocus: i == 0,
                focusNode: i == 0 ? _firstResultFocus : null,
                onTap: () => _open(item),
                builder: (f) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: item.poster != null
                            ? Stack(
                                fit: StackFit.expand,
                                children: [
                                  CachedNetworkImage(
                                    imageUrl: item.poster!,
                                    fit: BoxFit.cover,
                                    width: double.infinity,
                                    memCacheWidth: 240,
                                    placeholder: (_, __) =>
                                        Container(color: const Color(0xFF1c1c1c)),
                                    errorWidget: (_, __, ___) => Container(
                                      color: const Color(0xFF1c1c1c),
                                      child: const Icon(Icons.movie, color: Colors.white24),
                                    ),
                                  ),
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
                            : Container(color: const Color(0xFF1c1c1c)),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: f ? Colors.white : Colors.white70,
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
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

  /// Panel de historial mostrado cuando aún no hay búsqueda.
  Widget _buildHistory() {
    if (_history.isEmpty) {
      return const Center(
        child: Text(
          'Escribe y pulsa Buscar para encontrar películas y series',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white38, fontSize: 14),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Búsquedas recientes',
          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 2),
        Text(
          '${_history.length} búsqueda${_history.length == 1 ? '' : 's'}',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 11),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: ListView.separated(
            itemCount: _history.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final q = _history[i];
              return Focusable(
                onTap: () => _onHistoryTap(q),
                builder: (f) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: f
                        ? Colors.white.withValues(alpha: 0.12)
                        : Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: f ? Colors.white : Colors.transparent,
                      width: 1.2,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.history,
                        size: 18,
                        color: f ? Colors.white : Colors.white54,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          q,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: f ? Colors.white : Colors.white70,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.search,
                        size: 16,
                        color: f ? Colors.white : Colors.white38,
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
}

// ── Teclado on-screen ──────────────────────────────────────────────────────

class _Keyboard extends StatelessWidget {
  final bool showAccents;
  final ValueChanged<String> onKey;
  final VoidCallback onBackspace;
  final VoidCallback onClear;
  final VoidCallback onToggleAccents;
  final VoidCallback onSearch;
  final bool searchEnabled;
  final FocusNode aKeyFocusNode;
  final FocusNode searchButtonFocusNode;
  final VoidCallback? onRequestMenuFocus;

  const _Keyboard({
    required this.showAccents,
    required this.onKey,
    required this.onBackspace,
    required this.onClear,
    required this.onToggleAccents,
    required this.onSearch,
    required this.searchEnabled,
    required this.aKeyFocusNode,
    required this.searchButtonFocusNode,
    this.onRequestMenuFocus,
  });

  static const _rowsNormal = [
    ['a', 'b', 'c', 'd', 'e'],
    ['f', 'g', 'h', 'i', 'j'],
    ['k', 'l', 'm', 'n', 'o'],
    ['p', 'q', 'r', 's', 't'],
    ['u', 'v', 'w', 'x', 'y'],
  ];

  static const _rowsAccents = [
    ['á', 'é', 'í', 'ó', 'ú'],
    ['ü', 'ñ', 'Á', 'É', 'Í'],
    ['Ó', 'Ú', 'Ü', '¿', '¡'],
    ['1', '2', '3', '4', '5'],
    ['6', '7', '8', '9', '0'],
  ];

  static const _leftEdgeNormal = {'a', 'f', 'k', 'p', 'u', 'z'};
  static const _leftEdgeAccents = {'á', 'ü', 'Ó', '1', '6'};

  @override
  Widget build(BuildContext context) {
    final rows = showAccents ? _rowsAccents : _rowsNormal;
    final leftEdge = showAccents ? _leftEdgeAccents : _leftEdgeNormal;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                for (final char in row) ...[
                  _KeyBtn(
                    label: char,
                    onTap: () => onKey(char),
                    focusNode: (!showAccents && char == 'a') ? aKeyFocusNode : null,
                    allowLeftEscape: leftEdge.contains(char),
                    onRequestMenuFocus: onRequestMenuFocus,
                  ),
                  const SizedBox(width: 6),
                ],
              ],
            ),
          ),
        if (!showAccents)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                _KeyBtn(
                  label: 'z',
                  onTap: () => onKey('z'),
                  allowLeftEscape: true,
                  onRequestMenuFocus: onRequestMenuFocus,
                ),
                const SizedBox(width: 6),
                _KeyBtn(label: 'ñ', onTap: () => onKey('ñ')),
                const SizedBox(width: 6),
                _KeyBtn(
                  label: ' ',
                  icon: Icons.space_bar,
                  onTap: () => onKey(' '),
                  flex: 2,
                ),
                const SizedBox(width: 6),
                _KeyBtn(icon: Icons.backspace_outlined, onTap: onBackspace),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                _KeyBtn(
                  label: ' ',
                  icon: Icons.space_bar,
                  onTap: () => onKey(' '),
                  flex: 2,
                  allowLeftEscape: true,
                  onRequestMenuFocus: onRequestMenuFocus,
                ),
                const SizedBox(width: 6),
                _KeyBtn(icon: Icons.backspace_outlined, onTap: onBackspace),
                const SizedBox(width: 6),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        // Fila: X (limpiar) + toggle acentos
        Row(
          children: [
            _KeyBtn(
              icon: Icons.close,
              onTap: onClear,
              allowLeftEscape: true,
              onRequestMenuFocus: onRequestMenuFocus,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _AccentToggle(isActive: showAccents, onTap: onToggleAccents),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Botón Buscar (solo ejecuta la búsqueda al pulsarlo)
        _SearchButton(
          enabled: searchEnabled,
          onTap: onSearch,
          focusNode: searchButtonFocusNode,
        ),
      ],
    );
  }
}

class _KeyBtn extends StatefulWidget {
  final String? label;
  final IconData? icon;
  final VoidCallback onTap;
  final int flex;
  final FocusNode? focusNode;
  final bool allowLeftEscape;
  final VoidCallback? onRequestMenuFocus;

  const _KeyBtn({
    this.label,
    this.icon,
    required this.onTap,
    this.flex = 1,
    this.focusNode,
    this.allowLeftEscape = false,
    this.onRequestMenuFocus,
  });

  @override
  State<_KeyBtn> createState() => _KeyBtnState();
}

class _KeyBtnState extends State<_KeyBtn> {
  bool _hasFocus = false;

  @override
  Widget build(BuildContext context) {
    final btn = Focus(
      focusNode: widget.focusNode,
      autofocus: widget.focusNode != null,
      onFocusChange: (f) => setState(() => _hasFocus = f),
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
            widget.allowLeftEscape) {
          widget.onRequestMenuFocus?.call();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 38,
          decoration: BoxDecoration(
            color: _hasFocus ? Colors.white : _kKey,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _hasFocus ? Colors.white : Colors.transparent,
              width: 1.5,
            ),
          ),
          alignment: Alignment.center,
          child: widget.icon != null
              ? Icon(widget.icon, size: 18, color: _hasFocus ? Colors.black : Colors.white70)
              : Text(
                  widget.label ?? '',
                  style: TextStyle(
                    color: _hasFocus ? Colors.black : Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
        ),
      ),
    );
    return Expanded(flex: widget.flex, child: btn);
  }
}

class _AccentToggle extends StatefulWidget {
  final bool isActive;
  final VoidCallback onTap;
  const _AccentToggle({required this.isActive, required this.onTap});

  @override
  State<_AccentToggle> createState() => _AccentToggleState();
}

class _AccentToggleState extends State<_AccentToggle> {
  bool _hasFocus = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _hasFocus = f),
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 38,
          decoration: BoxDecoration(
            color: widget.isActive
                ? (_hasFocus ? _kAccent : _kAccent.withValues(alpha: 0.9))
                : (_hasFocus ? Colors.white : _kKey),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _hasFocus ? Colors.white : Colors.transparent,
              width: 1.5,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            widget.isActive ? 'ABC' : 'ÁÉÍ',
            style: TextStyle(
              color: widget.isActive
                  ? Colors.white
                  : (_hasFocus ? Colors.black : Colors.white),
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

/// Botón Buscar: única vía para disparar la búsqueda.
class _SearchButton extends StatefulWidget {
  final bool enabled;
  final VoidCallback onTap;
  final FocusNode focusNode;

  const _SearchButton({
    required this.enabled,
    required this.onTap,
    required this.focusNode,
  });

  @override
  State<_SearchButton> createState() => _SearchButtonState();
}

class _SearchButtonState extends State<_SearchButton> {
  bool _hasFocus = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      onFocusChange: (f) => setState(() => _hasFocus = f),
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter) {
          if (widget.enabled) widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 42,
          decoration: BoxDecoration(
            color: widget.enabled
                ? (_hasFocus ? _kAccent : _kAccent.withValues(alpha: 0.85))
                : _kKey.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _hasFocus && widget.enabled ? Colors.white : Colors.transparent,
              width: 1.5,
            ),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.search,
                size: 18,
                color: widget.enabled ? Colors.white : Colors.white38,
              ),
              const SizedBox(width: 8),
              Text(
                'Buscar',
                style: TextStyle(
                  color: widget.enabled ? Colors.white : Colors.white38,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}