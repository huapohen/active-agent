import 'package:flutter/material.dart';

import '../office_state.dart' hide Json;
import 'business_widgets.dart';
import 'office_dialogs.dart';
import 'office_theme.dart';
import 'plugins.dart';
import 'settings_account.dart';
import 'settings_session.dart';
import 'settings_widgets.dart';

class OfficeSettings extends StatefulWidget {
  const OfficeSettings({
    super.key,
    required this.state,
    this.onEnterprise,
    this.initialTab = -1,
    this.onNavigation,
    this.onClose,
    this.onOpenModule,
    this.onMessageGroups,
  });
  final OfficeState state;
  final VoidCallback? onEnterprise, onNavigation, onClose, onMessageGroups;
  final int initialTab;
  final ValueChanged<int>? onOpenModule;
  @override
  State<OfficeSettings> createState() => _OfficeSettingsState();
}

class _OfficeSettingsState extends State<OfficeSettings> {
  late int _tab;
  late final OfficeSettingsSession _session;
  final _accountUpdates = ValueNotifier<int>(0);
  bool _accountBusy = false;
  String? _accountError;
  OfficeState get s => widget.state;
  Json get values => _session.values;
  bool get editable =>
      _session.valid && s.connected && !_session.busy && !_session.conflict;
  static const _labels = [
    '账号安全中心',
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
    '网络诊断',
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
  String _label(int index, bool mobile) => !mobile && index == 0
      ? '账号与安全'
      : !mobile && index == 11
      ? '系统诊断'
      : _labels[index];

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab;
    _session = OfficeSettingsSession(s);
    _loadAccount();
  }

  @override
  void dispose() {
    _accountUpdates.dispose();
    _session.dispose();
    super.dispose();
  }

  Future<void> _loadAccount({bool report = false}) async {
    if (!_session.valid || _accountBusy) return;
    setState(() {
      _accountBusy = true;
      _accountError = null;
    });
    _accountUpdates.value++;
    try {
      await Future.wait([s.getAccount(), s.loadAccountSessions()]);
      if (mounted && _session.valid && report) {
        notifyOffice(context, '账号服务连接正常');
      }
    } catch (error) {
      if (mounted && _session.valid) {
        setState(() => _accountError = friendlyError(error));
      }
    } finally {
      if (mounted) {
        setState(() => _accountBusy = false);
        _accountUpdates.value++;
      }
    }
  }

  Widget _unsupported(
    String title,
    String explanation, {
    String value = '尚未接入',
  }) => OfficeSettingsRow(
    title: title,
    value: value,
    unavailable: true,
    onTap: () => showOfficeSettingStatus(context, title, explanation),
  );
  Widget _section(bool mobile, String? title, List<Widget> children) =>
      OfficeSettingsSection(mobile: mobile, title: title, children: children);
  Widget _padded(Widget child) =>
      Padding(padding: const EdgeInsets.all(16), child: child);
  double get _scale => (values['text_scale'] as num?)?.toDouble() ?? 1;
  Widget _font() => OfficeFontSizePreview(
    scale: _scale,
    enabled: editable,
    onChanged: (value) => _session.save({'text_scale': value}),
  );
  Widget _alignment() => OfficeConversationLayoutPreview(
    value: str(values['message_alignment'], 'split'),
    enabled: editable,
    onChanged: (value) => _session.save({'message_alignment': value}),
  );

