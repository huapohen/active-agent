import 'dart:async';

import 'package:active_office/office_state.dart';
import 'package:active_office/ui/message_receipts.dart';
import 'package:active_office/ui/message_thread.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Json sampleMessage(
  String id,
  int seq, {
  String? replyTo,
  String kind = 'human',
}) => {
  'id': id,
  'seq': seq,
  'revision': 1,
  'content': '正文 $id',
  'author_id': 'author-$kind',
  'author': {'id': 'author-$kind', 'name': '作者 $kind', 'kind': kind},
  'at': '2026-09-06T12:00:00Z',
  'attachments': <Json>[],
  'reply_to': replyTo,
};
Json summary({
  String basis = 'explicit_read_ack',
  int read = 1,
  int eligible = 2,
}) => {
  'known': basis == 'explicit_read_ack',
  'basis': basis,
  'read_count': basis == 'explicit_read_ack' ? read : null,
  'eligible_count': basis == 'explicit_read_ack' ? eligible : null,
  'unread_count': basis == 'explicit_read_ack' ? eligible - read : null,
  'unknown_count': basis == 'explicit_read_ack' ? 0 : null,
};

class MessagePanelFixture extends OfficeState {
  MessagePanelFixture({String kind = 'human', int replies = 2}) {
    endpoint = 'https://panels.invalid';
    me = {'id': 'me', 'kind': kind, 'name': '当前身份'};
    connected = true;
    selectedRoomId = 'room-a';
    root = sampleMessage('root', 1);
    messages = List.generate(
      replies,
      (index) => sampleMessage(
        'reply-${index + 1}',
        index + 2,
        replyTo: index == 0 ? 'root' : 'reply-$index',
        kind: index.isEven ? 'agent' : 'human',
      ),
    );
    receipt = {
      'message_id': 'root',
      'receipt_summary': summary(),
      'readers': [
        {
          'principal_id': 'human-a',
          'name': '接收人',
          'kind': 'human',
          'status': 'read',
          'read': true,
          'current_member': false,
          'same_membership': true,
          'read_ack_seq': 10,
          'acknowledged_at': '2026-09-06T12:02:00Z',
        },
        {
          'principal_id': 'agent-a',
          'name': '接收 Agent',
          'kind': 'agent',
          'status': 'unread',
          'read': false,
          'current_member': true,
          'same_membership': false,
          'read_ack_seq': 0,
          'acknowledged_at': null,
        },
      ],
    };
  }
  late Json root, receipt;
  late List<Json> messages;
  final requests = <String>[], sends = <Json>[];
  int generation = 0, visibilityWrites = 0;
  OfficeException? readFailure, sendFailure;
  Completer<Json>? pendingRead, pendingSend;
  @override
  int get identityGeneration => generation;
  void emit() => notifyListeners();
  void changeIdentity() {
    generation++;
    emit();
  }

  @override
  Future<void> setConversationVisible(String roomId, bool visible) async {
    visibilityWrites++;
  }

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    expect(method, 'GET');
    expect(data, isNull);
    requests.add(path);
    if (pendingRead != null) return pendingRead!.future;
    if (readFailure case final failure?) {
      readFailure = null;
      throw failure;
    }
    if (path.endsWith('/readers')) return receipt;
    final uri = Uri.parse(path);
    expect(uri.path, '/rooms/room-a/messages/root/thread');
    final after = int.parse(uri.queryParameters['after']!);
    final limit = int.parse(uri.queryParameters['limit']!);
    final remaining = messages
        .where((message) => (message['seq'] as int) > after)
        .toList();
    final page = remaining.take(limit).toList();
    final last = page.isEmpty ? after : page.last['seq'] as int;
    return {
      'root_message': {...root},
      'messages': page.map((message) => {...message}).toList(),
      'total_replies': messages.length,
      'has_more': remaining.length > page.length,
      'next_after': remaining.length > page.length ? last : null,
      'after_cursor': last,
    };
  }

  @override
  Future<Json> send(
    String content, {
    List<String> mentions = const [],
    bool mentionAll = false,
    String? sourceRoomId,
    String? replyTo,
    String? clientId,
    List<String> attachmentIds = const [],
  }) async {
    sends.add({
      'content': content,
      'source_room_id': sourceRoomId,
      'reply_to': replyTo,
      'mentions': mentions,
      'mention_all': mentionAll,
      'attachment_ids': attachmentIds,
    });
    if (pendingSend != null) return pendingSend!.future;
    if (sendFailure case final failure?) {
      sendFailure = null;
      throw failure;
    }
    final message = {
      ...sampleMessage(
        'sent-${sends.length}',
        messages.length + 2,
        replyTo: replyTo,
        kind: me!['kind'],
      ),
      'content': content,
    };
    messages.add(message);
    return message;
  }
}

