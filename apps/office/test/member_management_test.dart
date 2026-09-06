import 'package:active_office/office_state.dart';
import 'package:active_office/ui/office_dialogs.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:active_office/ui/room_details.dart';
import 'package:active_office/ui/room_nickname.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'room_details_test.dart' show RoomDetailsFixture, copyRoom, tapVisible;

class MemberFixture extends RoomDetailsFixture {
  MemberFixture({super.agentOwner, super.direct}) {
    principals = [
      {'id': 'new-person', 'kind': 'human', 'name': '待加入同事'},
    ];
  }
  List<Json> get deletions =>
      calls.where((call) => call['method'] == 'DELETE').toList();
  @override
  Future<void> refresh() async {}

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    if (method == 'DELETE') {
      calls.add({'path': path, 'method': method, 'data': data});
      members.removeWhere(
        (member) => member['principal_id'] == path.split('/').last,
      );
      return {'removed': true};
    }
    if (path.endsWith('/members') && method == 'POST') {
      calls.add({'path': path, 'method': method, 'data': data});
      final principal = principals.firstWhere(
        (person) => person['id'] == data!['principal_id'],
      );
      final member = {
        ...principal,
        'principal_id': principal['id'],
        'role': 'member',
      };
      members.add(member);
      return copyRoom({'member': member});
    }
    return super.officeRequest(path, method: method, data: data);
  }
}

