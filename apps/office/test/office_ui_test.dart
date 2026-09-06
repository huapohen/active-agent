import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:active_office/main.dart';
import 'package:active_office/office_state.dart';

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
    meetings = [];
    calendarEvents = [];
  }
  @override
  Future<void> refreshOffice() async {}
  @override
  Future<void> refresh() async {}
  @override
  Future<void> selectRoom(String id) async {
    selectedRoomId = id;
    notifyListeners();
  }
}

void main() {
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
      final send = tester.getRect(find.text('发送').last);
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
    expect(find.text('发送'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    state.dispose();
  });
}
