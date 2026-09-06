import 'dart:async';

import 'package:active_office/office_state.dart';
import 'package:active_office/ui/office_dialogs.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:active_office/ui/room_details.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'member_management_test.dart' show MemberFixture;
import 'room_details_test.dart' show copyRoom, tapVisible;

class RoomPreferencesFixture extends MemberFixture {
  RoomPreferencesFixture({super.agentOwner, super.direct}) {
    room.addAll({
      'folded': false,
      'mute_all_mentions': false,
      'is_marked': true,
    });
    for (final member in members) {
      preferences['${member['principal_id']}'] = {
        'folded': false,
        'mute_all_mentions': false,
        'muted': false,
        'pinned': false,
        'favorite': false,
        'read_seq': 12,
      };
    }
  }
  final preferences = <String, Json>{};
  int generation = 0, changes = 0;
  @override
  int get identityGeneration => generation;
  bool failPreference = false, nestedOnly = false;
  Completer<Json>? delayedPreference;
  Json get mine => preferences['${me!['id']}']!;
  Json project() {
    final projected = {
      ...room,
      'preferences': {...mine},
    };
    for (final key in ['folded', 'mute_all_mentions', 'muted']) {
      if (nestedOnly) {
        projected.remove(key);
      } else {
        projected[key] = mine[key];
      }
    }
    projected['is_pinned'] = mine['pinned'];
    projected['is_favorite'] = mine['favorite'];
    return projected;
  }

  void network(bool value) {
    connected = value;
    notifyListeners();
  }

  void switchTo(String id) {
    generation++;
    me = {
      'id': id,
      'kind': id.startsWith('agent') ? 'agent' : 'human',
      'name': 'Fixture $id',
    };
    notifyListeners();
  }

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    if (path == '/rooms/room-1' && method == 'GET') {
      calls.add({'path': path, 'method': method, 'data': data});
      return copyRoom({'room': project(), 'members': members});
    }
    if (path == '/rooms/room-1/preferences' && method == 'PATCH') {
      calls.add({'path': path, 'method': method, 'data': copyRoom(data!)});
      if (failPreference) throw OfficeException(503, '暂时无法保存个人偏好');
      if (delayedPreference != null) return delayedPreference!.future;
      if (data.keys.any(
            (key) => ![
              'folded',
              'mute_all_mentions',
              'muted',
              'pinned',
              'favorite',
            ].contains(key),
          ) ||
          data.values.any((value) => value is! bool)) {
        throw OfficeException(422, '无效个人偏好');
      }
      if (room['kind'] == 'direct' && data['mute_all_mentions'] == true) {
        throw OfficeException(422, '单聊不支持所有人提及');
      }
      mine.addAll(data);
      return copyRoom({'room': project(), 'preferences': mine});
    }
    return super.officeRequest(path, method: method, data: data);
  }
}

Finder preference(String key) => find.byKey(ValueKey('room-preference-$key'));
SwitchListTile control(WidgetTester tester, String key) =>
    tester.widget<SwitchListTile>(preference(key));

