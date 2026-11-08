import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'stream_server.dart';

String _prettyTitle(String s) {
  s = s.trim();
  if (s.contains('-') && !s.contains(' ') && s.length > 3) {
    s = s.replaceAll('-', ' ').replaceAll('_', ' ');
  }
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.isEmpty) return 'Sin título';
  return s.split(' ').map((w) {
    if (w.isEmpty) return w;
    return w[0].toUpperCase() + (w.length > 1 ? w.substring(1).toLowerCase() : '');
  }).join(' ');
}

List<String> _parseLanguages(Map<String, dynamic> j) {
  final raw = j['languages'] ?? j['idiomas'] ?? j['langs'];
  if (raw is List) {
    return raw.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
  }
  if (raw is String && raw.isNotEmpty) {
    return raw.split(RegExp(r'[,|;]')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }
  return const [];
}


/// Campo de configuración que el creador del repo puede pedir al usuario.
/// Se guarda en caché de la app (por repoId + key).
class RepoConfigField extends Equatable {
  final String key;
  final String label;
  /// text | password | number | url | select | language | radio |
  /// checkbox | multiselect | multi | color | boolean | switch
  final String type;
  final String? defaultValue;
  final String? description;
  final String? placeholder;
  final bool required;
  /// Opciones: ["Latino","Castellano"] o [{id/value, label/name}]
  final List<String> options;
  /// Valores estables paralelos a [options] (si el JSON trae id/value).
  /// Si está vacío, se usa [options] como valor.
  final List<String> optionValues;

  const RepoConfigField({
    required this.key,
    required this.label,
    this.type = 'text',
    this.defaultValue,
    this.description,
    this.placeholder,
    this.required = false,
    this.options = const [],
    this.optionValues = const [],
  });

  String get _t => type.toLowerCase().trim();

  /// Una sola opción de una lista (select / radio / language).
  bool get isSelect {
    if (isMulti || isColor || isBool) return false;
    return _t == 'select' ||
        _t == 'language' ||
        _t == 'radio' ||
        _t == 'dropdown' ||
        (_t != 'text' &&
            _t != 'password' &&
            _t != 'number' &&
            _t != 'url' &&
            options.isNotEmpty);
  }

  /// Varias opciones a la vez (checkbox / multiselect). Valor guardado: "a,b,c".
  bool get isMulti =>
      _t == 'checkbox' ||
      _t == 'checkboxes' ||
      _t == 'multiselect' ||
      _t == 'multi' ||
      _t == 'multi-select' ||
      _t == 'tags';

  /// Selector de color (#RRGGBB).
  bool get isColor => _t == 'color' || _t == 'colour' || _t == 'hex';

  /// Boolean on/off.
  bool get isBool =>
      _t == 'boolean' || _t == 'bool' || _t == 'switch' || _t == 'toggle';

  String valueAt(int i) {
    if (i >= 0 && i < optionValues.length && optionValues[i].isNotEmpty) {
      return optionValues[i];
    }
    if (i >= 0 && i < options.length) return options[i];
    return '';
  }

  String labelAt(int i) {
    if (i >= 0 && i < options.length) return options[i];
    return valueAt(i);
  }

  /// Parsea valor multi: "a,b,c" | "a|b" | JSON array.
  static Set<String> parseMulti(String? raw) {
    if (raw == null || raw.trim().isEmpty) return {};
    final s = raw.trim();
    if (s.startsWith('[') && s.endsWith(']')) {
      try {
        // Evita importar dart:convert aquí: split simple de JSON array de strings
        final inner = s.substring(1, s.length - 1).trim();
        if (inner.isEmpty) return {};
        return inner
            .split(',')
            .map((e) => e.trim().replaceAll('"', '').replaceAll("'", ''))
            .where((e) => e.isNotEmpty)
            .toSet();
      } catch (_) {}
    }
    final sep = s.contains('|') ? '|' : ',';
    return s.split(sep).map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
  }

  static String encodeMulti(Iterable<String> values) =>
      values.map((e) => e.trim()).where((e) => e.isNotEmpty).join(',');

  factory RepoConfigField.fromJson(Map<String, dynamic> j) {
    final opts = <String>[];
    final vals = <String>[];
    final raw = j['options'] ?? j['values'] ?? j['choices'] ?? j['items'];
    if (raw is List) {
      for (final o in raw) {
        if (o is Map) {
          final label =
              (o['label'] ?? o['name'] ?? o['title'] ?? o['id'] ?? o['value'] ?? '')
                  .toString();
          final value =
              (o['value'] ?? o['id'] ?? o['key'] ?? o['label'] ?? o['name'] ?? '')
                  .toString();
          if (label.isNotEmpty || value.isNotEmpty) {
            opts.add(label.isNotEmpty ? label : value);
            vals.add(value.isNotEmpty ? value : label);
          }
        } else if (o != null) {
          final s = o.toString();
          if (s.isNotEmpty) {
            opts.add(s);
            vals.add(s);
          }
        }
      }
    }
    var type = (j['type'] ?? 'text').toString();
    // Si no hay type pero hay options y multiple:true → multiselect
    if ((type == 'text' || type.isEmpty) && opts.isNotEmpty) {
      if (j['multiple'] == true || j['multi'] == true) {
        type = 'multiselect';
      } else {
        type = 'select';
      }
    }
    // default puede ser lista en multi
    String? def = j['default']?.toString() ?? j['defaultValue']?.toString();
    if (def == null && j['default'] is List) {
      def = encodeMulti((j['default'] as List).map((e) => e.toString()));
    }
    return RepoConfigField(
      key: (j['key'] ?? j['name'] ?? '').toString(),
      label: (j['label'] ?? j['title'] ?? j['key'] ?? '').toString(),
      type: type,
      defaultValue: def,
      description: j['description']?.toString() ?? j['help']?.toString(),
      placeholder: j['placeholder']?.toString() ?? j['hint']?.toString(),
      required: j['required'] == true,
      options: opts,
      optionValues: vals,
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'label': label,
        'type': type,
        if (defaultValue != null) 'default': defaultValue,
        if (description != null) 'description': description,
        if (placeholder != null) 'placeholder': placeholder,
        'required': required,
        if (options.isNotEmpty) 'options': options,
        if (optionValues.isNotEmpty) 'optionValues': optionValues,
      };

  @override
  List<Object?> get props =>
      [key, label, type, defaultValue, required, options, optionValues];
}

/// Tema visual definido por el desarrollador del repo en lol.json.
/// Si falta, la app usa sus colores por defecto.
class RepoTheme extends Equatable {
  final Color? accent;
  final Color? onAccent;
  final Color? background;
  final Color? surface;
  final Color? highlight;

  const RepoTheme({
    this.accent,
    this.onAccent,
    this.background,
    this.surface,
    this.highlight,
  });

  static Color? parseColor(dynamic v) {
    if (v == null) return null;
    var s = v.toString().trim();
    if (s.isEmpty) return null;
    if (s.startsWith('#')) s = s.substring(1);
    if (s.length == 3) {
      s = s.split('').map((c) => '$c$c').join();
    }
    if (s.length == 6) s = 'FF$s';
    if (s.length != 8) return null;
    final n = int.tryParse(s, radix: 16);
    if (n == null) return null;
    return Color(n);
  }

  factory RepoTheme.fromJson(Map<String, dynamic>? j, {String? fallbackColor}) {
    if (j == null && (fallbackColor == null || fallbackColor.isEmpty)) {
      return const RepoTheme();
    }
    final m = j ?? const <String, dynamic>{};
    return RepoTheme(
      accent: parseColor(m['accent'] ?? m['primary'] ?? m['color'] ?? fallbackColor),
      onAccent: parseColor(m['onAccent'] ?? m['onPrimary'] ?? m['accentText']),
      background: parseColor(m['background'] ?? m['bg'] ?? m['scaffold']),
      surface: parseColor(m['surface'] ?? m['card'] ?? m['panel']),
      highlight: parseColor(m['highlight'] ?? m['focus'] ?? m['border']),
    );
  }

  Map<String, dynamic> toJson() {
    String? hex(Color? c) {
      if (c == null) return null;
      return '#${c.value.toRadixString(16).padLeft(8, '0').substring(2)}';
    }
    return {
      if (accent != null) 'accent': hex(accent),
      if (onAccent != null) 'onAccent': hex(onAccent),
      if (background != null) 'background': hex(background),
      if (surface != null) 'surface': hex(surface),
      if (highlight != null) 'highlight': hex(highlight),
    };
  }

  bool get hasAny =>
      accent != null ||
      onAccent != null ||
      background != null ||
      surface != null ||
      highlight != null;

  Color get effectiveAccent => accent ?? const Color(0xFFE50914);
  Color get effectiveOnAccent => onAccent ?? const Color(0xFFFFFFFF);
  Color get effectiveBackground => background ?? const Color(0xFF0B0E14);
  Color get effectiveSurface => surface ?? const Color(0xFF141A22);
  Color get effectiveHighlight => highlight ?? const Color(0xFFFF2D2D);

  ThemeData toThemeData() {
    final a = effectiveAccent;
    final bg = effectiveBackground;
    final sf = effectiveSurface;
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      primaryColor: a,
      colorScheme: ColorScheme.dark(
        primary: a,
        onPrimary: effectiveOnAccent,
        secondary: a,
        surface: sf,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: sf,
        elevation: 0,
        centerTitle: false,
        foregroundColor: Colors.white,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: sf,
        indicatorColor: a.withValues(alpha: 0.25),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final sel = states.contains(WidgetState.selected);
          return TextStyle(
            color: sel ? a : Colors.white70,
            fontSize: 12,
            fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final sel = states.contains(WidgetState.selected);
          return IconThemeData(color: sel ? a : Colors.white70);
        }),
      ),
      useMaterial3: true,
    );
  }

  @override
  List<Object?> get props => [accent, onAccent, background, surface, highlight];
}

