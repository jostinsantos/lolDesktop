import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

/// Imagen optimizada: memCache + placeholder skeleton + sheen superior (~22%).
class CachedPoster extends StatelessWidget {
  final String? url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final int? memCacheWidth;
  final int? memCacheHeight;
  final BorderRadius? borderRadius;
  /// Intensidad del sheen (0 = off).
  final double sheenStrength;

  const CachedPoster({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.memCacheWidth,
    this.memCacheHeight,
    this.borderRadius,
    this.sheenStrength = 0.22,
  });

  factory CachedPoster.poster(
    String? url, {
    double width = 130,
    double height = 195,
    double sheenStrength = 0.22,
  }) {
    return CachedPoster(
      url: url,
      width: width,
      height: height,
      memCacheWidth: (width * 2).round().clamp(100, 400),
      memCacheHeight: (height * 2).round().clamp(150, 600),
      sheenStrength: sheenStrength,
    );
  }

  factory CachedPoster.backdrop(
    String? url, {
    double? width,
    double height = 160,
    double sheenStrength = 0.18,
  }) {
    return CachedPoster(
      url: url,
      width: width,
      height: height,
      memCacheWidth: 640,
      memCacheHeight: 360,
      sheenStrength: sheenStrength,
    );
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 2.0);
    final mw = memCacheWidth ?? (width != null ? (width! * dpr).round() : 300);
    final mh = memCacheHeight ?? (height != null ? (height! * dpr).round() : 400);

    Widget image;
    if (url == null || url!.isEmpty) {
      image = const ColoredBox(color: Color(0xFF1A222D));
    } else {
      image = CachedNetworkImage(
        imageUrl: url!,
        fit: fit,
        width: width,
        height: height,
        memCacheWidth: mw,
        memCacheHeight: mh,
        fadeInDuration: const Duration(milliseconds: 150),
        fadeOutDuration: const Duration(milliseconds: 100),
        placeholder: (_, __) => const _SkeletonBox(),
        errorWidget: (_, __, ___) => const ColoredBox(
          color: Color(0xFF1A222D),
          child: Icon(Icons.broken_image, color: Colors.white24, size: 28),
        ),
      );
    }

    Widget child = image;
    if (sheenStrength > 0) {
      final sheenH = (height != null ? height! * 0.22 : 40.0).clamp(24.0, 80.0);
      child = Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(child: image),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: sheenH,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withValues(alpha: sheenStrength),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    if (width != null || height != null) {
      child = SizedBox(width: width, height: height, child: child);
    }

    if (borderRadius != null) {
      return ClipRRect(borderRadius: borderRadius!, child: child);
    }
    return child;
  }
}

class _SkeletonBox extends StatefulWidget {
  const _SkeletonBox();
  @override
  State<_SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<_SkeletonBox> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => ColoredBox(
        color: Color.lerp(const Color(0xFF151B24), const Color(0xFF1F2836), _c.value)!,
      ),
    );
  }
}

class SkeletonRow extends StatelessWidget {
  final double height;
  final double itemWidth;
  final int count;
  const SkeletonRow({super.key, this.height = 160, this.itemWidth = 110, this.count = 6});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: count,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, __) => ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(width: itemWidth, height: height, child: const _SkeletonBox()),
        ),
      ),
    );
  }
}

String formatTitle(String? raw) {
  if (raw == null || raw.trim().isEmpty) return 'Sin título';
  var s = raw.trim();
  if (s.contains('-') && !s.contains(' ') && s.length > 3) {
    s = s.replaceAll('-', ' ').replaceAll('_', ' ');
  }
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.split(' ').map((w) {
    if (w.isEmpty) return w;
    if (w.length == 1) return w.toUpperCase();
    return w[0].toUpperCase() + w.substring(1).toLowerCase();
  }).join(' ');
}
