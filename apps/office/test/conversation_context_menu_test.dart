import 'dart:async';

import 'package:active_office/message_groups.dart';
import 'package:active_office/office_state.dart';
import 'package:active_office/ui/conversation_context_menu.dart';
import 'package:active_office/ui/conversation_list.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class ContextMenuOffice extends OfficeState {
  ContextMenuOffice() {
    endpoint = 'https://room-menu.invalid';
    me = {'id': 'human-a', 'kind': 'human'};
    connected = true;
    selectedRoomId = 'unrelated-room';
    rooms = [
      room,
      {'id': 'unrelated-room', 'name': '另一会话'},
    ];
  }
  final Json room = {
    'id': 'target-room',
    'name': '目标工作群',
    'kind': 'group',
    'unread_count': 12,
    'created_at': '2026-09-06T04:00:00Z',
    'preferences': {'pinned': false, 'muted': true},
    'message_grouping': {'marked': false, 'completed': false},
    'last_message': {
      'id': 'latest',
      'seq': 31,
      'content': '最新进展',
      'at': '2026-09-07T05:04:00Z',
    },
  };
  final List<Json> writes = [];
  int generation = 1, refreshes = 0, agentEntrances = 0;
  bool conflict = false;
  Completer<void>? writeGate;
  final Json groupSnapshot = {
    'revision': 4,
    'groups': <Json>[],
    'order': <String>[],
    'shortcut_ids': <String>[],
  };
  @override
  int get identityGeneration => generation;
  void changeIdentity() {
    generation++;
    me = {'id': generation.isEven ? 'human-b' : 'human-a', 'kind': 'human'};
    notifyListeners();
  }

  @override
  Future<void> refresh() async {
    refreshes++;
  }

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    if (method == 'GET' && path == '/message-groups') {
      return Map.from(groupSnapshot);
    }
    if (method == 'GET' && path == '/rooms/target-room') return {'room': room};
    writes.add({
      'path': path,
      'data': Map<String, dynamic>.from(data ?? {}),
      'owner': me?['id'],
    });
    await writeGate?.future;
    if (conflict) throw OfficeException(409, '会话归组已变化，请重新打开菜单');
    if (path.endsWith('/message-groups')) {
      return {...groupSnapshot, 'revision': 5};
    }
    return {'room': room};
  }
}

