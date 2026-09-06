import 'dart:async';
import 'dart:convert';

import 'package:active_office/office_state.dart';
import 'package:active_office/ui/message_highlights.dart';
import 'package:active_office/ui/office_emoji.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class HighlightOffice extends OfficeState {
  HighlightOffice({String kind = 'human'}) {
    endpoint = 'https://highlight.invalid';
    me = {'id': 'member', 'kind': kind};
    selectedRoomId = 'r';
    connected = true;
  }
  int generation = 0;
  @override
  int get identityGeneration => generation;
  void emit() => notifyListeners();
  void changeIdentity() {
    generation++;
    emit();
  }

  final requests = <Json>[];
  Json source = {'id': 'm2', 'content': '新置顶消息', 'revision': 5};
  Json view = {
    'revision': 3,
    'items': [
      {
        'message_id': 'm1',
        'message_revision': 2,
        'set_by': 'member',
        'set_at': '2026-09-06T00:00:00Z',
        'source_status': 'current',
        'message': {'id': 'm1', 'content': '当前置顶正文', 'revision': 2},
      },
    ],
    'collapsed': false,
    'collapsed_revision': 0,
    'max_items': 1,
    'permissions': {
      'can_set': true,
      'can_clear': true,
      'basis': 'current_room_member',
    },
  };
  Completer<Json>? pendingGet, pendingPatch;
  OfficeException? failure;
  Json copy(Json value) => Json.from(jsonDecode(jsonEncode(value)) as Map);
  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    requests.add({
      'path': path,
      'method': method,
      'data': data == null ? null : copy(data),
    });
    if (path == '/rooms/r/messages/m2') return {'message': copy(source)};
    expect(
      path == '/rooms/r/highlights' ||
          path == '/rooms/r/highlights/preferences',
      isTrue,
    );
    if (method == 'GET') return pendingGet?.future ?? copy(view);
    if (pendingPatch != null) return pendingPatch!.future;
    if (failure != null) {
      final error = failure!;
      failure = null;
      throw error;
    }
    expect(method, 'PATCH');
    expect(data!['base_revision'], view['revision']);
    if (path.endsWith('/preferences')) {
      expect(data.keys.toSet(), {'base_revision', 'collapsed'});
      view['collapsed'] = data['collapsed'];
      view['collapsed_revision'] = view['revision'];
    } else {
      view['revision'] = (view['revision'] as int) + 1;
      view['collapsed'] = false;
      view['items'] = data['message_id'] == null
          ? <Json>[]
          : [
              {
                'message_id': data['message_id'],
                'message_revision': data['message_revision'],
                'set_by': 'member',
                'set_at': '2026-09-06T00:01:00Z',
                'source_status': 'current',
                'message': copy(source),
              },
            ];
    }
    return copy(view);
  }
}

