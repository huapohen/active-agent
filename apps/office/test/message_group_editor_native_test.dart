import 'package:active_office/message_groups.dart';
import 'package:active_office/office_state.dart';
import 'package:active_office/ui/message_group_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'message_groups_test.dart'
    show MessageGroupOfficeFixture, groupCopy, groupSurface;

class NativeEditorFixture extends MessageGroupOfficeFixture {
  NativeEditorFixture() {
    for (final snapshot in values.values) {
      snapshot['layout_version'] = 2;
      snapshot['message_display_rules'] = <String, String>{'groups': 'unread'};
      for (final entry in {'labels': '标签', 'documents': '云文档'}.entries) {
        (snapshot['order'] as List).insert(
          entry.key == 'labels' ? 4 : 7,
          entry.key,
        );
        (snapshot['groups'] as List).add({
          'id': entry.key,
          'name': entry.value,
          'type': 'builtin',
          'visible': true,
          'available': true,
          'room_ids': <String>[],
        });
      }
    }
  }

  final layoutWrites = <Json>[];
  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    if (path == '/message-groups' && method == 'PATCH') {
      layoutWrites.add(groupCopy(data!));
      final rules = data['message_display_rules'];
      final compatible = groupCopy(data)..remove('message_display_rules');
      final result = await super.officeRequest(
        path,
        method: method,
        data: compatible,
      );
      if (rules != null) {
        values[identity]!['message_display_rules'] = Map<String, String>.from(
          rules,
        );
        result['message_display_rules'] = Map<String, String>.from(rules);
      }
      return result;
    }
    return super.officeRequest(path, method: method, data: data);
  }
}

Future<({NativeEditorFixture state, OfficeMessageGroups controller})>
openEditor(
  WidgetTester tester,
  Size size, {
  NativeEditorFixture? fixture,
}) async {
  final state = fixture ?? NativeEditorFixture();
  final controller = OfficeMessageGroups(state);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.view.resetViewInsets();
    controller.dispose();
    state.dispose();
  });
  await controller.readLatest();
  await groupSurface(
    tester,
    size,
    Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showOfficeMessageGroupEditor(context, controller),
          child: const Text('打开分组编辑'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开分组编辑'));
  await tester.pumpAndSettle();
  return (state: state, controller: controller);
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      220,
      scrollable: find
          .descendant(
            of: find.byType(OfficeMessageGroupEditor),
            matching: find.byType(Scrollable),
          )
          .first,
    );
  } else {
    await tester.ensureVisible(finder);
  }
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> setRule(WidgetTester tester, String name, String rule) async {
  await tapVisible(tester, find.byTooltip('设置$name消息展示'));
  expect(find.text('消息展示设置'), findsOneWidget);
  expect(find.text('设置“$name”下的会话在“消息”分组中的展示效果'), findsOneWidget);
  await tester.tap(find.byKey(ValueKey('display-rule-$rule')));
  await tester.tap(find.text('完成').last);
  await tester.pumpAndSettle();
}

