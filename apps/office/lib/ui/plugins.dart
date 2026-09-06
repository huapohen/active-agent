import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'business_widgets.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';

class OfficePlugins extends StatefulWidget {
  const OfficePlugins({super.key, required this.state});
  final OfficeState state;
  @override
  State<OfficePlugins> createState() => _OfficePluginsState();
}

class _OfficePluginsState extends State<OfficePlugins> {
  String? _error;
  final Set<String> _saving = {};
  OfficeState get s => widget.state;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await s.loadPlugins();
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _toggle(Json plugin, bool enabled) async {
    final id = str(plugin['id']);
    setState(() {
      _saving.add(id);
      _error = null;
    });
    try {
      await s.configurePlugin(plugin, enabled: enabled);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _saving.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: s,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '所有内置办公模块与已登记扩展，都有可见的能力和个人配置。',
          style: TextStyle(fontSize: 12, color: mutedColor, height: 1.8),
        ),
        const SizedBox(height: 10),
        const Text(
          '个人启用偏好保存到你的身份配置。实际操作仍由会话与工作空间权限决定。',
          style: TextStyle(fontSize: 11, color: mutedColor, height: 1.8),
        ),
        BusinessError(_error),
        if (_error != null)
          TextButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重新读取插件'),
          ),
        const SizedBox(height: 18),
        if (s.plugins.isEmpty)
          const BusinessCard(
            child: Text(
              '暂无插件配置。',
              style: TextStyle(fontSize: 12, color: mutedColor),
            ),
          ),
        ...s.plugins.map((plugin) {
          final available = plugin['available'] == true;
          final allowed = plugin['enterprise_allowed'] != false;
          final schema = plugin['config_schema'] is Map
              ? Json.from(plugin['config_schema'])
              : <String, dynamic>{};
          final capabilities = s.capabilities
              .where((cap) => cap['plugin_id'] == plugin['id'])
              .toList();
          final features = capabilities.isEmpty
              ? maps(plugin['capabilities'])
              : capabilities;
          return Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: BusinessCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(9),
                        decoration: BoxDecoration(
                          color: available
                              ? selectedColor
                              : const Color(0xfff3f4f6),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Icon(
                          plugin['kind'] == 'hardware'
                              ? Icons.devices_other_outlined
                              : plugin['builtin'] == true
                              ? Icons.extension_outlined
                              : Icons.cable_outlined,
                          size: 23,
                          color: available ? accentColor : mutedColor,
                        ),
                      ),
                      const SizedBox(width: 13),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              str(plugin['name']),
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              !available
                                  ? '已登记，尚未连接'
                                  : !allowed
                                  ? '企业策略限制'
                                  : plugin['enabled'] == false
                                  ? '内置模块 · 个人偏好关闭'
                                  : '内置模块 · 可用',
                              style: TextStyle(
                                fontSize: 11,
                                color: available
                                    ? const Color(0xff319b6c)
                                    : const Color(0xffa47b3e),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    str(plugin['description']),
                    style: const TextStyle(
                      fontSize: 12,
                      color: mutedColor,
                      height: 1.7,
                    ),
                  ),
                  if (!available)
                    const Padding(
                      padding: EdgeInsets.only(top: 9),
                      child: Text(
                        '这项扩展当前不能执行操作。保存偏好与配置不会连接外部服务或设备。',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xff9b794d),
                          height: 1.7,
                        ),
                      ),
                    ),
                  if (available && !allowed)
                    const Padding(
                      padding: EdgeInsets.only(top: 9),
                      child: Text(
                        '企业策略限制了当前身份使用此应用。修改个人偏好不会覆盖企业权限。',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xff9b794d),
                          height: 1.7,
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('个人启用偏好', style: TextStyle(fontSize: 12)),
                    value: plugin['enabled'] == true,
                    onChanged: _saving.contains(str(plugin['id']))
                        ? null
                        : (value) => _toggle(plugin, value),
                  ),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: features
                        .map(
                          (cap) => Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xfff4f6f9),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              str(cap['name']),
                              style: const TextStyle(
                                fontSize: 10,
                                color: Color(0xff778297),
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                  if (schema.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    OutlinedButton.icon(
                      onPressed: () => showDialog<void>(
                        context: context,
                        barrierDismissible: false,
                        builder: (context) =>
                            _PluginConfig(state: s, plugin: plugin),
                      ),
                      icon: const Icon(Icons.tune, size: 15),
                      label: const Text('编辑配置'),
                    ),
                  ],
                ],
              ),
            ),
          );
        }),
      ],
    ),
  );
}

