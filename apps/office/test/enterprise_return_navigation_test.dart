import 'package:active_office/main.dart';
import 'package:active_office/office_state.dart';
import 'package:active_office/ui/enterprise.dart';
import 'package:active_office/ui/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'profile_navigation_test.dart' show ProfileNavigationOffice;

class ReturnOffice extends ProfileNavigationOffice {
  ReturnOffice() : super(admin: true);
  @override
  Future<Json> officeRequest(
    String path, {
    String method = 'GET',
    Json? data,
  }) async {
    if (path == '/enterprise' || path == '/enterprise/admin/overview') {
      return enterpriseSummary;
    }
    if (path.startsWith('/enterprise/admin/members')) {
      return {'members': <Json>[], 'total': 0};
    }
    if (path == '/enterprise/admin/departments') {
      return {'departments': <Json>[]};
    }
    if (path == '/enterprise/admin/roles') return {'roles': <Json>[]};
    return super.officeRequest(path, method: method, data: data);
  }
}

void main() {
  testWidgets(
    'mobile console closes to settings and settings still closes to messages',
    (tester) async {
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = ReturnOffice();
      await tester.pumpWidget(ActiveOfficeApp(state: state));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('我的与设置').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('设置').last);
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      tester
          .widget<OfficeSettings>(find.byType(OfficeSettings))
          .onEnterprise!();
      await tester.pumpAndSettle();
      expect(find.byType(OfficeEnterprise), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      await tester.tap(find.byTooltip('关闭企业管理'));
      await tester.pumpAndSettle();
      expect(find.byType(OfficeSettings), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      await tester.tap(find.byTooltip('关闭设置'));
      await tester.pumpAndSettle();
      expect(find.byType(OfficeSettings), findsNothing);
      expect(find.byType(OfficeEnterprise), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
}