void main() {
  for (final size in [
    const Size(320, 700),
    const Size(390, 844),
    const Size(1512, 982),
  ]) {
    testWidgets(
      '${size.width}px editor keeps native sheet actions fixed, adds Agent shortcut and cancels draft',
      (tester) async {
        final fixture = await openEditor(tester, size);
        final bounds = tester.getRect(
          find.byKey(const ValueKey('message-group-sheet-编辑分组')),
        );
        if (size.width < 760) {
          expect(bounds.left, 0);
          expect(bounds.width, size.width);
          expect(bounds.bottom, size.height);
          expect(bounds.top, greaterThan(0));
        }
        expect(find.byType(InputChip), findsNothing);
        expect(find.byType(PopupMenuButton<String>), findsNothing);
        expect(find.byTooltip('拖动消息调整顺序'), findsNothing);
        final fixed = tester.widget<IconButton>(
          find
              .ancestor(
                of: find.byTooltip('隐藏消息'),
                matching: find.byType(IconButton),
              )
              .first,
        );
        expect(fixed.onPressed, isNull);
        final savePosition = tester.getCenter(find.text('保存'));
        await tapVisible(tester, find.byTooltip('添加常用分组'));
        expect(find.text('选择常用分组'), findsOneWidget);
        await tapVisible(
          tester,
          find.byKey(const ValueKey('shortcut-choice-agents')),
        );
        expect(find.byKey(const ValueKey('shortcut-agents')), findsOneWidget);
        await tapVisible(tester, find.byTooltip('隐藏单聊'));
        expect(tester.getCenter(find.text('保存')), savePosition);
        expect(fixture.state.layoutWrites, isEmpty);
        await tester.tap(find.text('取消').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('打开分组编辑'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('shortcut-agents')), findsNothing);
        expect(find.byTooltip('隐藏单聊'), findsOneWidget);
        expect(fixture.state.layoutWrites, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final width in [320.0, 390.0]) {
    for (final entry in {
      'normal': '协作项目',
      'emoji': List.filled(20, '🚀').join(),
      'long': List.filled(40, '测').join(),
    }.entries) {
      testWidgets(
        '${width}px ${entry.key} shortcut preserves full name and removable control without overflow',
        (tester) async {
          final fixture = NativeEditorFixture();
          final snapshot = fixture.values['human-fixture']!;
          final label = (snapshot['groups'] as List).cast<Json>().firstWhere(
            (group) => group['id'] == 'label-human-fixture',
          );
          label['name'] = entry.value;
          snapshot['shortcut_ids'] = ['messages', 'label-human-fixture'];
          await openEditor(tester, Size(width, 844), fixture: fixture);
          final chip = find.byKey(
            const ValueKey('shortcut-label-human-fixture'),
          );
          final rect = tester.getRect(chip);
          expect(rect.left, greaterThanOrEqualTo(16));
          expect(rect.right, lessThanOrEqualTo(width - 16));
          if (entry.key == 'normal') expect(rect.width, lessThan(160));
          final name = find.descendant(
            of: chip,
            matching: find.text(entry.value),
          );
          expect(tester.widget<Text>(name).overflow, TextOverflow.ellipsis);
          expect(find.byTooltip(entry.value), findsOneWidget);
          final semantics = tester.ensureSemantics();
          await tester.pump();
          expect(
            tester
                .getSemantics(find.byTooltip(entry.value))
                .getSemanticsData()
                .tooltip,
            entry.value,
          );
          semantics.dispose();
          final remove = find.byTooltip('移除常用分组${entry.value}');
          expect(rect.contains(tester.getCenter(remove)), isTrue);
          await tester.tap(remove);
          await tester.pumpAndSettle();
          expect(chip, findsNothing);
          await tester.tap(find.text('保存'));
          await tester.pumpAndSettle();
          expect(fixture.layoutWrites.single['shortcut_ids'], ['messages']);
          expect(
            (fixture.values['human-fixture']!['groups'] as List).any(
              (group) => group['id'] == 'label-human-fixture',
            ),
            isTrue,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  for (final shortcut in [false, true]) {
    test(
      'hidden labels parent ${shortcut ? 'keeps shortcut child selected' : 'returns selected child to messages'}',
      () async {
        final state = NativeEditorFixture();
        final controller = OfficeMessageGroups(state);
        addTearDown(() {
          controller.dispose();
          state.dispose();
        });
        await controller.readLatest();
        controller.select('label-human-fixture');
        final snapshot = state.values['human-fixture']!;
        (snapshot['hidden_ids'] as List).add('labels');
        (snapshot['groups'] as List).cast<Json>().firstWhere(
          (group) => group['id'] == 'labels',
        )['visible'] = false;
        if (shortcut) {
          (snapshot['shortcut_ids'] as List).add('label-human-fixture');
        }
        await controller.readLatest();
        expect(
          controller.selectedId,
          shortcut ? 'label-human-fixture' : 'messages',
        );
      },
    );
  }

  for (final complete in [false, true]) {
    testWidgets(
      'inherited label ${complete ? 'completion confirms explicit always' : 'cancel preserves inheritance'} without touching a radio',
      (tester) async {
        final fixture = NativeEditorFixture();
        fixture.values['human-fixture']!['message_display_rules'] = {
          'groups': 'never',
        };
        await openEditor(tester, const Size(390, 844), fixture: fixture);
        await tapVisible(tester, find.byTooltip('设置标签消息展示'));
        final label = find.byKey(
          const ValueKey('label-display-label-human-fixture'),
        );
        expect(
          find.descendant(of: label, matching: find.text('跟随其他分组设置')),
          findsOneWidget,
        );
        await tapVisible(tester, label);
        expect(find.text('完成后应用当前选项'), findsOneWidget);
        await tester.tap(find.text(complete ? '完成' : '取消').last);
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: label,
            matching: find.text(complete ? '始终展示' : '跟随其他分组设置'),
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('完成').last);
        await tester.pumpAndSettle();
        expect(fixture.layoutWrites, isEmpty);
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(fixture.layoutWrites.single['message_display_rules'], {
          'groups': 'never',
          if (complete) 'label-human-fixture': 'always',
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'completing unchanged explicit always keeps that intent through a remote CAS change',
    (tester) async {
      final fixture = NativeEditorFixture();
      fixture.values['human-fixture']!['message_display_rules'] = {
        'groups': 'never',
        'label-human-fixture': 'always',
      };
      await openEditor(tester, const Size(390, 844), fixture: fixture);
      await tapVisible(tester, find.byTooltip('设置标签消息展示'));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('label-display-label-human-fixture')),
      );
      await tester.tap(find.text('完成').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成').last);
      await tester.pumpAndSettle();
      fixture.conflictOnce = true;
      fixture.values['human-fixture']!['message_display_rules']['label-human-fixture'] =
          'never';
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('读取最新分组'));
      await tapVisible(tester, find.text('保留我的编辑并采用新版本'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(fixture.layoutWrites.last['message_display_rules'], {
        'groups': 'never',
        'label-human-fixture': 'always',
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'gear options and nested label selections stay local until each level is completed and editor saved',
    (tester) async {
      final fixture = await openEditor(tester, const Size(390, 844));
      await setRule(tester, '单聊', 'never');
      expect(fixture.state.layoutWrites, isEmpty);
      await tapVisible(tester, find.byTooltip('设置标签消息展示'));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('label-display-label-human-fixture')),
      );
      await tester.tap(find.byKey(const ValueKey('display-rule-important')));
      await tester.tap(find.text('完成').last);
      await tester.pumpAndSettle();
      expect(find.text('有重要新消息时展示'), findsOneWidget);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byTooltip('设置标签消息展示'));
      expect(find.text('有重要新消息时展示'), findsNothing);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('label-display-label-human-fixture')),
      );
      await tester.tap(find.byKey(const ValueKey('display-rule-always')));
      await tester.tap(find.text('完成').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(fixture.state.layoutWrites.single['message_display_rules'], {
        'groups': 'unread',
        'direct': 'never',
        'label-human-fixture': 'always',
      });
      expect(
        fixture.controller.snapshot['message_display_rules'],
        fixture.state.layoutWrites.single['message_display_rules'],
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'CAS adoption preserves edited rules while merging untouched remote Agent rule',
    (tester) async {
      final fixture = await openEditor(tester, const Size(390, 844));
      await setRule(tester, '单聊', 'never');
      fixture.state.conflictOnce = true;
      fixture
              .state
              .values['human-fixture']!['message_display_rules']['agents'] =
          'important';
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('读取最新分组'));
      await tapVisible(tester, find.text('保留我的编辑并采用新版本'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(
        fixture.state.layoutWrites.map((write) => write['base_revision']),
        [7, 8],
      );
      expect(fixture.state.layoutWrites.last['message_display_rules'], {
        'groups': 'unread',
        'agents': 'important',
        'direct': 'never',
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'identity switch invalidates nested display settings before any write',
    (tester) async {
      final fixture = await openEditor(tester, const Size(390, 844));
      await tapVisible(tester, find.byTooltip('设置单聊消息展示'));
      await tester.tap(find.byKey(const ValueKey('display-rule-never')));
      fixture.state.switchIdentity('agent-fixture');
      await fixture.controller.readLatest();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('当前身份已变化'), findsWidgets);
      expect(find.text('完成'), findsNothing);
      expect(fixture.state.layoutWrites, isEmpty);
      expect(fixture.state.values['agent-fixture']!['message_display_rules'], {
        'groups': 'unread',
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'native drag handle reorders visible builtins and save retains Agent and label IDs',
    (tester) async {
      final fixture = await openEditor(tester, const Size(390, 844));
      final handle = find.byTooltip('拖动未读调整顺序');
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 150));
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, 65));
      await tester.pump(const Duration(milliseconds: 400));
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final order = List<String>.from(
        fixture.state.layoutWrites.single['order'],
      );
      expect(order.first, 'messages');
      expect(order.indexOf('marked'), lessThan(order.indexOf('unread')));
      expect(
        order,
        containsAll(['agents', 'label-human-fixture', 'labels', 'documents']),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
