import 'dart:async';
import 'dart:convert';

import 'package:active_office/office_state.dart';
import 'package:active_office/ui/message_personal.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Json personalEntry(int seq, {String room = 'room-a', bool hidden = false}) => {
  'room_id': room,
  'room_name': '来源会话 $room',
  'message': {
    'id': 'msg-$seq',
    'seq': seq,
    'revision': 1,
    'content': '正文 $seq :feishu:SMILE:',
    'at': '2026-09-06T14:00:00Z',
    'author_id': 'author-a',
    'author': {
      'id': 'author-a',
      'name': '同事甲',
      'kind': seq.isEven ? 'agent' : 'human',
    },
    'hidden': hidden,
    'personal_preferences': {'marked': true, 'hidden': hidden},
  },
};

Json copyPersonal(Json value) =>
    Json.from(jsonDecode(jsonEncode(value)) as Map);

class PersonalFixture extends OfficeState {
  PersonalFixture({String kind = 'human', int count = 1, bool hidden = false}) {
    endpoint = 'https://personal.invalid';
    me = {'id': 'self', 'name': '本人', 'kind': kind};
    connected = true;
    selectedRoomId = 'unrelated-room';
    entries = List.generate(
      count,
      (i) => personalEntry(count - i, hidden: hidden),
    );
  }
  late List<Json> entries;
  final reads = <String>[], changes = <Json>[];
  OfficeException? readError, writeError;
  Completer<void>? holdRead, holdWrite;
  Json? malformedPage;
  int generation = 0;
  bool failRefreshAfterWrite = false;
  @override
  int get identityGeneration => generation;
  void emit() => notifyListeners();

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    expect(method, 'GET');
    expect(data, isNull);
    reads.add(path);
    if (holdRead != null) await holdRead!.future;
    if (readError != null) throw readError!;
    final uri = Uri.parse(path);
    if (uri.path == '/message-marks' || uri.path == '/hidden-messages') {
      if (malformedPage != null) return malformedPage!;
      expect(uri.queryParameters['limit'], '50');
      expect(
        uri.queryParameters.keys.toSet().difference({
          'limit',
          'before',
          'room_id',
        }),
        isEmpty,
      );
      final hidden = uri.path == '/hidden-messages';
      final before =
          int.tryParse(uri.queryParameters['before'] ?? '') ?? 999999;
      final room = uri.queryParameters['room_id'];
      final candidates = entries.where((item) {
        final m = item['message'] as Json;
        final prefs = m['personal_preferences'] as Json;
        return (room == null || room == item['room_id']) &&
            (m['seq'] as int) < before &&
            (hidden
                ? prefs['hidden'] == true
                : prefs['marked'] == true && prefs['hidden'] != true);
      }).toList();
      final chosen = candidates.take(50).map(copyPersonal).toList();
      return {
        'items': chosen,
        'has_more': candidates.length > 50,
        'next_before': candidates.length > 50
            ? (chosen.last['message'] as Json)['seq']
            : null,
      };
    }
    final messageId = uri.path.split('/').last;
    final entry = entries.firstWhere(
      (item) => (item['message'] as Json)['id'] == messageId,
    );
    return {'message': copyPersonal(entry['message'] as Json)};
  }

  @override
  Future<void> setMessagePersonal(
    String roomId,
    String messageId, {
    bool? marked,
    bool? hidden,
  }) async {
    changes.add({
      'room_id': roomId,
      'message_id': messageId,
      'marked': ?marked,
      'hidden': ?hidden,
    });
    if (holdWrite != null) await holdWrite!.future;
    if (writeError != null) throw writeError!;
    final item = entries.firstWhere(
      (item) =>
          item['room_id'] == roomId &&
          (item['message'] as Json)['id'] == messageId,
    );
    final message = item['message'] as Json,
        prefs = (item['message'] as Json)['personal_preferences'] as Json;
    if (marked != null) prefs['marked'] = marked;
    if (hidden != null) {
      prefs['hidden'] = hidden;
      message['hidden'] = hidden;
    }
    if (failRefreshAfterWrite) readError = OfficeException(503, '列表刷新失败');
    emit();
  }
}