/// Manifest de un repositorio (plantilla obligatoria).
/// Cada repo en GitHub debe tener un archivo `lol.json` (también se aceptan
/// `nuvio.json`, `manifest.json`, `addon.json` por compatibilidad).
class RepoManifest extends Equatable {
  final String id;
  final String name;
  final String version;
  final String description;
  final String? icon; // URL o path relativo (ej. icon.png en la raíz del repo)
  final String? banner; // URL o path relativo (ej. banner.png)
  final String author;
  final String repo; // user/repo
  final String? entryJs; // plugin.js / index.js
  final List<RepoConfigField> configFields;
  final List<String> capabilities;
  /// Idiomas que ofrece el repo (Latino, Castellano, ...).
  final List<String> languages;
  final Map<String, dynamic> raw;

  /// Solo desarrollador del repo: paginar lista de episodios en series largas.
  final bool episodesPagination;
  final int episodesPerPage;

  /// apiVersion del addon (ej. 6).
  final int? apiVersion;
  /// Si el addon declara uso de browser/webview.
  final bool browser;
  /// Etiqueta de sección (section.label) para agrupar en la UI.
  final String? sectionLabel;
  /// Color principal suelto (legacy) o base del theme.
  final Color? color;
  /// Tema visual del repo (accent, background, surface...).
  final RepoTheme theme;

