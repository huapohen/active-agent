import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'business_widgets.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';
import 'plugins.dart';

class OfficeSettings extends StatefulWidget {
  const OfficeSettings({super.key, required this.state, this.onEnterprise});
  final OfficeState state;
  final VoidCallback? onEnterprise;
  @override
  State<OfficeSettings> createState() => _OfficeSettingsState();
}

class _OfficeSettingsState extends State<OfficeSettings> {
  int _tab = 0;
  bool _busy = false;
  String? _error;
  OfficeState get s => widget.state;
  static const _labels = ['账号与安全', '通用', '消息与效率', '插件与能力'];
  static const _icons = [
    Icons.manage_accounts_outlined,
    Icons.tune,
    Icons.chat_bubble_outline,
    Icons.extension_outlined,
  ];
  @override
  void initState() {
    super.initState();
    _loadAccount();
  }

  Future<void> _loadAccount() async {
    try {
      await Future.wait([s.getAccount(), s.loadAccountSessions()]);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _save(Json values) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await s.saveSettings(values);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _account() => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _AccountEditor(state: s),
  );
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth > 720;
      return Column(
        children: [
          const BusinessHeader(title: '设置', subtitle: '让你的工作空间更合心意'),
          const Divider(height: 1),
          if (!wide)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 7,
                children: List.generate(
                  _labels.length,
                  (i) => ChoiceChip(
                    label: Text(
                      _labels[i],
                      style: const TextStyle(fontSize: 11),
                    ),
                    selected: _tab == i,
                    showCheckmark: false,
                    onSelected: (_) => setState(() => _tab = i),
                  ),
                ),
              ),
            ),
          Expanded(
            child: Row(
              children: [
                if (wide)
                  Container(
                    width: 180,
                    color: const Color(0xfff7f8fa),
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: List.generate(
                        _labels.length,
                        (i) => Padding(
                          padding: const EdgeInsets.only(bottom: 5),
                          child: Material(
                            color: _tab == i
                                ? selectedColor
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(6),
                            child: ListTile(
                              dense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              minLeadingWidth: 19,
                              leading: Icon(
                                _icons[i],
                                size: 18,
                                color: _tab == i ? accentColor : mutedColor,
                              ),
                              title: Text(
                                _labels[i],
                                style: const TextStyle(fontSize: 12),
                              ),
                              onTap: () => setState(() => _tab = i),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(24),
                    children: [
                      Text(
                        _labels[_tab],
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 24),
                      if (_tab == 0) ...[
                        BusinessCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  PersonAvatar(
                                    name: str(s.me?['name']),
                                    agent: s.me?['kind'] == 'agent',
                                    size: 44,
                                  ),
                                  const SizedBox(width: 13),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          str(s.me?['name']),
                                          style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        Text(
                                          s.me?['kind'] == 'agent'
                                              ? 'Agent 工作身份'
                                              : '个人工作身份',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: mutedColor,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 22),
                              Text(
                                '账号：${str(s.accountInfo['username'], '尚未设置账号密码')}',
                                style: const TextStyle(fontSize: 13),
                              ),
                              const SizedBox(height: 13),
                              OutlinedButton(
                                onPressed: _account,
                                child: Text(
                                  s.accountInfo['username'] == null
                                      ? '设置账号密码'
                                      : '修改账号密码',
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        const Text(
                          '登录会话',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '撤销后，该登录会话将需要重新验证身份。',
                          style: TextStyle(fontSize: 11, color: mutedColor),
                        ),
                        const SizedBox(height: 12),
                        if (s.accountSessions.isEmpty)
                          const Text(
                            '没有账号密码登录会话。',
                            style: TextStyle(color: mutedColor, fontSize: 12),
                          ),
                        ...s.accountSessions.reversed.map(
                          (session) => Material(
                            color: Colors.white,
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(
                                session['active'] == true
                                    ? Icons.devices
                                    : Icons.history,
                                size: 21,
                                color: mutedColor,
                              ),
                              title: Text(
                                session['active'] == true ? '有效登录会话' : '已结束会话',
                                style: const TextStyle(fontSize: 12),
                              ),
                              subtitle: Text(
                                '登录 ${fullOfficeTime(session['created_at'])}\n到期 ${fullOfficeTime(session['expires_at'])}',
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: mutedColor,
                                ),
                              ),
                              trailing: session['active'] == true
                                  ? TextButton(
                                      onPressed: _busy
                                          ? null
                                          : () async {
                                              setState(() => _busy = true);
                                              try {
                                                await s.revokeSession(
                                                  str(session['id']),
                                                );
                                              } catch (e) {
                                                if (mounted) {
                                                  setState(
                                                    () => _error =
                                                        friendlyError(e),
                                                  );
                                                }
                                              } finally {
                                                if (mounted) {
                                                  setState(() => _busy = false);
                                                }
                                              }
                                            },
                                      child: const Text('撤销'),
                                    )
                                  : null,
                            ),
                          ),
                        ),
                        const SizedBox(height: 23),
                        TextButton.icon(
                          onPressed: s.disconnect,
                          icon: const Icon(Icons.logout, size: 17),
                          label: const Text('退出当前身份'),
                        ),
                      ],
                      if (_tab == 0 && widget.onEnterprise != null)
                        OutlinedButton.icon(
                          onPressed: widget.onEnterprise,
                          icon: const Icon(Icons.apartment_outlined, size: 17),
                          label: const Text('打开企业管理后台'),
                        ),
                      if (_tab == 1) ...[
                        const Text(
                          '文字大小',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 7),
                        const Text(
                          '调整整个办公界面的文字比例。',
                          style: TextStyle(fontSize: 11, color: mutedColor),
                        ),
                        const SizedBox(height: 15),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [0.85, 1.0, 1.15, 1.3]
                              .map(
                                (scale) => ChoiceChip(
                                  label: Text('${(scale * 100).round()}%'),
                                  selected:
                                      ((s.settings['text_scale'] as num?)
                                              ?.toDouble() ??
                                          1) ==
                                      scale,
                                  showCheckmark: false,
                                  onSelected: _busy
                                      ? null
                                      : (_) => _save({'text_scale': scale}),
                                ),
                              )
                              .toList(),
                        ),
                        const SizedBox(height: 27),
                        const BusinessCard(
                          color: Color(0xfff7f9fc),
                          child: Text(
                            '预览：让人与 Agent 在同一个工作空间里，读懂上下文，一起推进工作。',
                            style: TextStyle(fontSize: 14, height: 1.9),
                          ),
                        ),
                      ],
                      if (_tab == 2) ...[
                        const Text(
                          '消息布局',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 13),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: ['split', 'left']
                              .map(
                                (value) => ChoiceChip(
                                  label: Text(
                                    value == 'split' ? '自己在右，伙伴在左' : '所有消息左对齐',
                                  ),
                                  selected:
                                      str(
                                        s.settings['message_alignment'],
                                        'split',
                                      ) ==
                                      value,
                                  showCheckmark: false,
                                  onSelected: _busy
                                      ? null
                                      : (_) =>
                                            _save({'message_alignment': value}),
                                ),
                              )
                              .toList(),
                        ),
                        const Divider(height: 42),
                        const Text(
                          '发送快捷键',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 13),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: ['enter', 'mod_enter']
                              .map(
                                (value) => ChoiceChip(
                                  label: Text(
                                    value == 'enter'
                                        ? 'Enter 发送'
                                        : 'Ctrl / ⌘ + Enter 发送',
                                  ),
                                  selected:
                                      str(
                                        s.settings['send_shortcut'],
                                        'enter',
                                      ) ==
                                      value,
                                  showCheckmark: false,
                                  onSelected: _busy
                                      ? null
                                      : (_) => _save({'send_shortcut': value}),
                                ),
                              )
                              .toList(),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'Shift + Enter 始终换行。输入法选词时不会发送。',
                          style: TextStyle(fontSize: 11, color: mutedColor),
                        ),
                        const Divider(height: 42),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                            '会话列表显示消息预览',
                            style: TextStyle(fontSize: 14),
                          ),
                          subtitle: const Text(
                            '关闭后，列表将隐藏最近一条消息的正文。',
                            style: TextStyle(fontSize: 11, color: mutedColor),
                          ),
                          value: s.settings['show_message_preview'] != false,
                          onChanged: _busy
                              ? null
                              : (value) =>
                                    _save({'show_message_preview': value}),
                        ),
                      ],
                      if (_tab == 3) OfficePlugins(state: s),
                      BusinessError(_error),
                      if (_busy) const LinearProgressIndicator(minHeight: 2),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
}

class _AccountEditor extends StatefulWidget {
  const _AccountEditor({required this.state});
  final OfficeState state;
  @override
  State<_AccountEditor> createState() => _AccountEditorState();
}

class _AccountEditorState extends State<_AccountEditor> {
  late final _username = TextEditingController(
    text: str(widget.state.accountInfo['username']),
  );
  final _current = TextEditingController(),
      _password = TextEditingController(),
      _confirm = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    for (final c in [_username, _current, _password, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
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
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.state.accountInfo['username'] == null ? '设置账号密码' : '修改账号密码',
    ),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
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
              if (widget.state.accountInfo['username'] != null) ...[
                const SizedBox(height: 16),
                TextFormField(
                  controller: _current,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: '当前密码'),
                  validator: (v) => v?.isNotEmpty == true ? null : '请输入当前密码',
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
              BusinessError(_error),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: Text(_busy ? '保存中…' : '保存'),
      ),
    ],
  );
}
