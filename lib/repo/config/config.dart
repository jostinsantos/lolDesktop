import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../data/models/repo_manifest.dart';
import '../../../data/services/repo_manager.dart';
import '../../../data/services/content_cache.dart';
import '../../../data/services/js_runtime.dart';

const _card = Color(0xFF161A22);
const _border = Color(0xFF1E2430);
const _accent = Color(0xFFE50914);

/// Config del repo — muestra configFields del manifest (igual que TV).
class RepoConfigPage extends StatefulWidget {
  final InstalledRepo repo;
  const RepoConfigPage({super.key, required this.repo});

  @override
  State<RepoConfigPage> createState() => _RepoConfigPageState();
}

class _RepoConfigPageState extends State<RepoConfigPage> {
  late Map<String, TextEditingController> _controllers;
  late Map<String, String> _selectValues;
  late Map<String, Set<String>> _multiValues;
  late Map<String, bool> _boolValues;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controllers = {};
    _selectValues = {};
    _multiValues = {};
    _boolValues = {};
    for (final f in widget.repo.manifest.configFields) {
      final saved = widget.repo.userConfig[f.key] ?? f.defaultValue ?? '';
      if (f.isMulti) {
        _multiValues[f.key] = RepoConfigField.parseMulti(saved);
      } else if (f.isBool) {
        final v = saved.toLowerCase();
        _boolValues[f.key] = v == '1' || v == 'true' || v == 'yes' || v == 'on';
      } else if (f.isSelect || f.isColor) {
        _selectValues[f.key] = saved;
        if (f.isColor) {
          _controllers[f.key] = TextEditingController(text: saved);
        }
      } else {
        _controllers[f.key] = TextEditingController(text: saved);
      }
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, String> _collect() {
    final map = <String, String>{};
    _controllers.forEach((k, c) => map[k] = c.text.trim());
    _selectValues.forEach((k, v) => map[k] = v);
    _boolValues.forEach((k, v) => map[k] = v ? 'true' : 'false');
    _multiValues.forEach((k, v) => map[k] = RepoConfigField.encodeMulti(v));
    return map;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final id = widget.repo.manifest.id;
    final mgr = context.read<RepoManager>();
    final config = _collect();
    try {
      await mgr.saveUserConfig(id, config);
      final repo = mgr.getById(id) ?? widget.repo;
      try {
        final code = repo.jsCode;
        if (code != null && code.trim().isNotEmpty) {
          await JsAddonRuntime.instance.loadAddonCode(id, code);
          await JsAddonRuntime.instance.setConfig(id, config);
        }
      } catch (_) {}
      try {
        await ContentCache.instance.clearRepo(id);
      } catch (_) {}
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Configuración guardada'),
          backgroundColor: _accent,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mgr = context.watch<RepoManager>();
    final m = widget.repo.manifest;
    final fields = m.configFields;
    final enabled = (mgr.getById(m.id) ?? widget.repo).enabled;

    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 48),
      children: [
        Text('Ajustes de ${m.name}',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
        const SizedBox(height: 20),

        // Enable / version / uninstall
        Container(
          decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(14), border: Border.all(color: _border)),
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('Repositorio activado', style: TextStyle(color: Colors.white)),
                value: enabled,
                activeColor: _accent,
                onChanged: (v) => mgr.setEnabled(m.id, v),
              ),
              const Divider(color: _border, height: 1),
              ListTile(
                title: const Text('Versión', style: TextStyle(color: Colors.white)),
                subtitle: Text('v${m.version}', style: const TextStyle(color: Colors.white54, fontSize: 13)),
              ),
              if (m.author.isNotEmpty)
                ListTile(
                  title: const Text('Autor', style: TextStyle(color: Colors.white)),
                  subtitle: Text(m.author, style: const TextStyle(color: Colors.white54, fontSize: 13)),
                ),
            ],
          ),
        ),

