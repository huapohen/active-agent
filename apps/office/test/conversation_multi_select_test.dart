import 'dart:async';

import 'package:active_office/office_state.dart';
import 'package:active_office/ui/conversation.dart';
import 'package:active_office/ui/message_links.dart';
import 'package:active_office/ui/office_emoji.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'office_ui_test.dart' show LayoutOfficeState;

class MultiSelectOffice extends LayoutOfficeState {
  MultiSelectOffice() {
    final template = Map<String, dynamic>.from(
      (detail!['messages'] as List).single as Map,
    );
    detail!['messages'] = [
      for (var index = 1; index <= 3; index++)
        {
          ...template,
          'id': 'multi-$index',
          'seq': index,
          'content': '第 $index 条协作消息',
        },
    ];
    rooms.add({'id': 'room-target', 'name': '目标协作群', 'kind': 'group'});
  }

  int generation = 0;
  @override
  int get identityGeneration => generation;
  final reads = <String>[];
  final forwardAttempts = <(String, String, String?)>[];
  final forwarded = <String>[];
  String? failOnce, pendingForwardId;
  Completer<Json>? pendingForward, pendingRead;
  bool returnedHidden = false;

  void changeIdentity() {
    generation++;
    notifyListeners();
  }

  @override
  Future<void> reportVisibleMessageSequences(
    String roomId,
    Iterable<int> sequences, {
    required int selection,
    required int identityGeneration,
  }) async {}

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    if (path == '/emoji/recents') return {'emoji_ids': <String>[]};
    expect(method, 'GET');
    expect(data, isNull);
    reads.add(path);
    if (pendingRead != null) return pendingRead!.future;
    final id = Uri.decodeComponent(path.split('/').last);
    final message = (detail!['messages'] as List).cast<Map>().firstWhere(
      (m) => m['id'] == id,
    );
    return {
      'message': {...message, 'hidden': returnedHidden},
    };
  }

  @override
  Future<Json> forwardMessage(
    Json message,
    String targetRoomId, {
    String? sourceRoomId,
  }) async {
    final id = message['id'] as String;
    forwardAttempts.add((id, targetRoomId, sourceRoomId));
    if (pendingForwardId == id) return pendingForward!.future;
    if (failOnce == id) {
      failOnce = null;
      throw OfficeException(503, '该条暂时无法转发');
    }
    forwarded.add(id);
    return {'id': 'forwarded-$id'};
  }
}

