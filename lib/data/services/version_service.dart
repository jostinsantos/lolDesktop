import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:apk_sideload/install_apk.dart';

/// Verifica actualizaciones leyendo el JSON público en GitHub.
///
/// Fuente:
/// https://raw.githubusercontent.com/LOLapptv/lollite/main/lollite.json
class VersionService {
  VersionService._();
  static final VersionService instance = VersionService._();

  // ============================================
  // CONFIGURA AQUÍ LA VERSIÓN ACTUAL DE TU APP
  // ============================================
  static const String currentVersionName = '0.1.2'; // version (debe coincidir con pubspec / build)
  static const String currentParche = '014'; // parche local (comparar con remoto lollite.json)
  static const String appId = 'lollitedes';

  static const String manifestUrl =
      'https://raw.githubusercontent.com/LOLapptv/lollite/main/lollitedes.json';

  /// Obtiene la entrada de esta app desde GitHub.
  Future<AppVersionInfo?> fetchRemote() async {
    try {
      final res = await http
          .get(
            Uri.parse(manifestUrl),
            headers: const {
              'Accept': 'application/json',
              'User-Agent': 'LolliteApp/1.0',
              'Cache-Control': 'no-cache',
            },
          )
          .timeout(const Duration(seconds: 12));

      if (res.statusCode != 200) {
        debugPrint('[Version] HTTP ${res.statusCode}');
        return null;
      }

      final jsonData = json.decode(res.body);
      if (jsonData is! Map) return null;
      final apps = jsonData['apps'];
      if (apps is! List || apps.isEmpty) return null;

      Map<String, dynamic>? match;
      for (final e in apps) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        final id = (m['app'] ?? '').toString().toLowerCase();
        if (id == appId.toLowerCase() ||
            id == 'lollite-desktop' ||
            id == 'lollitedesktop' ||
            id == 'desktop') {
          match = m;
          break;
        }
      }
      // Fallback: primera entrada del JSON
      match ??= Map<String, dynamic>.from(apps.first as Map);
      return AppVersionInfo.fromJson(match);
    } catch (e) {
      debugPrint('[Version] fetch error: $e');
      return null;
    }
  }

  /// Compara nombres tipo "1.0.3" vs "1.0.2".
  /// >0 si a es más nueva, <0 si b es más nueva, 0 si iguales.
  static int compareVersionNames(String a, String b) {
    List<int> parts(String v) {
      final cleaned = v.trim();
      final only = RegExp(r'[0-9]+(?:\.[0-9]+)*').firstMatch(cleaned);
      final s = only?.group(0) ?? cleaned;
      return s.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    }

    final pa = parts(a);
    final pb = parts(b);
    final n = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < n; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  /// Compara parches tipo "2024.11.20" (orden lexicográfico tras normalizar).
  static int compareParche(String a, String b) {
    String norm(String v) {
      final digits = v.trim().replaceAll(RegExp(r'[^0-9.]'), '');
      return digits;
    }

    final na = norm(a);
    final nb = norm(b);
    // Primero por semver numérico de segmentos
    final cmp = compareVersionNames(na, nb);
    if (cmp != 0) return cmp;
    return na.compareTo(nb);
  }

  /// [notifyPatches]: si false, solo avisa por cambio de VERSIÓN (no por parche).
  Future<UpdateStatus> checkForUpdate({bool notifyPatches = true}) async {
    final latest = await fetchRemote();
    if (latest == null) {
      return UpdateStatus(
        requiresUpdate: false,
        hasVersionUpdate: false,
        hasPatchUpdate: false,
        latestVersion: null,
        message: 'No se pudo obtener información de actualización',
      );
    }

    final remoteName = latest.version.trim();
    final remoteParche = latest.parche.trim();

    // Versión siempre se notifica si el remoto es más nuevo
    final hasVersionUpdate =
        remoteName.isNotEmpty && compareVersionNames(remoteName, currentVersionName) > 0;

    final hasPatchUpdate = remoteParche.isNotEmpty &&
        compareParche(remoteParche, currentParche) > 0;

    // Solo VERSION siempre; PARCHES solo si el usuario tiene notificaciones activas
    final needsUpdate =
        hasVersionUpdate || (notifyPatches && hasPatchUpdate);

    String message;
    if (needsUpdate) {
      final parts = <String>[];
      if (hasVersionUpdate) {
        parts.add('versión ${latest.version}');
      }
      if (notifyPatches && hasPatchUpdate) {
        parts.add('parche ${latest.parche}');
      }
      message = 'Actualización disponible: ${parts.join(' · ')}';
    } else {
      message = 'Tu aplicación está actualizada';
    }

    return UpdateStatus(
      requiresUpdate: needsUpdate,
      hasVersionUpdate: hasVersionUpdate,
      hasPatchUpdate: hasPatchUpdate,
      latestVersion: latest,
      message: message,
    );
  }

  // ── Caché de última descarga (ABI + versión + URL) ──
  static const _kLastAbi = 'update_last_abi';
  static const _kLastVersion = 'update_last_version';
  static const _kLastParche = 'update_last_parche';
  static const _kLastUrl = 'update_last_url';
  static const _kLastAt = 'update_last_at';

  Future<void> saveLastDownload({
    required String abi,
    required String version,
    required String parche,
    required String url,
  }) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kLastAbi, abi);
      await p.setString(_kLastVersion, version);
      await p.setString(_kLastParche, parche);
      await p.setString(_kLastUrl, url);
      await p.setString(_kLastAt, DateTime.now().toIso8601String());
    } catch (e) {
      debugPrint('[Version] saveLastDownload: $e');
    }
  }

  Future<Map<String, String>?> loadLastDownload() async {
    try {
      final p = await SharedPreferences.getInstance();
      final abi = p.getString(_kLastAbi);
      final ver = p.getString(_kLastVersion);
      if (abi == null || ver == null) return null;
      return {
        'abi': abi,
        'version': ver,
        'parche': p.getString(_kLastParche) ?? '',
        'url': p.getString(_kLastUrl) ?? '',
        'at': p.getString(_kLastAt) ?? '',
      };
    } catch (_) {
      return null;
    }
  }

  /// ABI forzada para TV / Android TV (cache): solo armeabi.
  static const String tvForcedAbi = 'armeabi';

  /// Lista de ABIs disponibles en el remoto (con URL no vacía).
  List<({String id, String label, String url})> availableAbis(AppVersionInfo info) {
    final out = <({String id, String label, String url})>[];
    void add(String id, String label, String? url) {
      if (url != null && url.isNotEmpty) {
        out.add((id: id, label: label, url: url));
      }
    }
    add('windows', 'Windows (desktop)', info.urlWindows);
    add('arm64', 'ARM64 (recomendado móviles)', info.urlApkArm64);
    add('armeabi', 'ARMeabi (TV / dispositivos antiguos)', info.urlApkArmeabi);
    add('x86', 'x86 (emuladores)', info.urlApkX86);
    add('universal', 'Universal (todas las arquitecturas)', info.urlApkUniversal);
    return out;
  }

  /// Elige la mejor URL de APK según ABI preferida.
  String? resolveApkUrl(AppVersionInfo info, {String? preferredAbi}) {
    final order = <String>[
      if (preferredAbi != null) preferredAbi,
      'arm64',
      'universal',
      'armeabi',
      'x86',
    ];
    final seen = <String>{};
    for (final abi in order) {
      if (!seen.add(abi)) continue;
      final u = info.urlForAbi(abi);
      if (u != null && u.isNotEmpty) return u;
    }
    return null;
  }

  /// Descarga el APK a caché temporal. [onProgress] 0.0–1.0.
  /// Valida que el archivo sea un ZIP/APK real (cabecera PK) y no un HTML de error.
  Future<File?> downloadApk(
    String url, {
    void Function(double progress)? onProgress,
  }) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/lollite_update.apk');
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }

      final client = http.Client();
      try {
        final req = http.Request('GET', Uri.parse(url));
        req.headers['User-Agent'] = 'LolliteApp/1.0';
        req.headers['Accept'] = '*/*';
        final streamed =
            await client.send(req).timeout(const Duration(minutes: 8));
        if (streamed.statusCode != 200) {
          debugPrint('[Version] download HTTP ${streamed.statusCode} url=$url');
          return null;
        }
        final total = streamed.contentLength ?? 0;
        final sink = file.openWrite();
        var received = 0;
        await for (final chunk in streamed.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0 && onProgress != null) {
            onProgress((received / total).clamp(0.0, 1.0));
          }
        }
        await sink.flush();
        await sink.close();
        if (onProgress != null) onProgress(1.0);

        // Sanity: APK es un ZIP → empieza por "PK"
        final len = await file.length();
        if (len < 1024 * 50) {
          debugPrint('[Version] download too small: $len bytes');
          try {
            await file.delete();
          } catch (_) {}
          return null;
        }
        final raf = await file.open();
        final header = await raf.read(4);
        await raf.close();
        final isZip = header.length >= 2 && header[0] == 0x50 && header[1] == 0x4B;
        if (!isZip) {
          debugPrint('[Version] download is not an APK/ZIP (bad header)');
          try {
            await file.delete();
          } catch (_) {}
          return null;
        }
        debugPrint('[Version] download OK ${len ~/ (1024 * 1024)} MB → ${file.path}');
        return file;
      } finally {
        client.close();
      }
    } catch (e) {
      debugPrint('[Version] download error: $e');
      return null;
    }
  }

  /// Descarga paquete de actualización desktop (zip o exe).
  Future<File?> downloadDesktopPackage(
    String url, {
    void Function(double progress)? onProgress,
  }) async {
    try {
      final dir = await getTemporaryDirectory();
      final lower = url.toLowerCase();
      final ext = lower.contains('.zip')
          ? 'zip'
          : (lower.contains('.exe') ? 'exe' : 'bin');
      final file = File('${dir.path}/lollitedes_update.$ext');
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }

      final client = http.Client();
      try {
        final req = http.Request('GET', Uri.parse(url));
        req.headers['User-Agent'] = 'LOLLiteDesktop/1.0';
        req.headers['Accept'] = '*/*';
        final streamed =
            await client.send(req).timeout(const Duration(minutes: 30));
        if (streamed.statusCode != 200) {
          debugPrint('[Version] desktop download HTTP ${streamed.statusCode}');
          return null;
        }
        final total = streamed.contentLength ?? 0;
        final sink = file.openWrite();
        var received = 0;
        await for (final chunk in streamed.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0 && onProgress != null) {
            onProgress((received / total).clamp(0.0, 1.0));
          }
        }
        await sink.flush();
        await sink.close();
        if (onProgress != null) onProgress(1.0);

        final len = await file.length();
        if (len < 1024 * 20) {
          debugPrint('[Version] desktop download too small: $len');
          try {
            await file.delete();
          } catch (_) {}
          return null;
        }
        debugPrint(
            '[Version] desktop download OK ${len ~/ (1024 * 1024)} MB → ${file.path}');
        return file;
      } finally {
        client.close();
      }
    } catch (e) {
      debugPrint('[Version] desktop download error: $e');
      return null;
    }
  }

  /// Carpeta de instalación (donde está el .exe en ejecución).
  String? get installDirectory {
    try {
      final exe = Platform.resolvedExecutable;
      return File(exe).parent.path;
    } catch (_) {
      return null;
    }
  }

  /// Carpeta estable portable: %LOCALAPPDATA%\LOLLite
  Future<String> portableInstallDirectory() async {
    final local = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['USERPROFILE'] ??
        (await getTemporaryDirectory()).path;
    final dir = Directory('$local${Platform.pathSeparator}LOLLite');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  /// Ejecutándose desde build\windows\...\runner\Debug|Release
  bool get isRunningFromFlutterBuild {
    final d = (installDirectory ?? '').toLowerCase().replaceAll('/', '\\');
    return d.contains(r'\build\windows\') ||
        d.endsWith(r'\runner\debug') ||
        d.endsWith(r'\runner\release') ||
        d.endsWith(r'\runner\profile');
  }

  /// Acceso directo en el Escritorio.
  Future<bool> createDesktopShortcut({String? targetExe}) async {
    lastInstallError = null;
    if (!Platform.isWindows) {
      lastInstallError = 'Solo Windows';
      return false;
    }
    try {
      final exe = targetExe ?? Platform.resolvedExecutable;
      final workDir = File(exe).parent.path;
      final user = Platform.environment['USERPROFILE'];
      if (user == null || user.isEmpty) {
        lastInstallError = 'No se pudo localizar el Escritorio';
        return false;
      }
      final linkPath =
          '$user${Platform.pathSeparator}Desktop${Platform.pathSeparator}LOL Lite.lnk';
      final ps = '''
\$ws = New-Object -ComObject WScript.Shell
\$sc = \$ws.CreateShortcut('${linkPath.replaceAll("'", "''")}')
\$sc.TargetPath = '${exe.replaceAll("'", "''")}'
\$sc.WorkingDirectory = '${workDir.replaceAll("'", "''")}'
\$sc.Description = 'LOL Lite Desktop'
\$sc.Save()
''';
      final r = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          ps,
        ],
      ).timeout(const Duration(seconds: 15));
      if (r.exitCode != 0) {
        lastInstallError =
            '${r.stderr}'.trim().isNotEmpty ? '${r.stderr}'.trim() : 'Error creando acceso directo';
        return false;
      }
      return true;
    } catch (e) {
      lastInstallError = e.toString();
      return false;
    }
  }


  static const _kUpdatePending = 'update_just_applied';
  static const _kUpdatePendingVer = 'update_just_applied_version';

  /// Marca que se va a aplicar una actualización (mensaje al reabrir).
  Future<void> markUpdatePending({String? versionLabel}) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kUpdatePending, true);
      if (versionLabel != null && versionLabel.isNotEmpty) {
        await p.setString(_kUpdatePendingVer, versionLabel);
      }
    } catch (e) {
      debugPrint('[Version] markUpdatePending: $e');
    }
  }

  /// Si hubo update, limpia la marca y devuelve el texto de versión (o '').
  Future<String?> consumeUpdateSuccessMessage() async {
    try {
      final p = await SharedPreferences.getInstance();
      final pending = p.getBool(_kUpdatePending) ?? false;
      if (!pending) return null;
      await p.setBool(_kUpdatePending, false);
      final ver = p.getString(_kUpdatePendingVer) ?? '';
      await p.remove(_kUpdatePendingVer);
      return ver;
    } catch (_) {
      return null;
    }
  }

  /// Actualización in-place para instalación Inno / portable.
  ///
  /// Flujo:
  /// 1. Extrae el ZIP a carpeta temporal.
  /// 2. Lanza un script DETACHED que:
  ///    - Espera a que este proceso muera.
  ///    - Mata otros lollite.
  ///    - Copia TODO sobre la carpeta de instalación del usuario
  ///      (%LOCALAPPDATA%\LOLLite o donde esté el .exe actual).
  ///    - Actualiza accesos directos y registro "Iniciar con Windows".
  ///    - Reinicia lollite.exe.
  ///
  /// El ZIP debe contener lollite.exe + data\ (y dlls) en la raíz
  /// o dentro de UNA sola subcarpeta.
  Future<bool> applyDesktopUpdate(File package) async {
    lastInstallError = null;
    if (!Platform.isWindows) {
      lastInstallError = 'Auto-actualización desktop solo en Windows';
      return false;
    }

    final path = package.path;
    final lower = path.toLowerCase();
    final myPid = pid;
    final tmp = await getTemporaryDirectory();
    final logPath =
        '${tmp.path}${Platform.pathSeparator}lollitedes_update.log';

    // Instalador .exe suelto → lanzarlo y salir
    if (lower.endsWith('.exe')) {
      try {
        await File(logPath).writeAsString('Launching installer: $path\n');
        await Process.start(
          path,
          const <String>[],
          mode: ProcessStartMode.detached,
        );
        return true;
      } catch (e) {
        lastInstallError = 'No se pudo abrir el instalador: $e';
        return false;
      }
    }

    if (!lower.endsWith('.zip')) {
      lastInstallError =
          'Formato no soportado. Usa un .zip (lollite.exe + data/).';
      return false;
    }

    try {
      // Destino = carpeta real de instalación del usuario
      final String targetDir;
      if (isRunningFromFlutterBuild) {
        targetDir = await portableInstallDirectory();
      } else {
        targetDir = installDirectory ?? await portableInstallDirectory();
      }
      debugPrint('[Version] update targetDir=$targetDir');

      // Extraer ZIP
      final extractDir = Directory(
          '${tmp.path}${Platform.pathSeparator}lollitedes_extract');
      if (await extractDir.exists()) {
        try {
          await extractDir.delete(recursive: true);
        } catch (_) {}
      }
      await extractDir.create(recursive: true);

      var extracted = false;
      try {
        final r = await Process.run('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          "Expand-Archive -LiteralPath '${path.replaceAll("'", "''")}' "
              "-DestinationPath '${extractDir.path.replaceAll("'", "''")}' -Force",
        ]).timeout(const Duration(minutes: 15));
        extracted = r.exitCode == 0;
        if (!extracted) {
          debugPrint('[Version] Expand-Archive stderr: ${r.stderr}');
        }
      } catch (e) {
        debugPrint('[Version] Expand-Archive: $e');
      }
      if (!extracted) {
        try {
          final r = await Process.run(
            'tar',
            ['-xf', path, '-C', extractDir.path],
          ).timeout(const Duration(minutes: 15));
          extracted = r.exitCode == 0;
        } catch (e) {
          debugPrint('[Version] tar: $e');
        }
      }
      if (!extracted) {
        lastInstallError = 'No se pudo extraer el ZIP de actualización';
        return false;
      }

      // Localizar carpeta que contiene el .exe
      Directory sourceDir = extractDir;
      final kids = extractDir
          .listSync()
          .where((e) {
            final n = e.uri.pathSegments.isNotEmpty
                ? e.uri.pathSegments.last.toLowerCase()
                : '';
            return n != '__macosx' && n != '.ds_store';
          })
          .toList();
      if (kids.length == 1 && kids.first is Directory) {
        sourceDir = kids.first as Directory;
      }
      bool hasExe(Directory d) => d.listSync().any(
            (e) => e is File && e.path.toLowerCase().endsWith('.exe'),
          );
      if (!hasExe(sourceDir)) {
        for (final k in sourceDir.listSync()) {
          if (k is Directory && hasExe(k)) {
            sourceDir = k;
            break;
          }
        }
      }
      if (!hasExe(sourceDir)) {
        lastInstallError =
            'El ZIP no contiene ningún .exe (¿empaquetado mal?)';
        return false;
      }

      final src = sourceDir.path;
      final targetExe = '$targetDir${Platform.pathSeparator}lollite.exe';
      final batPath =
          '${tmp.path}${Platform.pathSeparator}lollitedes_apply_update.cmd';
      final ps1Path =
          '${tmp.path}${Platform.pathSeparator}lollitedes_apply_update.ps1';

      // Script PowerShell (rutas con here-strings para espacios)
      final psBody = '''
\$ErrorActionPreference = 'Continue'
\$APPDIR = @'
$targetDir
'@
\$SRC = @'
$src
'@
\$EXE = @'
$targetExe
'@
\$OLDPID = $myPid
\$LOG = @'
$logPath
'@
\$DESKTOP = [Environment]::GetFolderPath('Desktop')
\$LINK = Join-Path \$DESKTOP 'LOL Lite.lnk'
\$STARTMENU = Join-Path ([Environment]::GetFolderPath('Programs')) 'LOL Lite.lnk'

function Log(\$m) {
  try {
    Add-Content -LiteralPath \$LOG -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), \$m) -ErrorAction SilentlyContinue
  } catch {}
}

try { "" | Set-Content -LiteralPath \$LOG -Encoding UTF8 } catch {}
Log "=== LOL Lite UPDATE ==="
Log "APPDIR=\$APPDIR"
Log "SRC=\$SRC"
Log "EXE=\$EXE"
Log "OLDPID=\$OLDPID"

for (\$i = 0; \$i -lt 40; \$i++) {
  \$pr = Get-Process -Id \$OLDPID -ErrorAction SilentlyContinue
  if (-not \$pr) { Log "PID \$OLDPID terminado"; break }
  Start-Sleep -Milliseconds 500
}

Get-Process -Name 'lollite' -ErrorAction SilentlyContinue | ForEach-Object {
  Log ("Kill lollite PID=" + \$_.Id)
  Stop-Process -Id \$_.Id -Force -ErrorAction SilentlyContinue
}
Get-Process -ErrorAction SilentlyContinue | Where-Object {
  \$_.Path -and \$_.Path.StartsWith(\$APPDIR, [StringComparison]::OrdinalIgnoreCase)
} | ForEach-Object {
  Log ("Kill related " + \$_.ProcessName + " PID=" + \$_.Id)
  Stop-Process -Id \$_.Id -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 2

if (-not (Test-Path -LiteralPath \$APPDIR)) {
  New-Item -ItemType Directory -Path \$APPDIR -Force | Out-Null
  Log "Creado APPDIR"
}

Log "Copiando..."
\$copied = \$false
if (Get-Command robocopy -ErrorAction SilentlyContinue) {
  & robocopy \$SRC \$APPDIR /E /IS /IT /R:10 /W:2 /NFL /NDL /NJH /NJS /XD __MACOSX
  \$rc = \$LASTEXITCODE
  Log "robocopy exit=\$rc"
  if (\$rc -lt 8) { \$copied = \$true }
}
if (-not \$copied) {
  try {
    Copy-Item -Path (Join-Path \$SRC '*') -Destination \$APPDIR -Recurse -Force -ErrorAction Stop
    \$copied = \$true
    Log "Copy-Item OK"
  } catch {
    Log ("Copy-Item FAIL: " + \$_.Exception.Message)
  }
}
if (-not \$copied) {
  Log "ERROR: no se pudo copiar"
  exit 1
}

if (-not (Test-Path -LiteralPath \$EXE)) {
  \$found = Get-ChildItem -LiteralPath \$APPDIR -Filter 'lollite.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not \$found) {
    \$found = Get-ChildItem -LiteralPath \$APPDIR -Filter '*.exe' -File -ErrorAction SilentlyContinue |
      Where-Object { \$_.Name -notmatch 'flutter|crashpad|helper|unins|installer|vcredist' } |
      Select-Object -First 1
  }
  if (\$found) {
    \$EXE = \$found.FullName
    Log "Exe resuelto: \$EXE"
  }
}
if (-not (Test-Path -LiteralPath \$EXE)) {
  Log "ERROR: no hay lollite.exe en \$APPDIR"
  exit 1
}

try {
  \$regPath = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'
  \$prop = Get-ItemProperty -Path \$regPath -Name 'LolLiteDesktop' -ErrorAction SilentlyContinue
  if (\$null -ne \$prop) {
    Set-ItemProperty -Path \$regPath -Name 'LolLiteDesktop' -Value ('"' + \$EXE + '"')
    Log "Registro Run actualizado"
  }
} catch { Log ("Registry: " + \$_.Exception.Message) }

foreach (\$linkPath in @(\$LINK, \$STARTMENU)) {
  try {
    \$ws = New-Object -ComObject WScript.Shell
    \$sc = \$ws.CreateShortcut(\$linkPath)
    \$sc.TargetPath = \$EXE
    \$sc.WorkingDirectory = \$APPDIR
    \$sc.Description = 'LOL Lite'
    if (Test-Path -LiteralPath \$EXE) { \$sc.IconLocation = \$EXE + ',0' }
    \$sc.Save()
    Log ("Shortcut OK: " + \$linkPath)
  } catch { Log ("Shortcut fail: " + \$_.Exception.Message) }
}

Start-Sleep -Seconds 1
Log "Start \$EXE"
try {
  \$p = Start-Process -FilePath \$EXE -WorkingDirectory \$APPDIR -PassThru
  if (\$p) { Log ("Iniciado PID=" + \$p.Id) } else { Log "Start sin PID" }
} catch {
  Log ("Start FAIL: " + \$_.Exception.Message)
  exit 1
}
Log "OK"
exit 0
''';

      await File(ps1Path).writeAsString(psBody, flush: true);

      final cmdBody = '''
@echo off
start "" /b powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "$ps1Path"
''';
      await File(batPath).writeAsString(cmdBody, flush: true);

      debugPrint(
          '[Version] update script → $ps1Path log=$logPath target=$targetDir');

      await Process.start(
        'cmd.exe',
        ['/c', batPath],
        mode: ProcessStartMode.detached,
        workingDirectory: tmp.path,
        runInShell: false,
      );

      await Future<void>.delayed(const Duration(milliseconds: 400));
      return true;
    } catch (e) {
      lastInstallError = 'Error aplicando actualización: $e';
      debugPrint('[Version] applyDesktopUpdate: $e');
      return false;
    }
  }

  /// URL preferida para desktop Windows.
  String? resolveDesktopUrl(AppVersionInfo info) {
    final d = info.bestDesktopUrl;
    if (d != null && d.isNotEmpty) return d;
    return resolveApkUrl(info, preferredAbi: 'windows') ??
        resolveApkUrl(info, preferredAbi: 'universal');
  }

  /// Último error de instalación (para mostrar al usuario).
  String? lastInstallError;

  /// Instala un APK local con apk_sideload (solo Android).
  /// Requiere FileProvider con authority: ${applicationId}.install_apk.fileprovider
  Future<bool> installApkFile(String path) async {
    lastInstallError = null;
    if (!Platform.isAndroid) {
      lastInstallError = 'Solo disponible en Android';
      return false;
    }
    try {
      final f = File(path);
      if (!await f.exists()) {
        lastInstallError = 'El APK no existe en $path';
        return false;
      }
      final len = await f.length();
      if (len < 1024 * 50) {
        lastInstallError = 'APK incompleto ($len bytes)';
        return false;
      }
      await InstallApk().installApk(path);
      return true;
    } catch (e) {
      lastInstallError = e.toString();
      debugPrint('[Version] install error: $e');
      return false;
    }
  }
}