  /// Estilo de tarjetas en novedades del launcher:
  /// `poster` = vertical, `banner`/`backdrop` = horizontal.
  /// El repo lo declara en lol.json; también puede ir por ítem en getNews.
  final String newsImageStyle;

  const RepoManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    this.icon,
    this.banner,
    required this.author,
    required this.repo,
    this.entryJs,
    this.configFields = const [],
    this.capabilities = const ['home', 'discover', 'search', 'meta', 'streams'],
    this.languages = const [],
    this.raw = const {},
    this.episodesPagination = false,
    this.episodesPerPage = 20,
    this.apiVersion,
    this.browser = false,
    this.sectionLabel,
    this.color,
    this.theme = const RepoTheme(),
    this.newsImageStyle = 'poster',
  });


  /// Repo orientado a TV en vivo / IPTV (no catálogo VOD).
  bool get isLiveRepo {
    bool hit(String s) {
      final t = s.toLowerCase().trim();
      return t == 'live' ||
          t == 'tv' ||
          t == 'iptv' ||
          t == 'channel' ||
          t == 'channels' ||
          t == 'canales' ||
          t == 'en vivo' ||
          t == 'envivo';
    }

    for (final c in capabilities) {
      if (hit(c)) return true;
    }
    final cats = raw['categories'] ?? raw['category'];
    if (cats is List) {
      for (final c in cats) {
        if (hit(c.toString())) return true;
      }
    } else if (cats is String && hit(cats)) {
      return true;
    }
    final type =
        (raw['type'] ?? raw['repoType'] ?? raw['kind'] ?? '').toString();
    if (hit(type)) return true;
    return false;
  }

  /// Pestañas del menú del repo.
  /// Live IPTV → solo live + settings. Resto sin cambios.
  List<String> get resolvedTabs {
    if (isLiveRepo) {
      return const ['live', 'settings'];
    }

    final explicit = raw['tabs'] ?? raw['pages'] ?? raw['menu'];
    if (explicit is List && explicit.isNotEmpty) {
      return explicit
          .map((e) => e.toString().toLowerCase().trim())
          .where((e) => e.isNotEmpty)
          .map(_normalizeTab)
          .toSet()
          .toList();
    }
    final caps = capabilities.map((c) => c.toLowerCase().trim()).toSet();
    if (caps.isEmpty) {
      return const ['home', 'discover', 'search', 'library', 'settings'];
    }
    final tabs = <String>[];
    if (caps.contains('home')) tabs.add('home');
    if (caps.contains('discover') || caps.contains('browse')) {
      tabs.add('discover');
    }
    if (caps.contains('search')) tabs.add('search');
    if (caps.contains('live') ||
        caps.contains('channel') ||
        caps.contains('tv') ||
        caps.contains('iptv')) {
      tabs.add('live');
    }
    tabs.add('library');
    tabs.add('settings');
    if (tabs.isEmpty) {
      tabs.addAll(const ['home', 'search', 'library', 'settings']);
    }
    return tabs;
  }

  static String _normalizeTab(String t) {
    switch (t) {
      case 'inicio':
      case 'home':
      case 'main':
        return 'home';
      case 'descubrir':
      case 'discover':
      case 'browse':
      case 'explorar':
      case 'explore':
        return 'discover';
      case 'buscar':
      case 'search':
        return 'search';
      case 'live':
      case 'en vivo':
      case 'envivo':
      case 'channel':
      case 'channels':
      case 'canales':
      case 'tv':
      case 'iptv':
        return 'live';
      case 'biblioteca':
      case 'library':
      case 'bookmarks':
        return 'library';
      case 'ajustes':
      case 'settings':
      case 'config':
      case 'configuración':
      case 'configuracion':
        return 'settings';
      default:
        return t;
    }
  }

  /// Acento efectivo (theme.accent → color → default app).
  Color get accentColor => theme.accent ?? color ?? const Color(0xFFE50914);
  Color get backgroundColor => theme.effectiveBackground;
  Color get surfaceColor => theme.effectiveSurface;


  static String _parseNewsImageStyle(Map<String, dynamic> raw) {
    dynamic nested;
    final news = raw['news'];
    if (news is Map) nested = news;
    final v = (raw['newsImageStyle'] ??
            raw['newsStyle'] ??
            raw['news_image_style'] ??
            (nested is Map ? nested['imageStyle'] : null) ??
            (nested is Map ? nested['style'] : null) ??
            'poster')
        .toString()
        .toLowerCase()
        .trim();
    if (v.contains('banner') ||
        v.contains('back') ||
        v.contains('horizontal') ||
        v == 'wide') {
      return 'banner';
    }
    return 'poster';
  }

  factory RepoManifest.fromJson(Map<String, dynamic> j, {String? repo}) {
    final configRaw = j['config'] ?? j['settings'] ?? [];
    final fields = <RepoConfigField>[];
    if (configRaw is List) {
      for (final c in configRaw) {
        if (c is Map) fields.add(RepoConfigField.fromJson(Map<String, dynamic>.from(c)));
      }
    }
    final caps = j['capabilities'] ?? j['pages'] ?? ['home', 'discover', 'search', 'meta', 'streams'];

    bool paginate = false;
    int perPage = 20;
    final pagRoot = j['episodesPagination'] ?? j['paginateEpisodes'] ?? j['pagination'];
    if (pagRoot is bool) {
      paginate = pagRoot;
    } else if (pagRoot is Map) {
      final m = Map<String, dynamic>.from(pagRoot);
      paginate = m['enabled'] == true ||
          m['episodes'] == true ||
          m['paginate'] == true ||
          m['on'] == true;
      final pp = m['perPage'] ?? m['episodesPerPage'] ?? m['itemsPerPage'] ?? m['pageSize'];
      if (pp is num && pp.toInt() > 0) perPage = pp.toInt();
    } else if (pagRoot != null) {
      final s = pagRoot.toString().toLowerCase();
      paginate = s == 'true' || s == '1' || s == 'yes' || s == 'on';
    }
    final ppTop = j['episodesPerPage'] ?? j['itemsPerPage'] ?? j['perPage'];
    if (ppTop is num && ppTop.toInt() > 0) {
      perPage = ppTop.toInt();
    }
    if (perPage < 1) perPage = 20;
    if (perPage > 200) perPage = 200;

    String? sectionLabel;
    final sectionRaw = j['section'];
    if (sectionRaw is Map) {
      sectionLabel = (sectionRaw['label'] ?? sectionRaw['name'] ?? sectionRaw['title'])?.toString();
    } else if (sectionRaw is String && sectionRaw.isNotEmpty) {
      sectionLabel = sectionRaw;
    }

    final colorStr = j['color']?.toString();
    final themeMap = j['theme'] is Map
        ? Map<String, dynamic>.from(j['theme'] as Map)
        : null;
    final theme = RepoTheme.fromJson(themeMap, fallbackColor: colorStr);
    final parsedColor = RepoTheme.parseColor(colorStr) ?? theme.accent;

    final apiRaw = j['apiVersion'] ?? j['api'] ?? j['api_version'];
    int? apiVersion;
    if (apiRaw is num) {
      apiVersion = apiRaw.toInt();
    } else if (apiRaw != null) {
      apiVersion = int.tryParse(apiRaw.toString());
    }

    return RepoManifest(
      id: (j['id'] ?? j['name'] ?? repo ?? 'unknown').toString().toLowerCase().replaceAll(' ', '-'),
      name: (j['name'] ?? 'Sin nombre').toString(),
      version: (j['version'] ?? '1.0.0').toString(),
      description: (j['description'] ?? '').toString(),
      icon: j['icon']?.toString() ?? j['logo']?.toString(),
      banner: j['banner']?.toString() ?? j['bannerImage']?.toString(),
      author: (j['author'] ?? j['maintainer'] ?? '').toString(),
      repo: repo ?? (j['repo'] ?? '').toString(),
      entryJs: (j['entry'] ?? j['main'] ?? 'plugin.js').toString(),
      configFields: fields,
      capabilities: (caps is List) ? caps.map((e) => e.toString()).toList() : const [],
      languages: _parseLanguages(j),
      raw: Map<String, dynamic>.from(j),
      episodesPagination: paginate,
      episodesPerPage: perPage,
      newsImageStyle: _parseNewsImageStyle(j),
      apiVersion: apiVersion,
      browser: j['browser'] == true || j['browser'] == 'true' || j['browser'] == 1,
      sectionLabel: sectionLabel,
      color: parsedColor,
      theme: theme,
    );
  }

  RepoManifest copyWith({
    String? id,
    String? name,
    String? version,
    String? description,
    String? icon,
    String? banner,
    String? author,
    String? repo,
    String? entryJs,
    List<RepoConfigField>? configFields,
    List<String>? capabilities,
    List<String>? languages,
    Map<String, dynamic>? raw,
    bool? episodesPagination,
    int? episodesPerPage,
    int? apiVersion,
    bool? browser,
    String? sectionLabel,
    Color? color,
    RepoTheme? theme,
    String? newsImageStyle,
  }) {
    return RepoManifest(
      id: id ?? this.id,
      name: name ?? this.name,
      version: version ?? this.version,
      description: description ?? this.description,
      icon: icon ?? this.icon,
      banner: banner ?? this.banner,
      author: author ?? this.author,
      repo: repo ?? this.repo,
      entryJs: entryJs ?? this.entryJs,
      configFields: configFields ?? this.configFields,
      capabilities: capabilities ?? this.capabilities,
      languages: languages ?? this.languages,
      raw: raw ?? this.raw,
      episodesPagination: episodesPagination ?? this.episodesPagination,
      episodesPerPage: episodesPerPage ?? this.episodesPerPage,
      apiVersion: apiVersion ?? this.apiVersion,
      browser: browser ?? this.browser,
      sectionLabel: sectionLabel ?? this.sectionLabel,
      color: color ?? this.color,
      theme: theme ?? this.theme,
      newsImageStyle: newsImageStyle ?? this.newsImageStyle,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'version': version,
        'description': description,
        if (icon != null) 'icon': icon,
        if (banner != null) 'banner': banner,
        'author': author,
        'repo': repo,
        if (entryJs != null) 'entry': entryJs,
        'newsImageStyle': newsImageStyle,
        'config': configFields.map((e) => e.toJson()).toList(),
        'capabilities': capabilities,
        if (episodesPagination) 'episodesPagination': true,
        if (episodesPagination) 'episodesPerPage': episodesPerPage,
        if (apiVersion != null) 'apiVersion': apiVersion,
        if (browser) 'browser': true,
        if (sectionLabel != null) 'section': {'label': sectionLabel},
        if (theme.hasAny) 'theme': theme.toJson(),
      };

  @override
  List<Object?> get props => [id, name, version, repo, episodesPagination, episodesPerPage, apiVersion, newsImageStyle, sectionLabel, browser];
}


