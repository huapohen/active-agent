import 'package:active_office/ui/mobile_more_panel.dart';
import 'package:active_office/ui/mobile_navigation.dart';
import 'package:active_office/ui/office_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> mountPanel(
  WidgetTester tester, {
  List<OfficeNavigationItem> items = officeNavigationItems,
  List<OfficeNavigationItem> recent = const [],
  ValueChanged<OfficeNavigationItem>? onOpen,
  VoidCallback? onEdit,
  double width = 402,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width, 740);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 740),
          textScaler: TextScaler.linear(scale),
        ),
        child: Scaffold(
          body: OfficeMobileMorePanel(
            items: items,
            recentItems: recent,
            onOpen: onOpen ?? (_) {},
            onEditNavigation: onEdit ?? () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'empty history stays empty while authorized Agent and edit entries remain usable',
    (tester) async {
      final opened = <String>[];
      var edits = 0;
      await mountPanel(
        tester,
        onOpen: (item) => opened.add(item.id),
        onEdit: () => edits++,
      );
      expect(find.byKey(const ValueKey('mobile-recent-empty')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('mobile-recent-open-agents')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('mobile-more-open-agents')));
      expect(opened, ['agents']);
      await tester.tap(
        find.byKey(const ValueKey('mobile-more-edit-navigation')),
      );
      expect(edits, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'recent list uses four real unique entries in order; all and back stay within the panel',
    (tester) async {
      final history = [
        officeNavigationItems[10],
        officeNavigationItems[10],
        officeNavigationItems[9],
        officeNavigationItems[4],
        officeNavigationItems[7],
        officeNavigationItems[1],
        officeNavigationItems[2],
      ];
      final opened = <String>[];
      await mountPanel(
        tester,
        recent: history,
        onOpen: (item) => opened.add(item.id),
      );
      expect(
        find.byKey(const ValueKey('mobile-recent-open-approvals')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('mobile-recent-open-agents')),
        findsNothing,
      );
      final approvalY = tester
          .getTopLeft(
            find.byKey(const ValueKey('mobile-recent-open-approvals')),
          )
          .dy;
      final attendanceY = tester
          .getTopLeft(
            find.byKey(const ValueKey('mobile-recent-open-attendance')),
          )
          .dy;
      expect(approvalY, lessThan(attendanceY));
      await tester.tap(find.byKey(const ValueKey('mobile-recent-all')));
      await tester.pump();
      expect(find.byKey(const ValueKey('mobile-recent-back')), findsOneWidget);
      expect(find.byKey(const ValueKey('mobile-more-app-grid')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('mobile-recent-open-agents')));
      expect(opened, ['agents']);
      await tester.tap(find.byKey(const ValueKey('mobile-recent-back')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('mobile-more-app-grid')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('mobile-recent-open-agents')),
        findsNothing,
      );
    },
  );

  for (final width in [320.0, 402.0]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets(
        'more grid long names reflow at $width width and $scale text scale',
        (tester) async {
          final items = [
            for (var i = 0; i < 16; i++)
              OfficeNavigationItem('app-$i', '复杂工作应用名称第$i项', Icons.apps, i),
          ];
          await mountPanel(
            tester,
            items: items,
            recent: items.take(5).toList(),
            width: width,
            scale: scale,
          );
          expect(tester.takeException(), isNull);
          await tester.drag(
            find.byKey(const ValueKey('mobile-more-panel-scroll')),
            const Offset(0, -550),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
