import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'business_widgets.dart';
import 'office_theme.dart';

Future<void> showOfficeAccountEditor(BuildContext context, OfficeState state) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SettingsAccountEditor(state: state),
    );

class _SettingsAccountEditor extends StatefulWidget {
  const _SettingsAccountEditor({required this.state});
  final OfficeState state;
  @override
  State<_SettingsAccountEditor> createState() => _SettingsAccountEditorState();
}

class _SettingsAccountEditorState extends State<_SettingsAccountEditor> {
  late final TextEditingController _username;
  late final String _identity;
  late final bool _existing;
  bool _expired = false;
  String get _identityKey =>
      '${widget.state.identityGeneration}|${widget.state.endpoint}|${personId(widget.state.me ?? {})}';
  bool get _valid =>
      !_expired && widget.state.me != null && _identity == _identityKey;
  final _current = TextEditingController(),
      _password = TextEditingController(),
      _confirm = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _identity = _identityKey;
    _existing = widget.state.accountInfo['username'] != null;
    _username = TextEditingController(
      text: str(widget.state.accountInfo['username']),
    );
    widget.state.addListener(_identityChanged);
    if (!_valid) _lock();
  }

  void _lock() {
    _expired = true;
    for (final controller in [_username, _current, _password, _confirm]) {
      controller.clear();
    }
    _error = null;
  }

  void _identityChanged() {
    if (!mounted) return;
    setState(() {
      if (!_valid) _lock();
    });
  }

  @override
  void dispose() {
    widget.state.removeListener(_identityChanged);
    for (final c in [_username, _current, _password, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_valid ||
        !widget.state.connected ||
        _busy ||
        !_form.currentState!.validate()) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.state.setAccount(
        _username.text.trim(),
        _password.text,
        currentPassword: _current.text,
      );
      // A successful password update intentionally re-authenticates this same
      // account. OfficeState guards both responses against an unrelated login.
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted && _valid) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(_existing ? '修改账号密码' : '设置账号密码'),
    content: SizedBox(
      width: 420,
      child: !_valid
          ? const Text('工作身份已变更，账号与密码草稿已清空。请关闭后重新打开。')
          : SingleChildScrollView(
              child: Form(
                key: _form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: _username,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: '账号',
                        hintText: '至少 3 位字母、数字或 . _ @ + -',
                      ),
                      validator: (v) =>
                          RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._@+-]{2,99}$')
                              .hasMatch(v?.trim() ?? '')
                          ? null
                          : '请输入符合格式的账号',
                    ),
                    if (_existing) ...[
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _current,
                        obscureText: true,
                        enableSuggestions: false,
                        autocorrect: false,
                        decoration: const InputDecoration(labelText: '当前密码'),
                        validator: (v) =>
                            v?.isNotEmpty == true ? null : '请输入当前密码',
                      ),
                    ],
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _password,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: '新密码',
                        hintText: '10–256 个字符',
                      ),
                      validator: (v) =>
                          (v?.length ?? 0) >= 10 &&
                              (v?.length ?? 0) <= 256 &&
                              v!.trim().isNotEmpty
                          ? null
                          : '密码需要 10–256 个字符',
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _confirm,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: const InputDecoration(labelText: '确认新密码'),
                      validator: (v) => v == _password.text ? null : '两次密码不一致',
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      '保存后，原有登录会话将退出，当前身份会使用新密码重新登录。',
                      style: TextStyle(fontSize: 11, color: mutedColor),
                    ),
                    if (!widget.state.connected)
                      const Text(
                        '暂时离线，密码草稿已保留；重新连接后可继续保存。',
                        style: TextStyle(fontSize: 11, color: mutedColor),
                      ),
                    BusinessError(_error),
                  ],
                ),
              ),
            ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _busy || !_valid || !widget.state.connected ? null : _save,
        child: Text(_busy ? '保存中…' : '保存'),
      ),
    ],
  );
}