Future<void> launchMembers(
  WidgetTester tester,
  MemberFixture state, {
  bool nickname = false,
  bool details = false,
  bool applications = false,
  VoidCallback? tasks,
}) async {
  tester.view.physicalSize = const Size(390, 844);
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
            onPressed: () {
              if (nickname) {
                showOfficeRoomNickname(context, state, roomId: 'room-1');
              } else if (details) {
                showOfficeRoomDetails(
                  context,
                  state,
                  roomId: 'room-1',
                  onTasks: tasks,
                  onDocuments: applications ? () {} : null,
                  onRecords: applications ? () {} : null,
                );
              } else {
                OfficeDialogs.members(context, state, roomId: 'room-1');
              }
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void main() {
  for (final agent in [false, true]) {
    testWidgets(
      '${agent ? 'Agent' : 'human'} owner removes exact confirmed target from fixed room',
      (tester) async {
        final state = MemberFixture(agentOwner: agent);
        final targetName = agent ? '真实人类' : '真实 Agent';
        final targetId = agent ? 'human-1' : 'agent-1';
        await launchMembers(tester, state);
        await tapVisible(tester, find.byTooltip('移除 $targetName'));
        expect(find.textContaining('身份 ID：$targetId'), findsOneWidget);
        expect(find.textContaining('人机项目群'), findsNWidgets(2));
        expect(state.deletions, isEmpty);
        await tapVisible(tester, find.text('确认移除'));
        expect(state.deletions.single, {
          'path': '/rooms/room-1/members/$targetId',
          'method': 'DELETE',
          'data': {},
        });
        expect(
          state.members.any((member) => member['principal_id'] == targetId),
          false,
        );
        expect(find.byTooltip('移除 $targetName'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${agent ? 'Agent' : 'human'} changes only own nickname using independent revision',
      (tester) async {
        final state = MemberFixture(agentOwner: agent);
        await launchMembers(tester, state, nickname: true);
        await tester.enterText(find.byType(TextField), '  文档协作同事  ');
        await tapVisible(tester, find.text('保存昵称'));
        expect(
          state.patches.single['path'],
          '/rooms/room-1/membership-profile',
        );
        expect(state.patches.single['data'], {
          'nickname': '文档协作同事',
          'base_revision': 5,
        });
        expect(
          state.members.firstWhere(
            (member) => member['principal_id'] == state.me!['id'],
          )['display_name'],
          '文档协作同事',
        );
        expect(find.text('保存昵称'), findsNothing);
      },
    );
  }

  testWidgets('member removal cancel and protected owner/self never mutate', (
    tester,
  ) async {
    final state = MemberFixture();
    state.members.add({
      'principal_id': 'second-owner',
      'name': '另一位负责人',
      'kind': 'human',
      'role': 'owner',
    });
    await launchMembers(tester, state);
    expect(find.byTooltip('移除 真实人类'), findsNothing);
    expect(find.byTooltip('移除 另一位负责人'), findsNothing);
    await tapVisible(tester, find.byTooltip('移除 真实 Agent'));
    await tapVisible(tester, find.text('取消'));
    expect(state.deletions, isEmpty);
  });

  testWidgets('role change during confirmation prevents deletion', (
    tester,
  ) async {
    final state = MemberFixture();
    await launchMembers(tester, state);
    await tapVisible(tester, find.byTooltip('移除 真实 Agent'));
    state.members.last['role'] = 'owner';
    await tapVisible(tester, find.text('确认移除'));
    expect(state.deletions, isEmpty);
    expect(find.text('成员权限已变化，不能移除该成员'), findsOneWidget);
  });

  testWidgets(
    'identity change hides confirmation target and suppresses mutation',
    (tester) async {
      final state = MemberFixture();
      await launchMembers(tester, state);
      await tapVisible(tester, find.byTooltip('移除 真实 Agent'));
      state.switchIdentity();
      await tester.pumpAndSettle();
      expect(find.textContaining('身份 ID：agent-1'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认移除'))
            .onPressed,
        isNull,
      );
      expect(state.deletions, isEmpty);
    },
  );

  testWidgets(
    'direct conversation exposes no membership mutation or group nickname',
    (tester) async {
      final state = MemberFixture(direct: true);
      await launchMembers(tester, state);
      expect(find.byIcon(Icons.person_remove_outlined), findsNothing);
      expect(find.text('添加工作成员'), findsNothing);
      expect(find.text('我在本群的昵称'), findsNothing);
    },
  );

  testWidgets(
    'ordinary member can set own nickname but cannot add or remove people',
    (tester) async {
      final state = MemberFixture();
      state.members.first['role'] = 'member';
      await launchMembers(tester, state);
      expect(find.byIcon(Icons.person_remove_outlined), findsNothing);
      expect(find.text('添加工作成员'), findsNothing);
      expect(find.text('我在本群的昵称'), findsOneWidget);
    },
  );

  testWidgets(
    'member search accepts nickname and retains canonical identity; invite uses fixed room',
    (tester) async {
      final state = MemberFixture();
      state.members.last.addAll({'nickname': '文档搭档', 'display_name': '文档搭档'});
      await launchMembers(tester, state);
      await tester.enterText(
        find.widgetWithText(TextField, '搜索成员姓名、群昵称或 ID'),
        '文档搭档',
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: find.byType(ListTile), matching: find.text('文档搭档')),
        findsOneWidget,
      );
      expect(find.text('工作成员 · 真实 Agent'), findsOneWidget);
      await tapVisible(tester, find.text('添加'));
      expect(state.calls.where((call) => call['method'] == 'POST').single, {
        'path': '/rooms/room-1/members',
        'method': 'POST',
        'data': {'principal_id': 'new-person'},
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'nickname conflict retains draft and explicitly adopts latest revision',
    (tester) async {
      final state = MemberFixture()..conflictOnce = true;
      await launchMembers(tester, state, nickname: true);
      await tester.enterText(find.byType(TextField), '我的群昵称');
      await tapVisible(tester, find.text('保存昵称'));
      expect(find.text('我的群昵称'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存昵称'))
            .onPressed,
        isNull,
      );
      await tapVisible(tester, find.text('读取最新昵称'));
      expect(find.text('最新昵称：另一端的新昵称'), findsOneWidget);
      await tapVisible(tester, find.text('采用最新版本号，保留我的昵称'));
      await tapVisible(tester, find.text('保存昵称'));
      expect(state.patches.last['data'], {
        'nickname': '我的群昵称',
        'base_revision': 6,
      });
    },
  );

  testWidgets(
    'empty nickname resets canonical name and identity switch locks a draft',
    (tester) async {
      final state = MemberFixture();
      state.membership['nickname'] = '曾经的昵称';
      await launchMembers(tester, state, nickname: true);
      await tester.enterText(find.byType(TextField), '');
      await tapVisible(tester, find.text('保存昵称'));
      expect(state.patches.single['data'], {
        'nickname': '',
        'base_revision': 5,
      });
      expect(state.membership['display_name'], '真实人类');
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '私有昵称草稿');
      state.switchIdentity();
      await tester.pumpAndSettle();
      expect(find.text('私有昵称草稿'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存昵称'))
            .onPressed,
        isNull,
      );
      expect(state.patches.length, 1);
    },
  );

  testWidgets(
    'mobile detail has horizontal people and real group application links',
    (tester) async {
      var tasks = 0;
      final state = MemberFixture();
      await launchMembers(
        tester,
        state,
        details: true,
        applications: true,
        tasks: () => tasks++,
      );
      expect(
        tester
            .widget<ListView>(find.byKey(const ValueKey('room-member-strip')))
            .scrollDirection,
        Axis.horizontal,
      );
      expect(find.byTooltip('添加群成员'), findsOneWidget);
      expect(find.text('群应用'), findsOneWidget);
      expect(find.text('查看全部 2 位成员'), findsOneWidget);
      await tapVisible(tester, find.text('任务').first);
      expect(tasks, 1);
      expect(find.byType(OfficeRoomDetails), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
