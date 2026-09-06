import 'dart:async';
import 'dart:convert';

import 'package:active_office/office_state.dart';
import 'package:active_office/ui/agent_message_content.dart';
import 'package:active_office/ui/emoji_assets.dart';
import 'package:active_office/ui/office_emoji.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class EmojiFixture extends OfficeState {
  EmojiFixture({String kind = 'human'}) {
    endpoint = 'https://emoji.invalid';
    me = {'id': 'test-$kind', 'kind': kind, 'name': '表情测试身份'};
    connected = true;
  }
  int generation = 0;
  List<String> recents = ['feishu:OK', '😀'];
  final requests = <Json>[];
  OfficeException? failure;
  Completer<Json>? pendingGet, pendingPost, pendingDelete;
  @override
  int get identityGeneration => generation;
  void emit() => notifyListeners();
  void changeIdentity() {
    generation++;
    emit();
  }

  Json response() => {
    'emoji_ids': [...recents],
    'entries': <Json>[],
    'limit': 32,
    'updated_at': '2026-09-06T13:20:00Z',
  };
  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    expect(path, '/emoji/recents');
    requests.add({'path': path, 'method': method, 'data': data});
    if (method == 'GET' && pendingGet != null) return pendingGet!.future;
    if (method == 'POST' && pendingPost != null) return pendingPost!.future;
    if (method == 'DELETE' && pendingDelete != null) {
      return pendingDelete!.future;
    }
    if (failure case final error?) {
      failure = null;
      throw error;
    }
    if (method == 'POST') {
      expect(data!.keys, ['emoji']);
      final id = data['emoji'] as String;
      recents = [
        id,
        ...recents.where((entry) => entry != id),
      ].take(32).toList();
    }
    if (method == 'DELETE') {
      expect(data, isNull);
      recents = [];
    }
    return response();
  }
}

