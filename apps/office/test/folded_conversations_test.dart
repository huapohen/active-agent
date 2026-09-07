import 'dart:async';

import 'package:active_office/main.dart';
import 'package:active_office/office_state.dart';
import 'package:active_office/ui/conversation.dart';
import 'package:active_office/ui/conversation_list.dart';
import 'package:active_office/ui/message_group_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'message_groups_test.dart' show MessageGroupOfficeFixture, groupCopy;

/// Real shell, folder, menus, grouping controller and conversation widgets.
/// Only transport snapshots and room loading are replaced by deterministic data.
class FoldedOfficeFixture extends MessageGroupOfficeFixture {
  FoldedOfficeFixture({bool agent = false}) {
    rooms[0].addAll({'is_favorite': true, 'unread_count': 0});
    rooms[1].addAll({
      'folded': true,
      'is_favorite': true,
      'is_pinned': true,
      'unread_count': 7,
      // A stale pre-fold response must not resurrect navigation alerts.
      'notification_count': 7,
      'mention_count': 2,
      'explicit_mention_count': 1,
      'preferences': {'folded': true, 'favorite': true, 'muted': false},
    });
    rooms[2].addAll({
      'preferences': {'folded': true},
      'unread_count': 3,
      'notification_count': 0,
    });
    if (agent) switchIdentity('agent-fixture');
  }

  int generation = 0, refreshes = 0;
  bool failNextWrite = false;
  Completer<Json>? pendingWrite;
  final pendingPreferences = <String, Json>{};
  final openedRooms = <String>[];

  @override
  int get identityGeneration => generation;

  void advanceGeneration() {
    generation++;
    notifyListeners();
  }

  void goOffline() {
    connected = false;
    notifyListeners();
  }

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    if (!path.endsWith('/preferences')) {
      return super.officeRequest(path, method: method, data: data);
    }
    calls.add({
      'owner': identity,
      'path': path,
      'method': method,
      'data': data == null ? null : groupCopy(data),
    });
    expect(method, 'PATCH');
    expect(data!.keys, ['folded']);
    if (failNextWrite) {
      failNextWrite = false;
      throw OfficeException(503, '合成网络中断，请重试');
    }
    if (pendingWrite case final request?) return request.future;
    final id = Uri.decodeComponent(path.split('/')[2]);
    pendingPreferences[id] = groupCopy(data);
    return {'preferences': groupCopy(data)};
  }

  @override
  Future<void> refresh() async {
    refreshes++;
    rooms = [
      for (final room in rooms)
        if (pendingPreferences[room['id']] case final changes?)
          {
            ...room,
            ...changes,
            'preferences': {...?room['preferences'] as Map?, ...changes},
          }
        else
          room,
    ];
    pendingPreferences.clear();
    notifyListeners();
  }

  @override
  Future<void> selectRoom(String id) async {
    openedRooms.add(id);
    selectedRoomId = id;
    detail = {
      'room': groupCopy(rooms.firstWhere((room) => room['id'] == id)),
      'members': principals
          .map((person) => {...person, 'principal_id': person['id']})
          .toList(),
      'messages': <Json>[],
      'documents': <Json>[],
      'tasks': <Json>[],
      'runs': <Json>[],
      'pins': <Json>[],
      'has_more_messages': false,
    };
    notifyListeners();
  }
}

Finder roomRow(String id) => find.byKey(ValueKey('room-row-$id'));
Finder roomMenu(String id) => find.descendant(
  of: roomRow(id),
  matching: find.byType(PopupMenuButton<String>),
);
Finder inputWithHint(String hint) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.hintText == hint,
);

Future<void> mountFolded(
  WidgetTester tester,
  FoldedOfficeFixture state, {
  Size size = const Size(1512, 982),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.view.resetViewInsets();
    state.dispose();
  });
  await tester.pumpWidget(ActiveOfficeApp(state: state));
  await tester.pumpAndSettle();
}

Future<void> openFolder(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('folded-summary')));
  await tester.pumpAndSettle();
  expect(find.byType(OfficeFoldedConversations), findsOneWidget);
}

Future<void> openRoomMenu(WidgetTester tester, String id) async {
  await tester.tap(roomMenu(id));
  await tester.pumpAndSettle();
}

