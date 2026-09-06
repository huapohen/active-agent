import 'dart:async';
import 'dart:convert';

import 'package:active_office/office_state.dart';
import 'package:active_office/ui/room_details.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Json copyRoom(Json value) => Json.from(jsonDecode(jsonEncode(value)));

class RoomDetailsFixture extends OfficeState {
  RoomDetailsFixture({
    bool direct = false,
    bool agentOwner = false,
    this.canEdit = true,
  }) {
    connected = true;
    endpoint = 'https://room-details-fixture.example';
    me = {
      'id': agentOwner ? 'agent-1' : 'human-1',
      'name': '当前身份',
      'kind': agentOwner ? 'agent' : 'human',
    };
    selectedRoomId = 'unrelated-selection';
    room = {
      'id': 'room-1',
      'name': '人机项目群',
      'kind': direct ? 'direct' : 'group',
      'description': '共同完成办公任务',
      'revision': 42,
      'is_favorite': false,
      'is_pinned': false,
      'muted': false,
    };
    rooms = [room];
    members = [
      {
        'principal_id': 'human-1',
        'name': '真实人类',
        'kind': 'human',
        'role': agentOwner ? 'member' : 'owner',
      },
      {
        'principal_id': 'agent-1',
        'name': '真实 Agent',
        'kind': 'agent',
        'role': agentOwner ? 'owner' : 'member',
        'mode': 'mentions',
        'autonomy': {
          'enabled': false,
          'max_steps': 1,
          'review_interval_seconds': 300,
          'allowed_operations': [],
        },
      },
    ];
    detail = {'room': room, 'members': members};
  }
  late Json room;
  late List<Json> members;
  bool canEdit, conflictOnce = false, denied = false;
  final profile = <String, dynamic>{
    'room_id': 'room-1',
    'name': '人机项目群',
    'description': '共同完成办公任务',
    'revision': 3,
  };
  final announcement = <String, dynamic>{
    'room_id': 'room-1',
    'content': '周一交付共同文档',
    'revision': 7,
  };
  final calls = <Json>[];
  Completer<Json>? nextRead;

  void switchIdentity() {
    me = {'id': 'unrelated-person', 'kind': 'human', 'name': '其他身份'};
    notifyListeners();
  }

  List<Json> get patches =>
      calls.where((call) => call['method'] == 'PATCH').toList();

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    calls.add({
      'path': path,
      'method': method,
      'data': data == null ? null : copyRoom(data),
    });
    if (denied) throw OfficeException(403, '无权读取此会话');
    if (path == '/rooms/room-1') {
      final pending = nextRead;
      nextRead = null;
      return pending == null
          ? copyRoom({'room': room, 'members': members})
          : pending.future;
    }
    if (path == '/rooms/room-1/preferences') {
      for (final entry in data!.entries) {
        room[{
              'pinned': 'is_pinned',
              'favorite': 'is_favorite',
              'muted': 'muted',
            }[entry.key]!] =
            entry.value;
      }
      return copyRoom({'room': room});
    }
    final key = path.endsWith('/profile') ? 'profile' : 'announcement';
    final value = key == 'profile' ? profile : announcement;
    if (method == 'PATCH') {
      if (conflictOnce) {
        conflictOnce = false;
        value['revision'] = (value['revision'] as int) + 1;
        value[key == 'profile' ? 'description' : 'content'] = '另一位同事的最新编辑';
        throw OfficeException(409, '内容已被更新');
      }
      if (data!['base_revision'] != value['revision']) {
        throw OfficeException(409, '版本不一致');
      }
      value.addAll({...data}..remove('base_revision'));
      value['revision'] = (value['revision'] as int) + 1;
      if (key == 'profile') {
        room.addAll({
          'name': value['name'],
          'description': value['description'],
        });
      }
    }
    return copyRoom({
      key: value,
      'permissions': {'can_edit': canEdit},
    });
  }
}

