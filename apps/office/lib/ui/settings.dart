import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'business_widgets.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';
import 'plugins.dart';

class OfficeSettings extends StatefulWidget {
  const OfficeSettings({
    super.key,
    required this.state,
    this.onEnterprise,
    this.initialTab = -1,
    this.onNavigation,
    this.onClose,
    this.onOpenModule,
  });
  final OfficeState state;
  final VoidCallback? onEnterprise;
  final int initialTab;
  final VoidCallback? onNavigation;
  final VoidCallback? onClose;
  final ValueChanged<int>? onOpenModule;
  @override
  State<OfficeSettings> createState() => _OfficeSettingsState();
}

class _OfficeSettingsState extends State<OfficeSettings> {
  late int _tab = widget.initialTab;
  bool _busy = false;
  String? _error;
  OfficeState get s => widget.state;
  static const _labels = [
    '账号与安全',
    '通用',
    '隐私',
    '效率',
    '通知',
    '快捷键',
    '文档',
    '日历',
    '邮箱',
    '视频会议',
    '任务',
    '系统诊断',
    '实验室',
    '软件更新',
    '关于人机',
    'Agent 与插件',
  ];
  static const _icons = [
    Icons.manage_accounts_outlined,
    Icons.tune,
    Icons.lock_outline,
    Icons.bolt_outlined,
    Icons.notifications_outlined,
    Icons.keyboard_outlined,
    Icons.description_outlined,
    Icons.calendar_month_outlined,
    Icons.mail_outline,
    Icons.videocam_outlined,
    Icons.task_alt,
    Icons.monitor_heart_outlined,
    Icons.science_outlined,
    Icons.system_update_outlined,
    Icons.rocket_launch_outlined,
    Icons.extension_outlined,
  ];

