import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'focusable.dart';

/// Teclado QWERTY personalizado para Android TV.
class TvKeyboard extends StatefulWidget {
  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onSubmit;
  final VoidCallback? onClose;
  final String? hint;
  final bool autofocus;

  const TvKeyboard({
    super.key,
    required this.controller,
    this.onChanged,
    this.onSubmit,
    this.onClose,
    this.hint,
    this.autofocus = true,
  });

  /// Muestra el teclado como overlay centrado TV-friendly.
  static Future<String?> show(
    BuildContext context, {
    String initial = '',
    String? hint,
    String title = 'Escribir',
  }) async {
    final controller = TextEditingController(text: initial);
    final result = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Cerrar teclado',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (ctx, anim, sec) {
        return SafeArea(
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 920),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: _KeyboardPanel(
                    controller: controller,
                    hint: hint,
                    title: title,
                    onSubmit: () => Navigator.of(ctx).pop(controller.text),
                    onClose: () => Navigator.of(ctx).pop(null),
                  ),
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (ctx, anim, sec, child) {
        return FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.96, end: 1.0).animate(
              CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
            ),
            child: child,
          ),
        );
      },
    );
    controller.dispose();
    return result;
  }

  @override
  State<TvKeyboard> createState() => _TvKeyboardState();
}

class _TvKeyboardState extends State<TvKeyboard> {
  @override
  Widget build(BuildContext context) {
    return _KeyboardPanel(
      controller: widget.controller,
      hint: widget.hint,
      onSubmit: widget.onSubmit,
      onClose: widget.onClose,
      autofocus: widget.autofocus,
    );
  }
}

class _KeyboardPanel extends StatefulWidget {
  final TextEditingController controller;
  final String? hint;
  final String? title;
  final VoidCallback? onSubmit;
  final VoidCallback? onClose;
  final bool autofocus;

  const _KeyboardPanel({
    required this.controller,
    this.hint,
    this.title,
    this.onSubmit,
    this.onClose,
    this.autofocus = true,
  });

  @override
  State<_KeyboardPanel> createState() => _KeyboardPanelState();
}

class _KeyboardPanelState extends State<_KeyboardPanel> {
  bool _shift = false;
  bool _symbols = false;

