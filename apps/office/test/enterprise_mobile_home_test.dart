import 'package:active_office/ui/enterprise.dart';
import 'package:active_office/ui/office_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'enterprise_ui_test.dart' show EnterpriseTestOffice;

Future<void> mountMobileEnterprise(
  WidgetTester tester,
  EnterpriseTestOffice office, {
  double width = 390,
  double scale = 1,
  VoidCallback? onClose,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 844);
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
        body: OfficeEnterprise(state: office, onClose: onClose),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    office.dispose();
  });
}

Future<void> openMobileConsole(WidgetTester tester) async {
  final console = find.byKey(const ValueKey('enterprise-mobile-console'));
  await tester.ensureVisible(console);
  await tester.pumpAndSettle();
  await tester.tap(console);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Mobile enterprise shows factual ID, certification gap and copies the full ID',
    (tester) async {
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = call.arguments['text'] as String?;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final office = EnterpriseTestOffice(kind: 'agent');
      await mountMobileEnterprise(tester, office);
      expect(find.text('企业名称'), findsOneWidget);
      expect(find.text('企业编号'), findsOneWidget);
      expect(find.text('enterprise-workspace'), findsOneWidget);
      expect(find.text('成员与部门'), findsOneWidget);
      expect(find.text('添加企业成员'), findsOneWidget);
      expect(find.text('关联组织'), findsOneWidget);
      await tester.tap(find.text('企业编号'));
      await tester.pumpAndSettle();
      expect(copied, 'enterprise-workspace');
      await tester.tap(find.text('企业认证'));
      await tester.pumpAndSettle();
      expect(find.textContaining('尚未接入企业认证服务'), findsOneWidget);
      expect(find.text('已认证'), findsNothing);
      expect(office.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Mobile more refreshes through the real controller and close dispatches once',
    (tester) async {
      final office = EnterpriseTestOffice();
      var closed = 0;
      await mountMobileEnterprise(tester, office, onClose: () => closed++);
      final before = office.calls
          .where((call) => call == 'GET /enterprise')
          .length;
      await tester.tap(find.byTooltip('企业管理更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('刷新企业信息'));
      await tester.pumpAndSettle();
      expect(
        office.calls.where((call) => call == 'GET /enterprise').length,
        before + 1,
      );
      final close = tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.close))
          .onPressed!;
      close();
      close();
      expect(closed, 1);
      office.me = {'id': 'replacement', 'name': '新身份', 'kind': 'agent'};
      close();
      expect(closed, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [320.0, 390.0]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets(
        'Mobile home and all management destinations fit $width at $scale',
        (tester) async {
          final office = EnterpriseTestOffice();
          await mountMobileEnterprise(
            tester,
            office,
            width: width,
            scale: scale,
          );
          expect(
            find.byKey(const ValueKey('enterprise-mobile-home')),
            findsOneWidget,
          );
          final header = tester.getRect(
            find.byKey(const ValueKey('enterprise-mobile-header')),
          );
          final title = tester.getRect(
            find.byKey(const ValueKey('enterprise-mobile-title')),
          );
          final more = tester.getRect(
            find.byKey(const ValueKey('enterprise-mobile-more')),
          );
          final close = tester.getRect(
            find.byKey(const ValueKey('enterprise-mobile-close')),
          );
          expect(header.width, width);
          expect(header.height, 44);
          expect(title.center.dx, closeTo(width / 2, .1));
          expect(width - close.center.dx, closeTo(32, .1));
          expect(title.right, lessThan(more.left));
          expect(more.right, lessThanOrEqualTo(close.left));

          expect(tester.takeException(), isNull);
          await openMobileConsole(tester);
          expect(
            find.byKey(const ValueKey('enterprise-mobile-admin-menu')),
            findsOneWidget,
          );
          for (final index in [0, 1, 2, 3, 4, 5, 6]) {
            final destination = find.byKey(
              ValueKey('enterprise-mobile-destination-$index'),
            );
            await tester.ensureVisible(destination);
            await tester.pumpAndSettle();
            await tester.tap(destination);
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: 'destination $index',
            );
            await tester.tap(find.byTooltip('返回企业管理'));
            await tester.pumpAndSettle();
            await openMobileConsole(tester);
          }
          expect(office.writes, isEmpty);
        },
      );
    }
  }
}