  Widget _mobileIndex() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      for (final group in [
        [0, 1],
        [4],
        [2, 7, 8, 9, 10, 3],
        [6, 5, 15],
        [11, 12],
        [13, 14],
      ])
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final i in group) ...[
                  if (i != group.first)
                    const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    title: Text(
                      i == 0 ? '账号安全中心' : _labels[i],
                      style: const TextStyle(fontSize: 14),
                    ),
                    trailing: const Icon(
                      Icons.chevron_right,
                      size: 19,
                      color: mutedColor,
                    ),
                    onTap: () => setState(() => _tab = i),
                  ),
                ],
              ],
            ),
          ),
        ),
    ],
  );

  Widget _module(String title, int route, String detail) => BusinessCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          detail,
          style: const TextStyle(fontSize: 13, height: 1.7, color: mutedColor),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: widget.onOpenModule == null
              ? null
              : () => widget.onOpenModule!(route),
          icon: const Icon(Icons.open_in_new, size: 16),
          label: Text(title),
        ),
      ],
    ),
  );
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
      final tab = _tab < 0 ? 0 : _tab;
      return Column(
        children: [
          if (wide)
            const BusinessHeader(title: '设置')
          else
            SizedBox(
              height: 54,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Text(
                    _tab < 0 ? '设置' : (_tab == 0 ? '账号安全中心' : _labels[_tab]),
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (_tab >= 0 || widget.onClose != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(
                        tooltip: _tab >= 0 ? '返回设置' : '关闭设置',
                        icon: const Icon(Icons.chevron_left),
                        onPressed: _tab >= 0
                            ? () => setState(() => _tab = -1)
                            : widget.onClose,
                      ),
                    ),
                ],
              ),
            ),
          const Divider(height: 1),
          if (!wide && _tab < 0)
            Expanded(
              child: ColoredBox(
                color: const Color(0xfff5f6f7),
                child: _mobileIndex(),
              ),
            ),
          if (wide || _tab >= 0)
            Expanded(
              child: Row(
                children: [
                  if (wide)
                    Container(
                      width: 208,
                      color: const Color(0xfff7f8fa),
                      padding: const EdgeInsets.all(12),
                      child: ListView(
                        children: List.generate(
                          _labels.length,
                          (i) => Padding(
                            padding: const EdgeInsets.only(bottom: 5),
                            child: Material(
                              color: tab == i
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
                                  color: tab == i ? accentColor : mutedColor,
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
                          _labels[tab],
                          style: const TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 24),
                        if (tab == 0) ...[
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
                                  session['active'] == true
                                      ? '有效登录会话'
                                      : '已结束会话',
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
                                                    setState(
                                                      () => _busy = false,
                                                    );
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
                        if (tab == 0 && widget.onEnterprise != null)
                          OutlinedButton.icon(
                            onPressed: widget.onEnterprise,
                            icon: const Icon(
                              Icons.apartment_outlined,
                              size: 17,
                            ),
                            label: const Text('打开企业管理后台'),
                          ),
                        if (tab == 1) ...[
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
                        if (tab == 1) ...[
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
                                      value == 'split'
                                          ? '自己在右，伙伴在左'
                                          : '所有消息左对齐',
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
                                        : (_) => _save({
                                            'message_alignment': value,
                                          }),
                                  ),
                                )
                                .toList(),
                          ),
                        ],
                        if (tab == 5) ...[
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
                                        : (_) =>
                                              _save({'send_shortcut': value}),
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
                        ],
                        if (tab == 2 || tab == 4) ...[
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
                        if (tab == 1 && widget.onNavigation != null)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('编辑底栏'),
                            subtitle: const Text('增减和排序手机常用功能'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: widget.onNavigation,
                          ),
                        if (tab == 3)
                          _module(
                            '打开工作台',
                            5,
                            '集中使用常用办公工具。Agent 与插件中的原生能力可供 Agent 调用；自动化执行取决于已连接的插件。',
                          ),
                        if (tab == 4)
                          const Text(
                            '当前支持会话列表预览设置。系统推送、通知声音和免打扰时段尚未接入。',
                            style: TextStyle(color: mutedColor, height: 1.7),
                          ),
                        if (tab == 6)
                          _module(
                            '打开文档',
                            3,
                            '人机文档由 doc_free 提供。文档权限在具体文档中管理；默认新建权限、自动排版偏好尚未接入。',
                          ),
                        if (tab == 7)
                          _module('打开日历', 7, '可管理日程。全局提醒、时区与第三方日历同步偏好尚未接入。'),
                        if (tab == 8)
                          _module(
                            '打开邮箱',
                            8,
                            '可查看邮件与编辑草稿。签名、自动回复和外部邮箱账户配置尚未接入。',
                          ),
                        if (tab == 9)
                          _module(
                            '打开视频会议',
                            6,
                            '会议设备由实际会议服务管理。默认麦克风、摄像头与自动录制偏好尚未接入。',
                          ),
                        if (tab == 10)
                          _module('打开任务', 4, '可管理协作任务。每日提醒与外部任务同步偏好尚未接入。'),
                        if (tab == 11)
                          BusinessCard(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('账号连接检查'),
                                const SizedBox(height: 12),
                                const Text('重新读取当前账号与登录会话，检查服务是否可访问。'),
                                TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () async {
                                          setState(() {
                                            _busy = true;
                                            _error = null;
                                          });
                                          await _loadAccount();
                                          if (mounted) {
                                            setState(() => _busy = false);
                                            if (_error == null) {
                                              notifyOffice(
                                                this.context,
                                                '账号服务连接正常',
                                              );
                                            }
                                          }
                                        },
                                  child: const Text('检查连接'),
                                ),
                              ],
                            ),
                          ),
                        if (tab == 12)
                          const BusinessCard(
                            child: Text(
                              '暂无可启用的实验功能。已接入的 Agent 能力请在“Agent 与插件”中管理。',
                            ),
                          ),
                        if (tab == 13)
                          const BusinessCard(
                            child: Text('当前为本地开发预览版。自动更新服务尚未接入，请通过新的安装包更新。'),
                          ),
                        if (tab == 14)
                          const BusinessCard(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.rocket_launch,
                                  size: 44,
                                  color: accentColor,
                                ),
                                SizedBox(height: 16),
                                Text(
                                  '人机',
                                  style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                SizedBox(height: 12),
                                Text('人与 Agent 同权协作的办公空间'),
                                SizedBox(height: 8),
                                Text(
                                  'Active Agent · doc_free',
                                  style: TextStyle(color: mutedColor),
                                ),
                              ],
                            ),
                          ),
                        if (tab == 15) OfficePlugins(state: s),
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
