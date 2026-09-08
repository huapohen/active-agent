import 'package:active_office/office_state.dart';
import 'package:active_office/ui/conversation_list.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Json conversation({
  int unread = 7,
  bool muted = false,
  bool folded = false,
  String author = 'me',
  Json? receipt,
}) => {
  'id': 'badge-room',
  'name': '工作同事',
  'kind': 'direct',
  'unread_count': unread,
  'muted': muted,
  'folded': folded,
  'last_message': {
    'id': 'badge-message',
    'seq': 70,
    'author_id': author,
    'content': '共同推进工作',
    'receipt_summary': receipt,
  },
};
const confirmedReceipt = <String, dynamic>{
  'known': true,
  'basis': 'explicit_read_ack',
  'eligible_count': 1,
  'read_count': 1,
  'unread_count': 0,
  'unknown_count': 0,
};

Future<void> mountBadge(
  WidgetTester tester,
  Json room, {
  String? identity = 'me',
  double width = 320,
  bool preview = true,
}) async {
  tester.view.physicalSize = Size(width, 260);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: OfficeConversationRow(
            room: room,
            preview: preview,
            currentPrincipalId: identity,
            onOpen: () {},
            menu: const Icon(Icons.more_horiz),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder unreadBadge() =>
    find.byKey(const ValueKey('conversation-unread-badge-room'));
Finder readCheck() =>
    find.byKey(const ValueKey('conversation-read-badge-room'));

void main() {
  test('list activity time uses real message time or an empty room creation timestamp', () {
    expect(
      officeConversationActivityAt({
        'last_message': {'at': '2026-09-07T05:04:00Z'},
        'created_at': '2026-09-06T00:00:00Z',
      }),
      '2026-09-07T05:04:00Z',
    );
    expect(
      officeConversationActivityAt({
        'last_message': null,
        'created_at': '2026-09-06T00:00:00Z',
      }),
      '2026-09-06T00:00:00Z',
    );
    expect(
      officeConversationActivityAt({
        'last_message': {'at': 'invalid'},
        'created_at': '2026-09-06T00:00:00Z',
      }),
      isNull,
    );
    expect(officeConversationActivityAt({}), isNull);
  });
  testWidgets(
    'real preference flags control muted icon even when legacy summary differs',
    (tester) async {
      final room = conversation(muted: false)
        ..['preferences'] = {'muted': true};
      await mountBadge(tester, room);
      expect(
        find.byKey(const ValueKey('conversation-muted-badge-room')),
        findsOneWidget,
      );
      expect(officeNotificationCount(room), 0);
      room['muted'] = true;
      room['preferences'] = {'muted': false};
      await mountBadge(tester, room);
      expect(
        find.byKey(const ValueKey('conversation-muted-badge-room')),
        findsNothing,
      );
      expect(officeNotificationCount(room), 7);
    },
  );
  for (final width in [290.0, 390.0]) {
    testWidgets(
      'width $width preview replaces known emoji while keeping one-line receipts and unknown tokens',
      (tester) async {
        final room = conversation(receipt: confirmedReceipt);
        await mountBadge(tester, room, width: width);
        final before = tester.getSize(find.byType(OfficeConversationRow));
        room['last_message']['content'] =
            '已完成 :feishu:SMILE: :feishu:OK: :feishu:FutureUnknown:';
        await mountBadge(tester, room, width: width);
        final summary = tester.widget<Text>(
          find.byKey(const ValueKey('conversation-summary-badge-room')),
        );
        expect(summary.data, '已完成 [微笑] [OK] :feishu:FutureUnknown:');
        expect(summary.maxLines, 1);
        expect(summary.overflow, TextOverflow.ellipsis);
        expect(
          tester.getSize(find.byType(OfficeConversationRow)).height,
          before.height,
        );
        expect(readCheck(), findsOneWidget);
        expect(unreadBadge(), findsOneWidget);
        expect(find.textContaining(':feishu:SMILE:'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'hidden previews and retracted messages never expose emoji source text',
    (tester) async {
      final room = conversation();
      room['last_message']['content'] = '私有内容 :feishu:SMILE:';
      await mountBadge(tester, room, preview: false);
      expect(find.text('消息预览已隐藏'), findsOneWidget);
      expect(find.textContaining('私有内容'), findsNothing);
      expect(find.textContaining('[微笑]'), findsNothing);
      room['last_message']['retracted_at'] = '2026-09-06T16:00:00Z';
      await mountBadge(tester, room);
      expect(find.text('一条消息已撤回'), findsOneWidget);
      expect(find.textContaining('私有内容'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final mode in ['normal', 'muted', 'folded']) {
    testWidgets(
      '$mode unread appears once on the avatar top right with the appropriate notification color',
      (tester) async {
        final room = conversation(
          muted: mode == 'muted',
          folded: mode == 'folded',
        );
        await mountBadge(tester, room);
        expect(find.text('7'), findsOneWidget);
        final avatar = tester.getRect(
          find.byKey(const ValueKey('conversation-avatar-badge-room')),
        );
        final badge = tester.getRect(unreadBadge());
        expect(badge.center.dx, greaterThan(avatar.center.dx));
        expect(badge.top, lessThan(avatar.top));
        expect(badge.right, greaterThan(avatar.right));
        expect(badge.left, lessThan(avatar.right));
        final container = tester.widget<Container>(unreadBadge());
        final decoration = container.decoration! as BoxDecoration;
        expect(
          decoration.color,
          mode == 'normal' ? const Color(0xffed727a) : const Color(0xffb9c0cc),
        );
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Semantics && widget.properties.label == '7 条未读消息',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'zero and negative unread are absent while large counts cap only the visual text',
    (tester) async {
      await mountBadge(tester, conversation(unread: 0));
      expect(unreadBadge(), findsNothing);
      await mountBadge(tester, conversation(unread: -2));
      expect(unreadBadge(), findsNothing);
      await mountBadge(tester, conversation(unread: 137));
      expect(find.text('99+'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.label == '137 条未读消息',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final identity in ['human-self', 'agent-self']) {
    testWidgets(
      '$identity direct message shows a red read check only for its own explicit confirmed recipient',
      (tester) async {
        await mountBadge(
          tester,
          conversation(unread: 0, author: identity, receipt: confirmedReceipt),
          identity: identity,
        );
        expect(readCheck(), findsOneWidget);
        expect(tester.widget<Icon>(readCheck()).color, const Color(0xffed727a));
        expect(find.byTooltip('对方已读'), findsOneWidget);
        expect(find.text('共同推进工作'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  test('legacy unknown, worker activity, incoming, group, revoked and incomplete receipts never imply direct-message read', () {
    final variants = <Json>[
      conversation(
        receipt: {
          'known': false,
          'basis': 'legacy_unknown',
          'eligible_count': null,
          'read_count': null,
          'unread_count': null,
          'unknown_count': null,
        },
      ),
      conversation(receipt: {...confirmedReceipt, 'basis': 'worker_cursor'}),
      conversation(
        receipt: {...confirmedReceipt, 'read_count': 0, 'unread_count': 1},
      ),
      conversation(receipt: {...confirmedReceipt, 'eligible_count': 2}),
      conversation(receipt: {...confirmedReceipt, 'unknown_count': 1}),
      conversation(receipt: {'known': true, 'read_count': 1}),
      conversation(author: 'other', receipt: confirmedReceipt),
      {...conversation(receipt: confirmedReceipt), 'kind': 'group'},
      {
        ...conversation(receipt: confirmedReceipt),
        'last_message': {
          ...conversation(receipt: confirmedReceipt)['last_message'],
          'retracted_at': '2026-09-06T13:00:00Z',
        },
      },
    ];
    for (final room in variants) {
      room['read_seq'] = 9999;
      room['member_read_count'] = 1;
      expect(officeDirectMessageRead(room, 'me'), isFalse);
    }
    expect(
      officeDirectMessageRead(conversation(receipt: confirmedReceipt), null),
      isFalse,
    );
    expect(
      officeDirectMessageRead(conversation(receipt: confirmedReceipt), ''),
      isFalse,
    );
  });

  testWidgets(
    'legacy unknown stays unmarked and changing identity removes a previously justified read indicator',
    (tester) async {
      await mountBadge(
        tester,
        conversation(receipt: {'known': false, 'basis': 'legacy_unknown'}),
      );
      expect(readCheck(), findsNothing);
      await mountBadge(tester, conversation(receipt: confirmedReceipt));
      expect(readCheck(), findsOneWidget);
      await mountBadge(
        tester,
        conversation(receipt: confirmedReceipt),
        identity: 'new-agent',
      );
      expect(readCheck(), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow conversation keeps avatar badge, mention, pin and exact read evidence without overflow',
    (tester) async {
      final room = conversation(
        unread: 137,
        muted: true,
        receipt: confirmedReceipt,
      );
      room.addAll({
        'is_pinned': true,
        'mention_count': 1,
        'explicit_mention_count': 1,
      });
      await mountBadge(tester, room, width: 270);
      expect(find.text('99+'), findsOneWidget);
      expect(readCheck(), findsOneWidget);
      expect(find.text('[@你]'), findsOneWidget);
      expect(find.byTooltip('置顶聊天'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
