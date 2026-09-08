import 'package:active_office/enterprise_state.dart';
import 'package:active_office/ui/enterprise.dart';
import 'package:active_office/ui/enterprise_apps.dart';
import 'package:active_office/ui/enterprise_console_chrome.dart';
import 'package:active_office/ui/office_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'enterprise_ui_test.dart' show EnterpriseTestOffice;

Future<void> mountConsole(
  WidgetTester tester,
  EnterpriseTestOffice office, {
  double width = 1200,
  double scale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: OfficeEnterprise(key: ObjectKey(office), state: office),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    office.dispose();
  });
}

void main() {
  testWidgets(
    'Console navigation groups, collapse and Agent search open real destinations',
    (tester) async {
      final office = EnterpriseTestOffice(kind: 'agent');
      await mountConsole(tester, office);
      final navigation = find.byKey(
        const ValueKey('enterprise-console-navigation'),
      );
      expect(tester.getSize(navigation).width, 200);
      await tester.tap(find.byKey(const ValueKey('enterprise-nav-group-组织架构')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('enterprise-nav-1')), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('enterprise-navigation-search')),
        'Agent',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('成员与组织').last);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('enterprise-members-header')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('enterprise-nav-1')), findsOneWidget);
      expect(find.byType(DataTable), findsOneWidget);
      expect(find.text('Agent 企业所有者'), findsOneWidget);
      expect(find.text('张同学'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('enterprise-navigation-collapse')),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(navigation).width, 64);
      await tester.tap(find.byKey(const ValueKey('enterprise-nav-5')));
      await tester.pumpAndSettle();
      expect(find.byType(OfficeEnterpriseApps), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('enterprise-navigation-collapse')),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(navigation).width, 200);
      expect(office.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Navigation search cannot dispatch a captured action after identity replacement',
    (tester) async {
      final office = EnterpriseTestOffice();
      await mountConsole(tester, office);
      final navigate = tester
          .widget<EnterpriseConsoleHeader>(find.byType(EnterpriseConsoleHeader))
          .onNavigate!;
      final calls = office.calls.length;
      office.me = {'id': 'replacement', 'name': '新身份', 'kind': 'agent'};
      navigate(5);
      await tester.pumpAndSettle();
      expect(find.byType(OfficeEnterpriseApps), findsNothing);
      expect(office.calls.length, calls);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Ordinary human and Agent accounts have no enabled console search',
    (tester) async {
      for (final kind in ['human', 'agent']) {
        final office = EnterpriseTestOffice(role: 'member', kind: kind);
        await mountConsole(tester, office);
        expect(
          tester
              .widget<EnterpriseConsoleHeader>(
                find.byType(EnterpriseConsoleHeader),
              )
              .onNavigate,
          isNull,
        );
        expect(find.byType(EnterpriseConsoleNavigation), findsNothing);
        expect(office.calls, ['GET /enterprise']);
      }
    },
  );

  for (final width in [600.0, 846.0, 943.0, 1512.0]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('Console dashboard and members fit $width at $scale scale', (
        tester,
      ) async {
        final office = EnterpriseTestOffice(kind: 'agent');
        await mountConsole(tester, office, width: width, scale: scale);
        expect(
          find.byKey(const ValueKey('enterprise-overview-dashboard')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        if (width >= 760) {
          await tester.tap(find.byKey(const ValueKey('enterprise-nav-1')));
        } else {
          await tester.tap(find.widgetWithText(ChoiceChip, '成员与组织'));
        }
        await tester.pumpAndSettle();
        expect(find.textContaining('共 4 位成员'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  test('Overview counts remain server facts rather than computed from a filtered page', () async {
    final office = EnterpriseTestOffice();
    final enterprise = EnterpriseState(office);
    await enterprise.load();
    await enterprise.loadMembers(role: 'member');
    expect(enterprise.members.length, 2);
    expect(enterprise.counts['members'], 4);
    expect(enterprise.counts['agents'], 2);
    enterprise.dispose();
    office.dispose();
  });
}