Future<void> mountPanels(
  WidgetTester tester,
  MessagePanelFixture state, {
  double width = 390,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Column(
            children: [
              TextButton(
                onPressed: () => showOfficeMessageThread(
                  context,
                  state,
                  'room-a',
                  state.root,
                ),
                child: const Text('打开话题'),
              ),
              TextButton(
                onPressed: () => showOfficeMessageReceipts(
                  context,
                  state,
                  'room-a',
                  state.root,
                ),
                child: const Text('查看阅读'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder replyInput() => find.byKey(const ValueKey('thread-reply-input'));
String draft(WidgetTester tester) =>
    tester.widget<TextField>(replyInput()).controller!.text;
Future<void> finish(WidgetTester tester) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  for (final kind in ['human', 'agent']) {
    testWidgets(
      '$kind thread replies use original room and reply_to, retaining draft after a failed send',
      (tester) async {
        final state = MessagePanelFixture(kind: kind)
          ..sendFailure = OfficeException(503, '暂时无法发送');
        await mountPanels(tester, state);
        await tap(tester, find.text('打开话题'));
        expect(
          state.requests.single,
          '/rooms/room-a/messages/root/thread?after=0&limit=50',
        );
        expect(state.sends, isEmpty);
        expect(state.visibilityWrites, 0);
        await tester.enterText(replyInput(), '具体的共同回复');
        state.selectedRoomId = 'room-b';
        await tap(tester, find.text('发送回复'));
        expect(find.text('暂时无法发送'), findsOneWidget);
        expect(draft(tester), '具体的共同回复');
        await tap(tester, find.text('发送回复'));
        expect(state.sends.length, 2);
        for (final send in state.sends) {
          expect(send, {
            'content': '具体的共同回复',
            'source_room_id': 'room-a',
            'reply_to': 'root',
            'mentions': <String>[],
            'mention_all': false,
            'attachment_ids': <String>[],
          });
        }
        expect(draft(tester), isEmpty);
        expect(state.messages.last['content'], '具体的共同回复');
        await tap(tester, find.byTooltip('关闭话题'));
        await finish(tester);
      },
    );
  }

  testWidgets(
    'replying to a real descendant preserves its parent rather than creating a topic marker',
    (tester) async {
      final state = MessagePanelFixture(replies: 1);
      await mountPanels(tester, state, width: 1200);
      await tap(tester, find.text('打开话题'));
      final child = find.byKey(const ValueKey('thread-message-reply-1'));
      await tester.ensureVisible(child);
      await tester.pumpAndSettle();
      await tap(
        tester,
        find.descendant(
          of: child,
          matching: find.widgetWithText(TextButton, '回复'),
        ),
      );
      await tester.enterText(replyInput(), '继续这一条回复');
      await tap(tester, find.text('发送回复'));
      expect(state.sends.single['reply_to'], 'reply-1');
      expect(state.sends.single['content'], '继续这一条回复');
      await finish(tester);
    },
  );

  testWidgets(
    'thread pagination uses sequence cursors and refresh revalidates the complete loaded window',
    (tester) async {
      final state = MessagePanelFixture(replies: 55);
      await mountPanels(tester, state, width: 1200);
      await tap(tester, find.text('打开话题'));
      final scrollable = find
          .descendant(
            of: find.byKey(const ValueKey('thread-messages')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('加载更多回复'),
        1600,
        scrollable: scrollable,
        maxScrolls: 30,
      );
      await tap(tester, find.text('加载更多回复'));
      expect(
        state.requests.last,
        '/rooms/room-a/messages/root/thread?after=51&limit=50',
      );
      expect(find.text('加载更多回复'), findsNothing);
      state.messages[0] = {
        ...state.messages[0],
        'retracted_at': '2026-09-06T12:04:00Z',
        'content': '',
        'attachments': <Json>[],
      };
      state.root = {...state.root, 'content': '原消息已更新'};
      final count = state.requests.length;
      await tap(tester, find.byTooltip('刷新话题'));
      expect(state.requests.sublist(count), [
        '/rooms/room-a/messages/root/thread?after=0&limit=50',
        '/rooms/room-a/messages/root/thread?after=51&limit=50',
      ]);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('thread-message-root')),
        -1600,
        scrollable: scrollable,
        maxScrolls: 30,
      );
      await tester.pumpAndSettle();
      expect(find.text('原消息已更新'), findsOneWidget);
      expect(find.text('这条消息已撤回'), findsOneWidget);
      expect(find.text('正文 reply-1'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'offline thread retains the draft, then authorization failure removes old content without sending it',
    (tester) async {
      final state = MessagePanelFixture();
      await mountPanels(tester, state);
      await tap(tester, find.text('打开话题'));
      await tester.enterText(replyInput(), '保留的回复草稿');
      state.connected = false;
      state.emit();
      await tester.pumpAndSettle();
      expect(draft(tester), '保留的回复草稿');
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '发送回复'))
            .onPressed,
        isNull,
      );
      expect(state.sends, isEmpty);
      state.readFailure = OfficeException(403, '已经不是会话成员');
      state.connected = true;
      state.emit();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(state.requests.length, 2);
      expect(find.text('已经不是会话成员'), findsOneWidget);
      expect(find.text('正文 root'), findsNothing);
      expect(draft(tester), '保留的回复草稿');
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '发送回复'))
            .onPressed,
        isNull,
      );
      await finish(tester);
    },
  );

  testWidgets(
    'pending thread refresh pauses sending and can be closed without a late route pop',
    (tester) async {
      final state = MessagePanelFixture();
      await mountPanels(tester, state);
      await tap(tester, find.text('打开话题'));
      await tester.enterText(replyInput(), '等待读取完成');
      await tester.pumpAndSettle();
      state.pendingRead = Completer<Json>();
      await tester.tap(find.byTooltip('刷新话题'));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '发送回复'))
            .onPressed,
        isNull,
      );
      expect(draft(tester), '等待读取完成');
      expect(state.sends, isEmpty);
      await tester.tap(find.byTooltip('关闭话题'));
      await tester.pumpAndSettle();
      state.pendingRead!.complete({
        'root_message': state.root,
        'messages': state.messages,
        'total_replies': 2,
        'has_more': false,
        'next_after': null,
        'after_cursor': 3,
      });
      await tester.pumpAndSettle();
      expect(find.text('打开话题'), findsOneWidget);
      expect(find.byType(OfficeMessageThread), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'same-ID identity turnover clears draft and rejects a late thread read permanently',
    (tester) async {
      final state = MessagePanelFixture();
      await mountPanels(tester, state);
      await tap(tester, find.text('打开话题'));
      await tester.enterText(replyInput(), '旧身份草稿');
      final input = tester.widget<TextField>(replyInput()).controller!;
      state.pendingRead = Completer<Json>();
      await tester.tap(find.byTooltip('刷新话题'));
      await tester.pump();
      state.changeIdentity();
      state.changeIdentity();
      await tester.pumpAndSettle();
      expect(input.text, isEmpty);
      state.pendingRead!.complete({
        'root_message': sampleMessage('root', 1),
        'messages': <Json>[],
        'total_replies': 0,
        'has_more': false,
        'next_after': null,
        'after_cursor': 0,
      });
      await tester.pumpAndSettle();
      expect(find.text('工作身份已变化，请关闭后重新打开话题。'), findsOneWidget);
      expect(replyInput(), findsNothing);
      expect(find.text('正文 root'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'late successful send cannot restore a switched identity or close the underlying screen',
    (tester) async {
      final state = MessagePanelFixture()..pendingSend = Completer<Json>();
      await mountPanels(tester, state);
      await tap(tester, find.text('打开话题'));
      await tester.enterText(replyInput(), '发送期间换身份');
      await tap(tester, find.text('发送回复'));
      state.changeIdentity();
      await tester.pumpAndSettle();
      state.pendingSend!.complete(sampleMessage('late-sent', 4));
      await tester.pumpAndSettle();
      expect(find.text('工作身份已变化，请关闭后重新打开话题。'), findsOneWidget);
      expect(find.text('正文 late-sent'), findsNothing);
      expect(state.requests.length, 1);
      await tap(tester, find.byTooltip('关闭话题'));
      expect(find.text('打开话题'), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets(
    'readers use the explicit source and display membership snapshots and cumulative confirmation accurately',
    (tester) async {
      final state = MessagePanelFixture();
      await mountPanels(tester, state, width: 1200);
      await tap(tester, find.text('查看阅读'));
      expect(state.requests.single, '/rooms/room-a/messages/root/readers');
      expect(find.text('1 已读 · 1 未读'), findsOneWidget);
      expect(find.text('接收人'), findsOneWidget);
      expect(find.text('接收 Agent'), findsOneWidget);
      expect(find.textContaining('已离开会话'), findsOneWidget);
      expect(find.textContaining('已重新加入；按发送时身份统计'), findsOneWidget);
      expect(find.textContaining('最近确认：'), findsOneWidget);
      state.selectedRoomId = 'room-b';
      await tap(tester, find.byTooltip('刷新阅读状态'));
      expect(state.requests.last, '/rooms/room-a/messages/root/readers');
      expect(state.visibilityWrites, 0);
      expect(state.sends, isEmpty);
      await finish(tester);
    },
  );

  for (final basis in ['legacy_unknown', 'message_retracted']) {
    testWidgets(
      '$basis readers remain unknown without fabricated unread members',
      (tester) async {
        final state = MessagePanelFixture();
        state.receipt = {
          'message_id': 'root',
          'receipt_summary': summary(basis: basis),
          'readers': <Json>[],
        };
        await mountPanels(tester, state);
        await tap(tester, find.text('查看阅读'));
        expect(
          find.textContaining(basis == 'legacy_unknown' ? '阅读状态未知' : '消息已撤回'),
          findsOneWidget,
        );
        expect(find.text('未读'), findsNothing);
        expect(find.text('0 已读 · 0 未读'), findsNothing);
        expect(find.byType(ListTile), findsNothing);
        await finish(tester);
      },
    );
  }

  testWidgets(
    'reader refresh and late response cannot leak across identity turnover',
    (tester) async {
      final state = MessagePanelFixture();
      await mountPanels(tester, state);
      await tap(tester, find.text('查看阅读'));
      state.pendingRead = Completer<Json>();
      await tester.tap(find.byTooltip('刷新阅读状态'));
      await tester.pump();
      state.changeIdentity();
      await tester.pumpAndSettle();
      state.pendingRead!.complete(state.receipt);
      await tester.pumpAndSettle();
      expect(find.text('工作身份已变化，请关闭后重新打开阅读状态。'), findsOneWidget);
      expect(find.text('接收人'), findsNothing);
      expect(find.byTooltip('刷新阅读状态'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'direct read uses a red check, groups expose counts and unknown is not unread',
    (tester) async {
      var opened = 0;
      Future<void> render(
        Json receipt,
        String kind, {
        bool retracted = false,
      }) => tester.pumpWidget(
        MaterialApp(
          theme: officeTheme(),
          home: Scaffold(
            body: OfficeMessageReceiptIndicator(
              message: {
                'receipt_summary': receipt,
                if (retracted) 'retracted_at': '2026-09-06T12:00:00Z',
              },
              roomKind: kind,
              onOpen: () => opened++,
            ),
          ),
        ),
      );
      await render(summary(read: 1, eligible: 1), 'direct');
      expect(find.text('已读'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
      final button = tester.widget<TextButton>(find.byType(TextButton));
      expect(
        button.style!.foregroundColor!.resolve({}),
        const Color(0xffed727a),
      );
      await tap(tester, find.text('已读'));
      expect(opened, 1);
      await render(summary(read: 0, eligible: 1), 'direct');
      expect(find.text('未读'), findsOneWidget);
      await render(summary(), 'group');
      expect(find.text('1/2 已读'), findsOneWidget);
      await render(summary(basis: 'legacy_unknown'), 'group');
      expect(find.text('阅读状态未知'), findsOneWidget);
      await render(summary(), 'direct', retracted: true);
      expect(find.byType(TextButton), findsNothing);
      await finish(tester);
    },
  );
}