Future<({ContextMenuOffice state, OfficeMessageGroups groups})>
mountContextMenu(
  WidgetTester tester, {
  double width = 402,
  ContextMenuOffice? fixture,
}) async {
  tester.view.physicalSize = Size(width, 874);
  tester.view.devicePixelRatio = 1;
  final state = fixture ?? ContextMenuOffice();
  final groups = OfficeMessageGroups(state)..snapshot = state.groupSnapshot;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    groups.dispose();
    state.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.only(top: 190),
          child: Builder(
            builder: (context) => OfficeConversationRow(
              room: state.room,
              onOpen: () {},
              menu: const Icon(Icons.more_horiz),
              onContextMenuAt: (anchor) => showOfficeConversationContextMenu(
                context,
                state,
                groups,
                state.room,
                anchor: anchor,
                onAgent: () async {
                  state.agentEntrances++;
                },
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (state: state, groups: groups);
}

Future<void> openContextMenu(WidgetTester tester) async {
  await tester.longPress(find.byType(OfficeConversationRow));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'mobile long press shows the right aligned menu without an edit dialog or hidden read acknowledgment',
    (tester) async {
      final fixture = await mountContextMenu(tester);
      expect(find.byIcon(Icons.more_horiz), findsNothing);
      expect(
        find.byKey(const ValueKey('conversation-muted-target-room')),
        findsOneWidget,
      );
      await openContextMenu(tester);
      for (final text in [
        '置顶',
        '清除未读',
        '标记',
        '标签',
        '允许消息通知',
        '完成',
        'Agent 超级入口',
      ]) {
        expect(find.text(text), findsOneWidget);
      }
      expect(find.byType(Switch), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      final menu = tester.getRect(
        find.byKey(const ValueKey('conversation-context-menu')),
      );
      expect(menu.width, 256);
      expect(menu.right, lessThanOrEqualTo(386));
      expect(menu.top, greaterThan(190));
      expect(fixture.state.writes, isEmpty);
      expect(fixture.state.selectedRoomId, 'unrelated-room');
      await tester.tapAt(const Offset(20, 90));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('conversation-context-menu')),
        findsNothing,
      );
      expect(fixture.state.writes, isEmpty);
    },
  );

  for (final entry in <(String, String, Json)>[
    ('置顶', 'preferences', {'pinned': true}),
    ('清除未读', 'preferences', {'read_seq': 31}),
    ('允许消息通知', 'preferences', {'muted': false}),
    ('标记', 'message-groups', {'base_revision': 4, 'marked': true}),
    ('完成', 'message-groups', {'base_revision': 4, 'completed': true}),
  ]) {
    testWidgets(
      '${entry.$1} writes only the displayed intent to the source room',
      (tester) async {
        final fixture = await mountContextMenu(tester);
        await openContextMenu(tester);
        await tester.tap(find.text(entry.$1));
        await tester.pumpAndSettle();
        expect(fixture.state.writes, [
          {
            'path': '/rooms/target-room/${entry.$2}',
            'data': entry.$3,
            'owner': 'human-a',
          },
        ]);
        expect(fixture.state.refreshes, 1);
        expect(fixture.state.selectedRoomId, 'unrelated-room');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'server flags reverse actions and a read room disables clear unread',
    (tester) async {
      final state = ContextMenuOffice();
      state.room['preferences'] = {'pinned': true, 'muted': false};
      state.room['message_grouping'] = {'marked': true, 'completed': true};
      state.room['unread_count'] = 0;
      await mountContextMenu(tester, fixture: state);
      await openContextMenu(tester);
      for (final text in ['取消置顶', '取消标记', '关闭消息通知', '撤销完成']) {
        expect(find.text(text), findsOneWidget);
      }
      final clear = tester.widget<InkWell>(
        find.byKey(const ValueKey('conversation-menu-clearUnread')),
      );
      expect(clear.onTap, isNull);
      expect(state.writes, isEmpty);
    },
  );

  testWidgets(
    'identity A to B to A removes menu and retained item cannot write or pop a new route',
    (tester) async {
      final fixture = await mountContextMenu(tester);
      await openContextMenu(tester);
      final oldTap = tester
          .widget<InkWell>(find.byKey(const ValueKey('conversation-menu-pin')))
          .onTap!;
      fixture.state.changeIdentity();
      fixture.state.changeIdentity();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      unawaited(
        showDialog<void>(
          context: tester.element(find.byType(OfficeConversationRow)),
          builder: (_) => const AlertDialog(title: Text('新的页面')),
        ),
      );
      await tester.pumpAndSettle();
      oldTap();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('conversation-context-menu')),
        findsNothing,
      );
      expect(fixture.state.writes, isEmpty);
      expect(find.text('新的页面'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a delayed saved preference does not refresh another identity', (
    tester,
  ) async {
    final fixture = await mountContextMenu(tester);
    fixture.state.writeGate = Completer<void>();
    await openContextMenu(tester);
    await tester.tap(find.text('置顶'));
    await tester.pumpAndSettle();
    expect(fixture.state.writes.single['owner'], 'human-a');
    fixture.state.changeIdentity();
    fixture.state.writeGate!.complete();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(fixture.state.refreshes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('group revision conflict is visible and never silently retried', (
    tester,
  ) async {
    final fixture = await mountContextMenu(tester);
    fixture.state.conflict = true;
    await openContextMenu(tester);
    await tester.tap(find.text('标记'));
    await tester.pumpAndSettle();
    expect(fixture.state.writes, hasLength(1));
    expect(fixture.state.refreshes, 0);
    expect(find.textContaining('会话归组已变化'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Agent menu enters existing collaboration callback without sending messages',
    (tester) async {
      final fixture = await mountContextMenu(tester);
      await openContextMenu(tester);
      await tester.tap(find.text('Agent 超级入口'));
      await tester.pumpAndSettle();
      expect(fixture.state.agentEntrances, 1);
      expect(fixture.state.writes, isEmpty);
    },
  );

  testWidgets('only the labels item opens the existing grouping editor', (
    tester,
  ) async {
    final fixture = await mountContextMenu(tester);
    await openContextMenu(tester);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.text('标签'));
    await tester.pumpAndSettle();
    expect(find.text('整理会话 · 目标工作群'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(fixture.state.writes, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'desktop keeps visible menu access and secondary click opens the popup',
    (tester) async {
      await mountContextMenu(tester, width: 1200);
      expect(find.byIcon(Icons.more_horiz), findsOneWidget);
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.down(tester.getCenter(find.byType(OfficeConversationRow)));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('conversation-context-menu')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
