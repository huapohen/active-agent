import 'dart:async';
import 'dart:convert';

import 'package:active_office/office_state.dart';
import 'package:active_office/ui/message_thread.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'message_thread_receipts_test.dart' show MessagePanelFixture;
import 'office_state_test.dart' show Service;

class TopicFixture extends MessagePanelFixture {
  TopicFixture({super.kind});
  final creates = <Json>[];
  Completer<Json>? pendingTopic;
  OfficeException? topicFailure;
  bool wrongScope = false;
  OfficeException? topicReadFailure;

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    if (path == '/rooms/room-a/topics/topic-one') {
      if (topicReadFailure case final failure?) throw failure;
      return {
        'topic': {
          'id': 'topic-one',
          'room_id': 'room-a',
          'root_message_id': 'root',
        },
        'root_message': root,
      };
    }
    return super.officeRequest(path, method: method, data: data);
  }

  @override
  Future<Json> createMessageTopic(String roomId, Json rootMessage) async {
    creates.add({'room_id': roomId, 'root': Json.from(rootMessage)});
    if (pendingTopic != null) return pendingTopic!.future;
    if (topicFailure case final failure?) {
      topicFailure = null;
      throw failure;
    }
    return {
      'id': 'topic-one',
      'room_id': wrongScope ? 'another-room' : roomId,
      'root_message_id': rootMessage['id'],
    };
  }
}

Future<void> mountTopic(
  WidgetTester tester,
  TopicFixture state, {
  bool create = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: OfficeMessageThread(
          state: state,
          roomId: 'room-a',
          rootMessage: state.root,
          createTopic: create,
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  for (final kind in ['human', 'agent']) {
    testWidgets('$kind explicitly creates one topic before reading replies', (
      tester,
    ) async {
      final state = TopicFixture(kind: kind);
      await mountTopic(tester, state);
      await tester.pumpAndSettle();
      expect(state.creates, hasLength(1));
      expect(state.creates.single['room_id'], 'room-a');
      expect(state.creates.single['root']['id'], 'root');
      expect(state.sends, isEmpty);
      expect(find.text('正文 root'), findsOneWidget);
      state.selectedRoomId = 'room-b';
      await tester.tap(find.byTooltip('刷新话题'));
      await tester.pumpAndSettle();
      expect(state.creates, hasLength(1));
      expect(
        state.requests.every((path) => path.startsWith('/rooms/room-a/')),
        isTrue,
      );
    });
  }

  testWidgets('reading an existing reply thread creates no topic', (
    tester,
  ) async {
    final state = TopicFixture();
    await mountTopic(tester, state, create: false);
    await tester.pumpAndSettle();
    expect(state.creates, isEmpty);
    expect(state.requests, isNotEmpty);
  });

  testWidgets('failed topic creation can retry without sending chat', (
    tester,
  ) async {
    final state = TopicFixture()..topicFailure = OfficeException(503, '创建暂时失败');
    await mountTopic(tester, state);
    await tester.pumpAndSettle();
    expect(state.requests, isEmpty);
    expect(find.text('创建暂时失败'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('thread-reply-input')),
      '等待重试的草稿',
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '发送回复'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('重新加载话题'));
    await tester.pumpAndSettle();
    expect(state.creates, hasLength(2));
    expect(state.sends, isEmpty);
    expect(find.text('等待重试的草稿'), findsOneWidget);
  });

  testWidgets('late topic creation cannot populate a changed identity', (
    tester,
  ) async {
    final pending = Completer<Json>();
    final state = TopicFixture()..pendingTopic = pending;
    await mountTopic(tester, state);
    state.changeIdentity();
    await tester.pump();
    pending.complete({
      'id': 'topic-one',
      'room_id': 'room-a',
      'root_message_id': 'root',
    });
    await tester.pumpAndSettle();
    expect(state.requests, isEmpty);
    expect(find.text('正文 root'), findsNothing);
    expect(find.text('工作身份已变化，请关闭后重新打开话题。'), findsOneWidget);
  });

  testWidgets('wrong-scope topic response never unlocks replies', (
    tester,
  ) async {
    final state = TopicFixture()..wrongScope = true;
    await mountTopic(tester, state);
    await tester.pumpAndSettle();
    expect(state.requests, isEmpty);
    expect(find.text('话题响应不完整，请重试'), findsOneWidget);
    expect(find.text('正文 root'), findsNothing);
  });

  testWidgets('hidden explicit topic clears content and disables replies', (
    tester,
  ) async {
    final state = TopicFixture();
    await mountTopic(tester, state);
    await tester.pumpAndSettle();
    expect(find.text('正文 root'), findsOneWidget);
    state.topicReadFailure = OfficeException(
      409,
      '本人已隐藏话题根消息',
      code: 'message_hidden',
    );
    await tester.tap(find.byTooltip('刷新话题'));
    await tester.pumpAndSettle();
    expect(find.text('正文 root'), findsNothing);
    expect(find.text('正文 reply-1'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('thread-reply-input')),
      '保留回复',
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '发送回复'))
          .onPressed,
      isNull,
    );
    expect(state.sends, isEmpty);
  });

  testWidgets(
    'stale creation revision asks to reopen rather than retry forever',
    (tester) async {
      final state = TopicFixture()
        ..topicFailure = OfficeException(409, '消息已变化', code: 'conflict');
      await mountTopic(tester, state);
      await tester.pumpAndSettle();
      expect(find.text('原消息已变化，请关闭后重新打开话题。'), findsOneWidget);
      expect(find.text('重新加载话题'), findsNothing);
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == '刷新话题',
              ),
            )
            .onPressed,
        isNull,
      );
      expect(state.creates, hasLength(1));
    },
  );

  test(
    'topic transport preserves source revision and retry id for both kinds',
    () async {
      for (final kind in ['human', 'agent']) {
        final service = Service(kind);
        final requests = <Json>[];
        final office = OfficeState(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/messages/root/topic')) {
              expect(request.method, 'POST');
              expect(
                request.url.path,
                '/api/im/rooms/source-room/messages/root/topic',
              );
              expect(
                request.headers['authorization'],
                'Bearer private-test-identity',
              );
              requests.add(Json.from(jsonDecode(request.body)));
              if (requests.length == 1) {
                throw http.ClientException('Response lost');
              }
              return service.json({
                'topic': {
                  'id': 'topic-one',
                  'room_id': 'source-room',
                  'root_message_id': 'root',
                },
                'duplicate': true,
              });
            }
            return service.call(request);
          }),
        );
        await office.connect('http://localhost:3218', 'private-test-identity');
        final root = {'id': 'root', 'revision': 7};
        await expectLater(
          office.createMessageTopic('source-room', root),
          throwsA(isA<OfficeException>()),
        );
        final result = await office.createMessageTopic('source-room', root);
        expect(result['id'], 'topic-one');
        expect(requests, hasLength(2));
        expect(requests.first, requests.last);
        expect(requests.first['base_revision'], 7);
        expect(requests.first['client_id'], isNotEmpty);
        expect(service.sends, 0);
        expect(office.selectedRoomId, 'room-1');
        office.disconnect();
        office.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 130));
      }
    },
  );
}
