import 'dart:async';

import 'package:active_office/office_state.dart';
import 'package:active_office/ui/message_actions.dart';
import 'package:active_office/ui/office_emoji.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class MenuOffice extends OfficeState {
  MenuOffice({String kind = 'human'}) {
    endpoint = 'https://menu.invalid';
    me = {'id': 'menu-$kind', 'kind': kind, 'name': '消息菜单测试'};
    selectedRoomId = 'room-menu';
    connected = true;
  }
  int generation = 0;
  @override
  int get identityGeneration => generation;
  final requests = <Json>[];
  List<String> recent = [
    '😀',
    'feishu:OK',
    'feishu:THANKS',
    'feishu:HEART',
    'feishu:DONE',
    'feishu:APPLAUSE',
    'feishu:SMILE',
  ];
  Completer<Json>? pending;
  void changeIdentity() {
    generation++;
    notifyListeners();
  }

  void changeRoom() {
    selectedRoomId = 'room-other';
    notifyListeners();
  }

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    expect(path, '/emoji/recents');
    requests.add({'path': path, 'method': method, 'data': data});
    if (method == 'GET' && pending != null) return pending!.future;
    return {'emoji_ids': recent};
  }
}

const liveMessage = <String, dynamic>{
  'id': 'message-menu',
  'content': '协作消息',
  'pinned': false,
};