/// Resumen del contract.json del repo (opcional).
/// Define capacidades, permisos y reglas que el desarrollador declara.
class RepoContract extends Equatable {
  final int? apiVersion;
  final int? maxApiVersion;
  final List<String> capabilityNames;
  final List<String> requiredCapabilities;
  final List<String> needsApproval;
  final bool browser;
  final String? browserConsent;
  final bool telemetry;
  final String? telemetryConsent;
  final List<String> categories;
  final Map<String, dynamic> raw;

  const RepoContract({
    this.apiVersion,
    this.maxApiVersion,
    this.capabilityNames = const [],
    this.requiredCapabilities = const [],
    this.needsApproval = const [],
    this.browser = false,
    this.browserConsent,
    this.telemetry = false,
    this.telemetryConsent,
    this.categories = const [],
    this.raw = const {},
  });

  factory RepoContract.fromJson(Map<String, dynamic> j) {
    final caps = j['capabilities'];
    List<String> names = const [];
    List<String> required = const [];
    List<String> needsApproval = const [];
    if (caps is Map) {
      final n = caps['names'];
      if (n is List) names = n.map((e) => e.toString()).toList();
      final r = caps['required'];
      if (r is List) required = r.map((e) => e.toString()).toList();
      final a = caps['needsApproval'];
      if (a is List) needsApproval = a.map((e) => e.toString()).toList();
    } else if (caps is List) {
      names = caps.map((e) => e.toString()).toList();
    }

    final man = j['manifest'] is Map ? Map<String, dynamic>.from(j['manifest'] as Map) : <String, dynamic>{};
    final browserBlock = man['browser'] is Map ? Map<String, dynamic>.from(man['browser'] as Map) : null;
    final telemetryBlock = man['telemetry'] is Map ? Map<String, dynamic>.from(man['telemetry'] as Map) : null;

    bool browser = j['browser'] == true;
    String? browserConsent = browserBlock?['consentLine']?.toString();
    if (j['browser'] == 'pages' || j['browser'] == true) browser = true;

    bool telemetry = j['telemetry'] == true || j['telemetry'] == 'verbose';
    String? telemetryConsent = telemetryBlock?['consentLine']?.toString();

    List<String> categories = const [];
    final cat = j['categories'] ?? man['categories'];
    if (cat is List) {
      categories = cat.map((e) => e.toString()).toList();
    } else if (cat is Map && cat['values'] is List) {
      // schema only, ignore
    }

    final api = j['apiVersion'];
    final maxApi = j['maxApiVersion'];

    return RepoContract(
      apiVersion: api is num ? api.toInt() : int.tryParse('$api'),
      maxApiVersion: maxApi is num ? maxApi.toInt() : int.tryParse('$maxApi'),
      capabilityNames: names,
      requiredCapabilities: required,
      needsApproval: needsApproval,
      browser: browser,
      browserConsent: browserConsent,
      telemetry: telemetry,
      telemetryConsent: telemetryConsent,
      categories: categories,
      raw: Map<String, dynamic>.from(j),
    );
  }

