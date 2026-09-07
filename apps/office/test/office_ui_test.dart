import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:active_office/main.dart';
import 'package:active_office/office_state.dart';
import 'package:active_office/ui/settings.dart';
import 'package:active_office/ui/mailbox.dart';
import 'package:active_office/ui/approvals.dart';
import 'package:active_office/ui/mobile_more_menu.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;

class LayoutOfficeState extends OfficeState {
  LayoutOfficeState({String kind = 'human'}) {
    endpoint = 'https://office.example';
    me = {'id': 'me', 'name': '界面验证成员', 'kind': kind};
    connected = true;
    final now = DateTime.now().toUtc().toIso8601String();
    final room = <String, dynamic>{
      'id': 'room-demo',
      'name': '协作测试项目',
      'kind': 'group',
      'description': '讨论、文档与任务共享同一工作上下文',
      'preferences': {'favorite': true},
      'is_favorite': true,
      'unread_count': 0,
    };
    final doc = <String, dynamic>{
      'id': 'doc-demo',
      'title': '团队共同方案',
      'content': '# 共同目标\n\n完成可验证的协作闭环。',
      'revision': 1,
      'updated_at': now,
      'room_ids': ['room-demo'],
    };
    final message = <String, dynamic>{
      'id': 'message-demo',
      'seq': 1,
      'revision': 1,
      'author_id': 'me',
      'author': me,
      'content': '工作资料已准备好，我们在共同文档中继续完善。',
      'at': now,
      'mentions': <String>[],
      'reactions': <String, dynamic>{},
      'attachments': <Json>[],
    };
    rooms = [
      {...room, 'last_message': message},
    ];
    selectedRoomId = 'room-demo';
    principals = [
      me!,
      {'id': 'agent-demo', 'name': '协作 Agent', 'kind': 'agent'},
    ];
    agents = [principals.last];
    allDocuments = [doc];
    allTasks = [];
    detail = {
      'room': room,
      'members': [
        {
          'principal_id': 'me',
          'name': '界面验证成员',
          'kind': kind,
          'role': 'owner',
          'mode': 'active',
          'read_seq': 1,
        },
        {
          'principal_id': 'agent-demo',
          'name': '协作 Agent',
          'kind': 'agent',
          'role': 'member',
          'mode': 'mentions',
          'read_seq': 1,
        },
      ],
      'messages': [message],
      'documents': [doc],
      'tasks': <Json>[],
      'runs': <Json>[],
      'pins': <Json>[],
      'has_more_messages': false,
    };
    apps = [
      {
        'id': 'docs',
        'name': '共享文档',
        'route': '/office#docs',
        'available': true,
      },
      {
        'id': 'meetings',
        'name': '视频会议',
        'route': '/office#meetings',
        'available': true,
      },
      {
        'id': 'calendar',
        'name': '日历',
        'route': '/office#calendar',
        'available': true,
      },
      {
        'id': 'tasks',
        'name': '任务',
        'route': '/office#tasks',
        'available': true,
      },
    ];
    appFavorites = ['docs', 'meetings', 'calendar', 'tasks'];
    approvalTemplates = [
      {
        'id': 'general',
        'name': '通用审批',
        'fields': ['title', 'description', 'approver_id'],
      },
      {
        'id': 'leave',
        'name': '请假申请',
        'fields': ['title', 'description', 'approver_id', 'payload'],
      },
      {
        'id': 'expense',
        'name': '报销申请',
        'fields': ['title', 'description', 'approver_id', 'payload'],
      },
      {
        'id': 'attendance_correction',
        'name': '补卡申请',
        'fields': ['date', 'check_in_at'],
      },
    ];
    plugins = [
      {
        'id': 'native-docs',
        'name': '协作文档插件',
        'description': '共享内容',
        'builtin': true,
        'available': true,
        'enabled': true,
        'revision': 1,
        'config_schema': {},
        'capabilities': [],
      },
      {
        'id': 'demo-device',
        'name': '待连接设备',
        'description': '已登记的设备扩展',
        'builtin': false,
        'kind': 'hardware',
        'available': false,
        'enabled': false,
        'revision': 1,
        'config_schema': {
          'enabled_notes': {
            'type': 'boolean',
            'label': '记录备注',
            'default': false,
          },
        },
        'config': {},
        'capabilities': [],
      },
    ];
    settings = {
      'message_alignment': 'split',
      'send_shortcut': 'enter',
      'text_scale': 1.0,
      'show_message_preview': true,
      'revision': 1,
    };
    mailFolders = [
      {'id': 'inbox', 'name': '收件箱', 'count': 0},
      {'id': 'sent', 'name': '已发送', 'count': 0},
      {'id': 'drafts', 'name': '草稿箱', 'count': 0},
      {'id': 'archive', 'name': '归档', 'count': 0},
      {'id': 'trash', 'name': '废纸篓', 'count': 0},
    ];
    meetings = [];
    calendarEvents = [];
  }
  @override
  Future<void> refreshOffice() async {}
  @override
  Future<void> refreshBusiness() async {}
  @override
  Future<void> getAccount() async {}
  @override
  Future<void> loadAccountSessions() async {}
  @override
  Future<void> loadPlugins() async {}
  @override
  Future<void> configurePlugin(
    Json plugin, {
    bool? enabled,
    Json? config,
  }) async {
    final stored = plugins.firstWhere((p) => p['id'] == plugin['id']);
    if (enabled != null) stored['enabled'] = enabled;
    if (config != null) stored['config'] = config;
    notifyListeners();
  }

