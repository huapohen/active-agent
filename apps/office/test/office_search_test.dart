import 'dart:async';
import 'dart:convert';

import 'package:active_office/main.dart';
import 'package:active_office/office_state.dart';
import 'package:active_office/ui/search_filters.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'office_ui_test.dart' show LayoutOfficeState;

class SearchTransportState extends OfficeState {
  SearchTransportState({super.client});
  @override
  Future<void> refresh() async {}
  @override
  Future<void> refreshBusiness() async {}
}

class SearchLayoutState extends LayoutOfficeState {
  final queries = <Json>[];
  String? openedRoom;
  @override
  Future<void> search(
    String query, {
    String type = 'all',
    String? roomId,
    String? authorId,
    String? after,
    String? before,
  }) async {
    queries.add({
      'q': query,
      'type': type,
      'room_id': roomId,
      'author_id': authorId,
      'after': after,
      'before': before,
    });
    searchResults = List.generate(
      25,
      (index) => {
        'id': 'message-$index',
        'type': 'message',
        'room_id': 'room-$index',
        'title': '工作结果 $index',
        'snippet': '可验证的办公内容',
      },
    );
    searchTruncated = true;
    notifyListeners();
  }

  @override
  Future<void> selectRoom(String id) async => openedRoom = id;
}

void main() {
  test(
    'Search sends encoded structural filters and preserves server truncation',
    () async {
      final requests = <http.Request>[];
      final poll = Completer<http.Response>();
      final state = SearchTransportState(
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/presence')) return poll.future;
          if (request.url.path.endsWith('/me')) {
            return http.Response(
              jsonEncode({
                'principal': {'id': 'test-member'},
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'results': [
                {'type': 'document', 'id': 'doc-1'},
              ],
              'truncated': true,
              'filters': {'type': 'document'},
            }),
            200,
          );
        }),
      );
      await state.connect('https://office.example', 'synthetic-search-token');
      await state.search(
        '计划 & 协作',
        type: 'document',
        roomId: 'room & 1',
        authorId: 'agent-1',
        after: '2026-09-05T16:00:00.000Z',
        before: '2026-09-06T16:00:00.000Z',
      );
      final request = requests.lastWhere((r) => r.url.path.endsWith('/search'));
      expect(request.url.queryParameters, {
        'q': '计划 & 协作',
        'type': 'document',
        'room_id': 'room & 1',
        'author_id': 'agent-1',
        'after': '2026-09-05T16:00:00.000Z',
        'before': '2026-09-06T16:00:00.000Z',
      });
      expect(state.searchTruncated, isTrue);
      expect(state.searchFilters['type'], 'document');
      await state.search('');
      expect(state.searchResults, isEmpty);
      expect(state.searchTruncated, isFalse);
      state.dispose();
      poll.complete(http.Response('{}', 200));
    },
  );

  test(
    'Date ranges include entire local end date and remove incompatible filters',
    () {
      final filters = OfficeSearchFilters(
        roomId: 'r',
        authorId: 'a',
        dates: DateTimeRange(
          start: DateTime(2026, 9, 5),
          end: DateTime(2026, 9, 6),
        ),
      );
      expect(DateTime.parse(filters.after!).toLocal(), DateTime(2026, 9, 5));
      expect(DateTime.parse(filters.before!).toLocal(), DateTime(2026, 9, 7));
      expect(filters.forType('mail').roomId, isNull);
      expect(filters.forType('mail').authorId, 'a');
      expect(filters.forType('agent').active, isFalse);
    },
  );

  testWidgets(
    'Global search supports shortcut, real filter request and keyboard opening',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1512, 982);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = SearchLayoutState();
      await tester.pumpWidget(ActiveOfficeApp(state: state));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      final input = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == '搜索人、Agent 和工作内容',
      );
      expect(input, findsOneWidget);
      await tester.enterText(input, '工作');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.textContaining('当前只展示部分匹配项'), findsOneWidget);
      final searchDomains = find.ancestor(
        of: find.widgetWithText(ChoiceChip, '文档'),
        matching: find.byType(ListView),
      );
      await tester.tap(
        find.descendant(
          of: searchDomains,
          matching: find.widgetWithText(ChoiceChip, '消息'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(state.queries.last['type'], 'message');
      await tester.tap(find.text('作者 / 会话 / 日期'));
      await tester.pumpAndSettle();
      final author = find.byWidgetPredicate(
        (w) =>
            w is DropdownButtonFormField<String> &&
            w.decoration.labelText == '作者 / 发起人',
      );
      await tester.tap(author);
      await tester.pumpAndSettle();
      await tester.tap(find.text('协作 Agent · Agent').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('应用筛选'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(state.queries.last['author_id'], 'agent-demo');
      await tester.tap(input);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('search-result-1')))
            .selected,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(state.openedRoom, 'room-1');
      expect(input, findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets('Mobile search filters fit and Escape closes search', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = SearchLayoutState();
    await tester.pumpWidget(ActiveOfficeApp(state: state));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    await tester.tap(find.text('作者 / 会话 / 日期'));
    await tester.pumpAndSettle();
    expect(find.text('筛选工作内容'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byTooltip('关闭搜索'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
}
