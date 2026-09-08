import 'package:active_office/ui/settings.dart';
import 'package:active_office/ui/settings_widgets.dart';
import 'package:active_office/ui/office_theme.dart' show officeTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'settings_deepening_test.dart' show SettingsFixture;

Future<void> mount(
  WidgetTester tester,
  SettingsFixture state, {
  double width = 1000,
  double scale = 1,
  int tab = -1,
  VoidCallback? close,
  VoidCallback? enterprise,
  ValueChanged<int>? openModule,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 745);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 745),
          textScaler: TextScaler.linear(scale),
        ),
        child: Scaffold(
          body: OfficeSettings(
            state: state,
            initialTab: tab,
            onClose: close,
            onEnterprise: enterprise,
            onOpenModule: openModule,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'desktop settings has one continuous document with matched chrome',
    (tester) async {
      var closed = 0;
      final state = SettingsFixture();
      await mount(tester, state, close: () => closed++);
      final account = find.byKey(const ValueKey('settings-section-0'));
      final general = find.byKey(const ValueKey('settings-section-1'));
      expect(tester.getTopLeft(account).dx, 264);
      expect(tester.getTopLeft(account).dy, 87);
      expect(tester.getTopLeft(general).dy, lessThan(480));
      expect(
        find.byKey(const ValueKey('settings-desktop-document')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('settings-section-10')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('settings-category-0'))).width,
        228,
      );
      await tester.tap(find.byTooltip('关闭设置'));
      expect(closed, 1);
      expect(state.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'category clicks scroll document anchors and manual scroll follows selection',
    (tester) async {
      final state = SettingsFixture();
      await mount(tester, state);
      final document = find.byKey(const ValueKey('settings-desktop-document'));
      final controller = tester
          .widget<SingleChildScrollView>(document)
          .controller!;
      await tester.tap(find.byKey(const ValueKey('settings-category-4')));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('settings-section-4'))).dy,
        closeTo(87, 1),
      );
      expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('settings-category-4')))
            .selected,
        true,
      );
      expect(controller.offset, greaterThan(1000));
      controller.jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('settings-category-0')))
            .selected,
        true,
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('settings-section-0'))).dy,
        87,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'security entry preserves detailed account and returns to same document',
    (tester) async {
      final state = SettingsFixture();
      await mount(tester, state);
      await tester.tap(
        find.byKey(const ValueKey('settings-account-security-entry')),
      );
      await tester.pumpAndSettle();
      expect(find.text('登录账号'), findsOneWidget);
      expect(find.text('修改账号密码'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('settings-desktop-document')),
        findsOneWidget,
      );
      expect(state.accountWrites, 0);
    },
  );

  testWidgets(
    'expired settings callbacks cannot navigate and account admin entry is permission gated',
    (tester) async {
      final state = SettingsFixture();
      var modules = 0, enterprise = 0;
      await mount(
        tester,
        state,
        enterprise: () => enterprise++,
        openModule: (_) => modules++,
      );
      final row = tester.widget<OfficeSettingsRow>(
        find.widgetWithText(OfficeSettingsRow, '打开邮箱'),
      );
      await tester.tap(
        find.byKey(const ValueKey('settings-account-security-entry')),
      );
      await tester.pumpAndSettle();
      expect(find.text('打开企业管理后台'), findsNothing);
      state.switchIdentity(same: true);
      await tester.pumpAndSettle();
      row.onTap!();
      expect(modules, 0);
      expect(enterprise, 0);
      expect(find.text('工作身份已变更，请关闭后重新打开设置。'), findsOneWidget);
      expect(state.writes, isEmpty);
    },
  );

  testWidgets(
    'resize between desktop and mobile retains selected category and anchor',
    (tester) async {
      final state = SettingsFixture();
      await mount(tester, state);
      await tester.tap(find.byKey(const ValueKey('settings-category-4')));
      await tester.pump(const Duration(milliseconds: 20));
      tester.view.physicalSize = const Size(402, 745);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-page-4')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-desktop-document')),
        findsNothing,
      );
      tester.view.physicalSize = const Size(1000, 745);
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('settings-section-4'))).dy,
        closeTo(87, 1),
      );
      expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('settings-category-4')))
            .selected,
        true,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rapid anchor selection and close discard old animations', (
    tester,
  ) async {
    final state = SettingsFixture();
    var closed = 0;
    await mount(tester, state, close: () => closed++);
    await tester.tap(find.byKey(const ValueKey('settings-category-4')));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.tap(find.byKey(const ValueKey('settings-category-1')));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('settings-section-1'))).dy,
      closeTo(87, 1),
    );
    expect(
      tester
          .widget<ListTile>(find.byKey(const ValueKey('settings-category-1')))
          .selected,
      true,
    );
    await tester.tap(find.byKey(const ValueKey('settings-category-8')));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.tap(find.byTooltip('关闭设置'));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(closed, 1);
    expect(state.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'mobile privacy shows specific reference entries without invented values or writes',
    (tester) async {
      final state = SettingsFixture();
      await mount(tester, state, width: 402, tab: 2);
      expect(find.text('添加我的方式'), findsOneWidget);
      expect(find.text('谁可直接与我单聊'), findsOneWidget);
      expect(find.text('屏蔽名单'), findsOneWidget);
      expect(find.text('0 人'), findsNothing);
      expect(find.text('中国大陆'), findsNothing);
      await tester.tap(find.text('添加我的方式'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(state.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [320.0, 402.0, 721.0, 950.0]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets(
        'settings chrome and theme previews fit width $width scale $scale',
        (tester) async {
          final state = SettingsFixture();
          await mount(tester, state, width: width, scale: scale, tab: 1);
          expect(tester.takeException(), isNull);
          if (width < 721) {
            final appearance = find.widgetWithText(OfficeSettingsRow, '外观');
            expect(tester.getSize(appearance).height, 52);
            expect(tester.getTopLeft(appearance).dy, 54);
            final time = find.byKey(const ValueKey('settings-time-format'));
            expect(tester.getSize(time).height, 52);
            expect(
              tester.widget<SwitchListTile>(time).activeTrackColor,
              const Color(0xff3370ff),
            );
            expect(find.text('24 小时制'), findsOneWidget);
            expect(find.text('例如：14:30'), findsNothing);
          }
        },
      );
    }
  }
}
