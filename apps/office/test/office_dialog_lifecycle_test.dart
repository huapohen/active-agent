import 'package:active_office/main.dart';
import 'package:active_office/office_state.dart';
import 'package:active_office/ui/office_dialogs.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'office_ui_test.dart' show LayoutOfficeState;

class RoomCreationOffice extends LayoutOfficeState {
  Json? created;
  @override
  Future<Json> createRoom(
    String name, {
    String description = '',
    List<String> memberIds = const [],
  }) async {
    created = {
      'id': 'created-room',
      'name': name,
      'description': description,
      'member_ids': memberIds,
      'kind': 'group',
    };
    rooms = [created!, ...rooms];
    selectedRoomId = 'created-room';
    detail = {...?detail, 'room': created!};
    notifyListeners();
    return created!;
  }
}

void main() {
  for (final save in [true, false]) {
    testWidgets(
      'Mobile room dialog ${save ? 'creates' : 'cancels'} without disposing inputs during exit',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final state = RoomCreationOffice();
        await tester.pumpWidget(ActiveOfficeApp(state: state));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('新建与添加'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('创建群组 · 人与 Agent'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == '群名称',
          ),
          'next',
        );
        await tester.enterText(
          find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == '共同目标',
          ),
          '下一阶段共同推进',
        );
        await tester.tap(find.byType(CheckboxListTile).first);
        await tester.pump();
        if (save) {
          await tester.tap(find.widgetWithText(FilledButton, '创建工作群'));
        } else {
          await tester.tap(find.text('取消'));
        }
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          tester.takeException(),
          isNull,
          reason: 'Inputs remain alive during reverse route animation',
        );
        await tester.pumpAndSettle();
        expect(find.widgetWithText(FilledButton, '创建工作群'), findsNothing);
        if (save) {
          expect(state.created?['name'], 'next');
          expect(state.created?['description'], '下一阶段共同推进');
          expect(state.created?['member_ids'], ['agent-demo']);
          expect(find.text('next'), findsWidgets);
        } else {
          expect(state.created, isNull);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
      },
    );
  }

  testWidgets(
    'Message edit returns content and survives dialog exit animation',
    (tester) async {
      String? saved;
      await tester.pumpWidget(
        MaterialApp(
          theme: officeTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async =>
                    saved = await OfficeDialogs.editText(context, '初始消息'),
                child: const Text('打开编辑'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开编辑'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '修改后的消息');
      await tester.tap(find.text('保存'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(saved, '修改后的消息');
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