Future<void> openPreferences(
  WidgetTester tester,
  RoomPreferencesFixture state, {
  double width = 390,
  bool members = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 982);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => members
                ? OfficeDialogs.members(context, state, roomId: 'room-1')
                : showOfficeRoomDetails(
                    context,
                    state,
                    roomId: 'room-1',
                    onChanged: () => state.changes++,
                  ),
            child: const Text('打开固定会话'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开固定会话'));
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
}

void main() {
  for (final width in [390.0, 1512.0]) {
    for (final agent in [false, true]) {
      testWidgets(
        '${agent ? 'Agent' : 'Human'} personal preferences keep scope and Feishu order $width',
        (tester) async {
          final state = RoomPreferencesFixture(agentOwner: agent)
            ..canEdit = false;
          // Personal preferences do not require ownership or profile permissions.
          for (final member in state.members) {
            member['role'] = 'member';
          }
          final other = agent ? 'human-1' : 'agent-1';
          final otherBefore = copyRoom(state.preferences[other]!);
          await openPreferences(tester, state, width: width);
          final membersBefore = state.members.map(copyRoom).toList();
          expect(find.byTooltip('编辑群资料'), findsNothing);
          await tester.ensureVisible(preference('folded'));
          final order = find
              .byType(SwitchListTile)
              .evaluate()
              .map((e) => (e.widget as SwitchListTile).key)
              .toList();
          expect(order, [
            for (final key in [
              'muted',
              'folded',
              'mute_all_mentions',
              'pinned',
              'favorite',
            ])
              ValueKey('room-preference-$key'),
          ]);
          expect(find.text('移入后不再接收消息提醒，可在折叠的会话中查看'), findsOneWidget);
          expect(control(tester, 'folded').value, false);
          expect(control(tester, 'mute_all_mentions').value, false);
          await tapVisible(tester, preference('folded'));
          expect(state.patches.last['data'], {'folded': true});
          expect(control(tester, 'folded').value, true);
          await tapVisible(tester, preference('mute_all_mentions'));
          expect(state.patches.last['data'], {'mute_all_mentions': true});
          expect(control(tester, 'mute_all_mentions').value, true);
          expect(
            state.patches.every(
              (p) => p['path'] == '/rooms/room-1/preferences',
            ),
            true,
          );
          expect(state.selectedRoomId, 'unrelated-selection');
          expect(state.preferences[other], otherBefore);
          expect(state.members, membersBefore);
          expect(state.mine['read_seq'], 12);
          expect(state.room['revision'], 42);
          expect(state.room['is_marked'], true);
          expect(state.mine['favorite'], false);
          expect(state.changes, 2);
          await tapVisible(tester, preference('folded'));
          expect(state.patches.last['data'], {'folded': false});
          expect(state.mine['mute_all_mentions'], true);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final agent in [false, true]) {
    testWidgets(
      'Direct ${agent ? 'Agent' : 'Human'} chat can fold without group-only controls or reads',
      (tester) async {
        final state = RoomPreferencesFixture(agentOwner: agent, direct: true);
        await openPreferences(tester, state);
        expect(find.text('会话详情'), findsOneWidget);
        expect(preference('mute_all_mentions'), findsNothing);
        expect(find.text('群公告'), findsNothing);
        await tapVisible(tester, preference('folded'));
        expect(state.patches.single['data'], {'folded': true});
        expect(state.calls.map((c) => c['path']).toList(), [
          '/rooms/room-1',
          '/rooms/room-1/preferences',
        ]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Details read nested personal preferences when top-level fields are absent',
    (tester) async {
      final state = RoomPreferencesFixture()..nestedOnly = true;
      state.mine.addAll({'folded': true, 'mute_all_mentions': true});
      await openPreferences(tester, state);
      await tester.ensureVisible(preference('folded'));
      expect(control(tester, 'folded').value, true);
      expect(control(tester, 'mute_all_mentions').value, true);
      await tapVisible(tester, preference('mute_all_mentions'));
      expect(state.patches.single['data'], {'mute_all_mentions': false});
      expect(control(tester, 'mute_all_mentions').value, false);
      expect(control(tester, 'folded').value, true);
    },
  );

  testWidgets(
    'Failed personal preference preserves displayed server value and can retry',
    (tester) async {
      final state = RoomPreferencesFixture()..failPreference = true;
      await openPreferences(tester, state);
      await tapVisible(tester, preference('folded'));
      expect(control(tester, 'folded').value, false);
      expect(state.mine['folded'], false);
      expect(state.changes, 0);
      expect(find.text('暂时无法保存个人偏好'), findsOneWidget);
      state.failPreference = false;
      await tapVisible(tester, preference('folded'));
      expect(control(tester, 'folded').value, true);
      expect(state.patches.length, 2);
      expect(state.changes, 1);
    },
  );

  testWidgets(
    'Late personal preference response cannot restore A after A B A generation switch',
    (tester) async {
      final state = RoomPreferencesFixture();
      await openPreferences(tester, state);
      state.delayedPreference = Completer<Json>();
      await tester.ensureVisible(preference('folded'));
      await tester.tap(preference('folded'));
      await tester.pump();
      expect(control(tester, 'folded').onChanged, isNull);
      state.switchTo('agent-1');
      state.switchTo('human-1');
      state.delayedPreference!.complete(
        copyRoom({
          'room': {...state.project(), 'folded': true},
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('工作身份已变更，请关闭后重新打开会话详情。'), findsOneWidget);
      expect(preference('folded'), findsNothing);
      expect(find.text('人机项目群'), findsNothing);
      expect(state.changes, 0);
      expect(state.patches.length, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Temporary disconnect preserves room details and resumes preferences after reconnect',
    (tester) async {
      final state = RoomPreferencesFixture();
      await openPreferences(tester, state);
      state.network(false);
      await tester.pumpAndSettle();
      expect(find.text('人机项目群'), findsOneWidget);
      await tester.ensureVisible(preference('folded'));
      expect(control(tester, 'folded').onChanged, isNull);
      expect(control(tester, 'mute_all_mentions').onChanged, isNull);
      expect(find.textContaining('工作身份已变更'), findsNothing);
      expect(state.patches, isEmpty);
      state.network(true);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(control(tester, 'folded').onChanged, isNotNull);
      await tapVisible(tester, preference('folded'));
      expect(state.patches.single['data'], {'folded': true});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Group profile draft survives offline recovery but locks on same-ID generation change',
    (tester) async {
      final state = RoomPreferencesFixture();
      await openPreferences(tester, state);
      await tapVisible(tester, find.byTooltip('编辑群资料'));
      await tester.enterText(
        find.widgetWithText(TextFormField, '群名称'),
        '离线保留的群资料草稿',
      );
      state.network(false);
      await tester.pumpAndSettle();
      expect(find.text('离线保留的群资料草稿'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNull,
      );
      state.network(true);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNotNull,
      );
      await tapVisible(tester, find.text('保存'));
      expect(state.patches.single['data'], {
        'base_revision': 3,
        'name': '离线保留的群资料草稿',
        'description': '共同完成办公任务',
      });
      await tapVisible(tester, find.byTooltip('编辑群资料'));
      await tester.enterText(
        find.widgetWithText(TextFormField, '群名称'),
        '切回仍锁的旧草稿',
      );
      state.switchTo('agent-1');
      state.switchTo('human-1');
      await tester.pumpAndSettle();
      expect(find.byType(TextFormField), findsNothing);
      expect(find.text('切回仍锁的旧草稿'), findsNothing);
      expect(state.patches.length, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Member search and removal confirmation survive offline pause without sending writes',
    (tester) async {
      final state = RoomPreferencesFixture();
      await openPreferences(tester, state, members: true);
      final search = find.widgetWithText(TextField, '搜索成员姓名、群昵称或 ID');
      await tester.enterText(search, 'Agent');
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byTooltip('移除 真实 Agent'));
      state.network(false);
      await tester.pumpAndSettle();
      expect(find.textContaining('身份 ID：agent-1'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认移除'))
            .onPressed,
        isNull,
      );
      expect(state.deletions, isEmpty);
      await tapVisible(tester, find.text('取消'));
      expect(
        tester
            .widget<EditableText>(
              find.descendant(of: search, matching: find.byType(EditableText)),
            )
            .controller
            .text,
        'Agent',
      );
      expect(find.text('真实 Agent'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == '移除 真实 Agent',
              ),
            )
            .onPressed,
        isNull,
      );
      state.network(true);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == '移除 真实 Agent',
              ),
            )
            .onPressed,
        isNotNull,
      );
      await tapVisible(tester, find.byTooltip('移除 真实 Agent'));
      await tapVisible(tester, find.text('确认移除'));
      expect(state.deletions.single['path'], '/rooms/room-1/members/agent-1');
      expect(tester.takeException(), isNull);
    },
  );
}
