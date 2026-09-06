import 'package:active_office/ui/office_shell.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desktop_navigation_test.dart';
import 'office_ui_test.dart' show LayoutOfficeState;

void main() {
  for (final kind in ['human', 'agent']) {
    testWidgets(
      '$kind can collapse and expand navigation through its context menu with separate CAS preference',
      (tester) async {
        final state = DesktopNavigationFixture(kind: kind);
        await mountNavigation(tester, state);
        await tapText(tester, '打开菜单');
        await tapText(tester, '收起导航栏');
        expect(state.writes.single, {
          'desktop_nav_collapsed': true,
          'base_revision': 7,
        });
        expect(state.settings['desktop_nav'], [
          'messages',
          'docs',
          'workbench',
        ]);
        await tapText(tester, '打开菜单');
        await tapText(tester, '展开导航栏');
        expect(state.writes.last, {
          'desktop_nav_collapsed': false,
          'base_revision': 8,
        });
      },
    );
  }
  testWidgets(
    'collapsed rail keeps icons and navigation editor available with no permanent editor label',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = LayoutOfficeState();
      state.settings['desktop_nav_collapsed'] = true;
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: officeTheme(),
          home: OfficeShell(state: state),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .getSize(find.byKey(const ValueKey('desktop-navigation-rail')))
            .width,
        72,
      );
      expect(find.text('更多 · 编辑导航栏'), findsNothing);
      expect(find.byTooltip('编辑导航栏'), findsOneWidget);
      expect(find.byTooltip('展开导航栏'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('desktop-nav-messages')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(
        find.byKey(const ValueKey('desktop-navigation-collapse')),
      );
      await tester.pumpAndSettle();
      expect(state.settings['desktop_nav_collapsed'], false);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('desktop-navigation-rail')))
            .width,
        180,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
