import 'package:active_office/main.dart';
import 'package:active_office/ui/message_group_widgets.dart';
import 'package:active_office/ui/message_group_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'message_groups_test.dart' show MessageGroupOfficeFixture;

Finder groupKey(String name) => find.byKey(ValueKey('message-groups-$name'));

Future<MessageGroupOfficeFixture> mountToggle(
  WidgetTester tester, {
  bool mobile = true,
}) async {
  tester.view.physicalSize = mobile
      ? const Size(390, 844)
      : const Size(1512, 982);
  tester.view.devicePixelRatio = 1;
  final state = MessageGroupOfficeFixture();
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(state.dispose);
  await tester.pumpWidget(ActiveOfficeApp(state: state));
  await tester.pumpAndSettle();
  return state;
}

Future<void> tapGroup(WidgetTester tester, String name) async {
  await tester.tap(groupKey(name));
  await tester.pumpAndSettle();
}

void main() {
  for (final mobile in [true, false]) {
    testWidgets(
      '${mobile ? 'mobile' : 'desktop'} group toggle moves to the correct header side and returns without duplicate controls',
      (tester) async {
        final state = await mountToggle(tester, mobile: mobile);
        final closed = tester.getCenter(groupKey('open'));
        if (!mobile) {
          expect(
            closed.dx,
            lessThan(
              tester
                  .getCenter(find.byKey(const ValueKey('message-list-title')))
                  .dx,
            ),
          );
        }
        for (var cycle = 0; cycle < 3; cycle++) {
          await tapGroup(tester, 'open');
          expect(groupKey('open'), findsNothing);
          expect(groupKey('close'), findsOneWidget);
          expect(find.byType(OfficeMessageGroupPanel), findsOneWidget);
          final toggle = tester.getCenter(groupKey('close'));
          final title = tester.getCenter(groupKey('title'));
          expect(toggle.dy, closeTo(title.dy, 1));
          if (mobile) {
            expect(toggle.dx, greaterThan(title.dx));
            expect(groupKey('manage'), findsNothing);
          } else {
            expect(toggle.dx, lessThan(title.dx));
            expect(groupKey('manage'), findsOneWidget);
            expect(
              tester.getCenter(groupKey('manage')).dx,
              greaterThan(title.dx),
            );
            expect(toggle.dx, closeTo(closed.dx, .1));
            expect(toggle.dy, closeTo(closed.dy, .1));
          }
          await tapGroup(tester, 'close');
          expect(find.byType(OfficeMessageGroupPanel), findsNothing);
          expect(groupKey('close'), findsNothing);
          expect(groupKey('open'), findsOneWidget);
          expect(tester.getCenter(groupKey('open')), closed);
        }
        expect(state.requests('PATCH'), isEmpty);
        expect(state.requests('POST'), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final dismissal in ['barrier', 'back', 'selection']) {
    testWidgets(
      'mobile $dismissal dismissal restores the message-side toggle',
      (tester) async {
        final state = await mountToggle(tester);
        await tapGroup(tester, 'open');
        final panel = find.byType(OfficeMessageGroupPanel);
        if (dismissal == 'barrier') {
          await tester.tapAt(const Offset(375, 150));
        } else if (dismissal == 'back') {
          await tester.binding.handlePopRoute();
        } else {
          final group = find.descendant(of: panel, matching: find.text('群聊'));
          await tester.ensureVisible(group);
          await tester.tap(group);
        }
        await tester.pumpAndSettle();
        expect(panel, findsNothing);
        expect(groupKey('open'), findsOneWidget);
        await tapGroup(tester, 'open');
        expect(groupKey('close'), findsOneWidget);
        if (dismissal == 'selection') {
          expect(
            tester.widget<OfficeMessageGroupPanel>(panel).controller.selectedId,
            'groups',
          );
        }
        expect(state.requests('PATCH'), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'desktop selecting a group keeps the toggle in the group header and preserves the filter after closing',
    (tester) async {
      final state = await mountToggle(tester, mobile: false);
      await tapGroup(tester, 'open');
      final group = find.descendant(
        of: find.byType(OfficeMessageGroupPanel),
        matching: find.text('群聊'),
      );
      await tester.ensureVisible(group);
      await tester.tap(group);
      await tester.pumpAndSettle();
      expect(groupKey('close'), findsOneWidget);
      expect(groupKey('open'), findsNothing);
      expect(find.text('人类同事单聊'), findsNothing);
      expect(find.text('人机共同项目群'), findsOneWidget);
      await tapGroup(tester, 'close');
      expect(find.text('人机共同项目群'), findsOneWidget);
      expect(find.text('人类同事单聊'), findsNothing);
      expect(state.requests('PATCH'), isEmpty);
    },
  );

  for (final mobile in [true, false]) {
    testWidgets(
      '${mobile ? 'mobile long press' : 'desktop gear'} editing can cancel back to the group header without moving its toggle',
      (tester) async {
        final state = await mountToggle(tester, mobile: mobile);
        await tapGroup(tester, 'open');
        final before = tester.getCenter(groupKey('close'));
        if (mobile) {
          await tester.longPress(groupKey('title'));
        } else {
          await tester.tap(groupKey('manage'));
        }
        await tester.pumpAndSettle();
        expect(find.byType(OfficeMessageGroupEditor), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(find.byType(OfficeMessageGroupEditor), findsNothing);
        expect(groupKey('open'), findsNothing);
        expect(tester.getCenter(groupKey('close')), before);
        expect(state.requests('PATCH'), isEmpty);
        expect(state.requests('POST'), isEmpty);
      },
    );
  }

  testWidgets(
    'desktop title right click preserves an alternate management entry',
    (tester) async {
      await mountToggle(tester, mobile: false);
      await tapGroup(tester, 'open');
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await mouse.down(tester.getCenter(groupKey('title')));
      await mouse.up();
      await mouse.removePointer();
      await tester.pumpAndSettle();
      expect(find.byType(OfficeMessageGroupEditor), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop route change and return retain the open group header location',
    (tester) async {
      await mountToggle(tester, mobile: false);
      await tapGroup(tester, 'open');
      final before = tester.getCenter(groupKey('close'));
      await tester.tap(find.byKey(const ValueKey('desktop-nav-contacts')));
      await tester.pumpAndSettle();
      expect(find.byType(OfficeMessageGroupPanel), findsNothing);
      await tester.tap(find.byKey(const ValueKey('desktop-nav-messages')));
      await tester.pumpAndSettle();
      expect(groupKey('open'), findsNothing);
      expect(tester.getCenter(groupKey('close')), before);
    },
  );

  for (final mobile in [true, false]) {
    testWidgets(
      '${mobile ? 'mobile' : 'desktop'} identity change invalidates retained group actions and restores a usable entry',
      (tester) async {
        final state = await mountToggle(tester, mobile: mobile);
        await tapGroup(tester, 'open');
        final old = tester.widget<OfficeMessageGroupPanel>(
          find.byType(OfficeMessageGroupPanel),
        );
        expect(find.text('人类私有项目'), findsOneWidget);
        state.switchIdentity('agent-fixture');
        await tester.pumpAndSettle();
        expect(find.text('人类私有项目'), findsNothing);
        old.onSelected('label-human-fixture');
        old.onManage();
        await tester.pumpAndSettle();
        expect(find.byType(OfficeMessageGroupEditor), findsNothing);
        if (mobile) {
          expect(find.text('工作身份已变化，请重新打开分组。'), findsOneWidget);
          await tester.tap(find.text('关闭'));
          await tester.pumpAndSettle();
        }
        expect(groupKey('open'), findsOneWidget);
        await tapGroup(tester, 'open');
        expect(find.text('Agent私有项目'), findsOneWidget);
        expect(
          tester
              .widget<OfficeMessageGroupPanel>(
                find.byType(OfficeMessageGroupPanel),
              )
              .controller
              .selectedId,
          'messages',
        );
        expect(state.requests('PATCH'), isEmpty);
        expect(state.requests('POST'), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'retained mobile close callbacks cannot pop an editor or a replacement drawer',
    (tester) async {
      await mountToggle(tester);
      await tapGroup(tester, 'open');
      final oldClose = tester
          .widget<OfficeMessageGroupPanel>(find.byType(OfficeMessageGroupPanel))
          .onClose!;
      await tester.longPress(groupKey('title'));
      await tester.pumpAndSettle();
      oldClose();
      await tester.pumpAndSettle();
      expect(find.byType(OfficeMessageGroupEditor), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tapGroup(tester, 'close');
      await tapGroup(tester, 'open');
      oldClose();
      await tester.pumpAndSettle();
      expect(find.byType(OfficeMessageGroupPanel), findsOneWidget);
      expect(groupKey('close'), findsOneWidget);
      expect(groupKey('open'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
