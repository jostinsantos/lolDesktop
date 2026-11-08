import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Escala global de la UI desktop (0.8 – 1.4).
class UiScaleService extends ChangeNotifier {
  UiScaleService._();
  static final UiScaleService instance = UiScaleService._();

  static const _key = 'ui_scale';
  double _scale = 1.0;
  double get scale => _scale;

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _scale = (p.getDouble(_key) ?? 1.0).clamp(0.8, 1.4);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setScale(double v) async {
    _scale = v.clamp(0.8, 1.4);
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setDouble(_key, _scale);
    } catch (_) {}
  }
}
