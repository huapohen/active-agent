import 'dart:async';

import 'package:active_office/office_state.dart';
import 'package:active_office/ui/conversation_details.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'office_ui_test.dart' show LayoutOfficeState;

class SearchOffice extends LayoutOfficeState {
  final requests = <String>[];
  final first = Completer<Json>();
  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    requests.add(path);
    if (path.startsWith('/search?')) {
      final uri = Uri.parse(path);
      expect(uri.queryParameters['room_id'], 'room-history');
      expect(uri.queryParameters['type'], 'message');
      if (uri.queryParameters['q'] == 'old') return first.future;
      return {
        'results': [
          {
            'id': 'msg-history',
            'snippet': '当前历史结果',
            'at': '2026-09-06T09:00:00Z',
          },
        ],
      };
    }
    if (path == '/rooms/room-history/messages/msg-history') {
      return {
        'message': {
          'id': 'msg-history',
          'content': '不在本地已加载列表的完整消息',
          'author': {'name': 'Agent 同事'},
          'at': '2026-09-06T09:00:00Z',
        },
      };
    }
    throw StateError(path);
  }
}

void main() {
  testWidgets(
    'server room search ignores stale reply and opens unloaded full message',
    (tester) async {
      final state = SearchOffice();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OfficeRoomSearch(state: state, roomId: 'room-history'),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'old');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.enterText(find.byType(TextField), 'new');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      state.first.complete({
        'results': [
          {'snippet': '过期结果'},
        ],
      });
      await tester.pumpAndSettle();
      expect(find.text('过期结果'), findsNothing);
      await tester.tap(find.text('当前历史结果'));
      await tester.pumpAndSettle();
      expect(find.text('不在本地已加载列表的完整消息'), findsOneWidget);
      expect(state.requests.last, '/rooms/room-history/messages/msg-history');
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );
  testWidgets('forward search requires target selection and explicit confirm', (
    tester,
  ) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showOfficeForwardPicker(
                  context,
                  [
                    {'id': 'a', 'name': '项目群'},
                    {'id': 'b', 'name': '机伴'},
                  ],
                  {'content': '转发预览'},
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认转发'))
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byType(TextField), '机伴');
    await tester.pumpAndSettle();
    expect(find.text('项目群'), findsNothing);
    await tester.tap(find.widgetWithText(ListTile, '机伴'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    await tester.tap(find.text('确认转发'));
    await tester.pumpAndSettle();
    expect(result, 'b');
  });
}