Future<void> mountBanner(
  WidgetTester tester,
  HighlightOffice state, {
  ValueChanged<String>? onOpen,
  String room = 'r',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: SizedBox(
          width: 390,
          child: OfficeMessageHighlightsBanner(
            state: state,
            roomId: room,
            onOpenMessage: onOpen ?? (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> openPanel(
  WidgetTester tester,
  HighlightOffice state, {
  bool setting = false,
  ValueChanged<bool?>? onResult,
  ValueChanged<String>? onOpen,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final result = await showOfficeMessageHighlight(
                context,
                state,
                'r',
                message: setting ? {'id': 'm2', 'revision': 1} : null,
                onOpenMessage: onOpen,
              );
              onResult?.call(result);
            },
            child: const Text('打开置顶'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开置顶'));
  await tester.pumpAndSettle();
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('compact top preview renders classic emoji within two lines', (
    tester,
  ) async {
    final state = HighlightOffice();
    addTearDown(state.dispose);
    (state.view['items'] as List).first['message']['content'] =
        '已完成 :feishu:OK: ${List.filled(80, '项目进展').join(' ')}';
    await mountBanner(tester, state);
    expect(find.byType(OfficeEmojiGlyph), findsOneWidget);
    expect(find.textContaining(':feishu:OK:'), findsNothing);
    final glyph = tester.element(find.byType(OfficeEmojiGlyph));
    expect(DefaultTextStyle.of(glyph).maxLines, 2);
    expect(DefaultTextStyle.of(glyph).overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'banner opens its message and personal collapse uses top revision without touching Pin',
    (tester) async {
      final state = HighlightOffice();
      addTearDown(state.dispose);
      final opened = <String>[];
      await mountBanner(tester, state, onOpen: opened.add);
      expect(find.text('当前置顶正文'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('highlight-open-m1')));
      expect(opened, ['m1']);
      await tester.tap(
        find.byKey(const ValueKey('message-highlights-collapse')),
      );
      await tester.pumpAndSettle();
      expect(state.requests.last, {
        'path': '/rooms/r/highlights/preferences',
        'method': 'PATCH',
        'data': {'base_revision': 3, 'collapsed': true},
      });
      expect(find.text('当前置顶正文'), findsNothing);
      expect(find.byTooltip('展开置顶消息'), findsOneWidget);
      expect(state.view['revision'], 3);
      expect(
        state.requests.any((r) => (r['path'] as String).contains('/pin')),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [390.0, 1000.0]) {
    testWidgets(
      'width $width opens original once after closing only its panel',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final state = HighlightOffice();
        addTearDown(state.dispose);
        final opened = <String>[];
        final results = <bool?>[];
        await openPanel(
          tester,
          state,
          onResult: results.add,
          onOpen: opened.add,
        );
        final button = find.widgetWithText(TextButton, '查看原消息');
        await tester.ensureVisible(button);
        final retained = tester.widget<TextButton>(button).onPressed!;
        await tester.tap(button);
        retained();
        await tester.pumpAndSettle();
        expect(opened, ['m1']);
        expect(results, [false]);
        expect(find.byType(OfficeMessageHighlights), findsNothing);
        expect(find.text('打开置顶'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'new shared revision reopens only the current banner and updated source stays current',
    (tester) async {
      final state = HighlightOffice();
      addTearDown(state.dispose);
      state.view['collapsed'] = true;
      state.view['collapsed_revision'] = 3;
      await mountBanner(tester, state);
      state.view['revision'] = 4;
      state.view['collapsed'] = false;
      (state.view['items'] as List).first['source_status'] = 'updated';
      (state.view['items'] as List).first['message']['content'] = '最新消息正文';
      state.emit();
      await tester.pumpAndSettle();
      expect(find.text('最新消息正文'), findsOneWidget);
      expect(find.text('消息内容已更新'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final kind in ['human', 'agent']) {
    testWidgets('$kind sets with fresh message revision and shared top CAS', (
      tester,
    ) async {
      final state = HighlightOffice(kind: kind);
      addTearDown(state.dispose);
      final result = <bool?>[];
      await openPanel(tester, state, setting: true, onResult: result.add);
      expect(find.text('新置顶消息'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('highlight-set')));
      expect(state.requests.last, {
        'path': '/rooms/r/highlights',
        'method': 'PATCH',
        'data': {'base_revision': 3, 'message_id': 'm2', 'message_revision': 5},
      });
      expect(result, [true]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'group permission gates cancellation and authorized clear remains separate from Pin',
    (tester) async {
      final state = HighlightOffice();
      addTearDown(state.dispose);
      state.view['permissions'] = {
        'can_set': false,
        'can_clear': false,
        'basis': 'current_room_member',
      };
      await openPanel(tester, state);
      expect(find.byKey(const ValueKey('highlight-clear')), findsNothing);
      expect(find.text('当前身份没有群内置顶管理权限。'), findsOneWidget);
      state.view['permissions'] = {
        'can_set': true,
        'can_clear': true,
        'basis': 'current_room_member',
      };
      await tester.tap(find.byTooltip('刷新顶部置顶'));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const ValueKey('highlight-clear')));
      await tester.tap(find.widgetWithText(FilledButton, '取消置顶'));
      await tester.pumpAndSettle();
      expect(find.text('当前没有顶部置顶消息'), findsOneWidget);
      expect(state.requests.last, {
        'path': '/rooms/r/highlights',
        'method': 'PATCH',
        'data': {'base_revision': 3, 'message_id': null},
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a stale top mutation requires refresh before another replacement',
    (tester) async {
      final state = HighlightOffice();
      addTearDown(state.dispose);
      await openPanel(tester, state, setting: true);
      state.failure = OfficeException(409, 'conflict');
      await tapVisible(tester, find.byKey(const ValueKey('highlight-set')));
      expect(find.textContaining('已被其他成员更新'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('highlight-set')))
            .onPressed,
        isNull,
      );
      state.view['revision'] = 8;
      await tester.tap(find.byTooltip('刷新顶部置顶'));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const ValueKey('highlight-set')));
      expect((state.requests.last['data'] as Map)['base_revision'], 8);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'offline keeps a visible snapshot but disables writes and late identity data is discarded',
    (tester) async {
      final state = HighlightOffice();
      addTearDown(state.dispose);
      await mountBanner(tester, state);
      state.connected = false;
      state.emit();
      await tester.pumpAndSettle();
      expect(find.text('当前置顶正文'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('message-highlights-collapse')),
            )
            .onPressed,
        isNull,
      );
      state.connected = true;
      state.pendingGet = Completer<Json>();
      state.emit();
      await tester.pump();
      state.changeIdentity();
      await tester.pump();
      state.pendingGet!.complete(state.copy(state.view));
      await tester.pumpAndSettle();
      expect(find.text('当前置顶正文'), findsNothing);
      expect(
        find.byKey(const ValueKey('message-highlights-banner')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('hidden and retracted sources never expose stale body text', (
    tester,
  ) async {
    final state = HighlightOffice();
    addTearDown(state.dispose);
    (state.view['items'] as List).first['message']['hidden'] = true;
    await mountBanner(tester, state);
    expect(find.text('当前置顶正文'), findsNothing);
    expect(
      find.byKey(const ValueKey('message-highlights-banner')),
      findsNothing,
    );
    (state.view['items'] as List).first['message'].remove('hidden');
    (state.view['items'] as List).first['source_status'] = 'retracted';
    state.emit();
    await tester.pumpAndSettle();
    expect(find.text('这条置顶消息已撤回'), findsOneWidget);
    expect(find.text('当前置顶正文'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final scenario in [('banner', 403), ('candidate', 404)]) {
    testWidgets('${scenario.$1} clears private previews after denied PATCH', (
      tester,
    ) async {
      final state = HighlightOffice();
      addTearDown(state.dispose);
      if (scenario.$1 == 'banner') {
        await mountBanner(tester, state);
        state.failure = OfficeException(scenario.$2, '当前成员已无访问权限');
        await tester.tap(
          find.byKey(const ValueKey('message-highlights-collapse')),
        );
        await tester.pumpAndSettle();
        expect(find.text('当前置顶正文'), findsNothing);
        expect(
          find.byKey(const ValueKey('message-highlights-collapse')),
          findsNothing,
        );
      } else {
        await openPanel(tester, state, setting: true);
        expect(find.text('新置顶消息'), findsOneWidget);
        state.failure = OfficeException(scenario.$2, '来源已不可访问');
        await tapVisible(tester, find.byKey(const ValueKey('highlight-set')));
        expect(find.text('当前置顶正文'), findsNothing);
        expect(find.text('新置顶消息'), findsNothing);
        expect(find.byKey(const ValueKey('highlight-set')), findsNothing);
        await tester.tap(find.byTooltip('刷新顶部置顶'));
        await tester.pumpAndSettle();
        expect(find.text('新置顶消息'), findsOneWidget);
      }
      expect(state.requests.where((r) => r['method'] == 'PATCH').length, 1);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'retained banner never adopts another room or restores a late personal write',
    (tester) async {
      final state = HighlightOffice();
      addTearDown(state.dispose);
      await mountBanner(tester, state);
      state.pendingPatch = Completer<Json>();
      await tester.tap(
        find.byKey(const ValueKey('message-highlights-collapse')),
      );
      await tester.pump();
      state.changeIdentity();
      await tester.pump();
      state.pendingPatch!.complete(state.copy(state.view));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('message-highlights-banner')),
        findsNothing,
      );
      await mountBanner(tester, state, room: 'another-room');
      expect(
        find.byKey(const ValueKey('message-highlights-banner')),
        findsNothing,
      );
      expect(
        state.requests.any(
          (r) => (r['path'] as String).contains('another-room'),
        ),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
