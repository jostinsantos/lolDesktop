import 'package:flutter/material.dart';
import 'launcher/home.dart';

/// Raíz de la UI para Android TV / Leanback.
/// Diseño completamente diferente al móvil:
/// - Navegación horizontal
/// - Foco blanco + auto-scroll
/// - Glassmorphism y transparencias
/// - Escala reducida (no parece un móvil girado)
/// - Teclado QWERTY propio en todos los inputs
class TvAppRoot extends StatelessWidget {
  const TvAppRoot({super.key});

  @override
  Widget build(BuildContext context) => const LauncherHome();
}
