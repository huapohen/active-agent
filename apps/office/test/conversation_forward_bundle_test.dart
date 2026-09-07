import 'dart:async';
import 'dart:convert';

import 'package:active_office/office_state.dart';
import 'package:active_office/ui/message_forward_bundle.dart';
import 'package:active_office/ui/message_links.dart';
import 'package:active_office/ui/message_original.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'conversation_multi_select_test.dart'
    show
        MultiSelectOffice,
        mountConversation,
        enterMultiSelect,
        selectMessage,
        openMessageMenu,
        selectionAction,
        captureClipboard;

Json cloneBundle(Json value) => Json.from(jsonDecode(jsonEncode(value)) as Map);

class ConversationBundleOffice extends MultiSelectOffice {
  ConversationBundleOffice({bool enabled = true}) {
    if (enabled) {
      detail!['native_features'] = {'message_forward_bundles': true};
    }
  }

  final bundleCalls = <String>[];
  final bundlePosts = <Json>[];
  final edits = <Json>[];
  Completer<Json>? pendingSubmission;
  Completer<Json>? pendingBundleRead;
  bool malformedReceipt = false;

  @override
  Future<void> editMessage(
    Json message,
    String content, {
    String? sourceRoomId,
    Json? richText,
  }) async {
    edits.add({
      'message_id': message['id'],
      'content': content,
      'source_room_id': sourceRoomId,
      'rich_text': richText,
    });
    final stored = (detail!['messages'] as List).cast<Json>().firstWhere(
      (item) => item['id'] == message['id'],
    );
    stored['content'] = content;
    stored['rich_text'] = richText;
    notifyListeners();
  }

  Json receipt(Json payload) => {
    'bundle': {
      'id': 'bundle-shared',
      'title': '聊天记录',
      'message_count': (payload['message_ids'] as List).length,
      'created_by': me!['id'],
      'created_at': '2026-09-07T01:00:00Z',
    },
    'deliveries': [
      for (final room in payload['target_room_ids'] as List)
        {
          'room_id': room,
          'message': {
            'id': 'delivered-$room',
            'kind': 'forward_bundle',
            'forward_bundle': {'id': 'bundle-shared'},
          },
        },
    ],
  };

  void installCard() {
    final message = (detail!['messages'] as List).first as Json;
    message.addAll({
      'kind': 'forward_bundle',
      'content': '请复核这份聊天记录',
      'forward_bundle': {
        'id': 'bundle-shared',
        'title': '协作聊天记录',
        'message_count': 2,
        'preview': [
          {'author_name': '团队成员', 'content': '已合并两条来源'},
        ],
      },
    });
  }

  Json get bundleDetails => {
    'room_id': 'room-demo',
    'message_id': 'multi-1',
    'bundle': {
      'id': 'bundle-shared',
      'title': '协作聊天记录',
      'message_count': 2,
      'snapshot_policy': 'shared_copy',
      'items': [
        {
          'source_message_id': 'shared-human',
          'source_revision': 3,
          'source_at': '2026-09-07T01:00:00Z',
          'kind': 'text',
          'author': {'id': 'human-source', 'name': '来源同事', 'kind': 'human'},
          'content': '分享原文：只在展开的聊天记录中显示',
          'attachments': <Json>[],
        },
        {
          'source_message_id': 'shared-agent',
          'source_revision': 1,
          'source_at': '2026-09-07T01:01:00Z',
          'kind': 'text',
          'author': {'id': 'agent-source', 'name': '复核 Agent', 'kind': 'agent'},
          'content': 'Agent 已检查共享的原始上下文',
          'attachments': <Json>[],
        },
      ],
    },
  };

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    if (path == '/rooms/room-demo/messages/forward-bundle') {
      expect(method, 'POST');
      bundleCalls.add('$method $path');
      final payload = cloneBundle(data!);
      bundlePosts.add(payload);
      if (pendingSubmission != null) return pendingSubmission!.future;
      if (malformedReceipt) return {'bundle': receipt(payload)['bundle']};
      return receipt(payload);
    }
    if (path == '/rooms') {
      expect(method, 'GET');
      bundleCalls.add('$method $path');
      return {'rooms': rooms};
    }
    if (path == '/rooms/room-target') {
      expect(method, 'GET');
      bundleCalls.add('$method $path');
      return {
        'room': {'id': 'room-target'},
        'members': [
          {...me!, 'principal_id': me!['id']},
          {'principal_id': 'agent-target', 'name': '目标 Agent', 'kind': 'agent'},
        ],
      };
    }
    if (path == '/rooms/room-demo/messages/multi-1/forward-bundle') {
      expect(method, 'GET');
      bundleCalls.add('$method $path');
      if (pendingBundleRead != null) return pendingBundleRead!.future;
      return cloneBundle(bundleDetails);
    }
    return super.officeRequest(path, method: method, data: data);
  }
}