  static const _rowsLower = [
    ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'],
    ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', 'ñ'],
    ['z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '?'],
  ];

  static const _rowsUpper = [
    ['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P'],
    ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', 'Ñ'],
    ['Z', 'X', 'C', 'V', 'B', 'N', 'M', '!', '?', '/'],
  ];

  static const _rowsSymbols = [
    ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
    ['@', '#', '\$', '%', '&', '*', '-', '+', '(', ')'],
    ['_', '=', '[', ']', '{', '}', '/', ':', '"', "'"],
  ];

  List<List<String>> get _rows {
    if (_symbols) return _rowsSymbols;
    return _shift ? _rowsUpper : _rowsLower;
  }

  void _insert(String char) {
    final c = widget.controller;
    final text = c.text;
    final sel = c.selection;
    final start = sel.start >= 0 ? sel.start : text.length;
    final end = sel.end >= 0 ? sel.end : text.length;
    final newText = text.replaceRange(start, end, char);
    // El controller notifica solo a sus listeners (el preview con ValueListenableBuilder).
    c.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + char.length),
    );
  }

  void _backspace() {
    final c = widget.controller;
    final text = c.text;
    final sel = c.selection;
    if (sel.start != sel.end && sel.start >= 0) {
      final newText = text.replaceRange(sel.start, sel.end, '');
      c.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: sel.start),
      );
    } else if (text.isNotEmpty) {
      final pos = sel.start > 0 ? sel.start : text.length;
      if (pos > 0) {
        final newText = text.replaceRange(pos - 1, pos, '');
        c.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: pos - 1),
        );
      }
    }
  }

  void _space() => _insert(' ');

  Widget _key(
    String label, {
    double flex = 1,
    VoidCallback? onTap,
    bool wide = false,
    bool primary = false,
    IconData? icon,
  }) {
    return Expanded(
      flex: (flex * 10).round(),
      child: Padding(
        padding: const EdgeInsets.all(3.5),
        child: Focusable(
          onTap: onTap ?? () => _insert(label),
          builder: (focused) {
            final Color bg;
            final Color fg;
            final Color border;
            if (primary) {
              bg = focused ? Colors.white : const Color(0xFFE50914);
              fg = focused ? Colors.black : Colors.white;
              border = focused ? Colors.white : Colors.transparent;
            } else {
              bg = focused
                  ? Colors.white.withValues(alpha: 0.26)
                  : Colors.white.withValues(alpha: 0.08);
              fg = focused
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.92);
              border = focused ? Colors.white : Colors.white12;
            }
            return AnimatedContainer(
              duration: const Duration(milliseconds: 90),
              height: 46,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: bg,
                border: Border.all(
                  color: border,
                  width: focused ? 2 : 1,
                ),
                boxShadow: focused
                    ? [
                        BoxShadow(
                          color: Colors.white.withValues(alpha: 0.3),
                          blurRadius: 12,
                        )
                      ]
                    : null,
              ),
              child: icon != null
                  ? Icon(icon, size: 20, color: fg)
                  : Text(
                      label,
                      style: TextStyle(
                        color: fg,
                        fontSize: wide ? 15 : 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: const Color(0xFF141A22).withValues(alpha: 0.82),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.55),
                blurRadius: 40,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: FocusScope(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      if (widget.title != null) ...[
                        Text(
                          widget.title!,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.8,
                          ),
                        ),
                        const SizedBox(width: 16),
                      ],
                      Expanded(
                        child: ValueListenableBuilder<TextEditingValue>(
                          valueListenable: widget.controller,
                          builder: (context, value, _) {
                            final text = value.text;
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.35),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.white12),
                              ),
                              child: Text(
                                text.isEmpty
                                    ? (widget.hint ?? 'Escribe aquí…')
                                    : text,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: text.isEmpty
                                      ? Colors.white38
                                      : Colors.white,
                                  fontSize: 16,
                                  letterSpacing: 0.3,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Focusable(
                        onTap: widget.onClose,
                        builder: (f) => Container(
                          width: 40,
                          height: 40,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: f
                                ? Colors.white.withValues(alpha: 0.24)
                                : Colors.white.withValues(alpha: 0.08),
                            border: Border.all(
                              color: f ? Colors.white : Colors.transparent,
                              width: 2,
                            ),
                          ),
                          child: Icon(Icons.close,
                              size: 20,
                              color: f ? Colors.white : Colors.white70),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  for (final row in _rows)
                    RepaintBoundary(
                      child: Row(
                        children: [
                          for (final k in row) _key(k),
                        ],
                      ),
                    ),
                  RepaintBoundary(
                    child: Row(
                      children: [
                        _key(
                          _symbols ? 'ABC' : (_shift ? 'abc' : 'ABC'),
                          flex: 1.3,
                          onTap: () {
                            setState(() {
                              if (_symbols) {
                                _symbols = false;
                              } else {
                                _shift = !_shift;
                              }
                            });
                          },
                        ),
                        _key(
                          _symbols ? '#+=' : '123',
                          flex: 1.2,
                          onTap: () => setState(() => _symbols = !_symbols),
                        ),
                        _key('espacio', flex: 3.2, onTap: _space, wide: true),
                        _key(
                          '',
                          flex: 1.2,
                          icon: Icons.backspace_outlined,
                          onTap: _backspace,
                        ),
                        _key(
                          'OK',
                          flex: 1.4,
                          primary: true,
                          onTap: widget.onSubmit,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Campo de texto TV (se mantiene por compatibilidad).
class TvTextField extends StatefulWidget {
  final TextEditingController? controller;
  final String? hint;
  final String? label;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final double height;
  final EdgeInsetsGeometry? padding;

  const TvTextField({
    super.key,
    this.controller,
    this.hint,
    this.label,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.height = 48,
    this.padding,
  });

  @override
  State<TvTextField> createState() => _TvTextFieldState();
}

class _TvTextFieldState extends State<TvTextField> {
  late final TextEditingController _controller;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? TextEditingController();
    _controller.addListener(_onText);
  }

  void _onText() {
    widget.onChanged?.call(_controller.text);
    setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onText);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  Future<void> _openKeyboard() async {
    final result = await TvKeyboard.show(
      context,
      initial: _controller.text,
      hint: widget.hint,
      title: widget.label ?? 'Buscar',
    );
    if (result != null && mounted) {
      _controller.text = result;
      widget.onSubmitted?.call(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focusable(
      autofocus: widget.autofocus,
      onTap: _openKeyboard,
      builder: (focused) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: widget.height,
          padding:
              widget.padding ?? const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: focused
                ? Colors.white.withValues(alpha: 0.14)
                : Colors.white.withValues(alpha: 0.07),
            border: Border.all(
              color: focused ? Colors.white : Colors.white24,
              width: focused ? 2 : 1,
            ),
            boxShadow: focused
                ? [
                    BoxShadow(
                      color: Colors.white.withValues(alpha: 0.15),
                      blurRadius: 16,
                    )
                  ]
                : null,
          ),
          child: Row(
            children: [
              Icon(Icons.search,
                  size: 20, color: focused ? Colors.white : Colors.white54),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _controller.text.isEmpty
                      ? (widget.hint ?? 'Buscar…')
                      : _controller.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _controller.text.isEmpty
                        ? Colors.white38
                        : Colors.white,
                    fontSize: 15,
                  ),
                ),
              ),
              if (_controller.text.isNotEmpty)
                GestureDetector(
                  onTap: () {
                    _controller.clear();
                    widget.onChanged?.call('');
                  },
                  child: const Icon(Icons.close,
                      size: 18, color: Colors.white54),
                ),
            ],
          ),
        );
      },
    );
  }
}