class _PluginConfig extends StatefulWidget {
  const _PluginConfig({required this.state, required this.plugin});
  final OfficeState state;
  final Json plugin;
  @override
  State<_PluginConfig> createState() => _PluginConfigState();
}

class _PluginConfigState extends State<_PluginConfig> {
  late Json _plugin = widget.plugin;
  late final Json _schema = Json.from(widget.plugin['config_schema'] ?? {});
  late final Json _values = Json.from(widget.plugin['config'] ?? {});
  final Map<String, TextEditingController> _controllers = {};
  String? _error;
  bool _busy = false, _conflict = false;
  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
      _conflict = false;
    });
    try {
      await widget.state.configurePlugin(_plugin, config: _values);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = friendlyError(e);
          _conflict = e is OfficeException && e.status == 409;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(String key, Json descriptor) {
    final value = _values[key] ?? descriptor['default'];
    final label = str(descriptor['label'], key);
    final choices = descriptor['enum'] as List?;
    if (choices != null && choices.isNotEmpty) {
      return DropdownButtonFormField<dynamic>(
        initialValue: choices.contains(value) ? value : null,
        decoration: InputDecoration(labelText: label),
        items: choices
            .map(
              (choice) => DropdownMenuItem<dynamic>(
                value: choice,
                child: Text(str(choice)),
              ),
            )
            .toList(),
        onChanged: _busy ? null : (next) => setState(() => _values[key] = next),
      );
    }
    if (descriptor['type'] == 'boolean') {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label, style: const TextStyle(fontSize: 13)),
        value: value == true,
        onChanged: _busy ? null : (next) => setState(() => _values[key] = next),
      );
    }
    if (descriptor['type'] == 'string' || descriptor['type'] == 'number') {
      final controller = _controllers.putIfAbsent(
        key,
        () => TextEditingController(text: str(value)),
      );
      return TextField(
        controller: controller,
        enabled: !_busy,
        keyboardType: descriptor['type'] == 'number'
            ? const TextInputType.numberWithOptions(decimal: true, signed: true)
            : TextInputType.text,
        maxLength: descriptor['type'] == 'string' ? 1000 : null,
        decoration: InputDecoration(labelText: label),
        onChanged: (text) {
          if (descriptor['type'] == 'number') {
            final number = num.tryParse(text);
            if (number != null && number.isFinite) {
              _values[key] = number;
            } else {
              _values[key] = text;
            }
          } else {
            _values[key] = text;
          }
        },
      );
    }
    return Text(
      '$label：当前客户端暂不支持此配置类型',
      style: const TextStyle(fontSize: 11, color: mutedColor),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${str(_plugin['name'])} · 配置'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_plugin['available'] != true)
              const Padding(
                padding: EdgeInsets.only(bottom: 15),
                child: Text(
                  '扩展尚未连接。这里仅保存配置。',
                  style: TextStyle(fontSize: 11, color: Color(0xff9b794d)),
                ),
              ),
            ..._schema.entries
                .where((entry) => entry.value is Map)
                .map(
                  (entry) => Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: _field(entry.key, Json.from(entry.value)),
                  ),
                ),
            BusinessError(_error),
            if (_conflict)
              TextButton(
                onPressed: _busy
                    ? null
                    : () async {
                        try {
                          await widget.state.loadPlugins();
                          final latest = widget.state.plugins
                              .where((p) => p['id'] == _plugin['id'])
                              .firstOrNull;
                          if (latest != null && mounted) {
                            setState(() {
                              _plugin = latest;
                              _conflict = false;
                              _error = '已读取最新版本号，上方编辑保留。请核对配置后再保存。';
                            });
                          }
                        } catch (e) {
                          if (mounted) {
                            setState(() => _error = friendlyError(e));
                          }
                        }
                      },
                child: const Text('保留编辑，读取最新配置版本'),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _busy || _conflict ? null : _save,
        child: Text(_busy ? '保存中…' : '保存配置'),
      ),
    ],
  );
}
