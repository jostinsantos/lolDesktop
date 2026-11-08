import 'dart:ui';
import 'package:flutter/material.dart';

/// Contenedor glassmorphism reutilizable para TV.
class Glass extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double blur;
  final Color? tint;
  final Border? border;
  final List<BoxShadow>? boxShadow;
  final double opacity;

  const Glass({
    super.key,
    required this.child,
    this.borderRadius = 16,
    this.padding,
    this.margin,
    this.blur = 18,
    this.tint,
    this.border,
    this.boxShadow,
    this.opacity = 0.12,
  });

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(borderRadius);
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: boxShadow ??
            [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
      ),
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              borderRadius: r,
              color: (tint ?? Colors.white).withValues(alpha: opacity),
              border: border ??
                  Border.all(
                    color: Colors.white.withValues(alpha: 0.14),
                    width: 1,
                  ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Fondo oscuro base de la app TV.
const kTvBg = Color(0xFF0B0E14);
const kTvSurface = Color(0xFF141A22);
const kTvAccent = Color(0xFFE50914);
const kTvCard = Color(0xFF1A222D);
