import 'package:active_office/ui/conversation.dart';
import 'package:active_office/office_state.dart' show OfficeException;
import 'package:active_office/ui/message_actions.dart';
import 'package:active_office/ui/message_original.dart';
import 'package:active_office/ui/mentions.dart';
import 'package:active_office/ui/office_theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'office_ui_test.dart' show LayoutOfficeState;

class InteractionOffice extends LayoutOfficeState {
  final retractions = <String?>[];
  final reads = <String>[];
  bool denied = false;
  bool withdrawn = true;
  @override
  Future<void> retractMessage(Json message, {String? sourceRoomId}) async {
    retractions.add(sourceRoomId);
  }

  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    reads.add(path);
    if (denied) throw OfficeException(403, '需要当前会话成员资格');
    if (path.endsWith('/messages/parent')) {
      return {
        'message': {
          'id': 'parent',
          'content': withdrawn ? '' : '曾经可读的原文',
          'retracted_at': withdrawn ? '2026-09-06T00:00:00Z' : null,
          'author': {'name': '原名', 'display_name': '群内昵称', 'kind': 'agent'},
          'history': [],
          'attachments': [],
        },
      };
    }
    throw StateError(path);
  }
}

void size(WidgetTester t, Size size) {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('open original clears content after membership is revoked', (
    tester,
  ) async {
    final state = InteractionOffice()..withdrawn = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OfficeMessageOriginal(
            state: state,
            roomId: 'room-source',
            messageId: 'parent',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('曾经可读的原文'), findsOneWidget);
    state.denied = true;
    state.notifyListeners();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.text('曾经可读的原文'), findsNothing);
    expect(find.textContaining('需要当前会话成员资格'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  for (final mobile in [true, false]) {
    testWidgets(
      '${mobile ? 'mobile long press' : 'desktop right click'} on selectable text exposes one reply',
      (tester) async {
        size(tester, mobile ? const Size(390, 844) : const Size(1000, 800));
        final state = InteractionOffice();
        await tester.pumpWidget(
          MaterialApp(
            theme: officeTheme(),
            home: Scaffold(
              body: OfficeConversation(state: state, mobile: mobile),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final text = find.byType(SelectableText).first;
        if (mobile) {
          await tester.longPress(text);
        } else {
          final gesture = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
            buttons: kSecondaryMouseButton,
          );
          await gesture.down(tester.getCenter(text));
          await gesture.up();
        }
        await tester.pumpAndSettle();
        expect(find.text('回复'), findsOneWidget);
        await tester.tap(find.text('回复'));
        await tester.pumpAndSettle();
        expect(find.textContaining('回复 界面验证成员'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
      },
    );
  }
  testWidgets('compact landscape action sheet scrolls without clipping', (
    tester,
  ) async {
    size(tester, const Size(640, 360));
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(640, 360),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showOfficeMessageActions(context, {}, own: true),
                child: const Text('操作'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('操作'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('撤回消息'));
    await tester.pumpAndSettle();
    expect(find.text('撤回消息'), findsOneWidget);
  });

  testWidgets(
    'mobile long press opens action grid, cancel does not retract and confirm captures source room',
    (tester) async {
      size(tester, const Size(390, 844));
      final state = InteractionOffice();
      await tester.pumpWidget(
        MaterialApp(
          theme: officeTheme(),
          home: Scaffold(body: OfficeConversation(state: state, mobile: true)),
        ),
      );
      await tester.pumpAndSettle();
      final region = find.byKey(const ValueKey('message-actions-message-demo'));
      await tester.longPressAt(tester.getTopLeft(region) + const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.text('查看原文'), findsOneWidget);
      await tester.tap(find.text('撤回消息'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(state.retractions, isEmpty);
      await tester.tap(find.byTooltip('消息操作').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('撤回消息'));
      await tester.pumpAndSettle();
      state.selectedRoomId = 'room-another';
      await tester.tap(find.text('确认撤回'));
      await tester.pumpAndSettle();
      expect(state.retractions, ['room-demo']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );
  testWidgets('desktop secondary click offers ownership scoped actions', (
    tester,
  ) async {
    size(tester, const Size(1000, 800));
    String? action;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: OfficeMessageActionRegion(
                onOpen: (position) async {
                  action = await showOfficeMessageActions(
                    context,
                    {'pinned': false},
                    own: false,
                    position: position,
                  );
                },
                child: const SizedBox(
                  width: 250,
                  height: 100,
                  child: Text('伙伴消息'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final point = tester.getCenter(find.byType(OfficeMessageActionRegion));
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.down(point);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('编辑消息'), findsNothing);
    expect(find.text('撤回消息'), findsNothing);
    await tester.tap(find.text('回复'));
    await tester.pumpAndSettle();
    expect(action, 'reply');
  });
  testWidgets(
    'unloaded quoted message opens fixed source and shows withdrawal tombstone',
    (tester) async {
      final state = InteractionOffice();
      state.selectedRoomId = 'room-another';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OfficeMessageOriginal(
              state: state,
              roomId: 'room-source',
              messageId: 'parent',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(state.reads, ['/rooms/room-source/messages/parent']);
      expect(find.text('这条消息已撤回'), findsOneWidget);
      expect(find.text('群内昵称'), findsOneWidget);
      state.me = {'id': 'new-identity', 'name': '其他人'};
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('群内昵称'), findsNothing);
      expect(find.text('工作身份已切换，请重新打开原文'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );
  testWidgets(
    'mention search matches nickname while returning stable agent identity',
    (tester) async {
      OfficeMentionSelection? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  selected = await showDialog<OfficeMentionSelection>(
                    context: context,
                    builder: (_) => const OfficeMentionPicker(
                      people: [
                        {
                          'id': 'agent-stable',
                          'name': '原名',
                          'display_name': '产品负责人',
                          'kind': 'agent',
                        },
                      ],
                      selected: [],
                      mobile: false,
                      group: true,
                    ),
                  );
                },
                child: const Text('提及'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('提及'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '产品负责人');
      await tester.pumpAndSettle();
      expect(find.text('产品负责人'), findsWidgets);
      final tile = find.ancestor(
        of: find.text('产品负责人').last,
        matching: find.byType(CheckboxListTile),
      );
      if (tile.evaluate().isNotEmpty) {
        await tester.tap(tile);
      } else {
        await tester.tap(find.text('产品负责人').last);
      }
      await tester.pumpAndSettle();
      final confirm = find.textContaining('确定');
      await tester.tap(confirm.first);
      await tester.pumpAndSettle();
      expect(selected?.selectedIds, ['agent-stable']);
      expect(selected?.mentionAll, false);
    },
  );
}
