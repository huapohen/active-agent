import 'dart:async';

import 'package:active_office/office_state.dart';
import 'package:active_office/ui/conversation.dart';
import 'package:active_office/ui/office_theme.dart' show PersonAvatar;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shell_interactions_test.dart' show InteractionOffice, mountShell;

class ShellFidelityOffice extends InteractionOffice {
  ShellFidelityOffice({super.kind}) {
    final original = Map<String, dynamic>.from(detail!);
    final source = {
      ...rooms.single,
      'name': '被操作的来源会话',
      'preferences': {'favorite': false, 'pinned': false},
      'is_favorite': false,
      'is_pinned': false,
      'message_grouping': {'marked': false, 'completed': false},
    };
    final other = {...source, 'id': 'room-other', 'name': '当前另一会话'};
    rooms = [source, other];
    details = {
      for (final room in rooms)
        room['id'] as String: {...original, 'room': room, 'messages': <Json>[]},
    };
    selectedRoomId = 'room-other';
    detail = details[selectedRoomId];
  }

  late Map<String, Json> details;
  final requests = <Json>[];
  final opened = <String>[];
  int selections = 1;
  Completer<void>? selectionGate;
  @override
  int get conversationSelection => selections;

  @override
  Future<void> selectRoom(String id) async {
    opened.add(id);
    final scope = identityGeneration;
    await selectionGate?.future;
    if (scope != identityGeneration) return;
    selectedRoomId = id;
    selections++;
    detail = details[id];
    notifyListeners();
  }

  @override
  Future<void> refresh() async => notifyListeners();

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    if (path == '/message-groups' && method == 'GET') {
      return {
        'revision': 4,
        'groups': [
          {
            'id': 'messages',
            'name': '消息',
            'type': 'builtin',
            'visible': true,
            'room_ids': rooms.map((room) => room['id']).toList(),
          },
        ],
        'order': ['messages'],
        'shortcut_ids': ['messages'],
      };
    }
    requests.add({'path': path, 'method': method, 'data': data});
    if (path == '/rooms/room-demo/preferences' && method == 'PATCH') {
      final source = rooms.firstWhere((room) => room['id'] == 'room-demo');
      source['preferences'] = {...source['preferences'] as Map, ...?data};
      return {'room': source};
    }
    throw StateError('Unexpected fidelity request: $method $path');
  }
}

Finder sourceRow() => find.byKey(const ValueKey('room-row-room-demo'));
Finder otherRow() => find.byKey(const ValueKey('room-row-room-other'));
Finder composer() => find.byKey(const ValueKey('composer-input'));

Future<void> openSourceMenu(
  WidgetTester tester, {
  required bool desktop,
}) async {
  if (desktop) {
    await tester.tap(sourceRow(), buttons: kSecondaryMouseButton);
  } else {
    await tester.longPress(sourceRow());
  }
  await tester.pumpAndSettle();
  expect(
    find.byKey(const ValueKey('conversation-context-menu')),
    findsOneWidget,
  );
}

