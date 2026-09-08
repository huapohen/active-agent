import 'package:active_office/main.dart';
import 'package:active_office/ui/app_workbench.dart';
import 'package:active_office/ui/calendar.dart';
import 'package:active_office/ui/meetings.dart';
import 'package:active_office/ui/minutes.dart';
import 'package:active_office/ui/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'profile_navigation_test.dart' show ProfileNavigationOffice;

class CalendarMeetingNavigationOffice extends ProfileNavigationOffice {
  CalendarMeetingNavigationOffice({super.kind}) {
    settings = {
      ...settings,
      'mobile_nav': ['messages', 'calendar', 'meetings', 'workbench'],
    };
  }

  int generation = 0;
  @override
  int get identityGeneration => generation;
  void expireIdentity() {
    generation++;
    notifyListeners();
  }

  @override
  Future<void> recordWorkbenchVisit(String appId) async {}
}

void main() {
  testWidgets(
    'calendar profile card hides stale identity and rejects retained copy action',
    (tester) async {
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = CalendarMeetingNavigationOffice();
      var clipboardWrites = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clipboardWrites++;
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.pumpWidget(ActiveOfficeApp(state: state));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(NavigationDestination, '日历'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('我的与设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的个人名片'));
      await tester.pumpAndSettle();
      expect(find.text('账号：test.member'), findsOneWidget);
      final copy = tester
          .widget<TextButton>(find.widgetWithText(TextButton, '复制身份 ID'))
          .onPressed!;
      state.expireIdentity();
      await tester.pumpAndSettle();
      expect(find.text('账号：test.member'), findsNothing);
      expect(find.text('身份已改变，请关闭后重新打开个人名片。'), findsOneWidget);
      copy();
      await tester.pumpAndSettle();
      expect(clipboardWrites, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  for (final kind in ['human', 'agent']) {
    testWidgets(
      '$kind mobile calendar and meeting headers preserve profile and settings return',
      (tester) async {
        tester.view.physicalSize = const Size(402, 874);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final state = CalendarMeetingNavigationOffice(kind: kind);
        await tester.pumpWidget(ActiveOfficeApp(state: state));
        await tester.pumpAndSettle();
        for (final label in ['日历', '视频会议']) {
          await tester.tap(find.widgetWithText(NavigationDestination, label));
          await tester.pumpAndSettle();
          expect(find.byTooltip('我的与设置'), findsOneWidget);
          await tester.tap(find.byTooltip('我的与设置'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('设置').last);
          await tester.tap(find.text('设置').last);
          await tester.pumpAndSettle();
          expect(find.byType(OfficeSettings), findsOneWidget);
          await tester.tap(find.byTooltip('关闭设置'));
          await tester.pumpAndSettle();
          expect(
            find.byType(label == '日历' ? OfficeCalendar : OfficeMeetings),
            findsOneWidget,
          );
          expect(find.byTooltip('我的与设置'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        tester.widget<OfficeMeetings>(find.byType(OfficeMeetings)).onMinutes!();
        await tester.pumpAndSettle();
        expect(find.byType(OfficeMinutes), findsOneWidget);
        expect(state.minutesReads, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        state.dispose();
      },
    );
  }

  testWidgets(
    'workbench calendar closes and meeting-to-calendar returns one page',
    (tester) async {
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = CalendarMeetingNavigationOffice();
      await tester.pumpWidget(ActiveOfficeApp(state: state));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(NavigationDestination, '工作台'));
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(
              of: find.byType(OfficeAppWorkbench),
              matching: find.text('日历'),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(find.byType(OfficeCalendar), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('workbench-app-close')));
      await tester.pumpAndSettle();
      expect(find.byType(OfficeCalendar), findsNothing);
      await tester.tap(
        find
            .descendant(
              of: find.byType(OfficeAppWorkbench),
              matching: find.text('视频会议'),
            )
            .first,
      );
      await tester.pumpAndSettle();
      tester.widget<OfficeMeetings>(find.byType(OfficeMeetings)).onCalendar();
      await tester.pumpAndSettle();
      expect(find.byType(OfficeCalendar), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('workbench-app-back')));
      await tester.pumpAndSettle();
      expect(find.byType(OfficeMeetings), findsOneWidget);
      expect(find.byType(OfficeCalendar), findsNothing);
      await tester.tap(find.byKey(const ValueKey('workbench-app-close')));
      await tester.pumpAndSettle();
      expect(find.byType(OfficeMeetings), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
}