        // Config fields del repo
        if (fields.isNotEmpty) ...[
          const SizedBox(height: 24),
          const Text('Configuración del repositorio',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(14), border: Border.all(color: _border)),
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                for (var i = 0; i < fields.length; i++) ...[
                  if (i > 0) const Divider(color: _border, height: 24),
                  _buildField(fields[i]),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    style: FilledButton.styleFrom(backgroundColor: _accent, padding: const EdgeInsets.symmetric(vertical: 14)),
                    child: _saving
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('Guardar configuración'),
                  ),
                ),
              ],
            ),
          ),
        ] else ...[
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(14), border: Border.all(color: _border)),
            child: const Text(
              'Este repositorio no define campos de configuración.',
              style: TextStyle(color: Colors.white54),
            ),
          ),
        ],

        const SizedBox(height: 24),
        Material(
          color: _card,
          borderRadius: BorderRadius.circular(12),
          child: ListTile(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: _border)),
          title: const Text('Desinstalar repositorio', style: TextStyle(color: Colors.redAccent)),
          trailing: const Icon(Icons.delete_outline, color: Colors.redAccent),
          onTap: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: _card,
                title: const Text('Desinstalar', style: TextStyle(color: Colors.white)),
                content: Text('¿Desinstalar ${m.name}?', style: const TextStyle(color: Colors.white70)),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Desinstalar'),
                  ),
                ],
              ),
            );
            if (ok == true) {
              await mgr.uninstall(m.id);
              if (context.mounted) Navigator.of(context).maybePop();
            }
          },
        ),
        ),
      ],
    );
  }

  Widget _buildField(RepoConfigField f) {
    if (f.isBool) return _buildBool(f);
    if (f.isMulti) return _buildMulti(f);
    if (f.isSelect) return _buildSelect(f);
    return _buildText(f);
  }

  Widget _buildText(RepoConfigField f) {
    final ctrl = _controllers.putIfAbsent(f.key, () => TextEditingController());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(f.label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        if ((f.description ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 6),
            child: Text(f.description!, style: const TextStyle(color: Colors.white38, fontSize: 12.5)),
          )
        else
          const SizedBox(height: 6),
        TextField(
          controller: ctrl,
          obscureText: f.type.toLowerCase() == 'password',
          keyboardType: f.type.toLowerCase() == 'number' ? TextInputType.number : TextInputType.text,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: f.placeholder,
            hintStyle: const TextStyle(color: Colors.white24),
            filled: true,
            fillColor: const Color(0xFF1A1F2A),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
          ),
        ),
      ],
    );
  }

  Widget _buildSelect(RepoConfigField f) {
    // Construir items únicos (evita assert de DropdownButton con values duplicados)
    final seen = <String>{};
    final items = <DropdownMenuItem<String>>[];
    for (var i = 0; i < f.options.length; i++) {
      final v = f.valueAt(i);
      if (v.isEmpty || seen.contains(v)) continue;
      seen.add(v);
      items.add(DropdownMenuItem<String>(value: v, child: Text(f.labelAt(i))));
    }

    var current = _selectValues[f.key] ?? '';
    // Si el valor guardado no está en la lista, no lo pongas como value (rompe el assert)
    if (current.isNotEmpty && !seen.contains(current)) {
      // Intentar match flexible (es-MX vs es_MX vs es)
      String? match;
      final curNorm = current.toLowerCase().replaceAll('_', '-');
      for (final v in seen) {
        final vn = v.toLowerCase().replaceAll('_', '-');
        if (vn == curNorm || vn.startsWith(curNorm) || curNorm.startsWith(vn)) {
          match = v;
          break;
        }
      }
      if (match != null) {
        current = match;
        _selectValues[f.key] = match;
      } else {
        // Añadir el valor guardado como opción extra para no perderlo
        items.insert(0, DropdownMenuItem<String>(value: current, child: Text(current)));
        seen.add(current);
      }
    }

    final value = current.isEmpty || !seen.contains(current) ? null : current;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(f.label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        if ((f.description ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 6),
            child: Text(f.description!, style: const TextStyle(color: Colors.white38, fontSize: 12.5)),
          )
        else
          const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          value: value,
          dropdownColor: _card,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color(0xFF1A1F2A),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
          ),
          items: items,
          onChanged: (v) {
            if (v != null) setState(() => _selectValues[f.key] = v);
          },
        ),
      ],
    );
  }

  Widget _buildBool(RepoConfigField f) {
    final v = _boolValues[f.key] ?? false;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(f.label, style: const TextStyle(color: Colors.white)),
      subtitle: (f.description ?? '').isNotEmpty
          ? Text(f.description!, style: const TextStyle(color: Colors.white38, fontSize: 12.5))
          : null,
      value: v,
      activeColor: _accent,
      onChanged: (nv) => setState(() => _boolValues[f.key] = nv),
    );
  }

  Widget _buildMulti(RepoConfigField f) {
    final selected = _multiValues.putIfAbsent(f.key, () => <String>{});
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(f.label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: [
            for (var i = 0; i < f.options.length; i++)
              FilterChip(
                label: Text(f.labelAt(i)),
                selected: selected.contains(f.valueAt(i)),
                selectedColor: _accent.withValues(alpha: 0.3),
                checkmarkColor: _accent,
                labelStyle: const TextStyle(color: Colors.white),
                onSelected: (on) {
                  setState(() {
                    if (on) {
                      selected.add(f.valueAt(i));
                    } else {
                      selected.remove(f.valueAt(i));
                    }
                  });
                },
              ),
          ],
        ),
      ],
    );
  }
}
