import 'package:flutter/material.dart';

import 'home/home.dart';
import 'buscar/buscar.dart';
import 'descubrir/descubrir.dart';
import 'guardado/guardado.dart';
import 'ajustes/ajustes.dart'; // ← aquí debe estar tu página de Ajustes de PC

/// Shell principal para PC.
/// Tabs: Home | Buscar | Descubrir | Guardados | Ajustes
/// NavigationRail siempre comprimido (solo iconos + tooltips).
class PcMainHome extends StatefulWidget {
  const PcMainHome({super.key});

  @override
  State<PcMainHome> createState() => _PcMainHomeState();
}

class _PcMainHomeState extends State<PcMainHome> {
  int _index = 0;

  late final List<Widget> _pages = [
    const HomePage(),
    const BuscarPage(),
    const DescubrirPage(),
    const GuardadoPage(),
    const AjustesPage(), // ← usa tu página de escritorio (FuentesTab + Supabase PC)
  ];

  static const _bgRail = Color(0xFF0B0B0F);
  static const _bgContent = Color(0xFF0F0F14);
  static const _accent = Color(0xFFE50914);
  static const _divider = Color(0xFF1E1E28);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgContent,
      body: Row(
        children: [
          // ── Navigation Rail ────────────────────────────────────────────
          NavigationRail(
            extended: false,
            minWidth: 76,
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            backgroundColor: _bgRail,
            indicatorColor: _accent.withValues(alpha: 0.18),
            selectedIconTheme: const IconThemeData(
              color: _accent,
              size: 26,
            ),
            unselectedIconTheme: IconThemeData(
              color: Colors.white.withValues(alpha: 0.55),
              size: 24,
            ),
            labelType: NavigationRailLabelType.none,
            leading: Padding(
              padding: const EdgeInsets.only(top: 20, bottom: 28),
              child: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: _accent,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: _accent.withValues(alpha: 0.35),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Center(
                  child: Text(
                    'L+',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 17,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
              ),
            ),
            destinations: [
              _dest(
                icon: Icons.home_outlined,
                selectedIcon: Icons.home_rounded,
                label: 'Home',
              ),
              _dest(
                icon: Icons.search_outlined,
                selectedIcon: Icons.search_rounded,
                label: 'Buscar',
              ),
              _dest(
                icon: Icons.explore_outlined,
                selectedIcon: Icons.explore_rounded,
                label: 'Descubrir',
              ),
              _dest(
                icon: Icons.bookmark_border_rounded,
                selectedIcon: Icons.bookmark_rounded,
                label: 'Guardados',
              ),
              _dest(
                icon: Icons.settings_outlined,
                selectedIcon: Icons.settings_rounded,
                label: 'Ajustes',
              ),
            ],
          ),

          // Separador sutil
          Container(
            width: 1,
            color: _divider,
          ),

          // ── Contenido ──────────────────────────────────────────────────
          Expanded(
            child: IndexedStack(
              index: _index,
              children: _pages,
            ),
          ),
        ],
      ),
    );
  }

  NavigationRailDestination _dest({
    required IconData icon,
    required IconData selectedIcon,
    required String label,
  }) {
    return NavigationRailDestination(
      icon: Tooltip(
        message: label,
        waitDuration: const Duration(milliseconds: 400),
        child: Icon(icon),
      ),
      selectedIcon: Tooltip(
        message: label,
        waitDuration: const Duration(milliseconds: 400),
        child: Icon(selectedIcon),
      ),
      label: Text(label),
    );
  }
}