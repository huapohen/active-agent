import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../office_state.dart' hide Json;
import 'business_widgets.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';

class OfficeAuthProviders extends StatefulWidget {
  const OfficeAuthProviders({
    super.key,
    required this.endpoint,
    required this.discover,
    required this.start,
    required this.exchange,
    required this.onMethods,
    this.openUrl,
  });
  final String endpoint;
  final Future<Json> Function(String) discover;
  final Future<OfficeExternalLogin> Function(String, String) start;
  final Future<void> Function(String, OfficeExternalLogin, String) exchange;
  final void Function(bool password, bool token) onMethods;
  final Future<bool> Function(Uri)? openUrl;
  @override
  State<OfficeAuthProviders> createState() => _OfficeAuthProvidersState();
}

class _OfficeAuthProvidersState extends State<OfficeAuthProviders> {
  List<Json> _providers = [];
  bool _loading = true, _busy = false;
  String? _error, _notice;
  OfficeExternalLogin? _attempt;
  DateTime? _expiresAt;
  final _code = TextEditingController();
  Timer? _debounce;
  int _request = 0;
  @override
  void initState() {
    super.initState();
    _debounce = Timer(const Duration(milliseconds: 450), _load);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _request++;
    _code.dispose();
    _attempt = null;
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_request;
    final uri = Uri.tryParse(widget.endpoint.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final result = await widget.discover(widget.endpoint);
      if (!mounted || request != _request) return;
      setState(() {
        _providers = maps(result['providers']);
        _error = null;
      });
      widget.onMethods(
        (result['local_password'] as Map?)?['enabled'] != false,
        (result['machine_token'] as Map?)?['enabled'] != false,
      );
    } catch (_) {
      if (mounted && request == _request) {
        setState(() => _error = '暂时无法读取企业登录方式，可重试或使用已有账号与令牌。');
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Future<void> _start(Json provider) async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final attempt = await widget.start(widget.endpoint, str(provider['id']));
      if (!mounted) return;
      setState(() {
        _attempt = attempt;
        _expiresAt = DateTime.now().add(Duration(seconds: attempt.expiresIn));
        _code.clear();
      });
      final uri = Uri.parse(attempt.authorizationUrl);
      final opened =
          await (widget.openUrl?.call(uri) ??
              launchUrl(uri, mode: LaunchMode.externalApplication));
      if (mounted && !opened) {
        setState(() => _notice = '浏览器未打开。可复制授权链接，在浏览器完成企业登录。');
      }
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exchange() async {
    if (_code.text.trim().isEmpty) {
      setState(() => _error = '请输入浏览器中显示的一次性登录码');
      return;
    }
    if (_expiresAt == null || DateTime.now().isAfter(_expiresAt!)) {
      setState(() => _error = '本次登录已过期，请重新选择企业登录方式');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.exchange(widget.endpoint, _attempt!, _code.text.trim());
      if (mounted) {
        setState(() {
          _code.clear();
          _attempt = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_loading)
        const Padding(
          padding: EdgeInsets.only(top: 18),
          child: LinearProgressIndicator(minHeight: 2),
        ),
      if (_providers.isNotEmpty) ...[
        const Divider(height: 32),
        const Text(
          '企业登录',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        ..._providers.map(
          (provider) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: OutlinedButton.icon(
              onPressed: _busy ? null : () => _start(provider),
              icon: const Icon(Icons.domain_outlined, size: 17),
              label: Text('使用${str(provider['label'], str(provider['id']))}登录'),
            ),
          ),
        ),
      ],
      if (_attempt != null) ...[
        const SizedBox(height: 10),
        const Text(
          '在浏览器完成企业登录后，将页面显示的一次性登录码粘贴到这里。登录码须在生成后 2 分钟内使用，且只能由本次发起的客户端兑换。',
          style: TextStyle(fontSize: 11, color: mutedColor, height: 1.8),
        ),
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(
              ClipboardData(text: _attempt!.authorizationUrl),
            );
            if (mounted) setState(() => _notice = '本次授权链接已复制');
          },
          icon: const Icon(Icons.copy_outlined, size: 15),
          label: const Text('复制本次授权链接'),
        ),
        TextField(
          controller: _code,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: '一次性登录码'),
          onSubmitted: (_) => _busy ? null : _exchange(),
        ),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: _busy ? null : _exchange,
          child: Text(_busy ? '正在登录…' : '验证并进入工作空间'),
        ),
      ],
      if (_notice != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _notice!,
            style: const TextStyle(
              fontSize: 11,
              color: mutedColor,
              height: 1.8,
            ),
          ),
        ),
      BusinessError(_error),
      if (_error != null && _attempt == null)
        TextButton(
          onPressed: _loading
              ? null
              : () {
                  setState(() => _loading = true);
                  _load();
                },
          child: const Text('重新读取企业登录方式'),
        ),
    ],
  );
}