  void _subpage(String title, Widget Function() contents) {
    if (!_session.valid) return;
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          backgroundColor: const Color(0xfff5f6f8),
          appBar: AppBar(
            title: Text(
              title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
          ),
          body: SafeArea(
            top: false,
            child: AnimatedBuilder(
              animation: Listenable.merge([_session, _accountUpdates]),
              builder: (_, _) => !_session.valid
                  ? const Center(child: Text('工作身份已变更，请关闭后重新打开设置。'))
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        contents(),
                        const SizedBox(height: 18),
                        OfficeSettingsFeedback(session: _session),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _general(bool mobile) => [
    if (mobile) ...[
      _section(true, null, [
        OfficeSettingsRow(
          title: '外观',
          value: '浅色',
          onTap: () =>
              _subpage('外观', () => _padded(const OfficeAppearancePreview())),
        ),
        OfficeSettingsRow(
          title: '会话显示模式',
          value: values['message_alignment'] == 'left' ? '左对齐' : '左右分布',
          onTap: () => _subpage('会话显示模式', _alignment),
        ),
      ]),
    ] else ...[
      _section(false, '外观', [
        _padded(const OfficeAppearancePreview()),
        _unsupported('主题色', '当前使用人机蓝色。自定义主题色尚未接入；选择主题色不会改变当前界面。', value: '人机蓝'),
      ]),
      _section(false, '会话显示模式', [_padded(_alignment())]),
    ],
    _section(mobile, mobile ? null : '语言与显示', [
      _unsupported('显示语言', '当前界面为简体中文。多语言切换尚未接入，消息与文档仍保留原文。', value: '简体中文'),
      _unsupported(
        '名片页姓名展示',
        '当前展示工作身份本名；群聊内可以设置本人群昵称。名片姓名的不同语言与顺序偏好尚未接入。',
        value: '工作身份本名',
      ),
      _unsupported('内容翻译', '自动翻译与默认目标语言尚未接入。当前消息、邮件与文档按原文显示。'),
    ]),
    if (mobile)
      _section(true, null, [
        OfficeSettingsRow(
          title: '字体大小',
          value: '${(_scale * 100).round()}%',
          onTap: () => _subpage('字体大小', _font),
        ),
      ])
    else
      _section(false, '字体大小', [
        _padded(_font()),
        _unsupported('窗口缩放', '当前仅支持上方文字比例设置。整个窗口的缩放比例尚未接入。'),
      ]),
    _section(mobile, mobile ? null : '时间显示', [
      SwitchListTile(
        key: const ValueKey('settings-time-format'),
        title: const Text('24 小时制', style: TextStyle(fontSize: 14)),
        subtitle: Text(
          values['time_format'] == '12h' ? '例如：下午 2:30' : '例如：14:30',
          style: const TextStyle(fontSize: 11, color: mutedColor),
        ),
        value: values['time_format'] != '12h',
        onChanged: editable
            ? (value) => _session.save({'time_format': value ? '24h' : '12h'})
            : null,
      ),
    ]),
    _section(mobile, mobile ? null : '连接与存储', [
      OfficeSettingsRow(
        title: '网络诊断',
        description: '检查当前账号服务连接',
        onTap: () =>
            mobile ? _subpage('网络诊断', _diagnostics) : setState(() => _tab = 11),
      ),
      if (!mobile)
        _unsupported(
          '文件保存位置',
          '当前附件由系统下载或打开流程处理。自定义默认下载位置尚未接入。',
          value: '由系统管理',
        ),
      _unsupported('缓存清理', '当前没有可列出容量并安全删除的离线缓存管理服务。此处不会清除聊天记录、共同文档或账号数据。'),
    ]),
    if (widget.onNavigation != null)
      _section(mobile, '常用功能', [
        OfficeSettingsRow(
          title: '编辑底栏',
          description: '增减和排序手机常用功能',
          onTap: widget.onNavigation,
        ),
      ]),
  ];

  Widget _previewToggle() => SwitchListTile(
    title: const Text('会话列表显示消息预览', style: TextStyle(fontSize: 14)),
    subtitle: const Text(
      '关闭后，列表隐藏最近一条消息的正文。',
      style: TextStyle(fontSize: 11, color: mutedColor),
    ),
    value: values['show_message_preview'] != false,
    onChanged: editable
        ? (value) => _session.save({'show_message_preview': value})
        : null,
  );

  List<Widget> _account(bool mobile) => [
    _section(mobile, '工作身份', [
      ListTile(
        leading: PersonAvatar(
          name: str(s.me?['name']),
          agent: s.me?['kind'] == 'agent',
          size: 44,
        ),
        title: Text(str(s.me?['name'])),
        subtitle: Text(s.me?['kind'] == 'agent' ? 'Agent 工作身份' : '个人工作身份'),
      ),
      OfficeSettingsRow(
        title: '登录账号',
        value: str(s.accountInfo['username'], '尚未设置'),
      ),
      OfficeSettingsRow(
        title: s.accountInfo['username'] == null ? '设置账号密码' : '修改账号密码',
        onTap: () => showOfficeAccountEditor(context, s),
      ),
    ]),
    _section(mobile, '登录会话', [
      if (s.accountSessions.isEmpty)
        const OfficeSettingsRow(
          title: '没有账号密码登录会话',
          description: '账号密码登录后，可以在这里管理有效会话。',
        ),
      for (final session in s.accountSessions.reversed)
        ListTile(
          leading: Icon(
            session['active'] == true ? Icons.devices : Icons.history,
            size: 21,
            color: mutedColor,
          ),
          title: Text(
            session['active'] == true ? '有效登录会话' : '已结束会话',
            style: const TextStyle(fontSize: 13),
          ),
          subtitle: Text(
            '登录 ${fullOfficeTime(session['created_at'], context: context)}\n到期 ${fullOfficeTime(session['expires_at'], context: context)}',
            style: const TextStyle(fontSize: 10),
          ),
          trailing: session['active'] == true
              ? TextButton(
                  onPressed: _accountBusy || !s.connected
                      ? null
                      : () => _revoke(str(session['id'])),
                  child: const Text('撤销'),
                )
              : null,
        ),
    ]),
    if (widget.onEnterprise != null)
      _section(mobile, '企业管理', [
        OfficeSettingsRow(
          title: '打开企业管理后台',
          icon: Icons.apartment_outlined,
          onTap: widget.onEnterprise,
        ),
      ]),
    _section(mobile, null, [
      OfficeSettingsRow(
        title: '退出当前身份',
        icon: Icons.logout,
        onTap: s.disconnect,
      ),
    ]),
  ];

  Future<void> _revoke(String id) async {
    if (!_session.valid || !s.connected || _accountBusy) return;
    setState(() {
      _accountBusy = true;
      _accountError = null;
    });
    try {
      await s.revokeSession(id);
    } catch (error) {
      if (mounted && _session.valid) {
        setState(() => _accountError = friendlyError(error));
      }
    } finally {
      if (mounted) setState(() => _accountBusy = false);
    }
  }

  Widget _diagnostics() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_accountError != null) BusinessError(_accountError),
      _section(true, '当前服务', [
        OfficeSettingsRow(title: '连接状态', value: s.connected ? '已连接' : '连接中断'),
        const OfficeSettingsRow(
          title: '账号连接检查',
          description: '重新读取当前账号与登录会话，检查服务是否可访问。',
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: OutlinedButton.icon(
            onPressed: _accountBusy ? null : () => _loadAccount(report: true),
            icon: const Icon(Icons.monitor_heart_outlined, size: 18),
            label: const Text('检查连接'),
          ),
        ),
      ]),
    ],
  );

  Widget _moduleEntry(String title, int route) => OfficeSettingsRow(
    title: title,
    value: widget.onOpenModule == null ? '当前不可用' : null,
    icon: Icons.open_in_new,
    onTap: widget.onOpenModule == null
        ? null
        : () => widget.onOpenModule!(route),
  );

  List<Widget> _moduleSettings(int tab, bool mobile) => switch (tab) {
    6 => [
      _section(mobile, '编辑', [
        _unsupported('自动大写句首字母', '自动大写偏好尚未接入，编辑器会保留你输入的原文。'),
        _unsupported('首行缩进', '默认首行缩进设置尚未接入，当前按文档编辑器实际排版显示。'),
      ]),
      _section(mobile, '权限与记录', [
        _unsupported('访问记录', '全局文档访问记录开关尚未接入。文档修订与共同修改记录保留在具体文档中。'),
        _unsupported('新文档默认访问权限', '默认新建权限偏好尚未接入。请在具体共同文档中核对实际共享范围。'),
        _moduleEntry('打开文档', 3),
      ]),
    ],
    7 => [
      _section(mobile, '提醒与日程', [
        _unsupported('非全天日程提醒', '全局非全天提醒偏好尚未接入；当前日程按已设置的时间管理。'),
        _unsupported('全天日程提醒', '全局全天提醒时间尚未接入。'),
        _unsupported('默认日程时长', '默认日程时长偏好尚未接入，可在创建日程时选择具体开始与结束时间。'),
      ]),
      _section(mobile, '日历显示', [
        _unsupported('每周第一天', '每周第一天的自定义偏好尚未接入。'),
        _unsupported('工作时间', '工作时间段与非工作时间显示偏好尚未接入。'),
        _unsupported(
          '当前设备时区',
          '时区切换偏好尚未接入；日程显示由当前设备本地时区换算。',
          value: DateTime.now().timeZoneName,
        ),
      ]),
      _section(mobile, '账号与同步', [
        _unsupported('第三方日历管理', '第三方日历授权与同步尚未接入。'),
        _unsupported('CalDAV 同步', 'CalDAV 账号连接与同步服务尚未接入。'),
        _moduleEntry('打开日历', 7),
      ]),
    ],
    8 => [
      _section(mobile, '账号与发信', [
        _unsupported('邮箱账号', '外部邮箱账号授权与配置尚未接入。当前仅展示已接入邮箱模块提供的邮件与草稿。'),
        _unsupported('发信地址与名称', '自定义发信身份偏好尚未接入。'),
        _unsupported('邮件签名', '自动追加签名服务尚未接入，可在草稿正文中直接编辑。'),
        _unsupported('自动回复', '自动回复规则与实际邮件投递服务尚未接入。'),
      ]),
      _section(mobile, '邮件管理', [
        _unsupported('邮件视图', '紧凑视图与会话聚合偏好尚未接入。'),
        _unsupported('拦截与信任发件人', '发件人拦截与信任列表尚未接入。'),
        _unsupported('第三方客户端', '第三方邮件客户端授权尚未接入。'),
        _moduleEntry('打开邮箱', 8),
      ]),
    ],
    9 => [
      _section(mobile, '音频与视频', [
        _unsupported('默认麦克风', '全局默认设备选择尚未接入。请在实际音视频会话和操作系统中确认麦克风权限。'),
        _unsupported('默认摄像头', '全局默认摄像头偏好尚未接入。摄像头权限由实际会议与操作系统管理。'),
        _unsupported('进出会议声音', '进出会议提示音偏好尚未接入。'),
      ]),
      _section(mobile, '字幕与录制', [
        _unsupported('字幕', '实时字幕服务与语言配置尚未接入。'),
        _unsupported('会议自动云录制', '自动云录制服务尚未接入，不会因为打开此设置页启动录制。'),
        _unsupported('录制提醒', '录制状态通知偏好尚未接入。'),
        _moduleEntry('打开视频会议', 6),
      ]),
    ],
    10 => [
      _section(mobile, '任务提醒', [
        _unsupported('每日任务提醒', '全局每日提醒时间尚未接入，可在具体任务中维护负责人、状态与截止时间。'),
        _unsupported('到期提醒', '全局任务到期提醒偏好尚未接入。'),
      ]),
      _section(mobile, '协作与同步', [
        _unsupported('默认负责人', '新任务的默认负责人偏好尚未接入，创建时可以选择人类或 Agent 成员。'),
        _unsupported('外部任务同步', '外部任务系统授权与同步尚未接入。'),
        _moduleEntry('打开任务', 4),
      ]),
    ],
    _ => [],
  };

  List<Widget> _contents(int tab, bool mobile) {
    if ([6, 7, 8, 9, 10].contains(tab)) return _moduleSettings(tab, mobile);
    return switch (tab) {
      0 => _account(mobile),
      1 => _general(mobile),
      2 => [
        _section(mobile, '消息隐私', [
          _previewToggle(),
          _unsupported(
            '搜索与发现权限',
            '账号可搜索范围与外部联系人隐私偏好尚未接入；当前实际访问仍遵守工作空间和会话成员权限。',
          ),
        ]),
      ],
      3 => [
        _section(mobile, '消息效率', [
          OfficeSettingsRow(
            title: '消息分组',
            description: '按未读、@我与自定义分组筛选工作会话',
            value: widget.onMessageGroups == null ? '当前不可用' : null,
            onTap: widget.onMessageGroups,
          ),
          _unsupported('会话滑动操作', '自定义会话左右滑动行为尚未接入，置顶与免打扰可在会话详情中设置。'),
          _unsupported('语音消息自动转文字', '语音消息自动转写服务尚未接入。'),
          _unsupported('进入会话定位到', '默认定位偏好尚未接入；当前会话会加载可用消息并按现有滚动行为展示。'),
        ]),
        _section(mobile, '输入与状态', [
          _unsupported('词典提示', '共享词典与术语提示服务尚未接入。'),
          _unsupported('智能纠错', '智能纠错偏好尚未接入，系统输入法仍按设备设置工作。'),
          _unsupported('个人状态', '定时状态与自动状态规则尚未接入。'),
          _moduleEntry('打开工作台', 5),
        ]),
      ],
      4 => [
        _section(mobile, '消息通知', [
          _previewToggle(),
          _unsupported('系统推送', '后台系统推送服务尚未接入。当前会话内消息仍通过在线服务更新。'),
          _unsupported('通知声音', '通知音效配置尚未接入。'),
          _unsupported('免打扰时段', '全局免打扰时段尚未接入，可在单个会话详情中开启消息免打扰。'),
        ]),
      ],
      5 => [
        _section(mobile, '发送快捷键', [
          _padded(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final value in ['enter', 'mod_enter'])
                      ChoiceChip(
                        label: Text(
                          value == 'enter' ? 'Enter 发送' : 'Ctrl / ⌘ + Enter 发送',
                        ),
                        selected:
                            str(values['send_shortcut'], 'enter') == value,
                        showCheckmark: false,
                        onSelected: editable
                            ? (_) => _session.save({'send_shortcut': value})
                            : null,
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Shift + Enter 始终换行。输入法选词时不会发送。',
                  style: TextStyle(fontSize: 11, color: mutedColor),
                ),
              ],
            ),
          ),
        ]),
      ],
      11 => [_diagnostics()],
      12 => [
        _section(mobile, '实验功能', [
          const OfficeSettingsRow(
            title: '暂无可启用的实验功能',
            description: '已接入的原生能力可在人机 Agent 分类中管理。',
          ),
          OfficeSettingsRow(
            title: 'Agent 与插件',
            onTap: () => setState(() => _tab = 15),
          ),
        ]),
      ],
      13 => [
        _section(mobile, '版本与更新', [
          const OfficeSettingsRow(title: '当前版本', value: '本地开发预览版'),
          _unsupported('检查更新', '自动更新服务尚未接入，请使用主项目发布的新安装包更新。'),
        ]),
      ],
      14 => [
        _section(mobile, null, [
          const Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              children: [
                AppLogo(size: 64),
                SizedBox(height: 18),
                Text(
                  '人机',
                  style: TextStyle(fontSize: 25, fontWeight: FontWeight.w600),
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
        ]),
      ],
      15 => [OfficePlugins(state: s)],
      _ => [],
    };
  }