Future<void> launchRoom(
  WidgetTester tester,
  RoomDetailsFixture state, {
  Size size = const Size(1100, 1100),
  VoidCallback? search,
}) async {
  tester.view.reset();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showOfficeRoomDetails(
              context,
              state,
              roomId: 'room-1',
              onSearch: search,
            ),
            child: const Text('打开详情'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开详情'));
  await tester.pumpAndSettle();
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'desktop drawer uses actual humans and agents; scoped independent preferences',
    (tester) async {
      final state = RoomDetailsFixture();
      await launchRoom(tester, state);
      expect(tester.getSize(find.byType(OfficeRoomDetails)).width, 400);
      expect(find.text('真实人类'), findsOneWidget);
      expect(find.text('真实 Agent'), findsOneWidget);
      expect(find.text('1 位人类 · 1 位 Agent'), findsOneWidget);
      for (final key in ['pinned', 'favorite', 'muted']) {
        await tapVisible(tester, find.byKey(ValueKey('room-preference-$key')));
        expect(state.patches.last['path'], '/rooms/room-1/preferences');
        expect(state.patches.last['data'], {key: true});
      }
      expect(state.room['is_pinned'], true);
      expect(state.room['is_favorite'], true);
      expect(state.room['muted'], true);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mobile direct details never request group-only endpoints', (
    tester,
  ) async {
    final state = RoomDetailsFixture(direct: true);
    await launchRoom(tester, state, size: const Size(390, 844));
    expect(tester.getSize(find.byType(OfficeRoomDetails)).width, 390);
    expect(find.text('会话详情'), findsOneWidget);
    expect(state.calls.map((call) => call['path']), ['/rooms/room-1']);
    expect(find.text('群公告'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final agent in [false, true]) {
    testWidgets(
      '${agent ? 'Agent' : 'human'} owner edits profile using own revision',
      (tester) async {
        final state = RoomDetailsFixture(agentOwner: agent);
        await launchRoom(tester, state);
        await tapVisible(tester, find.byTooltip('编辑群资料'));
        await tester.enterText(
          find.widgetWithText(TextFormField, '群名称'),
          '新的共同项目群',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, '群介绍'),
          '可见的共同工作',
        );
        await tapVisible(tester, find.text('保存'));
        expect(state.patches.single['path'], '/rooms/room-1/profile');
        expect(state.patches.single['data'], {
          'base_revision': 3,
          'name': '新的共同项目群',
          'description': '可见的共同工作',
        });
        expect(find.text('新的共同项目群'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('member permission remains read-only for Agent identity', (
    tester,
  ) async {
    final state = RoomDetailsFixture(agentOwner: true, canEdit: false);
    await launchRoom(tester, state);
    expect(find.byTooltip('编辑群资料'), findsNothing);
    expect(find.byTooltip('编辑群公告'), findsNothing);
    await tapVisible(tester, find.text('群公告'));
    expect(find.text('周一交付共同文档'), findsNWidgets(2));
    expect(state.patches, isEmpty);
  });

  testWidgets(
    'announcement conflict preserves draft and requires explicit revision adoption on mobile',
    (tester) async {
      final state = RoomDetailsFixture()..conflictOnce = true;
      await launchRoom(tester, state, size: const Size(390, 844));
      await tapVisible(tester, find.byTooltip('编辑群公告'));
      await tester.enterText(find.byType(TextFormField), '我的公告草稿');
      await tapVisible(tester, find.text('保存'));
      expect(state.patches.single['data'], {
        'base_revision': 7,
        'content': '我的公告草稿',
      });
      expect(find.text('我的公告草稿'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNull,
      );
      await tapVisible(tester, find.text('读取最新内容'));
      expect(find.text('另一位同事的最新编辑'), findsOneWidget);
      await tapVisible(tester, find.text('采用最新版本号，保留我的草稿'));
      expect(find.text('我的公告草稿'), findsOneWidget);
      await tapVisible(tester, find.text('保存'));
      expect(state.patches.last['data'], {
        'base_revision': 8,
        'content': '我的公告草稿',
      });
      expect(find.text('编辑群公告'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'search only filters real members and navigation closes the details route',
    (tester) async {
      var searches = 0;
      final state = RoomDetailsFixture();
      await launchRoom(tester, state, search: () => searches++);
      await tester.enterText(find.widgetWithText(TextField, '搜索群成员'), 'Agent');
      await tester.pumpAndSettle();
      expect(find.text('真实人类'), findsNothing);
      expect(find.text('真实 Agent'), findsOneWidget);
      expect(find.byTooltip('真实 Agent · 人格与参与'), findsOneWidget);
      await tapVisible(tester, find.text('查找聊天内容'));
      expect(searches, 1);
      expect(find.byType(OfficeRoomDetails), findsNothing);
    },
  );

  testWidgets(
    'identity switch hides profile draft and suppresses stale mutation',
    (tester) async {
      final state = RoomDetailsFixture();
      await launchRoom(tester, state);
      await tapVisible(tester, find.byTooltip('编辑群资料'));
      await tester.enterText(find.widgetWithText(TextFormField, '群名称'), '私有草稿');
      state.switchIdentity();
      await tester.pumpAndSettle();
      expect(find.text('私有草稿'), findsNothing);
      expect(find.byType(TextFormField), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNull,
      );
      expect(state.patches, isEmpty);
      await tapVisible(tester, find.text('取消'));
      expect(find.text('真实人类'), findsNothing);
    },
  );

  testWidgets(
    'late room response cannot restore content after identity changed',
    (tester) async {
      final state = RoomDetailsFixture();
      await launchRoom(tester, state);
      final pending = Completer<Json>();
      state.nextRead = pending;
      await tester.tap(find.byTooltip('刷新详情'));
      await tester.pump();
      state.switchIdentity();
      await tester.pump();
      pending.complete(
        copyRoom({'room': state.room, 'members': state.members}),
      );
      await tester.pumpAndSettle();
      expect(find.text('真实人类'), findsNothing);
      expect(find.text('人机项目群'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Agent participation dialog locks when identity changes', (
    tester,
  ) async {
    final state = RoomDetailsFixture();
    await launchRoom(tester, state);
    await tapVisible(tester, find.byTooltip('真实 Agent · 人格与参与'));
    expect(find.text('主动参与'), findsOneWidget);
    state.switchIdentity();
    await tester.pumpAndSettle();
    expect(find.text('主动参与'), findsNothing);
    expect(find.text('工作身份已变更'), findsOneWidget);
    expect(state.patches, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