Future<void> mountPicker(
  WidgetTester tester,
  EmojiFixture state,
  List<String> selected, {
  Size viewport = const Size(800, 800),
  Size box = const Size(380, 430),
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: box.width,
            height: box.height,
            child: OfficeEmojiPicker(state: state, onSelected: selected.add),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> search(WidgetTester tester, String text) async {
  if (find.byType(TextField).evaluate().isEmpty) {
    await tap(tester, find.byKey(const ValueKey('emoji-open-search')));
  }
  await tester.enterText(find.byType(TextField), text);
  await tester.pumpAndSettle();
}

Finder emoji(String id) => find.byKey(ValueKey('emoji-$id'));
Future<void> finish(WidgetTester tester) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'nonselectable message content leaves plain and emoji long presses to the parent action region',
    (tester) async {
      var presses = 0;
      for (final content in ['触摸消息', '触摸 :feishu:OK: 消息']) {
        await tester.pumpWidget(
          MaterialApp(
            theme: officeTheme(),
            home: Scaffold(
              body: GestureDetector(
                onLongPress: () => presses++,
                child: AgentMessageContent(
                  message: {
                    'author': {'kind': 'human'},
                    'content': content,
                  },
                  runs: const [],
                  onRecords: (_) {},
                  selectable: false,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(SelectableText), findsNothing);
        expect(find.byType(SelectionArea), findsNothing);
        await tester.longPress(find.byType(AgentMessageContent));
        await tester.pumpAndSettle();
      }
      expect(presses, 2);
      expect(find.byType(OfficeEmojiGlyph), findsOneWidget);
      await finish(tester);
    },
  );

  test('bundled catalog has unique IDs and all classic entries resolve to bundled PNGs', () async {
    final catalog = jsonDecode(
      await rootBundle.loadString('assets/emoji/catalog.json'),
    ) as Map;
    final entries = (catalog['entries'] as List).cast<Map>();
    expect(entries.length, 4126);
    expect(entries.map((entry) => entry['id']).toSet().length, 4126);
    final classic = entries
        .where((entry) => (entry['id'] as String).startsWith('feishu:'))
        .toList();
    expect(classic.length, 182);
    for (final entry in classic) {
      final mapped = officeClassicEmoji[entry['id']]!;
      expect(mapped.$2, entry['asset']);
      final data = await rootBundle.load(mapped.$2);
      expect(data.buffer.asUint8List(data.offsetInBytes, 8), [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
      ]);
    }
    expect(officeEmojiText('feishu:OK'), ':feishu:OK:');
    expect(officeEmojiText(':feishu:OK:'), ':feishu:OK:');
    expect(officeEmojiText('😀'), '😀');
  });

  for (final kind in ['human', 'agent']) {
    testWidgets(
      '$kind selects canonical IDs and records only personal emoji recents',
      (tester) async {
        final state = EmojiFixture(kind: kind), selected = <String>[];
        await mountPicker(tester, state, selected);
        expect(state.requests.single['method'], 'GET');
        await tap(tester, emoji('feishu:OK'));
        expect(selected, ['feishu:OK']);
        expect(state.requests.last, {
          'path': '/emoji/recents',
          'method': 'POST',
          'data': {'emoji': 'feishu:OK'},
        });
        await tap(tester, find.byKey(const ValueKey('emoji-open-recents')));
        expect(emoji('feishu:OK'), findsOneWidget);
        expect(emoji('😀'), findsOneWidget);
        await finish(tester);
      },
    );
  }

  testWidgets(
    'Chinese and English search crosses categories and full catalog grid remains lazy',
    (tester) async {
      final state = EmojiFixture(), selected = <String>[];
      await mountPicker(tester, state, selected);
      await search(tester, '点赞');
      expect(emoji('feishu:THUMBSUP'), findsOneWidget);
      await search(tester, 'grinning face');
      expect(emoji('😀'), findsOneWidget);
      expect(emoji('feishu:THUMBSUP'), findsNothing);
      await tap(tester, emoji('😀'));
      expect(selected.single, '😀');
      await tap(tester, find.byKey(const ValueKey('emoji-open-library')));
      final grid = tester.widget<SliverGrid>(
        find.byKey(const ValueKey('emoji-grid')),
      );
      expect((grid.delegate as SliverChildBuilderDelegate).childCount, 4126);
      expect(find.byType(OfficeEmojiGlyph).evaluate().length, lessThan(150));
      await finish(tester);
    },
  );

  testWidgets(
    'default view shows fourteen shortcuts and defaults in one seven-column scroll',
    (tester) async {
      final state = EmojiFixture()
        ..recents = officeClassicEmoji.keys.take(32).toList();
      final selected = <String>[];
      await mountPicker(tester, state, selected);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.text('最常使用'), findsOneWidget);
      expect(find.text('默认表情'), findsOneWidget);
      final recentGrid = tester.widget<SliverGrid>(
        find.byKey(const ValueKey('emoji-recent-shortcuts')),
      );
      final defaultGrid = tester.widget<SliverGrid>(
        find.byKey(const ValueKey('emoji-grid')),
      );
      expect(
        (recentGrid.delegate as SliverChildBuilderDelegate).childCount,
        14,
      );
      expect(
        (defaultGrid.delegate as SliverChildBuilderDelegate).childCount,
        182,
      );
      for (final grid in [recentGrid, defaultGrid]) {
        expect(
          (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
              .crossAxisCount,
          7,
        );
        expect(
          (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
              .mainAxisExtent,
          42,
        );
      }
      final shortcuts = state.recents
          .take(14)
          .map((id) => find.byKey(ValueKey('emoji-recent-$id')))
          .toList();
      final firstRow = shortcuts
          .take(7)
          .map((finder) => tester.getRect(finder))
          .toList();
      final secondRow = shortcuts
          .skip(7)
          .map((finder) => tester.getRect(finder))
          .toList();
      expect(firstRow.map((rect) => rect.top).toSet().length, 1);
      expect(secondRow.map((rect) => rect.top).toSet().length, 1);
      expect(secondRow.first.top - firstRow.first.top, 42);
      expect(
        tester.getRect(find.text('默认表情')).top,
        greaterThan(secondRow.first.bottom),
      );
      expect(
        tester.getRect(find.text('默认表情')).bottom,
        lessThan(
          tester.getRect(find.byKey(const ValueKey('emoji-fixed-footer'))).top,
        ),
      );
      expect(
        tester
            .widgetList<OfficeEmojiGlyph>(find.byType(OfficeEmojiGlyph))
            .every((glyph) => glyph.size == 28),
        isTrue,
      );
      final footerBefore = tester.getRect(
        find.byKey(const ValueKey('emoji-fixed-footer')),
      );
      await tester.drag(
        find.byKey(const ValueKey('emoji-scroll')),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('emoji-fixed-footer'))),
        footerBefore,
      );
      final scroll = tester
          .widget<CustomScrollView>(find.byKey(const ValueKey('emoji-scroll')))
          .controller!;
      expect(scroll.offset, greaterThan(100));
      expect(find.byType(OfficeEmojiGlyph).evaluate().length, lessThan(150));
      await finish(tester);
    },
  );

  testWidgets(
    'library and search keep Unicode categories and canonical code matching available',
    (tester) async {
      final state = EmojiFixture(), selected = <String>[];
      await mountPicker(tester, state, selected);
      await tap(tester, find.byKey(const ValueKey('emoji-open-library')));
      expect(find.text('表情库'), findsOneWidget);
      await tap(tester, find.widgetWithText(ChoiceChip, '旗帜'));
      final grid = tester.widget<SliverGrid>(
        find.byKey(const ValueKey('emoji-grid')),
      );
      expect(
        (grid.delegate as SliverChildBuilderDelegate).childCount,
        greaterThan(100),
      );
      expect(
        (grid.delegate as SliverChildBuilderDelegate).childCount,
        lessThan(4126),
      );
      await search(tester, 'feishu:THUMBSUP');
      expect(emoji('feishu:THUMBSUP'), findsOneWidget);
      await search(tester, '😀');
      expect(emoji('😀'), findsOneWidget);
      await tap(tester, find.byTooltip('收起搜索'));
      expect(find.byType(TextField), findsNothing);
      await tap(tester, find.byKey(const ValueKey('emoji-open-classic')));
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.text('最常使用'), findsOneWidget);
      expect(find.text('默认表情'), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets(
    'shortcut selection and management retain all thirty-two personal recents',
    (tester) async {
      final state = EmojiFixture()
        ..recents = officeClassicEmoji.keys.take(32).toList();
      final selected = <String>[];
      await mountPicker(tester, state, selected);
      final chosen = state.recents[5];
      await tap(tester, find.byKey(ValueKey('emoji-recent-$chosen')));
      expect(selected, [chosen]);
      expect(state.requests.last['data'], {'emoji': chosen});
      await tap(tester, find.byKey(const ValueKey('emoji-open-recents')));
      final grid = tester.widget<SliverGrid>(
        find.byKey(const ValueKey('emoji-grid')),
      );
      expect((grid.delegate as SliverChildBuilderDelegate).childCount, 32);
      expect(find.text('最近使用 · 32/32'), findsOneWidget);
      expect(emoji(chosen), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('emoji-open-classic')));
      final retained = tester
          .widget<InkWell>(
            find.descendant(
              of: find.byKey(ValueKey('emoji-recent-$chosen')),
              matching: find.byType(InkWell),
            ),
          )
          .onTap!;
      state.changeIdentity();
      await tester.pumpAndSettle();
      retained();
      expect(selected, [chosen]);
      expect(find.text('工作身份已变化，请重新打开表情。'), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets(
    'mobile emoji sheet drags from forty-five to eighty-five percent before scrolling',
    (tester) async {
      final state = EmojiFixture()
        ..recents = officeClassicEmoji.keys.take(14).toList();
      addTearDown(state.dispose);
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: officeTheme(),
          home: Scaffold(
            body: Column(
              children: [
                const Text('聊天仍在背景中'),
                Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showOfficeEmojiPicker(context, state),
                    child: const Text('打开选择器'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tap(tester, find.text('打开选择器'));
      final pickerFinder = find.byType(OfficeEmojiPicker);
      final initialRect = tester.getRect(pickerFinder);
      expect(initialRect.height, closeTo(800 * .45, 1));
      expect(initialRect.top, greaterThan(400));
      expect(find.text('聊天仍在背景中'), findsOneWidget);
      expect(find.text('最常使用'), findsOneWidget);
      expect(find.text('默认表情'), findsOneWidget);
      final picker = tester.widget<OfficeEmojiPicker>(pickerFinder);
      final scroll = tester.widget<CustomScrollView>(
        find.byKey(const ValueKey('emoji-scroll')),
      );
      expect(picker.scrollController, isNotNull);
      expect(scroll.controller, same(picker.scrollController));
      await tester.timedDrag(
        find.byKey(const ValueKey('emoji-drag-handle')),
        const Offset(0, -320),
        const Duration(milliseconds: 600),
      );
      await tester.pumpAndSettle();
      final expandedRect = tester.getRect(pickerFinder);
      expect(expandedRect.height, closeTo(800 * .85, 1));
      expect(expandedRect.top, closeTo(120, 1));
      final footerBefore = tester.getRect(
        find.byKey(const ValueKey('emoji-fixed-footer')),
      );
      await tester.timedDrag(
        find.byKey(const ValueKey('emoji-scroll')),
        const Offset(0, -250),
        const Duration(milliseconds: 500),
      );
      await tester.pumpAndSettle();
      expect(scroll.controller!.offset, greaterThan(100));
      expect(tester.getRect(pickerFinder), expandedRect);
      expect(
        tester.getRect(find.byKey(const ValueKey('emoji-fixed-footer'))),
        footerBefore,
      );
      expect(pickerFinder, findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('emoji-open-classic')));
      await tap(tester, find.byKey(const ValueKey('emoji-open-search')));
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byType(TextField)).bottom,
        lessThanOrEqualTo(500),
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('emoji-fixed-footer'))).bottom,
        lessThanOrEqualTo(500),
      );
      await search(tester, 'THUMBSUP');
      expect(emoji('feishu:THUMBSUP'), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets(
    'pointer hover opens a large preview without choosing or recording an emoji',
    (tester) async {
      final state = EmojiFixture(), selected = <String>[];
      await mountPicker(tester, state, selected);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1, 1));
      await mouse.moveTo(tester.getCenter(emoji('feishu:OK')));
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is OfficeEmojiGlyph &&
              widget.id == 'feishu:OK' &&
              widget.size == 54,
        ),
        findsOneWidget,
      );
      expect(selected, isEmpty);
      expect(
        state.requests.where((request) => request['method'] == 'POST'),
        isEmpty,
      );
      await mouse.removePointer();
      await finish(tester);
    },
  );

  testWidgets('older recent read cannot replace a newer chosen emoji', (
    tester,
  ) async {
    final state = EmojiFixture()..pendingGet = Completer<Json>();
    final selected = <String>[];
    await mountPicker(tester, state, selected);
    await tap(tester, emoji('feishu:THUMBSUP'));
    await tap(tester, find.byKey(const ValueKey('emoji-open-recents')));
    expect(emoji('feishu:THUMBSUP'), findsOneWidget);
    state.pendingGet!.complete({
      'emoji_ids': ['😀'],
      'entries': <Json>[],
      'limit': 32,
      'updated_at': null,
    });
    await tester.pumpAndSettle();
    expect(emoji('feishu:THUMBSUP'), findsOneWidget);
    expect(selected, ['feishu:THUMBSUP']);
    await finish(tester);
  });

  testWidgets(
    'offline still chooses local emoji while recents writes and clearing stay disabled',
    (tester) async {
      final state = EmojiFixture(), selected = <String>[];
      await mountPicker(
        tester,
        state,
        selected,
        viewport: const Size(320, 400),
        box: const Size(300, 300),
      );
      state.connected = false;
      state.emit();
      await tester.pumpAndSettle();
      final count = state.requests.length;
      await tap(tester, emoji('feishu:OK'));
      expect(selected, ['feishu:OK']);
      expect(state.requests.length, count);
      await tap(tester, find.byKey(const ValueKey('emoji-open-recents')));
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '清空最近使用'))
            .onPressed,
        isNull,
      );
      expect(find.textContaining('离线可选表情'), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets(
    'failed recent POST keeps selection and retries recording without selecting twice',
    (tester) async {
      final state = EmojiFixture(), selected = <String>[];
      await mountPicker(tester, state, selected);
      state.failure = OfficeException(503, '服务稍后恢复');
      await tap(tester, emoji('feishu:OK'));
      expect(selected, ['feishu:OK']);
      expect(find.textContaining('最近使用未同步'), findsOneWidget);
      await tap(tester, find.widgetWithText(TextButton, '重试'));
      expect(selected, ['feishu:OK']);
      expect(
        state.requests.where((request) => request['method'] == 'POST').length,
        2,
      );
      expect(find.textContaining('最近使用未同步'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'clear recents uses DELETE, preserves entries on failure, and empties only on success',
    (tester) async {
      final state = EmojiFixture(), selected = <String>[];
      await mountPicker(tester, state, selected);
      await tap(tester, find.byKey(const ValueKey('emoji-open-recents')));
      state.failure = OfficeException(503, '无法清空');
      await tap(tester, find.widgetWithText(TextButton, '清空最近使用'));
      expect(emoji('feishu:OK'), findsOneWidget);
      expect(find.textContaining('最近使用未清空'), findsOneWidget);
      await tap(tester, find.widgetWithText(TextButton, '重试'));
      expect(find.text('还没有最近使用的表情'), findsOneWidget);
      expect(
        state.requests.where((request) => request['method'] == 'DELETE').length,
        2,
      );
      expect(state.recents, isEmpty);
      expect(selected, isEmpty);
      await finish(tester);
    },
  );

  testWidgets(
    'pending clear cannot race a new selection and late result cannot restore an old identity',
    (tester) async {
      final state = EmojiFixture(), selected = <String>[];
      await mountPicker(tester, state, selected);
      await tap(tester, find.byKey(const ValueKey('emoji-open-recents')));
      state.pendingDelete = Completer<Json>();
      await tap(tester, find.widgetWithText(TextButton, '清空最近使用'));
      await tap(tester, emoji('feishu:OK'));
      expect(selected, isEmpty);
      state.changeIdentity();
      state.changeIdentity();
      await tester.pumpAndSettle();
      state.pendingDelete!.complete({
        'emoji_ids': <String>[],
        'entries': <Json>[],
        'limit': 32,
        'updated_at': null,
      });
      await tester.pumpAndSettle();
      expect(find.text('工作身份已变化，请重新打开表情。'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(emoji('feishu:OK'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'same-ID identity turnover clears query and invalidates retained emoji callbacks',
    (tester) async {
      final state = EmojiFixture()..pendingGet = Completer<Json>();
      final selected = <String>[];
      await mountPicker(tester, state, selected);
      await search(tester, '点赞');
      final controller = tester
          .widget<TextField>(find.byType(TextField))
          .controller!;
      final oldChoose = tester
          .widget<InkWell>(
            find.descendant(
              of: emoji('feishu:THUMBSUP'),
              matching: find.byType(InkWell),
            ),
          )
          .onTap!;
      state.changeIdentity();
      await tester.pumpAndSettle();
      expect(controller.text, isEmpty);
      oldChoose();
      state.pendingGet!.complete(state.response());
      await tester.pumpAndSettle();
      expect(selected, isEmpty);
      expect(state.requests.length, 1);
      expect(find.text('工作身份已变化，请重新打开表情。'), findsOneWidget);
      await finish(tester);
    },
  );

  for (final width in [390.0, 1200.0]) {
    testWidgets(
      '${width.toInt()}px modal returns the canonical ID and begins recording before it closes',
      (tester) async {
        final state = EmojiFixture();
        addTearDown(state.dispose);
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        String? selected;
        await tester.pumpWidget(
          MaterialApp(
            theme: officeTheme(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    selected = await showOfficeEmojiPicker(context, state);
                  },
                  child: const Text('打开选择器'),
                ),
              ),
            ),
          ),
        );
        await tap(tester, find.text('打开选择器'));
        await tap(tester, emoji('feishu:OK'));
        expect(selected, 'feishu:OK');
        expect(state.requests.last['method'], 'POST');
        expect(find.byType(OfficeEmojiPicker), findsNothing);
        await finish(tester);
      },
    );
  }

  testWidgets(
    'known message tokens render local glyphs while ordinary and unknown text remain selectable',
    (tester) async {
      Future<void> render(String content) => tester.pumpWidget(
        MaterialApp(
          theme: officeTheme(),
          home: Scaffold(
            body: AgentMessageContent(
              message: {
                'author': {'kind': 'human'},
                'content': content,
              },
              runs: const [],
              onRecords: (_) {},
              onAction: (_) {},
            ),
          ),
        ),
      );
      await render('普通消息 😀');
      expect(find.byType(SelectableText), findsOneWidget);
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        '普通消息 😀',
      );
      expect(
        tester
            .widget<SelectableText>(find.byType(SelectableText))
            .contextMenuBuilder,
        isNotNull,
      );
      await render('未知 :feishu:NOT_REAL: 保持原文');
      expect(find.byType(SelectableText), findsOneWidget);
      await render('做好了 :feishu:OK: 谢谢 :feishu:THANKS: 😀');
      await tester.pumpAndSettle();
      expect(find.byType(SelectionArea), findsOneWidget);
      expect(find.byType(OfficeEmojiGlyph), findsNWidgets(2));
      expect(
        tester
            .widgetList<OfficeEmojiGlyph>(find.byType(OfficeEmojiGlyph))
            .map((widget) => widget.id),
        ['feishu:OK', 'feishu:THANKS'],
      );
      final rich = tester.widget<Text>(
        find.byWidgetPredicate(
          (widget) => widget is Text && widget.textSpan != null,
        ),
      );
      expect(rich.textSpan!.toPlainText(), contains('做好了'));
      expect(rich.textSpan!.toPlainText(), contains('谢谢'));
      expect(rich.textSpan!.toPlainText(), contains('😀'));
      await finish(tester);
    },
  );
}