  Widget _mobileIndex() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      for (final group in [
        [0, 1],
        [4],
        [2, 7, 8, 9, 10, 3],
        [6, 5],
        [15],
        [11, 12],
        [13, 14],
      ])
        _section(true, group.first == 15 ? '人机 Agent' : null, [
          for (final tab in group)
            OfficeSettingsRow(
              title: _labels[tab],
              onTap: () => setState(() => _tab = tab),
            ),
        ]),
    ],
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _session,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth > 720;
        final tab = _tab < 0 ? 0 : _tab;
        return Material(
          color: wide ? Colors.white : const Color(0xfff5f6f8),
          child: Column(
            children: [
              Material(
                color: Colors.white,
                child: SizedBox(
                  height: wide ? 70 : 54,
                  child: Row(
                    children: [
                      if (!wide && (_tab >= 0 || widget.onClose != null))
                        IconButton(
                          tooltip: _tab >= 0 ? '返回设置' : '关闭设置',
                          onPressed: _tab >= 0
                              ? () => setState(() => _tab = -1)
                              : widget.onClose,
                          icon: const Icon(Icons.chevron_left),
                        ),
                      if (wide) const SizedBox(width: 24),
                      Expanded(
                        child: Text(
                          wide || _tab < 0 ? '设置' : _labels[tab],
                          textAlign: wide ? TextAlign.start : TextAlign.center,
                          style: TextStyle(
                            fontSize: wide ? 23 : 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (wide && widget.onClose != null)
                        IconButton(
                          tooltip: '关闭设置',
                          onPressed: widget.onClose,
                          icon: const Icon(Icons.close),
                        ),
                      const SizedBox(width: 16),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: !_session.valid
                    ? const Center(child: Text('工作身份已变更，请关闭后重新打开设置。'))
                    : !wide && _tab < 0
                    ? _mobileIndex()
                    : Row(
                        children: [
                          if (wide)
                            Material(
                              color: const Color(0xfff7f8fa),
                              child: SizedBox(
                                width: 208,
                                child: ListView(
                                  padding: const EdgeInsets.all(12),
                                  children: [
                                    for (
                                      var index = 0;
                                      index < _labels.length;
                                      index++
                                    ) ...[
                                      if (index == 15)
                                        const Padding(
                                          padding: EdgeInsets.fromLTRB(
                                            12,
                                            14,
                                            12,
                                            8,
                                          ),
                                          child: Text(
                                            '人机 Agent',
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: mutedColor,
                                            ),
                                          ),
                                        ),
                                      Material(
                                        color: tab == index
                                            ? selectedColor
                                            : Colors.transparent,
                                        borderRadius: BorderRadius.circular(6),
                                        child: ListTile(
                                          dense: true,
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                horizontal: 12,
                                              ),
                                          leading: Icon(
                                            _icons[index],
                                            size: 18,
                                            color: tab == index
                                                ? accentColor
                                                : mutedColor,
                                          ),
                                          minLeadingWidth: 19,
                                          title: Text(
                                            _label(index, false),
                                            style: const TextStyle(
                                              fontSize: 12,
                                            ),
                                          ),
                                          onTap: () =>
                                              setState(() => _tab = index),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          Expanded(
                            child: ListView(
                              key: ValueKey('settings-page-$tab'),
                              padding: EdgeInsets.all(wide ? 28 : 16),
                              children: [
                                if (wide) ...[
                                  Text(
                                    _label(tab, false),
                                    style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 26),
                                ],
                                ..._contents(tab, !wide),
                                OfficeSettingsFeedback(session: _session),
                                if (_accountError != null)
                                  BusinessError(_accountError),
                                if (_accountBusy && [0, 11].contains(tab))
                                  const LinearProgressIndicator(minHeight: 2),
                              ],
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    ),
  );
}