Future<void> closeFoldedTest(WidgetTester tester) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  for (final size in [const Size(390, 844), const Size(1512, 982)]) {
    testWidgets(
      '${size.width.toInt()}px default and favorites aggregate folded rooms while search and other groups retain them',
      (tester) async {
        final state = FoldedOfficeFixture();
        await mountFolded(tester, state, size: size);
        expect(roomRow('room-human'), findsOneWidget);
        expect(roomRow('room-agent'), findsNothing);
        expect(roomRow('room-mixed'), findsNothing);
        // The folded favorite must not leak into the horizontal favorites row.
        expect(find.text('Agent 同事单聊'), findsNothing);
        expect(find.text('人类同事单聊'), findsNWidgets(2));
        expect(find.byKey(const ValueKey('folded-summary')), findsOneWidget);
        expect(find.text('[有人@你] 2 个会话有新消息'), findsOneWidget);

        await openFolder(tester);
        expect(roomRow('room-human'), findsNothing);
        expect(roomRow('room-agent'), findsOneWidget);
        expect(roomRow('room-mixed'), findsOneWidget);
        await tester.enterText(inputWithHint('搜索折叠的会话'), 'Agent');
        await tester.pumpAndSettle();
        expect(roomRow('room-agent'), findsOneWidget);
        expect(roomRow('room-mixed'), findsNothing);
        await tester.tap(find.byTooltip('返回消息'));
        await tester.pumpAndSettle();

        await tester.enterText(inputWithHint('搜索会话'), 'Agent');
        await tester.pumpAndSettle();
        expect(roomRow('room-agent'), findsOneWidget);
        expect(find.byKey(const ValueKey('folded-summary')), findsNothing);
        await tester.enterText(inputWithHint('搜索会话'), '');
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ChoiceChip, '未读'));
        await tester.pumpAndSettle();
        expect(roomRow('room-agent'), findsOneWidget);
        expect(roomRow('room-mixed'), findsOneWidget);
        expect(find.byKey(const ValueKey('folded-summary')), findsNothing);

        await tester.tap(find.byTooltip('消息分组'));
        await tester.pumpAndSettle();
        final panel = find.byType(OfficeMessageGroupPanel);
        final group = find.descendant(of: panel, matching: find.text('群组'));
        await tester.ensureVisible(group);
        await tester.tap(group);
        await tester.pumpAndSettle();
        expect(roomRow('room-mixed'), findsOneWidget);
        expect(roomRow('room-agent'), findsNothing);
        expect(state.requests('PATCH'), isEmpty);
        await closeFoldedTest(tester);
      },
    );
  }

  for (final agent in [false, true]) {
    testWidgets(
      '${agent ? 'Agent' : 'human'} un-fold menu writes only the captured room preference and returns it to messages',
      (tester) async {
        final state = FoldedOfficeFixture(agent: agent);
        await mountFolded(tester, state);
        await openFolder(tester);
        await openRoomMenu(tester, 'room-agent');
        // A separate conversation selection must not redirect this menu.
        await state.selectRoom('room-mixed');
        await tester.pumpAndSettle();
        await tester.tap(find.text('移出折叠的会话'));
        await tester.pumpAndSettle();
        expect(state.requests('PATCH'), [
          {
            'owner': agent ? 'agent-fixture' : 'human-fixture',
            'path': '/rooms/room-agent/preferences',
            'method': 'PATCH',
            'data': {'folded': false},
          },
        ]);
        expect(state.refreshes, 1);
        expect(roomRow('room-agent'), findsNothing);
        expect(roomRow('room-mixed'), findsOneWidget);
        final updated = state.rooms.firstWhere((r) => r['id'] == 'room-agent');
        expect(updated['is_favorite'], isTrue);
        expect(updated['is_pinned'], isTrue);
        expect(updated['preferences']['muted'], isFalse);
        expect(updated['unread_count'], 7);
        expect(find.text('已移出折叠的会话'), findsOneWidget);
        await tester.tap(find.byTooltip('返回消息'));
        await tester.pumpAndSettle();
        expect(roomRow('room-agent'), findsOneWidget);
        await closeFoldedTest(tester);
      },
    );
  }

  testWidgets(
    'failed un-fold preserves folder and exposes failure without a success acknowledgment',
    (tester) async {
      final state = FoldedOfficeFixture()..failNextWrite = true;
      await mountFolded(tester, state);
      await openFolder(tester);
      await openRoomMenu(tester, 'room-agent');
      await tester.tap(find.text('移出折叠的会话'));
      await tester.pumpAndSettle();
      expect(state.refreshes, 0);
      expect(roomRow('room-agent'), findsOneWidget);
      expect(officeRoomFolded(state.rooms[1]), isTrue);
      expect(find.textContaining('合成网络中断'), findsOneWidget);
      expect(find.text('已移出折叠的会话'), findsNothing);
      expect(
        tester.widget<PopupMenuButton<String>>(roomMenu('room-agent')).enabled,
        isTrue,
      );
      await openRoomMenu(tester, 'room-agent');
      await tester.tap(find.text('移出折叠的会话'));
      await tester.pumpAndSettle();
      expect(state.requests('PATCH'), hasLength(2));
      expect(roomRow('room-agent'), findsNothing);
      await closeFoldedTest(tester);
    },
  );

  for (final change in ['principal', 'generation', 'endpoint']) {
    testWidgets('open folder menu cannot mutate after $change changes', (
      tester,
    ) async {
      final state = FoldedOfficeFixture();
      await mountFolded(tester, state);
      await openFolder(tester);
      await openRoomMenu(tester, 'room-agent');
      if (change == 'principal') {
        state.switchIdentity('agent-fixture');
      } else if (change == 'generation') {
        state.advanceGeneration();
      } else {
        state.endpoint = 'https://another-synthetic-office.example';
        state.notifyListeners();
      }
      await tester.pumpAndSettle();
      // The old popup route can remain visible, but its selection is inert.
      await tester.tap(find.text('移出折叠的会话'));
      await tester.pumpAndSettle();
      expect(state.requests('PATCH'), isEmpty);
      expect(state.refreshes, 0);
      expect(officeRoomFolded(state.rooms[1]), isTrue);
      await closeFoldedTest(tester);
    });
  }

  testWidgets(
    'offline menus are disabled and an already open menu cannot write after disconnect',
    (tester) async {
      final state = FoldedOfficeFixture();
      await mountFolded(tester, state);
      await openFolder(tester);
      await openRoomMenu(tester, 'room-agent');
      state.goOffline();
      await tester.pumpAndSettle();
      await tester.tap(find.text('移出折叠的会话'));
      await tester.pumpAndSettle();
      expect(state.requests('PATCH'), isEmpty);
      expect(
        tester.widget<PopupMenuButton<String>>(roomMenu('room-agent')).enabled,
        isFalse,
      );
      expect(
        tester.widget<PopupMenuButton<String>>(roomMenu('room-mixed')).enabled,
        isFalse,
      );
      await closeFoldedTest(tester);
    },
  );

  testWidgets(
    'late un-fold completion after identity switch cannot refresh or acknowledge for the new identity',
    (tester) async {
      final state = FoldedOfficeFixture()..pendingWrite = Completer<Json>();
      await mountFolded(tester, state);
      await openFolder(tester);
      await openRoomMenu(tester, 'room-agent');
      await tester.tap(find.text('移出折叠的会话'));
      await tester.pumpAndSettle();
      expect(state.requests('PATCH'), hasLength(1));
      expect(
        tester.widget<PopupMenuButton<String>>(roomMenu('room-agent')).enabled,
        isFalse,
      );
      state.switchIdentity('agent-fixture');
      await tester.pumpAndSettle();
      state.pendingWrite!.complete({
        'preferences': {'folded': false},
      });
      await tester.pumpAndSettle();
      expect(state.refreshes, 0);
      expect(find.text('已移出折叠的会话'), findsNothing);
      expect(officeRoomFolded(state.rooms[1]), isTrue);
      await closeFoldedTest(tester);
    },
  );

  testWidgets(
    'folded raw unread survives while mobile navigation alerts stay zero',
    (tester) async {
      final state = FoldedOfficeFixture();
      await mountFolded(tester, state, size: const Size(390, 844));
      Badge navigationBadge() => tester.widget<Badge>(
        find.byKey(const ValueKey('nav-badge-messages')),
      );
      expect(state.rooms.map(officeUnreadCount).reduce((a, b) => a + b), 10);
      expect(
        state.rooms.map(officeNotificationCount).reduce((a, b) => a + b),
        0,
      );
      expect(navigationBadge().isLabelVisible, isFalse);
      await openFolder(tester);
      expect(
        find.descendant(of: roomRow('room-agent'), matching: find.text('7')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: roomRow('room-mixed'), matching: find.text('3')),
        findsOneWidget,
      );
      expect(navigationBadge().isLabelVisible, isFalse);
      state.rooms[0]['unread_count'] = 1;
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(navigationBadge().isLabelVisible, isTrue);
      expect(state.rooms[1]['unread_count'], 7);
      expect(state.rooms[2]['unread_count'], 3);
      await closeFoldedTest(tester);
    },
  );

  testWidgets(
    'mobile conversation back returns to folder and folder back returns to messages',
    (tester) async {
      final state = FoldedOfficeFixture();
      await mountFolded(tester, state, size: const Size(390, 844));
      await openFolder(tester);
      await tester.tap(
        find.descendant(
          of: roomRow('room-agent'),
          matching: find.text('Agent 同事单聊'),
        ),
      );
      await tester.pumpAndSettle();
      expect(state.openedRooms, ['room-agent']);
      expect(find.byType(OfficeConversation), findsOneWidget);
      expect(find.byType(OfficeFoldedConversations), findsNothing);
      await tester.tap(find.byTooltip('返回会话'));
      await tester.pumpAndSettle();
      expect(find.byType(OfficeFoldedConversations), findsOneWidget);
      expect(roomRow('room-agent'), findsOneWidget);
      expect(roomRow('room-mixed'), findsOneWidget);
      await tester.tap(find.byTooltip('返回消息'));
      await tester.pumpAndSettle();
      expect(find.byType(OfficeFoldedConversations), findsNothing);
      expect(find.byKey(const ValueKey('folded-summary')), findsOneWidget);
      expect(roomRow('room-agent'), findsNothing);
      await closeFoldedTest(tester);
    },
  );
  testWidgets(
    'menu action follows its displayed intent when another client changes folded status',
    (tester) async {
      final state = FoldedOfficeFixture();
      await mountFolded(tester, state);
      await tester.tap(find.widgetWithText(ChoiceChip, '未读'));
      await tester.pumpAndSettle();
      // The unread group keeps the same row visible through preference changes.
      for (final desired in [false, true]) {
        await openRoomMenu(tester, 'room-agent');
        final label = desired ? '移入折叠的会话' : '移出折叠的会话';
        expect(find.text(label), findsOneWidget);
        state.rooms = [
          for (final room in state.rooms)
            if (room['id'] == 'room-agent')
              {
                ...room,
                'folded': desired,
                'preferences': {
                  ...?room['preferences'] as Map?,
                  'folded': desired,
                },
              }
            else
              room,
        ];
        state.notifyListeners();
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(state.requests('PATCH').last['data'], {'folded': desired});
        expect(officeRoomFolded(state.rooms[1]), desired);
      }
      expect(state.requests('PATCH'), hasLength(2));
      await closeFoldedTest(tester);
    },
  );

  for (final change in ['principal', 'generation', 'endpoint']) {
    testWidgets(
      'open default-list menu cannot mutate after $change changes with the same visible room',
      (tester) async {
        final state = FoldedOfficeFixture();
        await mountFolded(tester, state);
        await openRoomMenu(tester, 'room-human');
        if (change == 'principal') {
          state.switchIdentity('agent-fixture');
        } else if (change == 'generation') {
          state.advanceGeneration();
        } else {
          state.endpoint = 'https://another-synthetic-office.example';
          state.notifyListeners();
        }
        await tester.pumpAndSettle();
        await tester.tap(find.text('移入折叠的会话'));
        await tester.pumpAndSettle();
        expect(state.requests('PATCH'), isEmpty);
        expect(state.refreshes, 0);
        expect(officeRoomFolded(state.rooms[0]), isFalse);
        await closeFoldedTest(tester);
      },
    );
  }
}