class AppVersionInfo {
  final String app;
  final String version;
  final String parche;
  final String? urlApkArm64;
  final String? urlApkArmeabi;
  final String? urlApkX86;
  final String? urlApkUniversal;
  /// Windows desktop (exe / zip / installer)
  final String? urlWindows;
  final List<String> novedades;

  AppVersionInfo({
    required this.app,
    required this.version,
    required this.parche,
    this.urlApkArm64,
    this.urlApkArmeabi,
    this.urlApkX86,
    this.urlApkUniversal,
    this.urlWindows,
    this.novedades = const [],
  });

  factory AppVersionInfo.fromJson(Map<String, dynamic> j) {
    String? opt(dynamic v) {
      final s = v?.toString().trim();
      return (s != null && s.isNotEmpty) ? s : null;
    }

    final urls = j['paquete_url'];
    Map<String, dynamic> u = {};
    if (urls is Map) {
      u = Map<String, dynamic>.from(urls);
    }

    final nov = <String>[];
    final rawNov = j['novedades'];
    if (rawNov is List) {
      for (final e in rawNov) {
        final s = e?.toString().trim();
        if (s != null && s.isNotEmpty) nov.add(s);
      }
    } else if (rawNov is String && rawNov.trim().isNotEmpty) {
      nov.addAll(rawNov.split(RegExp(r'[\n;|]')).map((e) => e.trim()).where((e) => e.isNotEmpty));
    }

    return AppVersionInfo(
      app: j['app']?.toString() ?? '',
      version: j['version']?.toString() ?? '',
      parche: j['parche']?.toString() ?? '',
      urlApkArm64: opt(u['url_apk_arm64']),
      urlApkArmeabi: opt(u['url_apk_armeabi']),
      urlApkX86: opt(u['url_apk_x86']),
      urlApkUniversal: opt(u['url_apk_universal']),
      urlWindows: opt(u['url_windows'] ??
          u['url_exe'] ??
          u['url_desktop'] ??
          u['url_zip'] ??
          j['url_windows'] ??
          j['url_exe'] ??
          j['url_desktop']),
      novedades: nov,
    );
  }

  String? urlForAbi(String abi) {
    switch (abi) {
      case 'arm64':
        return urlApkArm64;
      case 'armeabi':
        return urlApkArmeabi;
      case 'x86':
        return urlApkX86;
      case 'universal':
        return urlApkUniversal;
      case 'windows':
      case 'desktop':
      case 'exe':
        return urlWindows;
      default:
        return urlWindows ?? urlApkUniversal;
    }
  }

  /// Mejor URL para desktop Windows.
  String? get bestDesktopUrl =>
      (urlWindows != null && urlWindows!.isNotEmpty) ? urlWindows : urlApkUniversal;
}

class UpdateStatus {
  final bool requiresUpdate;
  final bool hasVersionUpdate;
  final bool hasPatchUpdate;
  final AppVersionInfo? latestVersion;
  final String message;

  UpdateStatus({
    required this.requiresUpdate,
    required this.hasVersionUpdate,
    required this.hasPatchUpdate,
    required this.latestVersion,
    required this.message,
  });
}