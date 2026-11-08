import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Almacenamiento local simple (SharedPreferences + cache de configs de repos).
class LocalStorage {
  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  SharedPreferences get prefs {
    final p = _prefs;
    if (p == null) throw StateError('LocalStorage no inicializado');
    return p;
  }

  Future<void> setString(String key, String value) => prefs.setString(key, value);
  String? getString(String key) => prefs.getString(key);

  Future<void> setBool(String key, bool value) => prefs.setBool(key, value);
  bool? getBool(String key) => prefs.getBool(key);

  Future<void> setJson(String key, Object value) async {
    await prefs.setString(key, jsonEncode(value));
  }

  dynamic getJson(String key) {
    final raw = prefs.getString(key);
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> remove(String key) => prefs.remove(key);
}
