import 'package:flutter/material.dart';

const _accent = Color(0xFFE50914);

/// Lista horizontal con flechas laterales (ratón / trackpad a veces no arrastran bien).
class HScroller extends StatefulWidget {
  final double height;
  final int itemCount;
  final double itemExtent;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsets padding;
  final double spacing;

  const HScroller({
    super.key,
    required this.height,
    required this.itemCount,
    required this.itemBuilder,
    this.itemExtent = 140,
    this.padding = const EdgeInsets.symmetric(horizontal: 32),
    this.spacing = 12,
  });

  @override
  State<HScroller> createState() => _HScrollerState();
}

class _HScrollerState extends State<HScroller> {
  final _ctrl = ScrollController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _nudge(double dir) {
    if (!_ctrl.hasClients) return;
    final target = (_ctrl.offset + dir * (widget.itemExtent * 2.5))
        .clamp(0.0, _ctrl.position.maxScrollExtent);
    _ctrl.animateTo(target, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.itemCount <= 0) return SizedBox(height: widget.height);

    return SizedBox(
      height: widget.height,
      child: Stack(
        children: [
          ListView.separated(
            controller: _ctrl,
            scrollDirection: Axis.horizontal,
            padding: widget.padding,
            itemCount: widget.itemCount,
            separatorBuilder: (_, __) => SizedBox(width: widget.spacing),
            itemBuilder: widget.itemBuilder,
          ),
          // Flecha izquierda
          Positioned(
            left: 4,
            top: 0,
            bottom: 0,
            child: Center(
              child: _ArrowBtn(icon: Icons.chevron_left_rounded, onTap: () => _nudge(-1)),
            ),
          ),
          // Flecha derecha
          Positioned(
            right: 4,
            top: 0,
            bottom: 0,
            child: Center(
              child: _ArrowBtn(icon: Icons.chevron_right_rounded, onTap: () => _nudge(1)),
            ),
          ),
        ],
      ),
    );
  }
}

class _ArrowBtn extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _ArrowBtn({required this.icon, required this.onTap});

  @override
  State<_ArrowBtn> createState() => _ArrowBtnState();
}

class _ArrowBtnState extends State<_ArrowBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: Material(
        color: _h ? _accent.withValues(alpha: 0.9) : Colors.black.withValues(alpha: 0.55),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: widget.onTap,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Icon(widget.icon, color: Colors.white, size: 26),
          ),
        ),
      ),
    );
  }
}
