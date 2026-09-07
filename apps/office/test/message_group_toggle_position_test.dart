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
  Size? size,
  MessageGroupOfficeFixture? fixture,
}) async {
  tester.view.physicalSize =
      size ?? (mobile ? const Size(390, 844) : const Size(1512, 982));
  tester.view.devicePixelRatio = 1;
  final state = fixture ?? MessageGroupOfficeFixture();
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
  testWidgets(
    'version 2 group order controls the labels container and real document/topic filters',
    (tester) async {
      final fixture = MessageGroupOfficeFixture();
      final snapshot = fixture.values[fixture.identity]!;
      final groups = (snapshot['groups'] as List).cast<Map<String, dynamic>>();
      for (final entry in {
        'labels': '标签',
        'documents': '云文档',
        'topics': '话题',
      }.entries) {
        groups.add({
          'id': entry.key,
          'name': entry.value,
          'type': 'builtin',
          'visible': true,
          'available': true,
          'room_ids': ['room-mixed'],
          'room_count': 1,
          'unread_count': 23,
        });
      }
      snapshot['groups'] = groups;
      snapshot['layout_version'] = 2;
      snapshot['order'] = [
        'messages',
        'labels',
        'label-human-fixture',
        'unread',
        'marked',
        'mentions',
        'direct',
        'groups',
        'documents',
        'topics',
        'completed',
        'muted',
        'agents',
      ];
      await mountToggle(tester, fixture: fixture);
      await tapGroup(tester, 'open');
      final labelContainer = find.byKey(
        const ValueKey('message-group-labels-container'),
      );
      final unread = find.byKey(const ValueKey('message-group-row-unread'));
      expect(tester.getRect(labelContainer).bottom, tester.getRect(unread).top);
      expect(find.text('人类私有项目'), findsNothing);
      expect(find.text('23'), findsNothing);
      for (final entry in {'documents': '云文档', 'topics': '话题'}.entries) {
        if (find.byType(OfficeMessageGroupPanel).evaluate().isEmpty) {
          await tapGroup(tester, 'open');
        }
        final row = find.byKey(ValueKey('message-group-row-${entry.key}'));
        await tester.ensureVisible(row);
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(find.byType(OfficeMessageGroupPanel), findsNothing);
        expect(find.text('人机共同项目群'), findsOneWidget);
        expect(find.text('人类同事单聊'), findsNothing);
      }
      expect(fixture.requests('PATCH'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('hidden version 2 labels container does not leak its children', (
    tester,
  ) async {
    final fixture = MessageGroupOfficeFixture();
    final snapshot = fixture.values[fixture.identity]!;
    (snapshot['groups'] as List).add({
      'id': 'labels',
      'name': '标签',
      'type': 'builtin',
      'visible': false,
      'available': true,
      'room_ids': ['room-mixed'],
    });
    (snapshot['order'] as List).insert(4, 'labels');
    await mountToggle(tester, fixture: fixture);
    await tapGroup(tester, 'open');
    expect(groupKey('labels-toggle'), findsNothing);
    expect(find.text('人类私有项目'), findsNothing);
    expect(tester.takeException(), isNull);
  });

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
          expect(groupKey('close'), mobile ? findsNothing : findsOneWidget);
          expect(find.byType(OfficeMessageGroupPanel), findsOneWidget);
          final toggle = tester.getCenter(
            groupKey(mobile ? 'manage' : 'close'),
          );
          final title = tester.getCenter(groupKey('title'));
          expect(toggle.dy, closeTo(title.dy, 1));
          if (mobile) {
            expect(toggle.dx, greaterThan(title.dx));
            expect(groupKey('manage'), findsOneWidget);
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
          if (mobile) {
            await tapGroup(tester, 'manage');
            expect(find.byType(OfficeMessageGroupPanel), findsNothing);
            expect(find.byType(OfficeMessageGroupEditor), findsOneWidget);
            await tester.tap(find.text('取消'));
            await tester.pumpAndSettle();
          } else {
            await tapGroup(tester, 'close');
          }
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
          final group = find.descendant(of: panel, matching: find.text('群组'));
          await tester.ensureVisible(group);
          await tester.tap(group);
        }
        await tester.pumpAndSettle();
        expect(panel, findsNothing);
        expect(groupKey('open'), findsOneWidget);
        await tapGroup(tester, 'open');
        expect(groupKey('manage'), findsOneWidget);
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
        matching: find.text('群组'),
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
      '${mobile ? 'mobile long press' : 'desktop gear'} editing returns to the correct surface after cancel',
      (tester) async {
        final state = await mountToggle(tester, mobile: mobile);
        await tapGroup(tester, 'open');
        final before = tester.getCenter(groupKey(mobile ? 'manage' : 'close'));
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
        if (mobile) {
          expect(groupKey('open'), findsOneWidget);
          expect(find.byType(OfficeMessageGroupPanel), findsNothing);
          await tapGroup(tester, 'open');
        } else {
          expect(groupKey('open'), findsNothing);
        }
        expect(tester.getCenter(groupKey(mobile ? 'manage' : 'close')), before);
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
        if (mobile) {
          await tester.tap(groupKey('labels-toggle'));
          await tester.pumpAndSettle();
        }
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
        if (mobile) {
          await tester.tap(groupKey('labels-toggle'));
          await tester.pumpAndSettle();
        }
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
      final old = tester.widget<OfficeMessageGroupPanel>(
        find.byType(OfficeMessageGroupPanel),
      );
      final oldClose = old.onClose!;
      await tester.tap(groupKey('manage'));
      await tester.pumpAndSettle();
      oldClose();
      old.onManage();
      await tester.pumpAndSettle();
      expect(find.byType(OfficeMessageGroupEditor), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tapGroup(tester, 'open');
      oldClose();
      await tester.pumpAndSettle();
      expect(find.byType(OfficeMessageGroupPanel), findsOneWidget);
      expect(groupKey('manage'), findsOneWidget);
      expect(groupKey('open'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(390, 844), const Size(402, 874)]) {
    testWidgets(
      'mobile ${size.width} drawer paints all safe areas and matches the full panel rhythm',
      (tester) async {
        tester.view.padding = const FakeViewPadding(top: 62, bottom: 34);
        addTearDown(tester.view.resetPadding);
        await mountToggle(tester, size: size);
        await tapGroup(tester, 'open');
        final surface = find.byKey(
          const ValueKey('message-groups-mobile-surface'),
        );
        expect(tester.getRect(surface).top, 0);
        expect(tester.getRect(surface).bottom, size.height);
        expect(tester.getSize(surface).width, closeTo(size.width * .80, .1));
        expect(tester.widget<Material>(surface).color, Colors.white);
        expect(tester.getRect(groupKey('title')).top, greaterThanOrEqualTo(62));
        expect(tester.widget<Text>(groupKey('title')).style?.fontSize, 20);
        final first = find.byKey(const ValueKey('message-group-row-messages'));
        final unread = find.byKey(const ValueKey('message-group-row-unread'));
        expect(tester.getSize(first).height, 49);
        expect(tester.getRect(unread).top - tester.getRect(first).top, 49);
        final text = find.descendant(of: first, matching: find.text('消息'));
        expect(tester.widget<Text>(text).style?.fontSize, 17);
        expect(find.text('人类私有项目'), findsNothing);
        expect(find.byTooltip('新建标签'), findsNothing);
        await tester.tap(groupKey('labels-toggle'));
        await tester.pumpAndSettle();
        expect(find.text('人类私有项目'), findsOneWidget);
        await tester.tap(groupKey('labels-toggle'));
        await tester.pumpAndSettle();
        expect(find.text('人类私有项目'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'identity change during drawer dismissal cannot open an old editor',
    (tester) async {
      final state = await mountToggle(tester);
      await tapGroup(tester, 'open');
      await tester.tap(groupKey('manage'));
      state.switchIdentity('agent-fixture');
      await tester.pumpAndSettle();
      expect(find.byType(OfficeMessageGroupPanel), findsNothing);
      expect(find.byType(OfficeMessageGroupEditor), findsNothing);
      expect(groupKey('open'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mobile empty labels offer a visible route to create a real label',
    (tester) async {
      final fixture = MessageGroupOfficeFixture();
      final snapshot = fixture.values[fixture.identity]!;
      (snapshot['groups'] as List).removeWhere(
        (item) => item['type'] == 'label',
      );
      (snapshot['order'] as List).removeWhere(
        (id) => (id as String).startsWith('label-'),
      );
      await mountToggle(tester, fixture: fixture);
      await tapGroup(tester, 'open');
      expect(groupKey('create-label'), findsNothing);
      await tester.tap(groupKey('labels-toggle'));
      await tester.pumpAndSettle();
      expect(groupKey('create-label'), findsOneWidget);
      await tester.tap(groupKey('create-label'));
      await tester.pumpAndSettle();
      expect(find.byType(OfficeMessageGroupPanel), findsNothing);
      await tester.enterText(find.widgetWithText(TextField, '标签名称'), '共同规划');
      await tester.tap(find.text('保存标签'));
      await tester.pumpAndSettle();
      final writes = fixture.requests('POST', '/message-groups');
      expect(writes, hasLength(1));
      expect((writes.single['data'] as Map)['name'], '共同规划');
      await tapGroup(tester, 'open');
      await tester.tap(groupKey('labels-toggle'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(OfficeMessageGroupPanel),
          matching: find.text('共同规划'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