  Map<String, dynamic> toJson() => {
        if (apiVersion != null) 'apiVersion': apiVersion,
        if (maxApiVersion != null) 'maxApiVersion': maxApiVersion,
        'capabilities': {
          'names': capabilityNames,
          'required': requiredCapabilities,
          'needsApproval': needsApproval,
        },
        if (browser) 'browser': true,
        if (browserConsent != null) 'browserConsent': browserConsent,
        if (telemetry) 'telemetry': true,
        if (telemetryConsent != null) 'telemetryConsent': telemetryConsent,
        if (categories.isNotEmpty) 'categories': categories,
      };

  factory RepoContract.fromStored(Map<String, dynamic> j) {
    // Preferir resumen compacto guardado por la app.
    if (j.containsKey('capabilities') || j.containsKey('apiVersion') || j.containsKey('browserConsent')) {
      final caps = j['capabilities'];
      List<String> names = const [];
      List<String> required = const [];
      List<String> needsApproval = const [];
      if (caps is Map) {
        if (caps['names'] is List) names = (caps['names'] as List).map((e) => e.toString()).toList();
        if (caps['required'] is List) required = (caps['required'] as List).map((e) => e.toString()).toList();
        if (caps['needsApproval'] is List) {
          needsApproval = (caps['needsApproval'] as List).map((e) => e.toString()).toList();
        }
      }
      return RepoContract(
        apiVersion: j['apiVersion'] is num ? (j['apiVersion'] as num).toInt() : int.tryParse('${j['apiVersion']}'),
        maxApiVersion: j['maxApiVersion'] is num ? (j['maxApiVersion'] as num).toInt() : int.tryParse('${j['maxApiVersion']}'),
        capabilityNames: names,
        requiredCapabilities: required,
        needsApproval: needsApproval,
        browser: j['browser'] == true,
        browserConsent: j['browserConsent']?.toString(),
        telemetry: j['telemetry'] == true,
        telemetryConsent: j['telemetryConsent']?.toString(),
        categories: j['categories'] is List ? (j['categories'] as List).map((e) => e.toString()).toList() : const [],
      );
    }
    if (j['raw'] is Map) {
      return RepoContract.fromJson(Map<String, dynamic>.from(j['raw'] as Map));
    }
    return RepoContract.fromJson(j);
  }

