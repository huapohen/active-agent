import 'package:active_office/office_state.dart';
import 'package:active_office/ui/message_hover_tools.dart';
import 'package:active_office/ui/office_emoji.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class HoverFixture extends OfficeState {
  HoverFixture() {
    endpoint = 'https://hover.invalid';
    me = {'id': 'hover-member', 'kind': 'human', 'name': '工作成员'};
    connected = true;
  }

  final requests = <(String, String, Json?)>[];

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    requests.add((method, path, data));
    if (path == '/emoji/recents') {
      return {
        'emoji_ids': [if (method == 'POST') data!['emoji']],
      };
    }
    throw StateError('Unexpected request: $method $path');
  }
}

const messageKey = ValueKey('hover-message-body');
const followingKey = ValueKey('hover-following-message');
Finder toolbar() => find.byKey(const ValueKey('message-hover-toolbar-m1'));
Finder timestamp() => find.byKey(const ValueKey('message-hover-time-m1'));

Future<void> mountHover(
  WidgetTester tester,
  HoverFixture state,
  List<String> actions, {
  bool enabled = true,
  bool active = true,
  bool mounted = true,
  bool use24Hours = true,
  String? sentAt = '2026-09-06T13:04:05',
  Offset messageOffset = const Offset(250, 240),
  ValueChanged<Offset>? onOpenMore,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(alwaysUse24HourFormat: use24Hours),
        child: child!,
      ),
      home: Scaffold(
        body: TickerMode(
          enabled: active,
          child: Stack(
            children: [
              Positioned(
                left: messageOffset.dx,
                top: messageOffset.dy,
                child: Column(
                  children: [
                    if (mounted)
                      OfficeMessageHoverTools(
                        messageId: 'm1',
                        state: state,
                        enabled: enabled,
                        timestamp: sentAt,
                        onAction: actions.add,
                        onOpenMore: onOpenMore,
                        child: const SizedBox(
                          key: messageKey,
                          width: 300,
                          height: 80,
                          child: ColoredBox(
                            color: Color(0xffeaf2ff),
                            child: Center(child: Text('项目更新消息')),
                          ),
                        ),
                      ),
                    const SizedBox(height: 18),
                    const SizedBox(
                      key: followingKey,
                      width: 280,
                      height: 65,
                      child: ColoredBox(
                        color: Color(0xfff1f3f5),
                        child: Center(child: Text('后续工作消息')),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<TestGesture> enterMessage(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: const Offset(700, 550));
  await mouse.moveTo(tester.getCenter(find.byKey(messageKey)));
  await tester.pump();
  return mouse;
}

Future<void> loadOpenPicker(WidgetTester tester) async {
  await tester.pump();
  // Bundled catalog decoding uses a real isolate; allow its completed asset
  // future to deliver outside Flutter's fake test clock before settling frames.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 30)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'hover time and toolbar do not move the message or its successor',
    (tester) async {
      final state = HoverFixture();
      addTearDown(state.dispose);
      await mountHover(tester, state, []);
      final messageBefore = tester.getRect(find.byKey(messageKey));
      final followingBefore = tester.getRect(find.byKey(followingKey));
      expect(toolbar(), findsNothing);
      expect(timestamp(), findsNothing);

      final mouse = await enterMessage(tester);
      expect(toolbar(), findsOneWidget);
      expect(timestamp(), findsOneWidget);
      expect(find.text('13:04'), findsOneWidget);
      expect(find.text('2026/09/06 13:04:05'), findsNothing);
      expect(find.byTooltip('2026/09/06 13:04:05'), findsOneWidget);
      expect(tester.getRect(find.byKey(messageKey)), messageBefore);
      expect(tester.getRect(find.byKey(followingKey)), followingBefore);
      final timeRect = tester.getRect(timestamp());
      final toolbarRect = tester.getRect(toolbar());
      // The test font has wider digits than the desktop font. The label
      // expands leftward while retaining the same 8 px gap beside the bubble.
      expect(timeRect.left, lessThanOrEqualTo(messageBefore.left - 44));
      expect(timeRect.right, messageBefore.left - 8);
      expect(timeRect.center.dy, messageBefore.center.dy);
      expect(toolbarRect.right, messageBefore.right);
      expect(toolbarRect.top, messageBefore.top - 36);

      await mouse.moveTo(const Offset(700, 550));
      await tester.pump(const Duration(milliseconds: 200));
      expect(toolbar(), findsNothing);
      expect(timestamp(), findsNothing);
      expect(tester.getRect(find.byKey(messageKey)), messageBefore);
      expect(tester.getRect(find.byKey(followingKey)), followingBefore);
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('12-hour preference changes only the independent time label', (
    tester,
  ) async {
    final state = HoverFixture();
    addTearDown(state.dispose);
    await mountHover(tester, state, [], use24Hours: false);
    final messageBefore = tester.getRect(find.byKey(messageKey));
    final followingBefore = tester.getRect(find.byKey(followingKey));
    final mouse = await enterMessage(tester);
    expect(find.text('下午 1:04'), findsOneWidget);
    expect(find.byTooltip('2026/09/06 下午 1:04:05'), findsOneWidget);
    expect(tester.getRect(timestamp()).right, messageBefore.left - 8);
    expect(tester.getRect(timestamp()).center.dy, messageBefore.center.dy);
    expect(tester.getRect(toolbar()).top, messageBefore.top - 36);
    expect(tester.getRect(find.byKey(messageKey)), messageBefore);
    expect(tester.getRect(find.byKey(followingKey)), followingBefore);
    await mouse.removePointer();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'moving onto the time exposes full precision without moving rows',
    (tester) async {
      final state = HoverFixture();
      addTearDown(state.dispose);
      await mountHover(tester, state, []);
      final messageBefore = tester.getRect(find.byKey(messageKey));
      final followingBefore = tester.getRect(find.byKey(followingKey));
      final mouse = await enterMessage(tester);
      await mouse.moveTo(tester.getCenter(timestamp()));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 250));
      expect(toolbar(), findsOneWidget);
      expect(find.text('2026/09/06 13:04:05'), findsOneWidget);
      expect(tester.getRect(find.byKey(messageKey)), messageBefore);
      expect(tester.getRect(find.byKey(followingKey)), followingBefore);
      await mouse.moveTo(const Offset(700, 550));
      await tester.pump(const Duration(seconds: 1));
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    },
  );

  for (final edge in [
    ('top left', const Offset(0, -30)),
    ('bottom right', const Offset(550, 560)),
  ]) {
    testWidgets('time and toolbar stay inside the $edge overlay boundary', (
      tester,
    ) async {
      final state = HoverFixture();
      addTearDown(state.dispose);
      await mountHover(tester, state, [], messageOffset: edge.$2);
      final messageBefore = tester.getRect(find.byKey(messageKey));
      final followingBefore = tester.getRect(find.byKey(followingKey));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(400, 350));
      await mouse.moveTo(
        Offset(
          messageBefore.center.dx.clamp(1.0, 799.0),
          messageBefore.center.dy.clamp(1.0, 599.0),
        ),
      );
      await tester.pump();
      for (final finder in [timestamp(), toolbar()]) {
        expect(finder, findsOneWidget);
        final bounds = tester.getRect(finder);
        expect(bounds.left, greaterThanOrEqualTo(8));
        expect(bounds.top, greaterThanOrEqualTo(8));
        expect(bounds.right, lessThanOrEqualTo(792));
        expect(bounds.bottom, lessThanOrEqualTo(592));
      }
      expect(tester.getRect(find.byKey(messageKey)), messageBefore);
      expect(tester.getRect(find.byKey(followingKey)), followingBefore);
      await mouse.removePointer();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('missing timestamp does not alter the toolbar anchor', (
    tester,
  ) async {
    final state = HoverFixture();
    addTearDown(state.dispose);
    await mountHover(tester, state, [], sentAt: null);
    final messageBefore = tester.getRect(find.byKey(messageKey));
    final mouse = await enterMessage(tester);
    expect(timestamp(), findsNothing);
    expect(toolbar(), findsOneWidget);
    expect(tester.getRect(toolbar()).top, messageBefore.top - 36);
    expect(tester.getRect(toolbar()).right, messageBefore.right);
    await mouse.removePointer();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'moving from a message into its toolbar preserves hover controls',
    (tester) async {
      final state = HoverFixture();
      addTearDown(state.dispose);
      await mountHover(tester, state, []);
      final mouse = await enterMessage(tester);

      await mouse.moveTo(tester.getCenter(find.byTooltip('转发')));
      await tester.pump(const Duration(milliseconds: 240));
      expect(toolbar(), findsOneWidget);
      expect(timestamp(), findsOneWidget);

      await mouse.moveTo(const Offset(700, 550));
      await tester.pump(const Duration(milliseconds: 120));
      expect(toolbar(), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
      expect(toolbar(), findsNothing);
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    },
  );

  for (final action in [
    ('reply', '回复'),
    ('forward', '转发'),
    ('topic', '创建话题'),
    ('agent', 'Agent 协作'),
    ('more', '更多'),
  ]) {
    testWidgets(
      '${action.$1} emits exactly its message action and closes tools',
      (tester) async {
        final state = HoverFixture();
        addTearDown(state.dispose);
        final actions = <String>[];
        await mountHover(tester, state, actions);
        final mouse = await enterMessage(tester);
        await tester.tap(find.byTooltip(action.$2));
        await tester.pump();
        expect(actions, [action.$1]);
        expect(toolbar(), findsNothing);
        await mouse.moveTo(const Offset(700, 550));
        await mouse.removePointer();
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('more can open a menu anchored to the actual toolbar button', (
    tester,
  ) async {
    final state = HoverFixture();
    addTearDown(state.dispose);
    final actions = <String>[];
    final positions = <Offset>[];
    await mountHover(tester, state, actions, onOpenMore: positions.add);
    final mouse = await enterMessage(tester);
    final moreRect = tester.getRect(find.byTooltip('更多'));
    await tester.tap(find.byTooltip('更多'));
    await tester.pump();
    expect(positions, [moreRect.bottomLeft]);
    expect(actions, isEmpty);
    expect(toolbar(), findsNothing);
    await mouse.moveTo(const Offset(700, 550));
    await mouse.removePointer();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
  });

  for (final transition in ['disable', 'inactive', 'unmount']) {
    testWidgets('$transition closes an open portal without frame assertions', (
      tester,
    ) async {
      final state = HoverFixture();
      addTearDown(state.dispose);
      final actions = <String>[];
      await mountHover(tester, state, actions);
      final mouse = await enterMessage(tester);
      expect(toolbar(), findsOneWidget);
      await mountHover(
        tester,
        state,
        actions,
        enabled: transition != 'disable',
        active: transition != 'inactive',
        mounted: transition != 'unmount',
      );
      await tester.pump(const Duration(milliseconds: 220));
      expect(toolbar(), findsNothing);
      expect(timestamp(), findsNothing);
      expect(actions, isEmpty);
      expect(tester.takeException(), isNull);
      await mouse.moveTo(const Offset(700, 550));
      await mouse.removePointer();
      await tester.pump(const Duration(milliseconds: 220));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'hovering reactions opens the full picker and selects a classic emoji',
    (tester) async {
      final state = HoverFixture();
      addTearDown(state.dispose);
      final actions = <String>[];
      await tester.runAsync(
        () => rootBundle.loadString('assets/emoji/catalog.json'),
      );
      await mountHover(tester, state, actions);
      final mouse = await enterMessage(tester);
      await mouse.moveTo(tester.getCenter(find.byTooltip('表情回应')));
      await loadOpenPicker(tester);
      expect(find.byType(OfficeEmojiPicker), findsOneWidget);
      expect(find.text('最常使用'), findsOneWidget);
      expect(find.text('默认表情'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byKey(const ValueKey('emoji-open-search')));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(TextField, '搜索表情（中文 / English）'),
        findsOneWidget,
      );

      final search = find.byType(TextField);
      await mouse.moveTo(tester.getCenter(search));
      await tester.pump(const Duration(milliseconds: 240));
      expect(find.byType(OfficeEmojiPicker), findsOneWidget);
      await tester.enterText(search, 'THUMBSUP');
      await tester.pumpAndSettle();
      final emoji = find.byKey(const ValueKey('emoji-feishu:THUMBSUP'));
      expect(emoji, findsOneWidget);
      await tester.tap(emoji);
      await tester.pumpAndSettle();
      expect(actions, ['react:feishu:THUMBSUP']);
      expect(
        state.requests.map((request) => [request.$1, request.$2, request.$3]),
        [
          ['GET', '/emoji/recents', null],
          [
            'POST',
            '/emoji/recents',
            {'emoji': 'feishu:THUMBSUP'},
          ],
        ],
      );
      expect(find.byType(OfficeEmojiPicker), findsNothing);
      expect(toolbar(), findsNothing);
      await mouse.moveTo(const Offset(700, 550));
      await mouse.removePointer();
      await tester.pump(const Duration(milliseconds: 220));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unmounting with the emoji menu open leaves no overlay assertion',
    (tester) async {
      final state = HoverFixture();
      addTearDown(state.dispose);
      await tester.runAsync(
        () => rootBundle.loadString('assets/emoji/catalog.json'),
      );
      await mountHover(tester, state, []);
      final mouse = await enterMessage(tester);
      await mouse.moveTo(tester.getCenter(find.byTooltip('表情回应')));
      // Unmount while the menu and its pending catalog load are both alive.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(OfficeEmojiPicker), findsOneWidget);
      await mountHover(tester, state, [], mounted: false);
      await tester.pumpAndSettle();
      expect(find.byType(OfficeEmojiPicker), findsNothing);
      expect(toolbar(), findsNothing);
      expect(tester.takeException(), isNull);
      await mouse.removePointer();
      await tester.pump(const Duration(milliseconds: 220));
      expect(tester.takeException(), isNull);
    },
  );
}
