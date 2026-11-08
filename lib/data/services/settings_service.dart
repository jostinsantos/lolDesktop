import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/storage/local_storage.dart';

enum UiMode { mobile, tv, desktop }

/// Modos de fondo del Home TV
enum HomeBgMode { tmdb, fixed, custom, lol }

/// Configuración global de la app: modo UI + notificaciones de parches + apariencia home.
class SettingsService extends ChangeNotifier {
  SettingsService(this._storage);

  final LocalStorage _storage;
  static const _keyMode = 'ui_mode';
  static const _keyChosen = 'ui_mode_chosen';
  static const _keyNotifyPatches = 'notify_patches';
  static const _keyDownloadsEnabled = 'downloads_enabled';
  static const _keyHomeBgMode = 'home_bg_mode';
  static const _keyHomeBgUrl = 'home_bg_url';
  static const _keyHomeBgBlur = 'home_bg_blur';
  static const _keyHomeBgDim = 'home_bg_dim';

  UiMode _mode = UiMode.mobile;
  bool _hasChosenMode = false;
  bool _notifyPatches = true;
  bool _downloadsEnabled = true;

  HomeBgMode _homeBgMode = HomeBgMode.tmdb;
  String _homeBgUrl = '';
  double _homeBgBlur = 16.0;
  double _homeBgDim = 0.0;

  UiMode get mode => _mode;
  bool get isTv => _mode == UiMode.tv;
  bool get isMobile => _mode == UiMode.mobile;
  bool get hasChosenMode => _hasChosenMode;
  bool get notifyPatches => _notifyPatches;
  bool get downloadsEnabled => _downloadsEnabled;

  HomeBgMode get homeBgMode => _homeBgMode;
  String get homeBgUrl => _homeBgUrl;
  double get homeBgBlur => _homeBgBlur;
  double get homeBgDim => _homeBgDim;

  bool get isDesktop => _mode == UiMode.desktop;

  Future<void> load() async {
    final raw = _storage.getString(_keyMode);
    final chosen = _storage.getString(_keyChosen);
    _hasChosenMode =
        chosen == '1' || raw == 'mobile' || raw == 'tv' || raw == 'desktop';
    if (raw == 'mobile') {
      _mode = UiMode.mobile;
    } else if (raw == 'tv') {
      _mode = UiMode.tv;
    } else if (raw == 'desktop') {
      _mode = UiMode.desktop;
    } else {
      _mode = UiMode.mobile;
      _hasChosenMode = false;
    }

    final np = _storage.getString(_keyNotifyPatches);
    _notifyPatches = np != '0';

    final dl = _storage.getString(_keyDownloadsEnabled);
    // Por defecto ON; solo se desactiva si el usuario eligió '0'
    _downloadsEnabled = dl != '0';

    final bgMode = _storage.getString(_keyHomeBgMode);
    switch (bgMode) {
      case 'fixed':
        _homeBgMode = HomeBgMode.fixed;
        break;
      case 'custom':
        _homeBgMode = HomeBgMode.custom;
        break;
      case 'lol':
        _homeBgMode = HomeBgMode.lol;
        break;
      default:
        _homeBgMode = HomeBgMode.tmdb;
    }
    _homeBgUrl = _storage.getString(_keyHomeBgUrl) ?? '';
    final blurRaw = _storage.getString(_keyHomeBgBlur);
    _homeBgBlur = double.tryParse(blurRaw ?? '') ?? 16.0;
    final dimRaw = _storage.getString(_keyHomeBgDim);
    _homeBgDim = double.tryParse(dimRaw ?? '') ?? 0.0;

    if (_hasChosenMode) {
      await _applyOrientation();
    }
    notifyListeners();
  }

  Future<void> setNotifyPatches(bool value) async {
    _notifyPatches = value;
    await _storage.setString(_keyNotifyPatches, value ? '1' : '0');
    notifyListeners();
  }

  Future<void> setDownloadsEnabled(bool value) async {
    _downloadsEnabled = value;
    await _storage.setString(_keyDownloadsEnabled, value ? '1' : '0');
    notifyListeners();
  }

  Future<void> setMode(UiMode mode) async {
    _mode = mode;
    _hasChosenMode = true;
    final s = switch (mode) {
      UiMode.mobile => 'mobile',
      UiMode.tv => 'tv',
      UiMode.desktop => 'desktop',
    };
    await _storage.setString(_keyMode, s);
    await _storage.setString(_keyChosen, '1');
    await _applyOrientation();
    notifyListeners();
  }

  Future<void> setHomeBgMode(HomeBgMode mode) async {
    _homeBgMode = mode;
    final s = switch (mode) {
      HomeBgMode.tmdb => 'tmdb',
      HomeBgMode.fixed => 'fixed',
      HomeBgMode.custom => 'custom',
      HomeBgMode.lol => 'lol',
    };
    await _storage.setString(_keyHomeBgMode, s);
    notifyListeners();
  }

  Future<void> setHomeBgUrl(String url) async {
    _homeBgUrl = url;
    await _storage.setString(_keyHomeBgUrl, url);
    notifyListeners();
  }

  Future<void> setHomeBgBlur(double value) async {
    _homeBgBlur = value.clamp(0.0, 40.0);
    await _storage.setString(_keyHomeBgBlur, _homeBgBlur.toStringAsFixed(1));
    notifyListeners();
  }

  Future<void> setHomeBgDim(double value) async {
    _homeBgDim = value.clamp(0.0, 0.6);
    await _storage.setString(_keyHomeBgDim, _homeBgDim.toStringAsFixed(2));
    notifyListeners();
  }

  Future<void> _applyOrientation() async {
    if (_mode == UiMode.tv || _mode == UiMode.desktop) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
  }
}