// The selection bar remains busy while its composer route is open. A bounded
// frame pump advances real transitions without waiting for that live spinner.
Future<void> pumpBundleRoute(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

Finder composer() => find.byType(OfficeMergedForwardComposer);
Finder mergeAction() =>
    find.byKey(const ValueKey('selected-messages-merge_forward'));

Future<void> openBundleComposer(WidgetTester tester) async {
  await tester.ensureVisible(mergeAction());
  await tester.pump();
  await tester.tap(mergeAction());
  await pumpBundleRoute(tester);
  expect(composer(), findsOneWidget);
}

Future<void> chooseBundleTarget(WidgetTester tester) async {
  final target = find.byKey(const ValueKey('bundle-target-room-target'));
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await tester.pump();
}

Future<void> cancelBundleComposer(WidgetTester tester) async {
  await tester.tap(find.descendant(of: composer(), matching: find.text('取消')));
  await tester.pumpAndSettle();
}

void main() {
  for (final mobile in [false, true]) {
    final entry = mobile ? 'mobile long press' : 'desktop right click';
    testWidgets(
      '$entry can clear a merged card comment and retain its content',
      (tester) async {
        final state = ConversationBundleOffice()..installCard();
        await mountConversation(tester, state, mobile: mobile);
        await openMessageMenu(tester, 'multi-1', mobile: mobile);
        final edit = find.byKey(const ValueKey('message-action-edit'));
        await tester.ensureVisible(edit);
        await tester.tap(edit);
        await tester.pumpAndSettle();
        final body = find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.hintText == '消息内容',
        );
        await tester.enterText(body, '');
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await tester.pumpAndSettle();
        expect(state.edits, [
          {
            'message_id': 'multi-1',
            'content': '',
            'source_room_id': 'room-demo',
            'rich_text': null,
          },
        ]);
        expect(find.text('请复核这份聊天记录'), findsNothing);
        expect(
          find.byKey(const ValueKey('forward-bundle-card-multi-1')),
          findsOneWidget,
        );
        expect(find.text('协作聊天记录'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      '$entry exposes merged forwarding only for a declared feature',
      (tester) async {
        final state = ConversationBundleOffice(enabled: false);
        await mountConversation(tester, state, mobile: mobile);
        await enterMultiSelect(tester, mobile: mobile);
        expect(mergeAction(), findsNothing);
        expect(
          find.byKey(const ValueKey('selected-messages-forward')),
          findsOneWidget,
        );
        state.detail!['native_features'] = {'message_forward_bundles': false};
        await selectMessage(tester, 'multi-2');
        expect(mergeAction(), findsNothing);
        state.detail!['native_features'] = {'message_forward_bundles': true};
        await selectMessage(tester, 'multi-3');
        expect(mergeAction(), findsOneWidget);
        expect(state.bundlePosts, isEmpty);
      },
    );

    testWidgets(
      '$entry retains selection on cancel and clears it only after a validated merged receipt',
      (tester) async {
        final state = ConversationBundleOffice();
        await mountConversation(tester, state, mobile: mobile);
        await enterMultiSelect(tester, mobile: mobile);
        await selectMessage(tester, 'multi-2');
        await openBundleComposer(tester);
        expect(find.text('聊天记录 · 2 条'), findsOneWidget);
        await chooseBundleTarget(tester);
        await cancelBundleComposer(tester);
        expect(composer(), findsNothing);
        expect(state.bundlePosts, isEmpty);
        expect(find.text('已选择 2 / 50 条'), findsOneWidget);
        for (final id in ['multi-1', 'multi-2']) {
          expect(
            tester
                .widget<Checkbox>(find.byKey(ValueKey('select-message-$id')))
                .value,
            isTrue,
          );
        }

        state.pendingSubmission = Completer<Json>();
        await openBundleComposer(tester);
        await chooseBundleTarget(tester);
        await tester.tap(find.byKey(const ValueKey('bundle-send')));
        await pumpBundleRoute(tester);
        expect(state.bundlePosts, hasLength(1));
        expect(state.bundlePosts.single['message_ids'], ['multi-1', 'multi-2']);
        expect(state.bundlePosts.single['target_room_ids'], ['room-target']);
        expect(state.bundlePosts.single['base_revisions'], {
          'multi-1': 1,
          'multi-2': 1,
        });
        expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('bundle-send')))
              .onPressed,
          isNull,
        );
        expect(find.text('聊天记录已合并转发'), findsNothing);
        state.pendingSubmission!.complete(
          state.receipt(state.bundlePosts.single),
        );
        await tester.pumpAndSettle();
        expect(composer(), findsNothing);
        expect(
          find.byKey(const ValueKey('select-message-multi-1')),
          findsNothing,
        );
        expect(find.text('取消多选'), findsNothing);
        expect(find.text('聊天记录已合并转发'), findsOneWidget);
        expect(find.byType(TextField), findsOneWidget);
        expect(state.forwardAttempts, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$entry conversation card opens its real target-room snapshot and returns',
      (tester) async {
        final state = ConversationBundleOffice()..installCard();
        await mountConversation(tester, state, mobile: mobile);
        expect(find.text('分享原文：只在展开的聊天记录中显示'), findsNothing);
        final card = find.byKey(const ValueKey('forward-bundle-card-multi-1'));
        await tester.ensureVisible(card);
        await tester.pumpAndSettle();
        await tester.tap(card);
        await tester.pumpAndSettle();
        expect(find.byType(OfficeForwardBundleDetails), findsOneWidget);
        expect(find.text('分享原文：只在展开的聊天记录中显示'), findsOneWidget);
        expect(find.text('Agent 已检查共享的原始上下文'), findsOneWidget);
        expect(state.bundleCalls, [
          'GET /rooms/room-demo/messages/multi-1/forward-bundle',
        ]);
        expect(state.bundlePosts, isEmpty);
        await tester.tap(
          find.descendant(
            of: find.byType(OfficeForwardBundleDetails),
            matching: find.text('关闭'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(OfficeForwardBundleDetails), findsNothing);
        expect(card, findsOneWidget);
        expect(find.byType(TextField), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'malformed delivery stays pending and cancel preserves the exact selection',
    (tester) async {
      final state = ConversationBundleOffice()..malformedReceipt = true;
      await mountConversation(tester, state);
      await enterMultiSelect(tester);
      await selectMessage(tester, 'multi-2');
      await openBundleComposer(tester);
      await chooseBundleTarget(tester);
      await tester.tap(find.byKey(const ValueKey('bundle-send')));
      await pumpBundleRoute(tester);
      expect(state.bundlePosts, hasLength(1));
      expect(composer(), findsOneWidget);
      expect(find.text('重试确认原请求'), findsOneWidget);
      expect(find.text('聊天记录已合并转发'), findsNothing);
      await cancelBundleComposer(tester);
      expect(find.text('已选择 2 / 50 条'), findsOneWidget);
      expect(state.forwardAttempts, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a late merged receipt cannot report success into a replacement login',
    (tester) async {
      final state = ConversationBundleOffice()
        ..pendingSubmission = Completer<Json>();
      await mountConversation(tester, state);
      await enterMultiSelect(tester);
      await openBundleComposer(tester);
      await chooseBundleTarget(tester);
      await tester.tap(find.byKey(const ValueKey('bundle-send')));
      await pumpBundleRoute(tester);
      expect(state.bundlePosts, hasLength(1));
      state.changeIdentity();
      await tester.pump();
      state.pendingSubmission!.complete(
        state.receipt(state.bundlePosts.single),
      );
      await pumpBundleRoute(tester);
      expect(find.text('工作身份已变更，请重新打开。'), findsOneWidget);
      expect(find.text('聊天记录已合并转发'), findsNothing);
      await cancelBundleComposer(tester);
      expect(find.text('取消多选'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final mobile in [false, true]) {
    for (final multi in [false, true]) {
      testWidgets(
        '${mobile ? 'mobile' : 'desktop'} ${multi ? 'multi-selection' : 'message menu'} copies full shared bundle content',
        (tester) async {
          final state = ConversationBundleOffice()..installCard();
          final clipboard = captureClipboard(tester);
          await mountConversation(tester, state, mobile: mobile);
          if (multi) {
            await enterMultiSelect(tester, mobile: mobile);
            await selectMessage(tester, 'multi-2');
            await selectionAction(tester, 'copy');
          } else {
            await openMessageMenu(tester, 'multi-1', mobile: mobile);
            await tester.tap(find.byKey(const ValueKey('message-action-copy')));
            await tester.pumpAndSettle();
          }
          expect(clipboard, hasLength(1));
          final text = clipboard.single;
          expect(text, contains('[协作聊天记录]'));
          expect(text, contains('请复核这份聊天记录'));
          expect(text, contains('来源同事'));
          expect(text, contains('分享原文：只在展开的聊天记录中显示'));
          expect(text, contains('复核 Agent'));
          expect(text, contains('Agent 已检查共享的原始上下文'));
          expect(text, isNot(contains('已合并两条来源')));
          expect(state.bundleCalls, [
            'GET /rooms/room-demo/messages/multi-1/forward-bundle',
          ]);
          if (multi) {
            expect(text, endsWith('\n\n第 2 条协作消息'));
            expect(find.text('已选择 2 / 50 条'), findsOneWidget);
          }
          expect(state.bundlePosts, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'select text shows the bundle and copy whole text rechecks the current card',
    (tester) async {
      final state = ConversationBundleOffice()..installCard();
      final clipboard = captureClipboard(tester);
      await mountConversation(tester, state);
      await openMessageMenu(tester, 'multi-1');
      final select = find.byKey(const ValueKey('message-action-select'));
      await tester.ensureVisible(select);
      await tester.pumpAndSettle();
      await tester.tap(select);
      await tester.pumpAndSettle();
      expect(find.text('选择文本'), findsOneWidget);
      expect(find.textContaining('分享原文：只在展开的聊天记录中显示'), findsOneWidget);
      expect(clipboard, isEmpty);
      ((state.detail!['messages'] as List).first as Json)['content'] = '更新后的附言';
      await tester.tap(find.text('复制全文'));
      await tester.pumpAndSettle();
      expect(clipboard, hasLength(1));
      expect(clipboard.single, contains('更新后的附言'));
      expect(clipboard.single, isNot(contains('请复核这份聊天记录')));
      expect(clipboard.single, contains('Agent 已检查共享的原始上下文'));
      expect(
        state.bundleCalls
            .where((call) => call.endsWith('/forward-bundle'))
            .length,
        2,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final multi in [false, true]) {
    testWidgets(
      'late ${multi ? 'selected' : 'single'} bundle copy never reaches a replacement login clipboard',
      (tester) async {
        final state = ConversationBundleOffice()
          ..installCard()
          ..pendingBundleRead = Completer<Json>();
        final clipboard = captureClipboard(tester);
        await mountConversation(tester, state);
        if (multi) {
          await enterMultiSelect(tester);
          await selectMessage(tester, 'multi-2');
          await selectionAction(tester, 'copy', settle: false);
        } else {
          await openMessageMenu(tester, 'multi-1');
          await tester.tap(find.byKey(const ValueKey('message-action-copy')));
        }
        await pumpBundleRoute(tester);
        expect(state.bundleCalls, [
          'GET /rooms/room-demo/messages/multi-1/forward-bundle',
        ]);
        state.changeIdentity();
        await tester.pump();
        state.pendingBundleRead!.complete(cloneBundle(state.bundleDetails));
        await tester.pumpAndSettle();
        expect(clipboard, isEmpty);
        expect(find.text('消息已复制'), findsNothing);
        expect(find.textContaining('未完成的消息仍保留选择'), findsNothing);
        expect(find.text('取消多选'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'bundle link copy keeps coordinates without reading the share body',
    (tester) async {
      final state = ConversationBundleOffice()..installCard();
      final clipboard = captureClipboard(tester);
      await mountConversation(tester, state);
      await enterMultiSelect(tester);
      await selectMessage(tester, 'multi-2');
      await selectionAction(tester, 'copy_link');
      expect(clipboard, [
        [
          officeMessageLink(state.endpoint, 'room-demo', 'multi-1'),
          officeMessageLink(state.endpoint, 'room-demo', 'multi-2'),
        ].join('\n\n'),
      ]);
      expect(state.bundleCalls, isEmpty);
      expect(find.text('已选择 2 / 50 条'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'changing rooms during a bundle copy rejects the late clipboard write',
    (tester) async {
      final state = ConversationBundleOffice()
        ..installCard()
        ..pendingBundleRead = Completer<Json>();
      final clipboard = captureClipboard(tester);
      await mountConversation(tester, state);
      await openMessageMenu(tester, 'multi-1');
      await tester.tap(find.byKey(const ValueKey('message-action-copy')));
      await pumpBundleRoute(tester);
      expect(state.bundleCalls, [
        'GET /rooms/room-demo/messages/multi-1/forward-bundle',
      ]);
      state.selectedRoomId = 'room-target';
      state.detail = null;
      state.notifyListeners();
      await tester.pump();
      state.pendingBundleRead!.complete(cloneBundle(state.bundleDetails));
      await tester.pumpAndSettle();
      expect(clipboard, isEmpty);
      expect(find.text('消息已复制'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'original message keeps bundle comment and expands the same shared card',
    (tester) async {
      final state = ConversationBundleOffice()..installCard();
      await mountBundleOriginal(tester, state);
      expect(find.text('请复核这份聊天记录'), findsOneWidget);
      final card = find.byKey(const ValueKey('forward-bundle-card-multi-1'));
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.byType(OfficeForwardBundleDetails), findsOneWidget);
      expect(find.text('分享原文：只在展开的聊天记录中显示'), findsOneWidget);
      expect(state.bundleCalls, [
        'GET /rooms/room-demo/messages/multi-1/forward-bundle',
      ]);
      await tester.tap(
        find.descendant(
          of: find.byType(OfficeForwardBundleDetails),
          matching: find.text('关闭'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(OfficeMessageOriginal), findsOneWidget);
      expect(find.text('请复核这份聊天记录'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('hidden original never renders the bundle card or shared body', (
    tester,
  ) async {
    final state = ConversationBundleOffice()
      ..installCard()
      ..returnedHidden = true;
    await mountBundleOriginal(tester, state);
    expect(find.text('这条消息已从你的聊天中删除'), findsOneWidget);
    expect(find.byType(OfficeForwardBundleCard), findsNothing);
    expect(find.text('请复核这份聊天记录'), findsNothing);
    expect(find.text('分享原文：只在展开的聊天记录中显示'), findsNothing);
    expect(state.bundleCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'same-principal login expires original details and rejects late refresh',
    (tester) async {
      final state = ConversationBundleOffice()..installCard();
      await mountBundleOriginal(tester, state);
      expect(find.byType(OfficeForwardBundleCard), findsOneWidget);
      final snapshot = cloneBundle(
        Json.from((state.detail!['messages'] as List).first as Map),
      );
      state.pendingRead = Completer<Json>();
      state.notifyListeners();
      await tester.pump(const Duration(milliseconds: 200));
      state.changeIdentity();
      await tester.pump();
      expect(find.text('工作身份已切换，请重新打开原文'), findsOneWidget);
      expect(find.byType(OfficeForwardBundleCard), findsNothing);
      state.pendingRead!.complete({'message': snapshot});
      await tester.pumpAndSettle();
      expect(find.text('工作身份已切换，请重新打开原文'), findsOneWidget);
      expect(find.byType(OfficeForwardBundleCard), findsNothing);
      expect(find.text('请复核这份聊天记录'), findsNothing);
      expect(find.text('重试'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> mountBundleOriginal(
  WidgetTester tester,
  ConversationBundleOffice state,
) async {
  addTearDown(state.dispose);
  tester.view.physicalSize = const Size(1100, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showOfficeMessageOriginal(
              context,
              state,
              'room-demo',
              'multi-1',
            ),
            child: const Text('查看原文'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('查看原文'));
  await tester.pumpAndSettle();
}
