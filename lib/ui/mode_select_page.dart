import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../data/services/settings_service.dart';

/// Primera ejecución: elegir interfaz Móvil o TV (enfocable con D-pad).
class ModeSelectPage extends StatefulWidget {
  const ModeSelectPage({super.key});

  @override
  State<ModeSelectPage> createState() => _ModeSelectPageState();
}

class _ModeSelectPageState extends State<ModeSelectPage> {
  final _mobileFocus = FocusNode(debugLabel: 'mode_mobile');
  final _tvFocus = FocusNode(debugLabel: 'mode_tv');
  int _index = 0; // 0 mobile, 1 tv

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mobileFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _mobileFocus.dispose();
    _tvFocus.dispose();
    super.dispose();
  }

  Future<void> _pick(UiMode mode) async {
    await context.read<SettingsService>().setMode(mode);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowLeft) {
      setState(() => _index = 1 - _index);
      (_index == 0 ? _mobileFocus : _tvFocus).requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.space) {
      _pick(_index == 0 ? UiMode.mobile : UiMode.tv);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0E14),
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      'Elige cómo usar la app',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Puedes cambiarlo después en Ajustes',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 36),
                    LayoutBuilder(
                      builder: (context, c) {
                        final wide = c.maxWidth > 520;
                        final cards = [
                          _ModeCard(
                            focusNode: _mobileFocus,
                            selected: _index == 0,
                            icon: Icons.phone_android_rounded,
                            title: 'Móvil',
                            subtitle: 'Interfaz vertical táctil',
                            onFocus: () => setState(() => _index = 0),
                            onTap: () => _pick(UiMode.mobile),
                          ),
                          _ModeCard(
                            focusNode: _tvFocus,
                            selected: _index == 1,
                            icon: Icons.tv_rounded,
                            title: 'TV',
                            subtitle: 'Interfaz horizontal con mando',
                            onFocus: () => setState(() => _index = 1),
                            onTap: () => _pick(UiMode.tv),
                          ),
                        ];
                        if (wide) {
                          return Row(
                            children: [
                              Expanded(child: cards[0]),
                              const SizedBox(width: 16),
                              Expanded(child: cards[1]),
                            ],
                          );
                        }
                        return Column(
                          children: [
                            cards[0],
                            const SizedBox(height: 16),
                            cards[1],
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 28),
                    Text(
                      'Usa ← → y OK en el mando, o toca una opción',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  final FocusNode focusNode;
  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onFocus;
  final VoidCallback onTap;

  const _ModeCard({
    required this.focusNode,
    required this.selected,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onFocus,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      onFocusChange: (v) {
        if (v) onFocus();
      },
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus || selected;
          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(18),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
                decoration: BoxDecoration(
                  color: focused
                      ? const Color(0xFF1A2332)
                      : const Color(0xFF141A22),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: focused
                        ? const Color(0xFF4FC3F7)
                        : Colors.white12,
                    width: focused ? 2.5 : 1,
                  ),
                  boxShadow: focused
                      ? [
                          BoxShadow(
                            color: const Color(0xFF4FC3F7).withValues(alpha: 0.25),
                            blurRadius: 18,
                            spreadRadius: 1,
                          )
                        ]
                      : null,
                ),
                child: Column(
                  children: [
                    Icon(icon, size: 48, color: focused ? const Color(0xFF4FC3F7) : Colors.white70),
                    const SizedBox(height: 14),
                    Text(
                      title,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