Future<void> mountConversation(
  WidgetTester tester,
  MultiSelectOffice state, {
  bool mobile = false,
}) async {
  tester.view.physicalSize = mobile
      ? const Size(390, 844)
      : const Size(1100, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: OfficeConversation(state: state, mobile: mobile),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> openMessageMenu(
  WidgetTester tester,
  String id, {
  bool mobile = false,
}) async {
  final message = find.byKey(ValueKey('message-content-$id'));
  await tester.ensureVisible(message);
  await tester.pumpAndSettle();
  if (mobile) {
    await tester.longPress(message);
  } else {
    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await mouse.down(tester.getCenter(message));
    await mouse.up();
    await mouse.removePointer();
  }
  await tester.pumpAndSettle();
}

Future<void> enterMultiSelect(
  WidgetTester tester, {
  bool mobile = false,
}) async {
  await openMessageMenu(tester, 'multi-1', mobile: mobile);
  final action = find.byKey(const ValueKey('message-action-multi_select'));
  await tester.ensureVisible(action);
  await tester.pumpAndSettle();
  await tester.tap(action);
  await tester.pumpAndSettle();
}

Future<void> selectMessage(WidgetTester tester, String id) async {
  final checkbox = find.byKey(ValueKey('select-message-$id'));
  await tester.ensureVisible(checkbox);
  await tester.pumpAndSettle();
  await tester.tap(checkbox);
  await tester.pumpAndSettle();
}

Future<void> selectionAction(
  WidgetTester tester,
  String action, {
  bool settle = true,
}) async {
  final button = find.byKey(ValueKey('selected-messages-$action'));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  if (action == 'forward') {
    // Batch selection stays busy while its destination dialog is open.
    // Wait for the route transition without waiting on that live spinner.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  } else if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> confirmTarget(WidgetTester tester, {bool settle = true}) async {
  await tester.tap(find.text('目标协作群'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(find.text('确认转发'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
}

List<String> captureClipboard(WidgetTester tester) {
  final writes = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        writes.add((call.arguments as Map)['text'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return writes;
}

void main() {
  for (final mobile in [false, true]) {
    testWidgets(
      '${mobile ? 'mobile long press' : 'desktop right click'} enters checkbox selection and cancel restores composer',
      (tester) async {
        final state = MultiSelectOffice();
        await mountConversation(tester, state, mobile: mobile);
        await enterMultiSelect(tester, mobile: mobile);
        expect(find.text('已选择 1 / 50 条'), findsOneWidget);
        expect(
          tester
              .widget<Checkbox>(
                find.byKey(const ValueKey('select-message-multi-1')),
              )
              .value,
          isTrue,
        );
        await selectMessage(tester, 'multi-2');
        expect(find.text('已选择 2 / 50 条'), findsOneWidget);
        expect(
          tester
              .widget<Checkbox>(
                find.byKey(const ValueKey('select-message-multi-2')),
              )
              .value,
          isTrue,
        );
        await selectMessage(tester, 'multi-1');
        expect(find.text('已选择 1 / 50 条'), findsOneWidget);
        expect(
          tester
              .widget<Checkbox>(
                find.byKey(const ValueKey('select-message-multi-1')),
              )
              .value,
          isFalse,
        );
        await tester.tap(find.text('取消多选'));
        await tester.pumpAndSettle();
        expect(find.byType(Checkbox), findsNothing);
        expect(
          find.byKey(const ValueKey('selected-messages-copy_link')),
          findsNothing,
        );
        expect(find.byType(TextField), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'desktop right click on mixed classic emoji text opens one complete message menu',
    (tester) async {
      final state = MultiSelectOffice();
      (state.detail!['messages'] as List).first['content'] =
          '协作 :feishu:OK: 已完成';
      await mountConversation(tester, state);
      expect(find.byType(SelectionArea), findsOneWidget);
      await openMessageMenu(tester, 'multi-1');
      expect(
        find.byKey(const ValueKey('message-action-multi_select')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('message-action-copy_link')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('message-action-select')),
        findsOneWidget,
      );
      expect(find.text('回复'), findsOneWidget);
      expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
      expect(find.byType(OfficeEmojiGlyph), findsWidgets);
      final select = find.byKey(const ValueKey('message-action-multi_select'));
      await tester.ensureVisible(select);
      await tester.pumpAndSettle();
      await tester.tap(select);
      await tester.pumpAndSettle();
      expect(find.text('已选择 1 / 50 条'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'copy message links rereads selected messages and copies ordered coordinate URLs',
    (tester) async {
      final state = MultiSelectOffice();
      final clipboard = captureClipboard(tester);
      await mountConversation(tester, state);
      await enterMultiSelect(tester);
      await selectMessage(tester, 'multi-3');
      await selectMessage(tester, 'multi-2');
      await selectionAction(tester, 'copy_link');
      expect(state.reads, [
        for (var index = 1; index <= 3; index++)
          '/rooms/room-demo/messages/multi-$index',
      ]);
      expect(clipboard, [
        [
          for (var index = 1; index <= 3; index++)
            officeMessageLink(state.endpoint, 'room-demo', 'multi-$index'),
        ].join('\n\n'),
      ]);
      expect(find.text('已复制 3 条消息链接'), findsOneWidget);
      expect(find.text('已选择 3 / 50 条'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'freshly hidden message prevents link copy and keeps the selection',
    (tester) async {
      final state = MultiSelectOffice()..returnedHidden = true;
      final clipboard = captureClipboard(tester);
      await mountConversation(tester, state);
      await enterMultiSelect(tester);
      await selectionAction(tester, 'copy_link');
      expect(clipboard, isEmpty);
      expect(find.textContaining('所选消息已删除或撤回'), findsOneWidget);
      expect(find.text('已选择 1 / 50 条'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'partial sequential forwarding retains failed and unattempted messages without duplicating success',
    (tester) async {
      final state = MultiSelectOffice()..failOnce = 'multi-2';
      await mountConversation(tester, state);
      await enterMultiSelect(tester);
      await selectMessage(tester, 'multi-2');
      await selectMessage(tester, 'multi-3');
      await selectionAction(tester, 'forward');
      await confirmTarget(tester);
      expect(state.forwardAttempts, [
        ('multi-1', 'room-target', 'room-demo'),
        ('multi-2', 'room-target', 'room-demo'),
      ]);
      expect(state.forwarded, ['multi-1']);
      expect(find.text('已选择 2 / 50 条'), findsOneWidget);
      expect(find.textContaining('未完成的消息仍保留选择'), findsOneWidget);
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const ValueKey('select-message-multi-1')),
            )
            .value,
        isFalse,
      );
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const ValueKey('select-message-multi-2')),
            )
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const ValueKey('select-message-multi-3')),
            )
            .value,
        isTrue,
      );
      // The failure snackbar overlays the bottom action bar briefly.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await selectionAction(tester, 'forward');
      expect(find.text('逐条转发 2 条消息'), findsOneWidget);
      await confirmTarget(tester);
      expect(state.forwardAttempts, [
        ('multi-1', 'room-target', 'room-demo'),
        ('multi-2', 'room-target', 'room-demo'),
        ('multi-2', 'room-target', 'room-demo'),
        ('multi-3', 'room-target', 'room-demo'),
      ]);
      expect(state.forwarded, ['multi-1', 'multi-2', 'multi-3']);
      expect(find.byType(Checkbox), findsNothing);
      expect(find.text('取消多选'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('same-principal identity turnover clears selected messages', (
    tester,
  ) async {
    final state = MultiSelectOffice();
    await mountConversation(tester, state);
    await enterMultiSelect(tester);
    await selectMessage(tester, 'multi-2');
    state.changeIdentity();
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNothing);
    expect(find.textContaining('已选择'), findsNothing);
    await enterMultiSelect(tester);
    expect(find.text('已选择 1 / 50 条'), findsOneWidget);
    expect(
      tester
          .widget<Checkbox>(
            find.byKey(const ValueKey('select-message-multi-2')),
          )
          .value,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'late fresh-message failure neither copies nor reports into the next identity',
    (tester) async {
      final state = MultiSelectOffice()..pendingRead = Completer<Json>();
      final clipboard = captureClipboard(tester);
      await mountConversation(tester, state);
      await enterMultiSelect(tester);
      await selectionAction(tester, 'copy_link', settle: false);
      expect(state.reads, ['/rooms/room-demo/messages/multi-1']);
      state.changeIdentity();
      await tester.pump();
      state.pendingRead!.completeError(OfficeException(503, '旧身份链接请求失败'));
      await tester.pumpAndSettle();
      expect(clipboard, isEmpty);
      expect(find.textContaining('旧身份链接请求失败'), findsNothing);
      expect(find.textContaining('未完成的消息仍保留选择'), findsNothing);
      expect(find.byType(Checkbox), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final multi in [false, true]) {
    testWidgets(
      'late ${multi ? 'batch' : 'single'} forwarding failure never reaches the next identity',
      (tester) async {
        final state = MultiSelectOffice()
          ..pendingForwardId = 'multi-1'
          ..pendingForward = Completer<Json>();
        await mountConversation(tester, state);
        if (multi) {
          await enterMultiSelect(tester);
          await selectMessage(tester, 'multi-2');
          await selectionAction(tester, 'forward');
        } else {
          await openMessageMenu(tester, 'multi-1');
          await tester.tap(
            find.byKey(const ValueKey('message-action-forward')),
          );
          await tester.pumpAndSettle();
        }
        await confirmTarget(tester, settle: false);
        expect(state.forwardAttempts, [
          ('multi-1', 'room-target', 'room-demo'),
        ]);
        state.changeIdentity();
        await tester.pump();
        state.pendingForward!.completeError(OfficeException(503, '旧身份转发请求失败'));
        await tester.pumpAndSettle();
        expect(state.forwardAttempts.length, 1);
        expect(find.textContaining('旧身份转发请求失败'), findsNothing);
        expect(find.textContaining('未完成的消息仍保留选择'), findsNothing);
        expect(find.byType(Checkbox), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