void main() {
  for (final desktop in [false, true]) {
    testWidgets(
      '${desktop ? 'desktop right click' : 'mobile long press'} pin appears as an avatar and opens its source room',
      (tester) async {
        final state = ShellFidelityOffice();
        await mountShell(
          tester,
          state,
          size: desktop ? const Size(1512, 982) : const Size(402, 874),
        );
        expect(
          find.byKey(const ValueKey('pinned-conversations-shelf')),
          findsNothing,
        );
        await openSourceMenu(tester, desktop: desktop);
        expect(state.selectedRoomId, 'room-other');
        expect(state.opened, isEmpty);
        expect(state.requests, isEmpty);
        await tester.tap(find.byKey(const ValueKey('conversation-menu-pin')));
        await tester.pumpAndSettle();
        expect(state.requests, [
          {
            'path': '/rooms/room-demo/preferences',
            'method': 'PATCH',
            'data': {'pinned': true},
          },
        ]);
        expect(state.selectedRoomId, 'room-other');
        expect(state.opened, isEmpty);
        final shelf = find.byKey(const ValueKey('pinned-conversations-shelf'));
        expect(shelf, findsOneWidget);
        expect(
          find.descendant(of: shelf, matching: find.byType(PersonAvatar)),
          findsOneWidget,
        );
        final source = find.descendant(
          of: shelf,
          matching: find.text('被操作的来源会话'),
        );
        await tester.tap(source);
        await tester.pumpAndSettle();
        expect(state.opened, ['room-demo']);
        expect(state.selectedRoomId, 'room-demo');
        expect(find.byType(OfficeConversation), findsOneWidget);
        expect(composer(), findsOneWidget);
        expect(state.requests.length, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      '${desktop ? 'desktop' : 'mobile'} Agent entry binds mentions to the source room real composer and preserves its draft',
      (tester) async {
        final state = ShellFidelityOffice(kind: 'agent');
        await mountShell(
          tester,
          state,
          size: desktop ? const Size(1512, 982) : const Size(402, 874),
        );
        await tester.tap(sourceRow());
        await tester.pumpAndSettle();
        await tester.enterText(composer(), '保留的真实群聊草稿');
        await tester.pumpAndSettle();
        if (!desktop) {
          await tester.tap(find.byTooltip('返回会话'));
          await tester.pumpAndSettle();
        }
        await tester.tap(otherRow());
        await tester.pumpAndSettle();
        if (!desktop) {
          await tester.tap(find.byTooltip('返回会话'));
          await tester.pumpAndSettle();
        }
        expect(state.selectedRoomId, 'room-other');
        await openSourceMenu(tester, desktop: desktop);
        await tester.tap(find.byKey(const ValueKey('conversation-menu-agent')));
        await tester.pumpAndSettle();
        expect(state.selectedRoomId, 'room-demo');
        expect(find.byTooltip('关闭 Agent 协作'), findsOneWidget);
        expect(find.byType(OfficeConversation), findsOneWidget);
        final colleague = find
            .ancestor(
              of: find.text('协作 Agent').last,
              matching: find.byType(Row),
            )
            .first;
        await tester.tap(
          find.descendant(
            of: colleague,
            matching: find.widgetWithText(TextButton, '@ 协作'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byTooltip('关闭 Agent 协作'), findsNothing);
        expect(
          find.byKey(const ValueKey('composer-mention-agent-demo')),
          findsOneWidget,
        );
        expect(
          tester.widget<TextField>(composer()).controller!.text,
          '保留的真实群聊草稿',
        );
        expect(state.requests, isEmpty);
        if (!desktop) {
          await tester.tap(find.byTooltip('返回会话'));
          await tester.pumpAndSettle();
        }
        await tester.tap(otherRow());
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('composer-mention-agent-demo')),
          findsNothing,
        );
        if (!desktop) {
          await tester.tap(find.byTooltip('返回会话'));
          await tester.pumpAndSettle();
        }
        await tester.tap(sourceRow());
        await tester.pumpAndSettle();
        expect(find.byTooltip('关闭 Agent 协作'), findsNothing);
        expect(
          find.byKey(const ValueKey('composer-mention-agent-demo')),
          findsOneWidget,
        );
        expect(
          tester.widget<TextField>(composer()).controller!.text,
          '保留的真实群聊草稿',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'identity turnover during source-room load does not open an Agent panel for the next identity',
    (tester) async {
      final state = ShellFidelityOffice();
      await mountShell(tester, state, size: const Size(402, 874));
      state.selectionGate = Completer<void>();
      await openSourceMenu(tester, desktop: false);
      await tester.tap(find.byKey(const ValueKey('conversation-menu-agent')));
      await tester.pumpAndSettle();
      state.changeIdentity();
      state.selectionGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byTooltip('关闭 Agent 协作'), findsNothing);
      expect(
        find.byKey(const ValueKey('composer-mention-agent-demo')),
        findsNothing,
      );
      expect(state.selectedRoomId, 'room-other');
      expect(state.requests, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