  /// Líneas legibles para el modal de instalación.
  List<String> get summaryLines {
    final lines = <String>[];
    if (apiVersion != null) {
      lines.add('API version: $apiVersion${maxApiVersion != null ? ' (máx. $maxApiVersion)' : ''}');
    }
    if (capabilityNames.isNotEmpty) {
      lines.add('Capacidades: ${capabilityNames.take(12).join(', ')}${capabilityNames.length > 12 ? '…' : ''}');
    }
    if (requiredCapabilities.isNotEmpty) {
      lines.add('Obligatorias: ${requiredCapabilities.join(', ')}');
    }
    if (needsApproval.isNotEmpty) {
      lines.add('Requieren aprobación: ${needsApproval.join(', ')}');
    }
    if (categories.isNotEmpty) {
      lines.add('Categorías: ${categories.join(', ')}');
    }
    if (browser) {
      lines.add(browserConsent ?? 'Puede abrir páginas web ocultas para encontrar el video');
    }
    if (telemetry) {
      lines.add(telemetryConsent ?? 'Puede compartir registros de errores con el desarrollador');
    }
    return lines;
  }

  @override
  List<Object?> get props => [apiVersion, capabilityNames, browser, telemetry];
}

/// Repo instalado localmente.
class InstalledRepo extends Equatable {
  final RepoManifest manifest;
  final String sourceUrl; // raw GitHub o URL del manifest
  final DateTime installedAt;
  final DateTime? updatedAt;
  final bool enabled;
  /// Código JS cacheado (si tiene entry)
  final String? jsCode;
  /// Valores de configuración del usuario (key -> value)
  final Map<String, String> userConfig;
  /// Contrato del plugin (contract.json), si el repo lo publica.
  final RepoContract? contract;

  const InstalledRepo({
    required this.manifest,
    required this.sourceUrl,
    required this.installedAt,
    this.updatedAt,
    this.enabled = true,
    this.jsCode,
    this.userConfig = const {},
    this.contract,
  });

  InstalledRepo copyWith({
    RepoManifest? manifest,
    String? sourceUrl,
    DateTime? installedAt,
    DateTime? updatedAt,
    bool? enabled,
    String? jsCode,
    Map<String, String>? userConfig,
    RepoContract? contract,
  }) {
    return InstalledRepo(
      manifest: manifest ?? this.manifest,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      installedAt: installedAt ?? this.installedAt,
      updatedAt: updatedAt ?? this.updatedAt,
      enabled: enabled ?? this.enabled,
      jsCode: jsCode ?? this.jsCode,
      userConfig: userConfig ?? this.userConfig,
      contract: contract ?? this.contract,
    );
  }

  Map<String, dynamic> toJson() => {
        'manifest': manifest.toJson(),
        'sourceUrl': sourceUrl,
        'installedAt': installedAt.toIso8601String(),
        if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
        'enabled': enabled,
        if (jsCode != null) 'jsCode': jsCode,
        'userConfig': userConfig,
        if (contract != null) 'contract': contract!.toJson(),
      };

  factory InstalledRepo.fromJson(Map<String, dynamic> j) {
    RepoContract? contract;
    final c = j['contract'];
    if (c is Map) {
      try {
        contract = RepoContract.fromStored(Map<String, dynamic>.from(c));
      } catch (_) {}
    }
    return InstalledRepo(
      manifest: RepoManifest.fromJson(
        Map<String, dynamic>.from(j['manifest'] as Map? ?? {}),
        repo: j['manifest']?['repo']?.toString(),
      ),
      sourceUrl: (j['sourceUrl'] ?? '').toString(),
      installedAt: DateTime.tryParse(j['installedAt']?.toString() ?? '') ?? DateTime.now(),
      updatedAt: j['updatedAt'] != null ? DateTime.tryParse(j['updatedAt'].toString()) : null,
      enabled: j['enabled'] != false,
      jsCode: j['jsCode']?.toString(),
      userConfig: Map<String, String>.from(
        (j['userConfig'] as Map? ?? {}).map((k, v) => MapEntry(k.toString(), v.toString())),
      ),
      contract: contract,
    );
  }

  @override
  List<Object?> get props => [manifest.id, sourceUrl, enabled];
}


/// Temporada (series).
class SeasonInfo {
  final int number;
  final String? name;
  final List<EpisodeInfo> episodes;

  SeasonInfo({required this.number, this.name, this.episodes = const []});

  factory SeasonInfo.fromJson(Map<String, dynamic> j) {
    final eps = <EpisodeInfo>[];
    final raw = j['episodes'] ?? j['capitulos'] ?? [];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) eps.add(EpisodeInfo.fromJson(Map<String, dynamic>.from(e)));
      }
    }
    return SeasonInfo(
      number: (j['number'] ?? j['numero'] ?? j['season'] ?? 0) is int
          ? (j['number'] ?? j['numero'] ?? j['season'] ?? 0) as int
          : int.tryParse('${j['number'] ?? j['numero'] ?? j['season'] ?? 0}') ?? 0,
      name: (j['name'] ?? j['nombre'] ?? j['title'])?.toString(),
      episodes: eps,
    );
  }
}

