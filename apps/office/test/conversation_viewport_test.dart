import 'package:active_office/office_state.dart' show OfficeConversationWindow;
import 'package:active_office/ui/conversation.dart';
import 'package:active_office/ui/office_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'office_ui_test.dart' show LayoutOfficeState;

class ViewportOffice extends LayoutOfficeState {
  ViewportOffice() {
    detail!['messages'] = List.generate(100, (i) => message(i + 21));
    detail!['has_more_messages'] = true;
    rooms.first['unread_count'] = 331;
  }
  int selection = 1, version = 1;
  bool unread = true, later = true;
  final visible = <List<int>>[];
  final visibility = <bool>[];
  Json message(int seq) => {
    'id': 'viewport-$seq',
    'seq': seq,
    'author_id': 'other',
    'author': {'name': '群聊成员', 'kind': 'human'},
    'content': '第 $seq 条协作消息。保留上下文以验证实际可见区域。',
    'at': '2026-09-06T12:00:00Z',
  };
  @override
  int get conversationSelection => selection;
  @override
  OfficeConversationWindow get conversationWindow => OfficeConversationWindow(
    roomId: 'room-demo',
    selection: selection,
    positionVersion: version,
    entryFirstUnreadSeq: 21,
    entryUnreadCount: 331,
    anchorSeq: unread ? 21 : null,
    firstUnreadSeq: 21,
    beforeCursor: unread ? 21 : 252,
    afterCursor: unread ? 120 : 351,
    hasMoreBefore: true,
    hasMoreAfter: later,
    remainingUnreadAfter: later ? 231 : 0,
    startAtUnread: unread,
  );
  @override
  Future<void> setConversationVisible(String roomId, bool value) async {
    visibility.add(value);
  }

  @override
  Future<void> reportVisibleMessageSequences(
    String roomId,
    Iterable<int> sequences, {
    required int selection,
    required int identityGeneration,
  }) async {
    visible.add(sequences.toList());
  }

  @override
  Future<void> jumpToLatestMessages() async {
    unread = false;
    later = false;
    version++;
    detail!['messages'] = List.generate(100, (i) => message(i + 252));
    notifyListeners();
  }
}

void main() {
  Future<void> host(
    WidgetTester t,
    ViewportOffice s, {
    bool active = true,
    bool mobile = false,
  }) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = mobile ? const Size(390, 844) : const Size(1000, 800);
    await t.pumpWidget(
      MaterialApp(
        theme: officeTheme(),
        home: Scaffold(
          body: AnimatedBuilder(
            animation: s,
            builder: (_, _) => TickerMode(
              enabled: active,
              child: OfficeConversation(state: s, mobile: mobile),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.pump(const Duration(milliseconds: 150));
  }

  Future<void> finish(WidgetTester t, ViewportOffice s) async {
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump(const Duration(milliseconds: 300));
    s.dispose();
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  }

  testWidgets(
    'first unread reports only viewport rectangles; scrolling adds visible sequences',
    (t) async {
      final s = ViewportOffice();
      await host(t, s);
      expect(
        find.byKey(const ValueKey('first-unread-divider')),
        findsOneWidget,
      );
      expect(find.textContaining('第 21 条协作消息'), findsOneWidget);
      final first = s.visible.expand((s) => s).toSet();
      expect(first, contains(21));
      expect(first.reduce((a, b) => a > b ? a : b), lessThan(40));
      expect(first, isNot(contains(120)));
      await t.drag(find.byType(ListView).first, const Offset(0, -450));
      await t.pumpAndSettle();
      await t.pump(const Duration(milliseconds: 150));
      expect(s.visible.last.any((seq) => !first.contains(seq)), isTrue);
      expect(t.takeException(), isNull);
      await finish(t, s);
    },
  );
  testWidgets(
    'hidden retained conversation reports nothing and resumes when shown',
    (t) async {
      final s = ViewportOffice();
      await host(t, s, active: false);
      expect(s.visible, isEmpty);
      await host(t, s);
      expect(s.visible.expand((s) => s), contains(21));
      await host(t, s, active: false);
      final count = s.visible.length;
      s.notifyListeners();
      await t.pumpAndSettle();
      await t.pump(const Duration(milliseconds: 400));
      expect(s.visible.length, count);
      await finish(t, s);
    },
  );
  testWidgets(
    'same room reentry registers selection and returns to first unread',
    (t) async {
      final s = ViewportOffice();
      await host(t, s);
      final shows = s.visibility.where((v) => v).length;
      await t.drag(find.byType(ListView).first, const Offset(0, -500));
      await t.pumpAndSettle();
      s.selection++;
      s.version++;
      s.notifyListeners();
      await t.pumpAndSettle();
      await t.pump(const Duration(milliseconds: 150));
      expect(s.visibility.where((v) => v).length, greaterThan(shows));
      expect(s.visible.last, contains(21));
      await finish(t, s);
    },
  );
  testWidgets('jump latest reports the rendered tail after positioning', (
    t,
  ) async {
    final s = ViewportOffice();
    await host(t, s);
    final before = s.visible.length;
    await t.tap(find.byKey(const ValueKey('jump-latest-messages')));
    await t.pumpAndSettle();
    await t.pump(const Duration(milliseconds: 200));
    expect(s.unread, isFalse);
    expect(
      s.visible.skip(before).expand((s) => s).every((seq) => seq >= 252),
      isTrue,
    );
    expect(s.visible.last, contains(351));
    expect(t.takeException(), isNull);
    await finish(t, s);
  });
  testWidgets(
    'mobile starts at unread and its long press panel blocks underlying receipts',
    (t) async {
      final s = ViewportOffice();
      await host(t, s, mobile: true);
      expect(
        find.byKey(const ValueKey('first-unread-divider')),
        findsOneWidget,
      );
      expect(s.visible.expand((v) => v), contains(21));
      expect(s.visible.expand((v) => v), isNot(contains(120)));
      await t.longPress(find.textContaining('第 21 条协作消息'));
      await t.pumpAndSettle();
      expect(find.text('表情回应'), findsOneWidget);
      expect(find.text('Agent 协作'), findsOneWidget);
      expect(s.visibility.last, isFalse);
      final count = s.visible.length;
      s.notifyListeners();
      await t.pumpAndSettle();
      await t.pump(const Duration(milliseconds: 200));
      expect(s.visible.length, count);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      await t.pump(const Duration(milliseconds: 150));
      expect(s.visibility.last, isTrue);
      expect(t.takeException(), isNull);
      await finish(t, s);
    },
  );
}
