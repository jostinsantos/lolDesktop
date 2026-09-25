import 'package:flutter/material.dart';

import 'fuentes_tab.dart'; // asegúrate de que el nombre del archivo coincida

class AjustesPage extends StatelessWidget {
  const AjustesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F14),
      body: FuentesTab(
        onRequestTabFocus: () {}, // no se usa en PC
      ),
    );
  }
}