Future<void> openMenu(
  WidgetTester tester, {
  bool mobile = true,
  bool own = true,
  Json message = liveMessage,
  MenuOffice? state,
  required ValueChanged<String?> onResult,
}) async {
  tester.view.physicalSize = mobile
      ? const Size(390, 844)
      : const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => onResult(
              await showOfficeMessageActions(
                context,
                message,
                own: own,
                position: const Offset(400, 30),
                state: state,
              ),
            ),
            child: const Text('打开消息菜单'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开消息菜单'));
  await tester.pumpAndSettle();
}

Future<void> choose(WidgetTester tester, String action) async {
  final finder = find.byKey(ValueKey('message-action-$action'));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  test('common action contract respects ownership, personal marks and forwarding state', () {
    final own = officeMessageActions(liveMessage, true);
    final other = officeMessageActions(liveMessage, false);
    expect(own.map((a) => a.$1).toSet().length, own.length);
    expect(
      own.map((a) => a.$1),
      containsAll([
        'multi_select',
        'mark',
        'copy_link',
        'forwarding',
        'hide',
        'task',
        'export',
        'select',
        'edit',
        'read',
        'original',
      ]),
    );
    expect(other.map((a) => a.$1), isNot(contains('forwarding')));
    expect(other.map((a) => a.$1), isNot(contains('edit')));
    expect(other.map((a) => a.$1), isNot(contains('retract')));
    final marked = officeMessageActions({
      ...liveMessage,
      'personal_preferences': {'marked': true},
      'forwarding_own_no_forward': true,
    }, true);
    expect(marked.firstWhere((a) => a.$1 == 'mark').$2, '取消标记');
    expect(marked.firstWhere((a) => a.$1 == 'forwarding').$2, '允许转发');
    expect(own.firstWhere((a) => a.$1 == 'forwarding').$2, '禁止转发');
    final retracted = officeMessageActions({
      ...liveMessage,
      'retracted_at': '2026-09-06T00:00:00Z',
    }, true);
    expect(
      retracted.map((a) => a.$1),
      isNot(
        anyOf(
          contains('emoji'),
          contains('reply'),
          contains('edit'),
          contains('forwarding'),
        ),
      ),
    );
    expect(
      retracted.map((a) => a.$1),
      containsAll(['read', 'original', 'hide']),
    );
  });

  testWidgets(
    'mobile has six reactions, one more entry and exactly four primary actions',
    (tester) async {
      await openMenu(tester, onResult: (_) {});
      expect(find.byType(OfficeEmojiGlyph), findsNWidgets(6));
      expect(find.byKey(const ValueKey('message-more-emoji')), findsOneWidget);
      final primary = find.byKey(const ValueKey('message-actions-primary'));
      expect(
        find.descendant(of: primary, matching: find.byType(InkWell)),
        findsNWidgets(4),
      );
      final rects = ['reply', 'forward', 'topic', 'copy']
          .map(
            (id) => tester.getRect(find.byKey(ValueKey('message-action-$id'))),
          )
          .toList();
      expect(rects.map((rect) => rect.top).toSet().length, 1);
      expect(rects.map((rect) => rect.width).toSet().length, 1);
      expect(find.byType(ListTile), findsWidgets);
      final scrollFinder = find.byKey(const ValueKey('message-actions-scroll'));
      expect(tester.getRect(scrollFinder).height, closeTo(844 * .45, 1));
      await tester.timedDrag(
        find.byKey(const ValueKey('message-actions-drag-handle')),
        const Offset(0, -338),
        const Duration(milliseconds: 600),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(scrollFinder).height, closeTo(844 * .85, 1));
      await tester.timedDrag(
        scrollFinder,
        const Offset(0, -300),
        const Duration(milliseconds: 500),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<SingleChildScrollView>(scrollFinder).controller!.offset,
        greaterThan(100),
      );
      expect(
        find.byKey(const ValueKey('message-actions-draggable-sheet')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final mobile in [true, false]) {
    for (final action in [
      'multi_select',
      'mark',
      'copy_link',
      'forwarding',
      'hide',
      'task',
      'export',
    ]) {
      testWidgets(
        '${mobile ? 'mobile' : 'desktop'} returns the $action contract once',
        (tester) async {
          final result = <String?>[];
          await openMenu(tester, mobile: mobile, onResult: result.add);
          await choose(tester, action);
          expect(result, [action]);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final kind in ['human', 'agent']) {
    testWidgets(
      '$kind quick reactions load six personal recents and preserve canonical IDs',
      (tester) async {
        final state = MenuOffice(kind: kind);
        addTearDown(state.dispose);
        final result = <String?>[];
        await openMenu(tester, state: state, onResult: result.add);
        expect(state.requests, [
          {'path': '/emoji/recents', 'method': 'GET', 'data': null},
        ]);
        expect(
          tester
              .widgetList<OfficeEmojiGlyph>(find.byType(OfficeEmojiGlyph))
              .map((g) => g.id),
          state.recent.take(6),
        );
        await tester.tap(find.byKey(const ValueKey('message-quick-😀')));
        await tester.pumpAndSettle();
        expect(result, ['react:😀']);
        expect(state.requests.last, {
          'path': '/emoji/recents',
          'method': 'POST',
          'data': {'emoji': '😀'},
        });
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'more opens the complete picker and records a chosen emoji only once',
    (tester) async {
      final state = MenuOffice();
      addTearDown(state.dispose);
      final result = <String?>[];
      await tester.runAsync(
        () => rootBundle.loadString('assets/emoji/catalog.json'),
      );
      await openMenu(tester, state: state, onResult: result.add);
      await tester.tap(find.byKey(const ValueKey('message-more-emoji')));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(OfficeEmojiPicker), findsOneWidget);
      expect(
        find.byKey(const ValueKey('message-actions-draggable-sheet')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('emoji-open-search')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'THUMBSUP');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('emoji-feishu:THUMBSUP')));
      await tester.pumpAndSettle();
      expect(result, ['react:feishu:THUMBSUP']);
      expect(state.requests.where((r) => r['method'] == 'POST').length, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final transition in ['identity', 'room']) {
    testWidgets(
      '$transition change expires retained callbacks and discards late recents',
      (tester) async {
        final state = MenuOffice()..pending = Completer<Json>();
        addTearDown(state.dispose);
        final result = <String?>[];
        await openMenu(tester, state: state, onResult: result.add);
        final oldChoose = tester
            .widget<IconButton>(
              find.byKey(const ValueKey('message-quick-feishu:THUMBSUP')),
            )
            .onPressed!;
        if (transition == 'identity') {
          state.changeIdentity();
        } else {
          state.changeRoom();
        }
        await tester.pumpAndSettle();
        oldChoose();
        state.pending!.complete({
          'emoji_ids': ['😀'],
        });
        await tester.pumpAndSettle();
        expect(find.byType(OfficeEmojiGlyph), findsNothing);
        expect(find.text('工作身份或会话已变化，请重新打开消息操作。'), findsOneWidget);
        expect(state.requests.length, 1);
        expect(result, isEmpty);
        await tester.tapAt(const Offset(20, 20));
        await tester.pumpAndSettle();
        expect(result, [null]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'offline menu uses bundled six without reading or writing recents',
    (tester) async {
      final state = MenuOffice()..connected = false;
      addTearDown(state.dispose);
      final result = <String?>[];
      await openMenu(tester, state: state, onResult: result.add);
      expect(state.requests, isEmpty);
      await tester.tap(
        find.byKey(const ValueKey('message-quick-feishu:THUMBSUP')),
      );
      await tester.pumpAndSettle();
      expect(result, ['react:feishu:THUMBSUP']);
      expect(state.requests, isEmpty);
    },
  );

  for (final mobile in [true, false]) {
    testWidgets(
      '${mobile ? 'mobile' : 'desktop'} forwarding protection disables forward but keeps own release control',
      (tester) async {
        final result = <String?>[];
        await openMenu(
          tester,
          mobile: mobile,
          message: {
            ...liveMessage,
            'no_forward': true,
            'forwarding_own_no_forward': true,
          },
          onResult: result.add,
        );
        final forward = find.byKey(const ValueKey('message-action-forward'));
        if (mobile) {
          expect(tester.widget<InkWell>(forward).onTap, isNull);
        } else {
          expect(
            tester.widget<PopupMenuItem<String>>(forward).enabled,
            isFalse,
          );
        }
        expect(find.text('允许转发'), findsOneWidget);
        await choose(tester, 'forwarding');
        expect(result, ['forwarding']);
      },
    );
  }
}
