import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'supabase/supabase_client.dart';
import 'features/main_home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // MediaKit
  try {
    MediaKit.ensureInitialized();
  } catch (e) {
    debugPrint('Error al inicializar MediaKit: $e');
  }

  // Window Manager (necesario para pantalla completa en el .exe)
  try {
    await windowManager.ensureInitialized();

    const windowOptions = WindowOptions(
      size: Size(1280, 720),
      minimumSize: Size(1024, 600),
      center: true,
      backgroundColor: Colors.black,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
      title: 'LOL+',
      fullScreen: false,
    );

    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  } catch (e) {
    debugPrint('Error al inicializar windowManager: $e');
  }

  // Supabase
  try {
    await AppSupabase.init();
  } catch (e) {
    debugPrint('Error al inicializar Supabase: $e');
  }

  runApp(const LolApp());
}

class LolApp extends StatelessWidget {
  const LolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LOL+',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0B0B0F),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFE50914),
          secondary: Color(0xFFE50914),
          surface: Color(0xFF16161D),
        ),
      ),
      home: const SplashScreen(),
    );
  }
}

/// Pantalla de carga con spinner + aviso beta
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 3), _mostrarAvisoBeta);
  }

  Future<void> _mostrarAvisoBeta() async {
    if (!mounted) return;

    final aceptado = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF16161D),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Color(0xFFE50914)),
            SizedBox(width: 8),
            Text(
              'Versión BETA',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: const Text(
          'Este programa es una versión BETA del programa original.\n\n'
          'Puede contener errores, funciones incompletas o cambios inesperados. '
          'Si estás de acuerdo, pulsa "Acepto" para continuar.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              'No',
              style: TextStyle(color: Colors.white70),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE50914),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Acepto'),
          ),
        ],
      ),
    );

    if (aceptado == true) {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const PcMainHome()),
      );
    } else {
      // Cierra la app si no acepta
      try {
        await windowManager.close();
      } catch (_) {
        // fallback por si windowManager falla
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF0B0B0F),
      body: Center(
        child: Image(
          image: AssetImage('assets/spiner.gif'),
          width: 120,
          height: 120,
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}