class EpisodeInfo {
  final int number;
  final String id;
  final String? title;
  final String? overview;
  final String? still; // imagen del episodio
  final int? runtime;

  EpisodeInfo({
    required this.number,
    required this.id,
    this.title,
    this.overview,
    this.still,
    this.runtime,
  });

  factory EpisodeInfo.fromJson(Map<String, dynamic> j) {
    final numRaw = (j['number'] ?? j['numero'] ?? j['episode'] ?? 0);
    final n = numRaw is int ? numRaw : int.tryParse('$numRaw') ?? 0;
    return EpisodeInfo(
      number: n,
      id: (j['id'] ?? j['_id'] ?? 'e$n').toString(),
      title: (j['title'] ?? j['titulo'] ?? j['name'])?.toString(),
      overview: (j['overview'] ?? j['description'] ?? j['plot'])?.toString(),
      still: (j['still'] ?? j['image'] ?? j['poster'] ?? j['backdrop'])?.toString(),
      runtime: (j['runtime'] as num?)?.toInt(),
    );
  }
}

/// Item de contenido genérico que devuelve un repo (home rows, search, etc).
class ContentItem {
  final String id;
  final String title;
  final String? poster;
  final String? backdrop;
  final String? logo;
  final String? overview;
  final String type; // movie | series | tv | episode | channel | other
  final double? rating;
  final String? year;
  final List<String> genres;
  final List<SeasonInfo> seasons;
  final int? season; // si es episodio
  final int? episode;
  /// IDs estándar opcionales para meta-búsqueda entre repos (TMDB / IMDb).
  final String? tmdbId;
  final String? imdbId;
  /// Segmentos skip intro/outro a nivel de meta (si el repo los envía en getMeta).
  final StreamSegments? segments;
  final Map<String, dynamic> extra;

  ContentItem({
    required this.id,
    required this.title,
    this.poster,
    this.backdrop,
    this.logo,
    this.overview,
    this.type = 'movie',
    this.rating,
    this.year,
    this.genres = const [],
    this.seasons = const [],
    this.season,
    this.episode,
    this.tmdbId,
    this.imdbId,
    this.segments,
    this.extra = const {},
  });

  bool get isSeries =>
      type == 'series' || type == 'tv' || type == 'show' || seasons.isNotEmpty;

  bool get isChannel =>
      type == 'channel' || type == 'live' || type == 'tvchannel' || type == 'iptv';

  /// Programa en vivo actual (si el repo lo pone en extra['currentProgram']).
  String? get currentProgram {
    final v = extra['currentProgram'] ??
        extra['nowPlaying'] ??
        extra['current_show'] ??
        extra['epg'];
    if (v == null) return null;
    if (v is String) return v.isEmpty ? null : v;
    if (v is Map) {
      return (v['title'] ?? v['name'] ?? v['programa'])?.toString();
    }
    return v.toString();
  }

  factory ContentItem.fromJson(Map<String, dynamic> j) {
    final seasons = <SeasonInfo>[];
    final rawSeasons = j['seasons'] ?? j['temporadas'] ?? [];
    if (rawSeasons is List) {
      for (final s in rawSeasons) {
        if (s is Map) seasons.add(SeasonInfo.fromJson(Map<String, dynamic>.from(s)));
      }
    }
    final genres = <String>[];
    final g = j['genres'] ?? j['genero'] ?? j['genres_list'];
    if (g is List) {
      for (final e in g) {
        if (e is Map) {
          genres.add((e['name'] ?? e['nombre'] ?? '').toString());
        } else {
          genres.add(e.toString());
        }
      }
    } else if (g is String && g.isNotEmpty) {
      genres.addAll(g.split(',').map((e) => e.trim()));
    }

    String? tmdb = (j['tmdbId'] ?? j['tmdb_id'] ?? j['idTmdb'] ?? j['idtmdb'])?.toString();
    String? imdb = (j['imdbId'] ?? j['imdb_id'] ?? j['idImdb'] ?? j['idimdb'])?.toString();
    // También desde ids anidados
    final ids = j['ids'] ?? j['externalIds'] ?? j['external_ids'];
    if (ids is Map) {
      tmdb ??= (ids['tmdb'] ?? ids['tmdbId'])?.toString();
      imdb ??= (ids['imdb'] ?? ids['imdbId'])?.toString();
    }

    StreamSegments? segments;
    final rawSeg = j['segments'] ?? j['skip'] ?? j['markers'];
    if (rawSeg != null) {
      final seg = StreamSegments.fromJson(rawSeg);
      if (seg.hasAny) segments = seg;
    }

    return ContentItem(
      id: (j['id'] ?? j['_id'] ?? '').toString(),
      title: _prettyTitle((j['title'] ?? j['name'] ?? 'Sin título').toString()),
      poster: j['poster']?.toString() ?? j['posterPath']?.toString() ?? j['image']?.toString(),
      backdrop: j['backdrop']?.toString() ?? j['background']?.toString(),
      logo: j['logo']?.toString(),
      overview: j['overview']?.toString() ?? j['description']?.toString() ?? j['plot']?.toString(),
      type: (j['type'] ?? j['media_type'] ?? 'movie').toString(),
      rating: (j['rating'] as num?)?.toDouble() ?? (j['vote_average'] as num?)?.toDouble(),
      year: j['year']?.toString() ?? j['releaseDate']?.toString()?.split('-').first,
      genres: genres.where((e) => e.isNotEmpty).toList(),
      seasons: seasons,
      season: (j['season'] as num?)?.toInt() ?? (j['temporada'] as num?)?.toInt(),
      episode: (j['episode'] as num?)?.toInt() ?? (j['capitulo'] as num?)?.toInt(),
      tmdbId: (tmdb != null && tmdb.isNotEmpty) ? tmdb : null,
      imdbId: (imdb != null && imdb.isNotEmpty) ? imdb : null,
      segments: segments,
      extra: Map<String, dynamic>.from(j),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        if (poster != null) 'poster': poster,
        if (backdrop != null) 'backdrop': backdrop,
        if (logo != null) 'logo': logo,
        if (overview != null) 'overview': overview,
        'type': type,
        if (rating != null) 'rating': rating,
        if (year != null) 'year': year,
        if (genres.isNotEmpty) 'genres': genres,
        if (season != null) 'season': season,
        if (episode != null) 'episode': episode,
        if (tmdbId != null) 'tmdbId': tmdbId,
        if (imdbId != null) 'imdbId': imdbId,
        if (segments != null) 'segments': segments!.toJson(),
      };
}

/// Tipos de bloque en el home del repo.
/// - hero: slider principal
/// - row / secondary: slider secundario (posters o backdrops)
/// - banner: un solo banner clickeable (promo del creador)
/// - catalog: slider de catálogos que abre la página de catálogos
enum HomeRowType { hero, row, banner, catalog }

/// Fila / bloque del home de un repo.
class HomeRow {
  final String id;
  final String title;
  final HomeRowType type;
  final List<ContentItem> items;
  /// Banner: imagen única (o se usa items.first.backdrop/poster)
  final String? bannerImage;
  final String? bannerUrl; // deep link opcional
  final String? catalogId; // para type=catalog
  /// poster | backdrop
  final String imageStyle;

