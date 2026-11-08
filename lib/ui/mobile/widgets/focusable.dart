import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Widget con foco para navegación TV (D-pad / mando).
/// En móvil se comporta como un InkWell normal.
class Focusable extends StatefulWidget {
  final Widget Function(bool focused) builder;
  final VoidCallback? onTap;
  final FocusNode? focusNode;
  final bool autofocus;

  const Focusable({
    super.key,
    required this.builder,
    this.onTap,
    this.focusNode,
    this.autofocus = false,
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
    _node = widget.focusNode ?? FocusNode();
    _node.addListener(_onFocus);
  }

  void _onFocus() {
    if (_focused != _node.hasFocus) {
      setState(() => _focused = _node.hasFocus);
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
        onTap: () {
          _node.requestFocus();
          widget.onTap?.call();
        },
        child: widget.builder(_focused),
      ),
    );
  }
}
