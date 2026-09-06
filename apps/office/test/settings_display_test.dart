import 'package:active_office/main.dart';
import 'package:active_office/ui/business_widgets.dart';
import 'package:active_office/ui/office_theme.dart';
import 'package:active_office/ui/profile_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'office_ui_test.dart' show LayoutOfficeState;
import 'profile_navigation_test.dart' show ProfileNavigationOffice;

void main() {
  testWidgets(
    'Time preference updates room previews and conversation timestamps',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1512, 982);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final state = LayoutOfficeState();
      final now = DateTime.now();
      final at = DateTime(now.year, now.month, now.day, 13, 7);
      final message = Map<String, dynamic>.from(state.detail!['messages'][0]);
      message['at'] = at.toUtc().toIso8601String();
      state.detail!['messages'] = [message];
      state.rooms[0]['last_message'] = message;
      state.settings = {...state.settings, 'time_format': '24h'};
      await tester.pumpWidget(ActiveOfficeApp(state: state));
      await tester.pumpAndSettle();
      expect(find.text('13:07'), findsOneWidget);
      expect(find.text('${at.month}/${at.day} 13:07'), findsOneWidget);

      state.settings = {...state.settings, 'time_format': '12h'};
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('下午 1:07'), findsOneWidget);
      expect(find.text('${at.month}/${at.day} 下午 1:07'), findsOneWidget);
      expect(find.text('13:07'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets('12-hour clock handles midnight, noon and full dates', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(alwaysUse24HourFormat: false),
          child: Builder(
            builder: (context) => Column(
              children: [
                Text(
                  officeHourMinute(
                    DateTime(2026, 9, 6, 0, 5),
                    context: context,
                  ),
                ),
                Text(
                  officeHourMinute(
                    DateTime(2026, 9, 6, 12, 5),
                    context: context,
                  ),
                ),
                Text(
                  fullOfficeTime(
                    DateTime(2026, 9, 6, 23, 59).toIso8601String(),
                    context: context,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.text('上午 12:05'), findsOneWidget);
    expect(find.text('下午 12:05'), findsOneWidget);
    expect(find.text('2026/09/06 下午 11:59'), findsOneWidget);
    expect(clockText('invalid'), isEmpty);
    expect(fullOfficeTime('invalid'), '—');
    // Callers without a widget context retain the existing 24-hour default.
    expect(officeHourMinute(DateTime(2026, 9, 6, 23, 59)), '23:59');
  });

  testWidgets(
    'An open profile clears the old identity and stays locked after switching back',
    (tester) async {
      final state = ProfileNavigationOffice(admin: true);
      final original = Map<String, dynamic>.from(state.me!);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: OfficeProfilePanel(state: state)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('编辑底栏'), findsNothing);
      expect(find.text('个人设置'), findsNothing);
      expect(find.text('设置'), findsOneWidget);
      expect(find.text(original['name']), findsOneWidget);
      state.me = {'id': 'other', 'name': '另一个身份', 'kind': 'agent'};
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text(original['name']), findsNothing);
      expect(find.text('真实协作企业'), findsNothing);
      expect(find.text('复制身份 ID'), findsNothing);
      expect(find.text('企业管理'), findsNothing);
      expect(find.text('工作身份已切换'), findsOneWidget);
      state.me = original;
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('工作身份已切换'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets(
    'Offline profile opens settings and closing returns to messages',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final state = ProfileNavigationOffice();
      await tester.pumpWidget(ActiveOfficeApp(state: state));
      await tester.pumpAndSettle();
      state.connected = false;
      state.notifyListeners();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('我的与设置').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      await tester.tap(find.byTooltip('关闭设置'));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('协作测试项目'), findsWidgets);
      expect(find.widgetWithText(ListTile, '编辑底栏'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );
}