  @override
  Future<void> loadMail(String folder, {String query = ''}) async {
    mailFolder = folder;
    notifyListeners();
  }

  @override
  Future<void> saveSettings(Json changes, {int? baseRevision}) async {
    settings.addAll(changes);
    notifyListeners();
  }

  @override
  Future<void> refresh() async {}
  @override
  Future<void> selectRoom(String id) async {
    selectedRoomId = id;
    notifyListeners();
  }
}

class MailConflictOfficeState extends LayoutOfficeState {
  String? savedBody;
  int? savedRevision;
  List<String>? savedRecipients;
  @override
  Future<Json> getMail(String id) async => {
    'id': id,
    'revision': 2,
    'status': 'draft',
    'subject': '共同邮件',
    'body': '另一个客户端的新内容',
    'to_ids': ['agent-demo'],
  };
  @override
  Future<Json> saveMailDraft({
    String? id,
    int? baseRevision,
    List<String> toIds = const [],
    List<String> ccIds = const [],
    List<String> bccIds = const [],
    String subject = '',
    String body = '',
  }) async {
    if (baseRevision == 1) throw OfficeException(409, '共同版本已变化。你的草稿仍在');
    savedBody = body;
    savedRevision = baseRevision;
    savedRecipients = toIds;
    return {
      'id': id,
      'revision': 3,
      'status': 'draft',
      'subject': subject,
      'body': body,
      'to_ids': toIds,
    };
  }
}

class ApprovalDetailOfficeState extends LayoutOfficeState {
  @override
  Future<Json> getApproval(String id) async => {
    'id': id,
    'title': '补卡申请',
    'created_by': 'me',
    'approver_id': 'agent-demo',
    'status': 'approved',
    'created_at': '2026-09-06T00:00:00Z',
    'description': '恢复漏记的上班记录',
    'payload': {
      'principal_id': 'me',
      'date': '2026-09-06',
      'timezone': 'Asia/Shanghai',
      'record_id': 'private-record-id',
      'base_record_revision': 3,
      'check_in_at': '2026-09-06T01:30:00Z',
      'check_out_at': null,
    },
    'audit': <Json>[],
  };
}