Future<void> mountPersonal(
  WidgetTester tester,
  PersonalFixture state, {
  String? roomId,
  bool hidden = false,
  Size size = const Size(1024, 950),
  ValueChanged<Json?>? onResult,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              final result = await showOfficePersonalMessages(
                context,
                state,
                roomId: roomId,
                hidden: hidden,
              );
              onResult?.call(result);
            },
            child: const Text('打开清单'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开清单'));
  await tester.pumpAndSettle();
}

Finder changeButton(int seq, {String room = 'room-a'}) =>
    find.byKey(ValueKey('personal-message-change-$room:msg-$seq'));
Finder openButton(int seq, {String room = 'room-a'}) =>
    find.byKey(ValueKey('personal-message-open-$room:msg-$seq'));
Future<void> loadMorePersonal(WidgetTester tester) async {
  final scrollable = find.descendant(
    of: find.byKey(const ValueKey('personal-messages-list')),
    matching: find.byType(Scrollable),
  );
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('personal-messages-more')),
    500,
    scrollable: scrollable,
    maxScrolls: 60,
  );
  await tester.tap(find.byKey(const ValueKey('personal-messages-more')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Human and Agent use their own marked collection and exact unmark intent with real reload',
    (tester) async {
      for (final kind in ['human', 'agent']) {
        final state = PersonalFixture(kind: kind);
        await mountPersonal(tester, state, roomId: 'room-a');
        expect(Uri.parse(state.reads.single).queryParameters, {
          'limit': '50',
          'room_id': 'room-a',
        });
        expect(find.text('标记的消息'), findsOneWidget);
        await tester.tap(changeButton(1));
        await tester.pumpAndSettle();
        expect(state.changes, [
          {'room_id': 'room-a', 'message_id': 'msg-1', 'marked': false},
        ]);
        expect(state.reads, hasLength(2));
        expect(find.text('暂无标记消息'), findsOneWidget);
        expect(find.text('已取消标记'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        state.dispose();
      }
    },
  );

  testWidgets(
    'all-room marked selection returns a fresh source message from its own room',
    (tester) async {
      final state = PersonalFixture();
      state.entries = [personalEntry(2, room: 'room-b'), personalEntry(1)];
      Json? result;
      await mountPersonal(tester, state, onResult: (value) => result = value);
      expect(
        Uri.parse(state.reads.single).queryParameters.containsKey('room_id'),
        isFalse,
      );
      (state.entries.first['message'] as Json)['content'] = '最新正文';
      await tester.tap(openButton(2, room: 'room-b'));
      await tester.pumpAndSettle();
      expect(state.reads.last, '/rooms/room-b/messages/msg-2');
      expect(result?['room_id'], 'room-b');
      expect((result?['message'] as Json?)?['content'], '最新正文');
      expect(state.changes, isEmpty);
    },
  );

  testWidgets(
    'mobile hidden list never renders injected body history or attachment text and restores only hidden',
    (tester) async {
      final state = PersonalFixture(hidden: true);
      final message = state.entries.first['message'] as Json;
      message['content'] = '禁止显示的正文';
      message['history'] = [
        {'content': '禁止显示的历史'},
      ];
      message['attachments'] = [
        {'filename': '禁止显示的附件'},
      ];
      await mountPersonal(
        tester,
        state,
        hidden: true,
        size: const Size(430, 930),
      );
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('同事甲'), findsNothing);
      expect(find.textContaining('同事甲'), findsOneWidget);
      expect(find.textContaining('禁止显示'), findsNothing);
      expect(find.text('打开原消息'), findsNothing);
      await tester.tap(changeButton(1));
      await tester.pumpAndSettle();
      expect(state.changes, [
        {'room_id': 'room-a', 'message_id': 'msg-1', 'hidden': false},
      ]);
      expect(find.text('暂无已删除消息'), findsOneWidget);
      expect(find.text('已恢复消息'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'collection pages use returned exclusive cursor and refresh retains loaded depth',
    (tester) async {
      final state = PersonalFixture(count: 120);
      await mountPersonal(tester, state);
      await loadMorePersonal(tester);
      expect(Uri.parse(state.reads.last).queryParameters['before'], '71');
      await loadMorePersonal(tester);
      expect(Uri.parse(state.reads.last).queryParameters['before'], '21');
      expect(
        find.byKey(const ValueKey('personal-messages-more')),
        findsNothing,
      );
      final beforeRefresh = state.reads.length;
      await tester.tap(find.byKey(const ValueKey('personal-messages-refresh')));
      await tester.pumpAndSettle();
      expect(state.reads.length, beforeRefresh + 3);
      expect(
        Uri.parse(state.reads[state.reads.length - 3]).queryParameters
            .containsKey('before'),
        isFalse,
      );
      expect(Uri.parse(state.reads.last).queryParameters['before'], '21');
    },
  );

  testWidgets(
    'non-advancing pagination reports error and preserves prior items',
    (tester) async {
      final state = PersonalFixture(count: 60);
      await mountPersonal(tester, state);
      state.malformedPage = {
        'items': [personalEntry(10)],
        'has_more': true,
        'next_before': 11,
      };
      await loadMorePersonal(tester);
      expect(
        find.byKey(const ValueKey('personal-messages-error')),
        findsOneWidget,
      );
      expect(state.changes, isEmpty);
    },
  );

  testWidgets(
    'write failure preserves row and retries the same explicit false intention',
    (tester) async {
      final state = PersonalFixture(hidden: true);
      await mountPersonal(tester, state, hidden: true);
      state.writeError = OfficeException(503, '恢复失败');
      await tester.tap(changeButton(1));
      await tester.pumpAndSettle();
      expect(changeButton(1), findsOneWidget);
      expect(find.text('已恢复消息'), findsNothing);
      state.writeError = null;
      await tester.tap(changeButton(1));
      await tester.pumpAndSettle();
      expect(state.changes, hasLength(2));
      expect(state.changes.first, state.changes.last);
      expect(find.text('已恢复消息'), findsOneWidget);
    },
  );

  testWidgets(
    'successful restore followed by failed refresh distinguishes write from list result',
    (tester) async {
      final state = PersonalFixture(hidden: true);
      await mountPersonal(tester, state, hidden: true);
      state.failRefreshAfterWrite = true;
      await tester.tap(changeButton(1));
      await tester.pumpAndSettle();
      expect(find.text('已恢复消息，列表刷新失败，请重试刷新。'), findsOneWidget);
      state.readError = null;
      await tester.tap(find.text('重试刷新'));
      await tester.pumpAndSettle();
      expect(state.changes, hasLength(1));
      expect(find.text('暂无已删除消息'), findsOneWidget);
      expect(find.text('已恢复消息，列表刷新失败，请重试刷新。'), findsNothing);
    },
  );

  testWidgets(
    'source newly hidden before open returns no stale content and refreshes collection',
    (tester) async {
      final state = PersonalFixture();
      Json? selected;
      await mountPersonal(tester, state, onResult: (value) => selected = value);
      final message = state.entries.first['message'] as Json;
      message['hidden'] = true;
      (message['personal_preferences'] as Json)['hidden'] = true;
      await tester.tap(openButton(1));
      await tester.pumpAndSettle();
      expect(selected, isNull);
      expect(find.textContaining('可在已删除消息中恢复'), findsOneWidget);
      expect(openButton(1), findsNothing);
      expect(state.changes, isEmpty);
    },
  );

  testWidgets('retracted marked messages render and return only a tombstone', (
    tester,
  ) async {
    final state = PersonalFixture();
    final message = state.entries.first['message'] as Json;
    message['retracted_at'] = '2026-09-06T14:02:00Z';
    message['content'] = '撤回前正文不可复活';
    message['history'] = [
      {'content': '旧版本'},
    ];
    Json? selected;
    await mountPersonal(tester, state, onResult: (value) => selected = value);
    expect(find.text('这条消息已撤回'), findsOneWidget);
    expect(find.textContaining('不可复活'), findsNothing);
    await tester.tap(openButton(1));
    await tester.pumpAndSettle();
    expect((selected?['message'] as Json?)?['content'], '');
    expect((selected?['message'] as Json?)?.containsKey('history'), isFalse);
  });

  testWidgets(
    'offline retains rows and disables actions without any write on reconnect',
    (tester) async {
      final state = PersonalFixture();
      await mountPersonal(tester, state);
      state.connected = false;
      state.emit();
      await tester.pumpAndSettle();
      expect(tester.widget<TextButton>(changeButton(1)).onPressed, isNull);
      expect(tester.widget<TextButton>(openButton(1)).onPressed, isNull);
      state.connected = true;
      state.emit();
      await tester.pumpAndSettle();
      expect(state.changes, isEmpty);
      expect(state.reads, hasLength(2));
    },
  );

  testWidgets(
    'identity A-B-A while refresh is pending permanently clears old rows',
    (tester) async {
      final state = PersonalFixture();
      await mountPersonal(tester, state);
      state.holdRead = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('personal-messages-refresh')));
      await tester.pump();
      state.generation++;
      state.emit();
      state.generation++;
      state.emit();
      state.holdRead!.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('工作身份或查看范围已变化'), findsOneWidget);
      expect(openButton(1), findsNothing);
      expect(state.changes, isEmpty);
    },
  );

  testWidgets(
    'late restore after identity switch cannot show success in another identity',
    (tester) async {
      final state = PersonalFixture(hidden: true);
      await mountPersonal(tester, state, hidden: true);
      state.holdWrite = Completer<void>();
      await tester.tap(changeButton(1));
      await tester.pump();
      state.generation++;
      state.emit();
      state.holdWrite!.complete();
      await tester.pumpAndSettle();
      expect(find.text('已恢复消息'), findsNothing);
      expect(find.textContaining('工作身份或查看范围已变化'), findsOneWidget);
      expect(state.reads, hasLength(1));
    },
  );

  testWidgets(
    'closing pending read never closes the underlying page or applies late output',
    (tester) async {
      final state = PersonalFixture();
      await mountPersonal(tester, state);
      state.holdRead = Completer<void>();
      await tester.tap(openButton(1));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('personal-messages-close')));
      await tester.pumpAndSettle();
      state.holdRead!.complete();
      await tester.pumpAndSettle();
      expect(find.text('打开清单'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'permission failure clears stale scoped content and can be retried',
    (tester) async {
      final state = PersonalFixture();
      await mountPersonal(tester, state, roomId: 'room-a');
      state.readError = OfficeException(403, '成员权限已变化');
      await tester.tap(find.byKey(const ValueKey('personal-messages-refresh')));
      await tester.pumpAndSettle();
      expect(openButton(1), findsNothing);
      state.readError = null;
      await tester.tap(find.text('重试刷新'));
      await tester.pumpAndSettle();
      expect(openButton(1), findsOneWidget);
      expect(state.changes, isEmpty);
    },
  );

  testWidgets(
    'a filtered collection never accepts rows from another source room',
    (tester) async {
      final state = PersonalFixture();
      state.malformedPage = {
        'items': [personalEntry(2, room: 'other-room')],
        'has_more': false,
        'next_before': null,
      };
      await mountPersonal(tester, state, roomId: 'room-a');
      expect(
        find.byKey(const ValueKey('personal-messages-error')),
        findsOneWidget,
      );
      expect(find.textContaining('来源会话 other-room'), findsNothing);
      expect(state.changes, isEmpty);
    },
  );
}
