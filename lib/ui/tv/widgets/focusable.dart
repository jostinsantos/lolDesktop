import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Focusable TV — solo borde sutil, SIN escala (evita recortes).
/// Auto-scroll al enfocar.
class Focusable extends StatefulWidget {
  final Widget Function(bool focused) builder;
  final VoidCallback? onTap;
  final FocusNode? focusNode;
  final bool autofocus;
  final Duration scrollDuration;
  final Curve scrollCurve;
  /// Callback cuando se presiona izquierda y este es el primer elemento
  /// (para volver al menú lateral).
  final VoidCallback? onLeftEdge;
  final bool isFirstInRow;

  const Focusable({
    super.key,
    required this.builder,
    this.onTap,
    this.focusNode,
    this.autofocus = false,
    this.scrollDuration = const Duration(milliseconds: 220),
    this.scrollCurve = Curves.easeOutCubic,
    this.onLeftEdge,
    this.isFirstInRow = false,
  });

  @override
  State<Focusable> createState() => _FocusableState();
}

class _FocusableState extends State<Focusable> {
  late final FocusNode _node;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _node = widget.focusNode ?? FocusNode(debugLabel: 'Focusable');
    _node.addListener(_onFocus);
  }

  void _onFocus() {
    final has = _node.hasFocus;
    if (_focused != has) {
      setState(() => _focused = has);
      if (has) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_node.hasFocus) return;
          Scrollable.ensureVisible(
            context,
            alignment: 0.4,
            duration: widget.scrollDuration,
            curve: widget.scrollCurve,
          );
        });
      }
    }
  }

  @override
  void dispose() {
    _node.removeListener(_onFocus);
    if (widget.focusNode == null) _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      autofocus: widget.autofocus,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;

        // Izquierda en el primer elemento → menú
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
            widget.isFirstInRow &&
            widget.onLeftEdge != null) {
          widget.onLeftEdge!();
          return KeyEventResult.handled;
        }

        if (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.space ||
            event.logicalKey == LogicalKeyboardKey.gameButtonA) {
          widget.onTap?.call();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: () {
          _node.requestFocus();
          widget.onTap?.call();
        },
        // SIN AnimatedScale — solo borde
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _focused
                  ? Colors.white.withValues(alpha: 0.9)
                  : Colors.transparent,
              width: _focused ? 2 : 0,
            ),
          ),
          child: widget.builder(_focused),
        ),
      ),
    );
  }
}