class IndependentBusinessOfficeState extends LayoutOfficeState {
  IndependentBusinessOfficeState() {
    libraryRooms = [
      {'id': 'room-demo', 'name': '独立业务空间', 'members': principals},
    ];
    selectedRoomId = null;
    detail = null;
    rooms = [];
    unavailableModules.add('im');
    allDocuments = [
      {
        'id': 'doc-demo',
        'title': '独立共同文档',
        'revision': 1,
        'room_ids': ['room-demo'],
      },
    ];
    allTasks = [
      {
        'id': 'task-demo',
        'room_id': 'room-demo',
        'room_name': '独立业务空间',
        'title': '交付共同成果',
        'status': 'open',
        'revision': 1,
        'assignee_id': 'agent-demo',
      },
    ];
  }
  String? documentReadRoom, documentSavedRoom, taskUpdatedRoom, taskStatus;
  @override
  Future<void> selectRoom(String id) async =>
      throw StateError('IM must remain unavailable');
  @override
  Future<Json> getDocument(String id, {required String roomId}) async {
    documentReadRoom = roomId;
    return {'id': id, 'title': '独立共同文档', 'content': '独立业务正文', 'revision': 1};
  }

  @override
  Future<Json> saveDocument({
    String? id,
    required String title,
    required String content,
    int? baseRevision,
    String? roomId,
  }) async {
    documentSavedRoom = roomId;
    return {
      'id': id ?? 'new-doc',
      'title': title,
      'content': content,
      'revision': 2,
    };
  }

  @override
  Future<void> updateTask(
    Json task, {
    String? status,
    String? assigneeId,
    String? roomId,
  }) async {
    taskUpdatedRoom = roomId ?? task['room_id'];
    taskStatus = status;
    task['status'] = status ?? task['status'];
    task['revision'] = 2;
    notifyListeners();
  }
}

