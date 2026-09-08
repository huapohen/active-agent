import 'package:active_office/ui/mobile_more_panel.dart';
import 'package:active_office/ui/mobile_more_menu.dart';
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
    'recent rows and four-column grid match the measured 402px reference',
    (tester) async {
      final recent = officeNavigationItems.sublist(7, 11);
      await mountPanel(tester, recent: recent);
      Rect box(String key) => tester.getRect(find.byKey(ValueKey(key)));
      final first = box('mobile-recent-open-calendar');
      final second = box('mobile-recent-open-mail');
      // Native screenshot review keeps the recent section above the wider grid;
      // include the menu's separate 13px handle area when comparing sheet crops.
      expect(first.left, 24);
      expect(first.top, 54);
      expect(first.width, 354);
      expect(first.height, 44);
      expect(second.top - first.bottom, 6);
      expect(box('mobile-more-recent-icon-calendar').size, const Size(22, 22));
      final icon = box('mobile-more-grid-icon-messages');
      final nextIcon = box('mobile-more-grid-icon-agents');
      expect(icon.size, const Size(48, 48));
      expect(icon.left, 32.25);
      expect(icon.top, 334);
      expect(nextIcon.center.dx - icon.center.dx, 96.5);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'sheet height follows the viewport while fitting a short parent',
    (tester) async {
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      Future<void> mount(double availableHeight) => tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(402, 874)),
            child: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                height: availableHeight,
                child: OfficeMobileMoreMenu(
                  onClose: () {},
                  child: const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      );
      await mount(713);
      final sheet = find.byKey(const ValueKey('mobile-more-sheet'));
      expect(tester.getSize(sheet).height, closeTo(874 * .64, .01));
      expect(
        tester.getSize(find.byKey(const ValueKey('mobile-more-sheet-handle'))),
        const Size(40, 4),
      );
      await mount(420);
      expect(tester.getSize(sheet).height, 420);
      expect(tester.takeException(), isNull);
    },
  );

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