  HomeRow({
    required this.id,
    required this.title,
    this.type = HomeRowType.row,
    required this.items,
    this.bannerImage,
    this.bannerUrl,
    this.catalogId,
    this.imageStyle = 'poster',
  });

  factory HomeRow.fromJson(Map<String, dynamic> j) {
    final list = (j['items'] ?? j['metas'] ?? j['results'] ?? j['catalogs'] ?? []) as List? ?? [];
    final typeRaw = (j['type'] ?? j['rowType'] ?? j['layout'] ?? 'row').toString().toLowerCase();
    HomeRowType type;
    switch (typeRaw) {
      case 'hero':
      case 'main':
      case 'principal':
      case 'featured':
        type = HomeRowType.hero;
        break;
      case 'banner':
      case 'promo':
      case 'ad':
        type = HomeRowType.banner;
        break;
      case 'catalog':
      case 'catalogs':
      case 'catalogo':
      case 'catalogos':
        type = HomeRowType.catalog;
        break;
      default:
        type = HomeRowType.row;
    }
    // Heurística por id/title si no vino type
    final id = (j['id'] ?? j['title'] ?? '').toString().toLowerCase();
    if (type == HomeRowType.row) {
      if (id.contains('hero') || id.contains('destacado') || id == 'top') type = HomeRowType.hero;
      if (id.contains('banner')) type = HomeRowType.banner;
      if (id.contains('catalog')) type = HomeRowType.catalog;
    }
    final style = (j['imageStyle'] ?? j['style'] ?? j['itemType'] ?? 'poster').toString();
    return HomeRow(
      id: (j['id'] ?? j['title'] ?? '').toString(),
      title: (j['title'] ?? j['name'] ?? 'Fila').toString(),
      type: type,
      items: list
          .whereType<Map>()
          .map((e) => ContentItem.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      bannerImage: (j['banner'] ?? j['image'] ?? j['bannerImage'])?.toString(),
      bannerUrl: (j['url'] ?? j['link'] ?? j['bannerUrl'])?.toString(),
      catalogId: (j['catalogId'] ?? j['catalog_id'])?.toString(),
      imageStyle: style.contains('back') ? 'backdrop' : 'poster',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'type': type.name,
        'items': items.map((e) => e.toJson()).toList(),
        if (bannerImage != null) 'bannerImage': bannerImage,
        if (bannerUrl != null) 'bannerUrl': bannerUrl,
        if (catalogId != null) 'catalogId': catalogId,
        'imageStyle': imageStyle,
      };
}

/// Catálogo (colección) que el repo puede exponer.
class CatalogInfo {
  final String id;
  final String title;
  final String? poster;
  final String? backdrop;
  final String? description;

  CatalogInfo({
    required this.id,
    required this.title,
    this.poster,
    this.backdrop,
    this.description,
  });

  factory CatalogInfo.fromJson(Map<String, dynamic> j) => CatalogInfo(
        id: (j['id'] ?? j['_id'] ?? '').toString(),
        title: (j['title'] ?? j['name'] ?? 'Catálogo').toString(),
        poster: (j['poster'] ?? j['image'] ?? j['banner'] ?? j['cover'])?.toString(),
        backdrop: (j['backdrop'] ?? j['background'] ?? j['banner'] ?? j['image'])?.toString(),
        description: (j['description'] ?? j['overview'])?.toString(),
      );

  ContentItem toContentItem() => ContentItem(
        id: id,
        title: title,
        poster: poster,
        backdrop: backdrop,
        overview: description,
        type: 'catalog',
      );
}
