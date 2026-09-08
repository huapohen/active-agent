import 'package:active_office/ui/office_theme.dart';
import 'package:active_office/ui/quick_create_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('desktop profile avatar stays circular and add menu has icons', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1512, 982);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: officeTheme(),
        home: Scaffold(
          body: Stack(
            children: [
              Positioned(
                left: 24,
                top: 24,
                child: PersonAvatar(name: 'huapohen', size: 34),
              ),
              Positioned(
                left: 122,
                top: 24,
                child: OfficeQuickCreateMenu(onSelected: (_) {}),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final avatar = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(PersonAvatar),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(avatar.decoration, isA<BoxDecoration>());
    expect((avatar.decoration! as BoxDecoration).shape, BoxShape.circle);

    await tester.tap(find.byTooltip('新建与添加'));
    // One frame is enough for the short response animation to be visible.
    await tester.pump(const Duration(milliseconds: 48));
    expect(find.byKey(const ValueKey('quick-create-group')), findsOneWidget);
    final group = find.byKey(const ValueKey('quick-create-group'));
    expect(
      tester.widgetList<Icon>(
        find.descendant(of: group, matching: find.byType(Icon)),
      ),
      hasLength(1),
    );
    await tester.pumpAndSettle();
  });
}