void main() {
  testWidgets(
    'Mobile Agent destination sits beside messages and opens colleague and store pages',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = LayoutOfficeState();
      state.catalog = [
        {
          'id': 'writer',
          'name': '演示技术作家',
          'profession': '技术写作',
          'description': '整理团队共同文档',
          'category_name': '产品与研发',
          'category_id': 'product',
          'skills': ['技术文档'],
        },
      ];
      await tester.pumpWidget(ActiveOfficeApp(state: state));
      await tester.pumpAndSettle();
      final navigation = tester.widget<NavigationBar>(
        find.byType(NavigationBar),
      );
      expect(
        navigation.destinations.whereType<NavigationDestination>().map(
          (item) => item.label,
        ),
        ['消息', 'Agent', '云文档', '工作台', '更多'],
      );
      final messageTab = find.widgetWithText(NavigationDestination, '消息');
      final agentTab = find.widgetWithText(NavigationDestination, 'Agent');
      final documentsTab = find.widgetWithText(NavigationDestination, '云文档');
      expect(
        tester.getCenter(agentTab).dx,
        greaterThan(tester.getCenter(messageTab).dx),
      );
      expect(
        tester.getCenter(agentTab).dx,
        lessThan(tester.getCenter(documentsTab).dx),
      );
      await tester.tap(agentTab);
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        1,
      );
      expect(find.text('协作 Agent'), findsOneWidget);
      expect(find.text('你的工作伙伴，共同参与、主动推进。'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Agent 商店'));
      await tester.pumpAndSettle();
      expect(find.text('演示技术作家'), findsOneWidget);
      await tester.tap(find.widgetWithText(NavigationDestination, '更多'));
      await tester.pumpAndSettle();
      expect(find.text('视频会议'), findsOneWidget);
      expect(find.text('邮箱'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );
  testWidgets('Mobile composer expands draft and opens actual task tools', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = LayoutOfficeState();
    await tester.pumpWidget(ActiveOfficeApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.text('协作测试项目').last);
    await tester.pumpAndSettle();
    final composer = find.byKey(const ValueKey('composer-input'));
    await tester.enterText(composer, '准备工作');
    await tester.tap(find.byTooltip('展开消息编辑器'));
    await tester.pumpAndSettle();
    final expanded = find.byKey(const ValueKey('expanded-body'));
    await tester.enterText(expanded, '完整工作背景\n下一步一起完成');
    await tester.tap(find.byKey(const ValueKey('expanded-collapse')));
    await tester.pumpAndSettle();
    expect(
      tester.takeException(),
      isNull,
      reason: 'Expanded editor must close safely',
    );
    expect(
      tester.widget<TextField>(composer).controller!.text,
      '完整工作背景\n下一步一起完成',
    );
    await tester.tap(find.byTooltip('更多工作工具'));
    await tester.pumpAndSettle();
    expect(
      tester.takeException(),
      isNull,
      reason: 'Mobile tools must fit the screen',
    );
    expect(find.text('文件与图片'), findsOneWidget);
    expect(find.text('日程'), findsOneWidget);
    expect(find.text('发起会议'), findsOneWidget);
    await tester.tap(find.text('任务').last);
    await tester.pumpAndSettle();
    expect(find.text('新建任务'), findsOneWidget);
    expect(find.text('目标与验收条件'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
  testWidgets('Docs and tasks remain writable when IM is disabled', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1512, 982);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = IndependentBusinessOfficeState();
    await tester.pumpWidget(ActiveOfficeApp(state: state));
    await tester.pumpAndSettle();
    expect(find.text('企业策略已限制此应用'), findsOneWidget);
    await tester.tap(find.text('云文档').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('独立共同文档'));
    await tester.pumpAndSettle();
    expect(state.documentReadRoom, 'room-demo');
    expect(find.text('独立业务正文'), findsOneWidget);
    await tester.tap(find.text('保存共同文档'));
    await tester.pumpAndSettle();
    expect(state.documentSavedRoom, 'room-demo');
    await tester.tap(find.byTooltip('关闭文档'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('任务').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('交付共同成果'));
    await tester.pumpAndSettle();
    expect(find.text('协作 Agent · Agent'), findsOneWidget);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(state.taskUpdatedRoom, 'room-demo');
    expect(state.taskStatus, 'done');
    expect(state.selectedRoomId, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
  testWidgets('Document closing keeps unsaved draft through route transition', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = IndependentBusinessOfficeState();
    state.endpoint = 'https://document-draft.example';
    await tester.pumpWidget(ActiveOfficeApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.text('云文档').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('独立共同文档'));
    await tester.pumpAndSettle();
    final title = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '给这份文档起个名字',
    );
    final body = find.byWidgetPredicate(
      (w) =>
          w is TextField && w.decoration?.hintText == '# 共同目标\n\n写下背景、依据和行动计划…',
    );
    await tester.enterText(title, '还未提交的共同方案');
    await tester.enterText(body, '# 新增依据\n保留我的本地修改');
    await tester.tap(find.byTooltip('关闭文档'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      tester.takeException(),
      isNull,
      reason: 'Controllers must survive reverse animation',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('独立共同文档'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(title).controller!.text, '还未提交的共同方案');
    expect(tester.widget<TextField>(body).controller!.text, '# 新增依据\n保留我的本地修改');
    expect(state.documentSavedRoom, isNull);
    expect(find.text('共同版本 r1'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭文档'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
  testWidgets('Approval shows business time and folds record identifiers', (
    tester,
  ) async {
    final state = ApprovalDetailOfficeState();
    final key = GlobalKey<OfficeApprovalsState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: officeTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        ),
        home: Scaffold(
          body: OfficeApprovals(key: key, state: state),
        ),
      ),
    );
    await tester.pumpAndSettle();
    key.currentState!.open('approval-demo');
    await tester.pumpAndSettle();
    expect(find.text('上班时间：2026/09/06 09:30（北京时间）'), findsOneWidget);
    expect(find.text('时区：北京时间（UTC+8）'), findsOneWidget);
    expect(find.text('原记录版本：第 3 版'), findsOneWidget);
    expect(find.textContaining('下班时间'), findsNothing);
    expect(find.textContaining('principal_id'), findsNothing);
    expect(find.textContaining('private-record-id'), findsNothing);
    await tester.ensureVisible(find.text('记录详情'));
    await tester.tap(find.text('记录详情'));
    await tester.pumpAndSettle();
    expect(find.text('考勤记录编号：private-record-id'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
  for (final tool in [('创建日程', '日程主题'), ('发起会议', '会议主题')]) {
    testWidgets('Desktop composer opens real ${tool.$1} form', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1512, 982);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = LayoutOfficeState();
      await tester.pumpWidget(ActiveOfficeApp(state: state));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('composer-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(tool.$1));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, tool.$2), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('消息').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('composer-input')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    });
  }
  testWidgets('Denied apps lock inner tabs and composer actions', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1512, 982);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = LayoutOfficeState()
      ..unavailableModules.addAll(['docs', 'tasks']);
    await tester.pumpWidget(ActiveOfficeApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('composer-more')));
    await tester.pumpAndSettle();
    for (final label in ['新建共同文档', '创建任务']) {
      final item = find.ancestor(
        of: find.text(label),
        matching: find.byType(PopupMenuItem<String>),
      );
      expect(tester.widget<PopupMenuItem<String>>(item).enabled, isFalse);
      await tester.tap(find.text(label), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('目标与验收条件'), findsNothing);
      expect(find.text('文档标题'), findsNothing);
    }
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.text('云文档').last);
    await tester.pumpAndSettle();
    expect(find.text('企业策略限制了此应用'), findsOneWidget);
    expect(find.text('团队共同方案'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
  for (final dimensions in [
    const Size(390, 844),
    const Size(943, 665),
    const Size(1512, 982),
  ]) {
    testWidgets('Office layout and app routes ${dimensions.width.toInt()}', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = dimensions;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = LayoutOfficeState();
      await tester.pumpWidget(ActiveOfficeApp(state: state));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (dimensions.width < 760) {
        await tester.tap(find.text('协作测试项目').last);
        await tester.pumpAndSettle();
      }
      await tester.enterText(
        find.byKey(const ValueKey('composer-input')),
        '布局检查草稿',
      );
      await tester.pumpAndSettle();
      final send = tester.getRect(find.byKey(const ValueKey('composer-send')));
      expect(send.right, lessThanOrEqualTo(dimensions.width));
      expect(send.bottom, lessThanOrEqualTo(dimensions.height));
      expect(tester.takeException(), isNull);
      if (dimensions.width < 760) {
        await tester.tap(find.byTooltip('返回会话'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('云文档').first);
      await tester.pumpAndSettle();
      expect(find.text('团队共同方案'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('工作台').first);
      await tester.pumpAndSettle();
      expect(find.text('我的常用'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('共享文档').first);
      await tester.pumpAndSettle();
      expect(find.text('主页'), findsWidgets);
      expect(tester.takeException(), isNull);
      if (dimensions.width < 760) {
        await tester.tap(find.text('更多').first);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('视频会议').first);
      await tester.pumpAndSettle();
      expect(find.text('发起会议'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (dimensions.width < 760) {
        await tester.tap(find.text('更多').first);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('日历').first);
      await tester.pumpAndSettle();
      expect(find.text('今天'), findsOneWidget);
      expect(tester.takeException(), isNull);
      for (final (entry, id) in [
        ('邮箱', 'mail'),
        ('考勤', 'attendance'),
        ('审批', 'approvals'),
        ('设置', 'settings'),
      ]) {
        late Finder destination;
        late Finder navigationScroll;
        if (dimensions.width < 760) {
          await tester.tap(find.widgetWithText(NavigationDestination, '更多'));
          await tester.pumpAndSettle();
          final menu = find.byType(OfficeMobileMoreMenu);
          destination = find.descendant(
            of: menu,
            matching: find.widgetWithText(ListTile, entry),
          );
          navigationScroll = find
              .descendant(of: menu, matching: find.byType(Scrollable))
              .first;
        } else {
          final rail = find
              .ancestor(
                of: find.byKey(const ValueKey('desktop-navigation-editor')),
                matching: find.byType(Column),
              )
              .first;
          destination = find.byKey(ValueKey('desktop-nav-$id'));
          final navigationList = find
              .descendant(of: rail, matching: find.byType(ListView))
              .first;
          navigationScroll = find
              .descendant(of: navigationList, matching: find.byType(Scrollable))
              .first;
        }
        // Navigation lists build offscreen entries lazily at smaller sizes.
        await tester.scrollUntilVisible(
          destination,
          160,
          scrollable: navigationScroll,
        );
        await tester.pumpAndSettle();
        expect(destination.hitTestable(), findsOneWidget, reason: entry);
        await tester.tap(destination);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: entry);
        expect(find.text(entry), findsWidgets);
      }

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      state.dispose();
    });
  }
  testWidgets('Agent login has identical office navigation', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1512, 982);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = LayoutOfficeState(kind: 'agent');
    await tester.pumpWidget(ActiveOfficeApp(state: state));
    await tester.pumpAndSettle();
    for (final entry in [
      '消息',
      'Agent',
      '通讯录',
      '云文档',
      '任务',
      '工作台',
      '视频会议',
      '日历',
    ]) {
      expect(find.text(entry), findsWidgets);
    }
    expect(find.byKey(const ValueKey('composer-send')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    state.dispose();
  });
  for (final size in [const Size(390, 844), const Size(1512, 982)]) {
    testWidgets('Native mention and Agent collaboration ${size.width}', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = LayoutOfficeState();
      await tester.pumpWidget(ActiveOfficeApp(state: state));
      await tester.pumpAndSettle();
      if (size.width < 760) {
        await tester.tap(find.text('协作测试项目').last);
        await tester.pumpAndSettle();
      }
      final composer = find.byKey(const ValueKey('composer-input'));
      await tester.enterText(composer, '');
      await tester.enterText(composer, '继续讨论 @');
      await tester.pumpAndSettle();
      expect(find.text('选择成员'), findsOneWidget);
      expect(find.text('@所有人 (2)'), findsOneWidget);
      await tester.tap(find.byTooltip('取消选择'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(composer).controller!.text, '继续讨论 @');
      await tester.tap(find.byTooltip('Agent 协作'));
      await tester.pumpAndSettle();
      expect(find.text('工作记录与成果'), findsOneWidget);
      expect(find.text('参与方式'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭 Agent 协作'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      state.dispose();
    });
  }
  testWidgets('Office settings persist actual selected behavior', (
    tester,
  ) async {
    final state = LayoutOfficeState();
    await tester.pumpWidget(
      MaterialApp(
        theme: officeTheme(),
        home: Scaffold(
          body: AnimatedBuilder(
            animation: state,
            builder: (_, _) => OfficeSettings(state: state),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('通用').first);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('消息气泡左对齐'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('消息气泡左对齐'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('消息气泡左对齐'));
    await tester.pumpAndSettle();
    expect(state.settings['message_alignment'], 'left');
    await tester.tap(find.text('快捷键').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ctrl / ⌘ + Enter 发送'));
    await tester.pumpAndSettle();
    expect(state.settings['send_shortcut'], 'mod_enter');
    await tester.scrollUntilVisible(
      find.text('Agent 与插件'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Agent 与插件').first);
    await tester.pumpAndSettle();
    expect(find.text('已登记，尚未连接'), findsOneWidget);
    final extensionSwitch = find.byWidgetPredicate(
      (w) => w is SwitchListTile && w.value == false,
    );
    await tester.ensureVisible(extensionSwitch);
    await tester.tap(extensionSwitch);
    await tester.pumpAndSettle();
    expect(state.plugins.last['enabled'], true);
    expect(find.text('已登记，尚未连接'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
  testWidgets('Mail draft conflict keeps author text until explicit merge', (
    tester,
  ) async {
    final state = MailConflictOfficeState();
    final key = GlobalKey<OfficeMailboxState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: officeTheme(),
        home: Scaffold(
          body: OfficeMailbox(key: key, state: state),
        ),
      ),
    );
    await tester.pumpAndSettle();
    key.currentState!.compose({
      'id': 'mail-draft',
      'revision': 1,
      'status': 'draft',
      'subject': '共同邮件',
      'body': '本地旧内容',
      'to_ids': ['agent-demo'],
    });
    await tester.pumpAndSettle();
    final body = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '写下需要正式沟通的内容',
    );
    await tester.enterText(body, '我正在合并的编辑');
    await tester.tap(find.text('保存草稿'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(body).controller!.text, '我正在合并的编辑');
    expect(find.textContaining('另一个客户端的新内容'), findsOneWidget);
    final merge = find.text('保留我的编辑，以最新版本继续合并');
    await tester.ensureVisible(merge);
    await tester.tap(merge);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存草稿'));
    await tester.pumpAndSettle();
    expect(state.savedBody, '我正在合并的编辑');
    expect(state.savedRevision, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    state.dispose();
  });
}
